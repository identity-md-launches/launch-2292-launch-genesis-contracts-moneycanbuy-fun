// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";

contract RejectsEth {
    ITaskVault internal immutable vault;

    constructor(ITaskVault v) {
        vault = v;
    }

    function create() external payable returns (uint256) {
        ImdPay memory none;
        return vault.createTask{value: msg.value}(address(0), 0.01 ether, 0, "Title", "c", 0, 0, "", 0.001 ether, none);
    }

    function withdrawTo(address to) external {
        vault.withdrawTo(address(0), to);
    }

    receive() external payable {
        revert("no ETH");
    }
}

/// @dev A disputer contract that tries to re-enter the vault when it receives ETH.
contract ReentrantDisputer {
    ITaskVault internal immutable vault;
    uint256 public subId;
    bool public reentered;

    constructor(ITaskVault v) {
        vault = v;
    }

    function approveImd(address imd) external {
        (bool ok,) = imd.call(abi.encodeWithSignature("approve(address,uint256)", address(vault), type(uint256).max));
        require(ok);
    }

    function dispute(uint256 s) external payable {
        subId = s;
        ImdPay memory none;
        vault.dispute{value: msg.value}(s, "r", msg.value, none);
    }

    function claim() external {
        vault.claimDisputer(subId);
    }

    receive() external payable {
        // any re-entry must fail; the vault then keeps the ETH as a credit
        try vault.claimDisputer(subId) {
            reentered = true;
        } catch {}
        try vault.withdraw(address(0)) {
            reentered = true;
        } catch {}
        revert("take it as credit");
    }
}

/// @dev Payment mode A (swap adapter), refunds, credits, blocked receivers, treasury sweep.
contract PaymentsTest is Base {
    function test_ModeA_SubmitWithEth_SurplusAndExcessRefunded() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 imdBefore = imd.balanceOf(doer);
        uint256 ethBefore = doer.balance;
        ImdPay memory pay = ImdPay({
            tokenIn: ETH,
            amountIn: 0.01 ether, // 3.125 IMD
            minImdOut: 1e18,
            deadline: uint64(_now() + 600),
            route: hex"01"
        });
        vm.prank(doer);
        uint256 s =
            vault.submit{value: 0.05 ether}(t, "https://x.com/doer/status/1", _noEvidence(), 0, type(uint256).max, pay);
        assertEq(_sub(s).bond, 1e18);
        assertEq(doer.balance, ethBefore - 0.01 ether); // excess 0.04 back
        assertEq(imd.balanceOf(doer) - imdBefore, 2.125e18); // surplus IMD back
        assertEq(vault.liabilities(address(imd)), 1e18);
        _assertSolvent();
        _claimEverythingAndCheck();
    }

    function test_ModeA_DisputeWithUsdc() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        ImdPay memory pay = ImdPay({
            tokenIn: address(usdc),
            amountIn: 10e6, // 1.25 IMD
            minImdOut: 1e18,
            deadline: uint64(_now() + 600),
            route: ""
        });
        uint256 usdcBefore = usdc.balanceOf(dave);
        vm.prank(dave);
        vault.dispute{value: 0.001 ether}(s, "r", 0.001 ether, pay);
        assertEq(usdcBefore - usdc.balanceOf(dave), 10e6);
        assertEq(imd.balanceOf(dave), 10_000e18 + 0.25e18);
        assertEq(usdc.allowance(address(vault), address(adapter)), 0);
        _claimEverythingAndCheck();
    }

    function test_ModeA_CreateImdTaskWithEth() public {
        ImdPay memory pay = ImdPay({
            tokenIn: ETH,
            amountIn: 0.02 ether, // 6.25 IMD
            minImdOut: 5e18,
            deadline: uint64(_now() + 600),
            route: ""
        });
        vm.prank(author);
        uint256 t =
            vault.createTask{value: 0.021 ether}(address(imd), 5e18, 0, "Title", "c", 0, 0, "", 0.001 ether, pay);
        trackedTasks.push(t);
        assertEq(vault.getTask(t).pot, 5e18);
        assertEq(imd.balanceOf(author), 10_000e18 + 1.25e18);
        _claimEverythingAndCheck();
    }

    function test_ModeA_Reverts() public {
        uint256 t = _create(author, address(usdc), 100e6);
        ImdPay memory pay =
            ImdPay({tokenIn: ETH, amountIn: 0.001 ether, minImdOut: 0.3e18, deadline: uint64(_now() + 600), route: ""});
        vm.startPrank(doer);
        vm.expectRevert(SwapShort.selector); // user minOut below the bond
        vault.submit{value: 0.001 ether}(t, "https://x.com/doer/status/1", _noEvidence(), 0, type(uint256).max, pay);
        pay.minImdOut = 1e18;
        vm.expectRevert("minOut"); // the adapter cannot deliver 1 IMD for 0.001 ETH (0.3125)
        vault.submit{value: 0.001 ether}(t, "https://x.com/doer/status/1", _noEvidence(), 0, type(uint256).max, pay);
        pay.amountIn = 0.01 ether;
        pay.deadline = uint64(_now() - 1);
        vm.expectRevert(SwapExpired.selector);
        vault.submit{value: 0.01 ether}(t, "https://x.com/doer/status/1", _noEvidence(), 0, type(uint256).max, pay);
        pay.deadline = uint64(_now() + 600);
        vm.expectRevert(NotEnoughEth.selector);
        vault.submit{value: 0.005 ether}(t, "https://x.com/doer/status/1", _noEvidence(), 0, type(uint256).max, pay);
        pay.tokenIn = address(nft);
        vm.expectRevert(BadCurrency.selector);
        vault.submit(t, "https://x.com/doer/status/1", _noEvidence(), 0, type(uint256).max, pay);
        vm.stopPrank();
    }

    function test_ModeA_Disabled() public {
        Params memory p = defaultParams();
        p.swapAdapter = address(0);
        vm.prank(owner);
        registry.proposeParams(p);
        _warp(48 hours);
        registry.activateParams();
        uint256 t = _create(author, address(usdc), 100e6);
        ImdPay memory pay =
            ImdPay({tokenIn: ETH, amountIn: 0.01 ether, minImdOut: 1e18, deadline: uint64(_now() + 600), route: ""});
        vm.prank(doer);
        vm.expectRevert(SwapDisabled.selector);
        vault.submit{value: 0.01 ether}(t, "https://x.com/doer/status/1", _noEvidence(), 0, type(uint256).max, pay);
        _submit(doer, t); // mode B still works
    }

    function test_EthRefundToRejectingContract_IsCredited() public {
        RejectsEth c = new RejectsEth(vault);
        vm.deal(address(c), 1 ether);
        uint256 t = c.create{value: 0.5 ether}(); // excess 0.489 cannot be pushed back
        trackedTasks.push(t);
        assertEq(vault.credits(ETH, address(c)), 0.489 ether);
        _assertSolvent();
        address to = makeAddr("sink");
        c.withdrawTo(to);
        assertEq(to.balance, 0.489 ether);
    }

    function test_BlockedReceiver_PaidAsCredit() public {
        uint256 t = _create(author, address(usdc), 100e6);
        _topUp(alice, t, 50e6);
        usdc.setBlocked(alice, true);
        _announceWithdraw(alice, t);
        vm.prank(alice);
        vault.withdrawContribution(t); // transfer fails -> credited, no revert
        assertEq(vault.credits(address(usdc), alice), 50e6);
        vm.prank(alice);
        vm.expectRevert(TransferFailed.selector);
        vault.withdraw(address(usdc));
        address fresh = makeAddr("fresh");
        vm.prank(alice);
        vault.withdrawTo(address(usdc), fresh);
        assertEq(usdc.balanceOf(fresh), 50e6);
        // a blocked doer does not block the task's settlement
        usdc.setBlocked(doer, true);
        _submit(doer, t);
        _warp(24 hours);
        vault.poke(t);
        assertEq(vault.credits(address(usdc), doer), 90e6);
        _assertSolvent();
    }

    function test_TreasurySweep_TakesEverything() public {
        uint256 t = _create(author, address(imd), 200e18); // large IMD task
        uint256 s = _submit(doer, t);
        _answer(s, true);
        _warp(24 hours);
        vault.poke(t);
        // fee 20 IMD, all to the single treasury; the check fee is not taken out of it
        assertEq(vault.treasuryPot(address(imd)), 20e18);
        vault.sweepTreasury(address(imd));
        assertEq(vault.treasuryPot(address(imd)), 0); // nothing kept back: the treasury pays for nothing
        assertEq(vault.credits(address(imd), treasury), 20e18);
        vault.sweepTreasury(ETH);
        assertEq(vault.credits(ETH, treasury), 0.001 ether); // the author fee
        _claimEverythingAndCheck();
    }

    function test_ModeA_CallSwarmWithEth() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        _warp(24 hours);
        ImdPay memory pay = ImdPay({
            tokenIn: ETH,
            amountIn: 0.005 ether, // 1.5625 IMD for bond 1 + fee 0.5
            minImdOut: 1.5e18,
            deadline: uint64(_now() + 600),
            route: ""
        });
        uint256 ethBefore = erin.balance;
        vm.prank(erin);
        vault.callSwarm{value: 0.01 ether}(s, false, "ipfs://caller-reason", type(uint256).max, pay);
        assertEq(ethBefore - erin.balance, 0.005 ether);
        assertEq(imd.balanceOf(erin), 10_000e18 + 0.0625e18); // surplus IMD back
        assertEq(uint8(_phase(s)), uint8(Phase.Asked));
        _claimEverythingAndCheck();
    }

    function test_ReentrancyOnEthPayout_BlockedAndCredited() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        ReentrantDisputer r = new ReentrantDisputer(vault);
        imd.mint(address(r), 10e18);
        r.approveImd(address(imd));
        vm.deal(address(this), 1 ether);
        r.dispute{value: 0.001 ether}(s);
        _vote(s, 1, 2, 120, 20);
        _warp(48 hours);
        vault.poke(t);
        r.claim();
        assertFalse(r.reentered());
        assertEq(vault.credits(ETH, address(r)), 0.001 ether); // ETH leftover kept as credit
        assertEq(imd.balanceOf(address(r)), 10e18 + 0.5e18); // bond back + half of the doer bond, paid directly
        _assertSolvent();
    }

    function test_TopUpHasNoFee() public {
        uint256 t = _create(author, address(usdc), 100e6);
        vm.prank(alice);
        vault.topUp(t, 10e6, _noSwap()); // no ETH needed: contributors pay no fee
        assertEq(vault.treasuryPot(ETH), 0.001 ether); // only the author fee
        _claimEverythingAndCheck();
    }
}
