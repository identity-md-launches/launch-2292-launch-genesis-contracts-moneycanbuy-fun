// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../Base.t.sol";
import {AskTerms, Facts} from "../../src/desks/DeskApi.sol";
import {LaunchPlan, LocalFactory} from "../../script/LaunchPlan.sol";

/// @dev The core split into vault + two desks: who may call what.
///      `test_Fixed_*` check the rule that closes a weakness (described above each); `test_Guard_*` are regression
///      protection for what holds.

interface IWire {
    function wire(address registry, address imd, address usdc, address caseDesk, address disputeDesk) external;
}

/// @dev "Vault" an attacker launches at index 2 of a front-run LocalFactory launch: wires the honest desks to itself.
contract EvilVault {
    constructor(address reg, address imd_, address usdc_, address cd, address dd) {
        IWire(cd).wire(reg, imd_, usdc_, cd, dd);
        IWire(dd).wire(reg, imd_, usdc_, cd, dd);
    }
}

/// @dev Gets control in the middle of a routed call (excess ETH refund) and tries every door.
contract Reenterer {
    ITaskVault internal immutable v;
    address internal immutable cd;
    uint256 public taskId;
    bool internal armed;
    bytes4[] public errs;

    constructor(ITaskVault v_, address cd_) {
        v = v_;
        cd = cd_;
    }

    function approve(address token) external {
        IERC20(token).approve(address(v), type(uint256).max);
    }

    function submit(uint256 t) external payable returns (uint256 s) {
        taskId = t;
        armed = true;
        ImdPay memory none;
        s = v.submit{value: msg.value}(
            t, "https://x.com/doer/status/1", Evidence(bytes32(0), false, ""), 0, type(uint256).max, none
        );
        armed = false;
    }

    function errCount() external view returns (uint256) {
        return errs.length;
    }

    receive() external payable {
        if (!armed) return;
        armed = false;
        _try(address(v), abi.encodeCall(ITaskVault.poke, (taskId)));
        _try(address(v), abi.encodeCall(ITaskVault.withdraw, (ETH)));
        _try(address(v), abi.encodeCall(ITaskVault.claimVoidSubmission, (1))); // routed
        _try(address(v), abi.encodeCall(TaskVault.credit, (ETH, address(this), 1 ether))); // bank
        _try(address(v), abi.encodeCall(TaskVault.advance, (taskId))); // task hook
        _try(cd, abi.encodeCall(CaseDesk.step, (1))); // desk internal
        _try(
            cd,
            bytes.concat(abi.encodeCall(CaseDesk.claimVoidSubmission, (1)), abi.encodePacked(address(this), uint256(0)))
        );
    }

    function _try(address to, bytes memory data) internal {
        (bool ok, bytes memory ret) = to.call(data);
        errs.push(ok ? bytes4(0xffffffff) : bytes4(ret));
    }
}

/// @dev Etched over the MockSwapAdapter: models a token in a user-chosen Uniswap path getting control mid-swap.
contract HookAdapter {
    address public vaultAddr;
    address public caseDeskAddr;
    address public disputeDeskAddr;
    uint256 public taskId;
    bytes4[] public errs;

    function setup(address v, address cd, address dd, uint256 t) external {
        vaultAddr = v;
        caseDeskAddr = cd;
        disputeDeskAddr = dd;
        taskId = t;
    }

    function errCount() external view returns (uint256) {
        return errs.length;
    }

    function swapExactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256,
        uint256,
        bytes calldata,
        address recipient
    ) external payable returns (uint256 out) {
        require(tokenIn == address(0) && msg.value == amountIn, "eth only");
        ImdPay memory none;
        _try(vaultAddr, abi.encodeCall(ITaskVault.poke, (taskId)));
        _try(vaultAddr, abi.encodeCall(ITaskVault.withdraw, (tokenOut)));
        _try(vaultAddr, abi.encodeCall(ITaskVault.dispute, (1, "r", 0.001 ether, none)));
        _try(vaultAddr, abi.encodeCall(TaskVault.settleValue, (address(this), 10 ether, 0)));
        _try(caseDeskAddr, abi.encodeCall(CaseDesk.step, (1)));
        _try(disputeDeskAddr, abi.encodeCall(DisputeDesk.dropCaller, (1)));
        out = amountIn * 312.5e18 / 1e18;
        MockERC20(tokenOut).mint(recipient, out);
    }

    function _try(address to, bytes memory data) internal {
        (bool ok, bytes memory ret) = to.call(data);
        errs.push(ok ? bytes4(0xffffffff) : bytes4(ret));
    }
}

contract ReviewSplitAccess is Base {
    address internal stranger = makeAddr("stranger");

    function _sfx(address who, uint256 value) internal pure returns (bytes memory) {
        return abi.encodePacked(who, value);
    }

    function _errOf(bytes memory ret) internal pure returns (bytes4) {
        return bytes4(ret);
    }

    // ================================================================== FIXED

    /// @dev The weakness: a permissionless LocalFactory.launchContracts whose salt does not include the caller. When
    ///      `new LocalFactory()` and the launches go out as separate public transactions, a mempool watcher could
    ///      launch the honest desk codes at their predicted addresses together with his own contract at index 2,
    ///      which wires the desks to itself; the honest core launch would then revert and the predicted vault never
    ///      exist (DoS of a self-deploy; the operator would start over with a new factory).
    /// The rule: only the creator of the LocalFactory may launch through it, so nobody can copy the codes out of
    /// the mempool, take the predicted desk addresses and wire them to a vault of his own.
    function test_Fixed_LocalFactoryLaunchesOnlyForItsDeployer() public {
        LocalFactory factory = new LocalFactory();
        LaunchPlan.Support memory s;
        s.registry = address(registry);
        s.textRules = address(new TextRules());
        s.questionBuilder = address(new SwarmQuestionBuilder());
        s.ballotChecker = address(new BallotChecker());
        s.attestationChecker = address(new AttestationChecker(address(registry)));
        (bytes[] memory codes,, address[] memory addrs) =
            LaunchPlan.core(factory, 2, s, address(imd), address(usdc), address(yolo));
        assertEq(factory.deployer(), address(this), "this test deployed the factory");

        // attacker copies codes[0..1] from the pending transaction and appends his own wiring contract
        bytes[] memory evil = new bytes[](3);
        evil[0] = codes[0];
        evil[1] = codes[1];
        evil[2] = abi.encodePacked(
            type(EvilVault).creationCode, abi.encode(address(registry), address(imd), address(usdc), addrs[0], addrs[1])
        );
        vm.prank(stranger);
        vm.expectRevert(LocalFactory.NotTheDeployer.selector);
        factory.launchContracts(2, evil);

        // the honest launch goes through and the vault stands at its predicted address
        address[] memory got = factory.launchContracts(2, codes);
        assertEq(got[0], addrs[0], "CaseDesk at the predicted address");
        assertEq(got[2], addrs[2], "vault at the predicted address");
        assertEq(CaseDesk(addrs[0]).vault(), addrs[2], "desk wired to the honest vault");
        assertEq(DisputeDesk(addrs[1]).vault(), addrs[2], "desk wired to the honest vault");
    }

    /// The reimbursement counts the canonical ABI encoding of the batch, so a tail of zero
    /// bytes appended by the relayer is not paid for. The padded call only costs the relayer more (its own intrinsic
    /// gas and the vault's memory copy), so padding is never profitable.
    function test_Fixed_RelayerPaddingIsNotReimbursed() public {
        vm.fee(0.1 gwei);
        uint256 tA = _create(author, address(imd), 10e18);
        uint256 sA = _submit(doer, tA);
        _dispute(dave, sA);
        uint256 tB = _create(author, address(imd), 10e18);
        uint256 sB = _submit(doer2, tB);
        _dispute(erin, sB);

        Ballot[] memory bs = new Ballot[](1);
        bs[0] = _ballot(sA, 0, 1, _ids(0, 50), voters[0]);
        uint256 c0 = vault.credits(ETH, relayer);
        vm.prank(relayer);
        (bool ok,) = address(vault).call(abi.encodeCall(ITaskVault.submitVotes, (sA, bs)));
        assertTrue(ok);
        uint256 paidPlain = vault.credits(ETH, relayer) - c0;

        uint256 pad = 64 * 1024;
        bs[0] = _ballot(sB, 0, 1, _ids(50, 50), voters[0]);
        bytes memory data = bytes.concat(abi.encodeCall(ITaskVault.submitVotes, (sB, bs)), new bytes(pad));
        uint256 c1 = vault.credits(ETH, relayer);
        vm.prank(relayer);
        (ok,) = address(vault).call(data);
        assertTrue(ok);
        uint256 paidPadded = vault.credits(ETH, relayer) - c1;
        assertEq(vault.relayerShortfall(sB, relayer), 0, "pot covered it all");

        uint256 perGas = block.basefee * 11_000 / 10_000; // basefee x (1 + markup)
        int256 extraGas = (int256(paidPadded) - int256(paidPlain)) / int256(perGas);
        emit log_named_int("extra gas reimbursed for 64 KB of padding", extraGas);
        // the padded call is reimbursed for the same canonical bytes: the difference is the execution of the copy,
        // far below the 4..10 gas per byte the padding costs the relayer itself
        assertLt(extraGas, int256(pad), "padding is paid at less than 1 gas per byte");
    }

    /// @dev The weakness (minor): without a check that each desk is wired in its own slot (caseDesk_ ==
    ///      address(this) for a CaseDesk), a launch with the two desk addresses swapped would deploy
    ///      "successfully": the vault would take task money while every submission reverts.
    /// The rule: a vault that puts the desks in each other's slots does not deploy at all, instead of
    /// deploying, taking money and reverting every submission.
    function test_Fixed_SwappedDesksRevertTheDeployment() public {
        TextRules text = new TextRules();
        address r = address(registry);
        CaseDesk cd = new CaseDesk(r, address(imd), address(usdc), address(text), address(new SwarmQuestionBuilder()));
        DisputeDesk dd = new DisputeDesk(r, address(imd), address(usdc), address(text), address(new BallotChecker()));
        assertTrue(cd.isCaseDesk(), "the CaseDesk knows its slot");
        assertFalse(dd.isCaseDesk(), "so does the DisputeDesk");
        address attestation = address(new AttestationChecker(r));
        vm.expectRevert(WrongWiring.selector);
        new TaskVault(
            r, address(imd), address(usdc), address(yolo), attestation, address(text), address(dd), address(cd)
        );
        // the right order deploys and wires both desks
        TaskVault good = new TaskVault(
            r, address(imd), address(usdc), address(yolo), attestation, address(text), address(cd), address(dd)
        );
        assertEq(good.caseDesk(), address(cd), "the CaseDesk slot holds the CaseDesk");
        assertEq(cd.vault(), address(good), "wired");
    }

    // ================================================================== GUARDS: routing table

    /// @dev Every routed selector is the same function on its desk (a signature drift would route into nothing).
    function test_Guard_RoutedSelectorsMatchDeskAbi() public pure {
        assertEq(ITaskVault.submit.selector, CaseDesk.submit.selector);
        assertEq(ITaskVault.claimVoidSubmission.selector, CaseDesk.claimVoidSubmission.selector);
        assertEq(ITaskVault.reply.selector, CaseDesk.reply.selector);
        assertEq(ITaskVault.getSubmission.selector, CaseDesk.getSubmission.selector);
        assertEq(ITaskVault.submissionCount.selector, bytes4(keccak256("submissionCount()")));
        assertEq(ITaskVault.stepDeadline.selector, CaseDesk.stepDeadline.selector);
        assertEq(ITaskVault.previewSwarmBody.selector, CaseDesk.previewSwarmBody.selector);
        assertEq(ITaskVault.quoteSubmission.selector, CaseDesk.quoteSubmission.selector);
        assertEq(ITaskVault.dispute.selector, DisputeDesk.dispute.selector);
        assertEq(ITaskVault.appeal.selector, DisputeDesk.appeal.selector);
        assertEq(ITaskVault.callSwarm.selector, DisputeDesk.callSwarm.selector);
        assertEq(ITaskVault.submitVotes.selector, DisputeDesk.submitVotes.selector);
        assertEq(ITaskVault.appealReply.selector, DisputeDesk.appealReply.selector);
        assertEq(ITaskVault.claimDisputer.selector, DisputeDesk.claimDisputer.selector);
        assertEq(ITaskVault.claimVoterReward.selector, DisputeDesk.claimVoterReward.selector);
        assertEq(ITaskVault.claimRelayerShortfall.selector, DisputeDesk.claimRelayerShortfall.selector);
        assertEq(ITaskVault.getDispute.selector, DisputeDesk.getDispute.selector);
        assertEq(ITaskVault.getDisputer.selector, DisputeDesk.getDisputer.selector);
        assertEq(ITaskVault.getAppeal.selector, DisputeDesk.getAppeal.selector);
        assertEq(ITaskVault.getSettlement.selector, DisputeDesk.getSettlement.selector);
        assertEq(ITaskVault.votesOf.selector, DisputeDesk.votesOf.selector);
        assertEq(ITaskVault.voterClaimed.selector, DisputeDesk.voterClaimed.selector);
        assertEq(ITaskVault.tokensVoted.selector, DisputeDesk.tokensVoted.selector);
        assertEq(ITaskVault.tokenVoted.selector, DisputeDesk.tokenVoted.selector);
        assertEq(ITaskVault.relayerShortfall.selector, bytes4(keccak256("relayerShortfall(uint256,address)")));
        assertEq(ITaskVault.voteDomainSeparator.selector, DisputeDesk.voteDomainSeparator.selector);
        assertEq(ITaskVault.quoteDisputeBond.selector, DisputeDesk.quoteDisputeBond.selector);
        assertEq(ITaskVault.quoteSwarmFee.selector, DisputeDesk.quoteSwarmFee.selector);
        assertEq(ITaskVault.paramsOf.selector, ParamsRegistry.paramsOf.selector);
    }

    function _internalSelectors() internal pure returns (bytes4[16] memory s) {
        s = [
            CaseDesk.step.selector,
            CaseDesk.finalize.selector,
            CaseDesk.advanced.selector,
            CaseDesk.startVote.selector,
            bytes4(keccak256("decide(uint256,(uint256,uint256,uint256,uint256))")), // removed (audit C-02)
            CaseDesk.markAppealed.selector,
            CaseDesk.askEscalation.selector,
            CaseDesk.subCore.selector,
            IWire.wire.selector,
            DisputeDesk.appealAsked.selector,
            DisputeDesk.dropCaller.selector,
            DisputeDesk.settle.selector,
            DisputeDesk.tally.selector,
            DisputeDesk.appealCore.selector,
            DisputeDesk.questionPart.selector,
            TaskVault.advanceFromSelf.selector
        ];
    }

    /// @dev No confused deputy: a user call that reaches a desk through the vault arrives with msg.sender == vault,
    ///      so no desk-internal selector may be routable. Every one of them is UnknownFunction at the vault.
    function test_Guard_VaultRoutesNoDeskInternalSelector() public {
        bytes4[16] memory s = _internalSelectors();
        for (uint256 i; i < s.length; ++i) {
            if (s[i] == TaskVault.advanceFromSelf.selector) continue; // implemented by the vault itself (OnlySelf)
            vm.prank(stranger);
            (bool ok, bytes memory ret) = address(vault).call(bytes.concat(s[i], new bytes(32 * 8)));
            assertFalse(ok, "internal selector routed");
            assertEq(_errOf(ret), UnknownFunction.selector);
        }
    }

    // ================================================================== GUARDS: the 52-byte suffix

    /// @dev Routed functions accept only the vault: a direct call with a forged suffix (victim as sender) reverts.
    function test_Guard_ForgedSuffixDirectToDeskReverts() public {
        uint256 t = _create(author, address(imd), 10e18);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);

        vm.startPrank(stranger);
        (bool ok, bytes memory ret) =
            address(caseDesk).call(bytes.concat(abi.encodeCall(CaseDesk.reply, (s, "x")), _sfx(doer, 0)));
        assertFalse(ok);
        assertEq(_errOf(ret), NotAuthorized.selector);
        // spend alice's approval to the vault as if she submitted
        (ok, ret) = address(caseDesk)
            .call(
                bytes.concat(
                    abi.encodeCall(
                        CaseDesk.submit,
                        (t, "https://x.com/doer/status/1", _noEvidence(), 0, type(uint256).max, _noSwap())
                    ),
                    _sfx(alice, 0)
                )
            );
        assertFalse(ok);
        assertEq(_errOf(ret), NotAuthorized.selector);
        // claim dave's disputer money / pretend to have sent 10 ETH
        (ok, ret) =
            address(disputeDesk).call(bytes.concat(abi.encodeCall(DisputeDesk.claimDisputer, (s)), _sfx(dave, 0)));
        assertFalse(ok);
        assertEq(_errOf(ret), NotAuthorized.selector);
        (ok, ret) = address(disputeDesk)
            .call(
                bytes.concat(
                    abi.encodeCall(DisputeDesk.dispute, (s, "r", 0.001 ether, _noSwap())), _sfx(stranger, 10 ether)
                )
            );
        assertFalse(ok);
        assertEq(_errOf(ret), NotAuthorized.selector);
        vm.stopPrank();
    }

    /// @dev A user-appended fake suffix is ignored: the vault appends the real one after it.
    function test_Guard_UserSuffixThroughVaultIsIgnored() public {
        uint256 t = _create(author, address(imd), 10e18);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);

        vm.prank(stranger);
        (bool ok, bytes memory ret) =
            address(vault).call(bytes.concat(abi.encodeCall(ITaskVault.reply, (s, "x")), _sfx(doer, 0)));
        assertFalse(ok);
        assertEq(_errOf(ret), NotDoer.selector);

        _warp(LONG);
        vault.poke(t);
        vm.prank(stranger);
        (ok, ret) = address(vault).call(bytes.concat(abi.encodeCall(ITaskVault.claimDisputer, (s)), _sfx(dave, 0)));
        assertFalse(ok);
        assertEq(_errOf(ret), NothingToClaim.selector);

        // the real owner with junk appended still works
        vm.prank(dave);
        (ok,) = address(vault).call(bytes.concat(abi.encodeCall(ITaskVault.claimDisputer, (s)), _sfx(stranger, 0)));
        assertTrue(ok);
        assertTrue(vault.getDisputer(s, dave).claimed);
    }

    /// @dev Siblings reach only the functions named for them: not each other's routed functions, not the vault-only
    ///      ones, not their own sibling-only ones; the vault reaches none of the sibling-only functions.
    function test_Guard_SiblingAndVaultCannotCrossCall() public {
        Facts memory f;
        bytes memory sfx = _sfx(alice, 1 ether);
        // the dispute desk as caller
        vm.startPrank(address(disputeDesk));
        vm.expectRevert(NotAuthorized.selector);
        caseDesk.step(1);
        vm.expectRevert(NotAuthorized.selector);
        caseDesk.finalize(1, Outcome.Unwound);
        (bool ok, bytes memory ret) =
            address(caseDesk).call(bytes.concat(abi.encodeCall(CaseDesk.claimVoidSubmission, (1)), sfx));
        assertFalse(ok);
        assertEq(_errOf(ret), NotAuthorized.selector);
        vm.expectRevert(NotAuthorized.selector);
        disputeDesk.settle(1, Outcome.Accepted, false, f);
        vm.stopPrank();
        // the case desk as caller
        vm.startPrank(address(caseDesk));
        (ok, ret) = address(disputeDesk)
            .call(bytes.concat(abi.encodeCall(DisputeDesk.dispute, (1, "r", 0.001 ether, _noSwap())), sfx));
        assertFalse(ok);
        assertEq(_errOf(ret), NotAuthorized.selector);
        (ok, ret) = address(disputeDesk).call(bytes.concat(abi.encodeCall(DisputeDesk.claimDisputer, (1)), sfx));
        assertFalse(ok);
        assertEq(_errOf(ret), NotAuthorized.selector);
        vm.expectRevert(NotAuthorized.selector);
        caseDesk.markAppealed(1);
        vm.expectRevert(NotAuthorized.selector);
        caseDesk.advanced(1);
        vm.stopPrank();
        // the vault as caller of sibling-only functions
        vm.startPrank(address(vault));
        vm.expectRevert(NotAuthorized.selector);
        disputeDesk.settle(1, Outcome.Accepted, false, f);
        vm.expectRevert(NotAuthorized.selector);
        disputeDesk.dropCaller(1);
        vm.expectRevert(NotAuthorized.selector);
        disputeDesk.appealAsked(1, 1);
        vm.expectRevert(NotAuthorized.selector);
        caseDesk.startVote(1, 1, 1);
        vm.expectRevert(NotAuthorized.selector);
        caseDesk.askEscalation(1, 1);
        vm.expectRevert(NotAuthorized.selector);
        caseDesk.advanced(1);
        vm.stopPrank();
    }

    // ================================================================== GUARDS: reentrancy under the one lock

    /// @dev A user regaining control inside a routed call (excess ETH refund at the end of submit) cannot reach any
    ///      state-changing path: the vault's own functions and routes are locked, bank/task hooks and the desks
    ///      refuse him.
    function test_Guard_ReentryFromEthRefundIsLocked() public {
        uint256 t = _create(author, address(imd), 10e18);
        Reenterer r = new Reenterer(vault, address(caseDesk));
        imd.mint(address(r), 100e18);
        r.approve(address(imd));
        vm.deal(address(this), 1 ether);
        uint256 s = r.submit{value: 1 ether}(t);
        assertEq(_sub(s).doer, address(r));
        assertEq(address(r).balance, 1 ether, "refund arrived");
        bytes4 lock = TaskVault.ReentrancyGuardReentrantCall.selector;
        assertEq(r.errCount(), 7);
        assertEq(r.errs(0), lock, "poke");
        assertEq(r.errs(1), lock, "withdraw");
        assertEq(r.errs(2), lock, "routed claimVoidSubmission");
        assertEq(r.errs(3), NotAuthorized.selector, "credit");
        assertEq(r.errs(4), NotAuthorized.selector, "advance");
        assertEq(r.errs(5), NotAuthorized.selector, "desk step");
        assertEq(r.errs(6), NotAuthorized.selector, "desk routed directly");
    }

    /// @dev The same from inside the swap of payment mode A (a token of a user-chosen Uniswap path gets control).
    function test_Guard_ReentryFromSwapHookIsLocked() public {
        uint256 t = _create(author, address(imd), 10e18);
        vm.etch(address(adapter), address(new HookAdapter()).code);
        HookAdapter h = HookAdapter(address(adapter));
        h.setup(address(vault), address(caseDesk), address(disputeDesk), t);
        ImdPay memory pay = ImdPay(ETH, 0.01 ether, 1e18, uint64(_now() + 1), hex"00");
        vm.prank(doer);
        uint256 s = vault.submit{value: 0.01 ether}(t, "https://x.com/doer/status/1", _noEvidence(), 0, 1e18, pay);
        assertEq(_sub(s).doer, doer);
        bytes4 lock = TaskVault.ReentrancyGuardReentrantCall.selector;
        assertEq(h.errCount(), 6);
        assertEq(h.errs(0), lock, "poke");
        assertEq(h.errs(1), lock, "withdraw");
        assertEq(h.errs(2), lock, "routed dispute");
        assertEq(h.errs(3), NotAuthorized.selector, "settleValue");
        assertEq(h.errs(4), NotAuthorized.selector, "desk step");
        assertEq(h.errs(5), NotAuthorized.selector, "desk dropCaller");
        _assertSolvent();
    }

    // ================================================================== GUARDS: emergency exit

    /// @dev A machine that can still move wins over the exit whatever gas the caller picks: the accepted submission
    ///      that nobody poked for 30+ days is not unwound (the exit reverts with the advance), poke then pays the doer.
    function testFuzz_Guard_EmergencyExitCannotBeatWorkingMachine(uint256 g) public {
        g = bound(g, 2_900_000, 8_000_000);
        uint256 t = _create(author, address(imd), 10e18);
        uint256 s = _submit(doer, t);
        _warp(24 hours + 31 days);
        vm.prank(stranger);
        (bool ok,) = address(vault).call{gas: g}(abi.encodeCall(ITaskVault.emergencyExit, (t)));
        assertFalse(ok, "exit must fail");
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Open));
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Completed));
    }

    // ================================================================== GUARDS: wiring

    /// @dev Desks wired in setUp cannot be rewired by anyone, even with the right environment.
    function test_Guard_NoRewireAfterLaunch() public {
        vm.prank(address(vault));
        vm.expectRevert(WiringClosed.selector);
        caseDesk.wire(address(registry), address(imd), address(usdc), address(caseDesk), address(disputeDesk));
        vm.prank(stranger);
        vm.expectRevert(WiringClosed.selector);
        disputeDesk.wire(address(registry), address(imd), address(usdc), address(caseDesk), address(disputeDesk));
    }

    /// @dev The guarantee rests only on transaction atomicity: inside the transaction that created a desk, the first
    ///      caller of `wire` wins (here a contract that creates a desk and wires it in one call; the LocalFactory
    ///      front-run above is the same thing). Nobody can wire a second time.
    function test_Guard_WireIsFirstComeInsideTheCreatingTx() public {
        SameTxWirer w = new SameTxWirer(address(registry), address(imd), address(usdc));
        CaseDesk cd = w.desk();
        assertEq(cd.vault(), address(w), "first caller in the creating tx wired it");
        vm.expectRevert(WiringClosed.selector);
        cd.wire(address(registry), address(imd), address(usdc), address(cd), address(cd));
    }
}

contract SameTxWirer {
    CaseDesk public desk;

    constructor(address reg, address imd_, address usdc_) {
        desk = new CaseDesk(reg, imd_, usdc_, address(1), address(2));
        desk.wire(reg, imd_, usdc_, address(desk), address(desk));
    }
}

/// @dev Without the Base setUp (which is one transaction): every top-level call here is its own transaction.
contract ReviewSplitAccessIsolated is Test {
    /// forge-config: default.isolate = true
    function test_Guard_WireClosesWithTheDeployTx() public {
        address reg = address(0xBEEF);
        address imd_ = address(0x1111);
        address usdc_ = address(0x2222);
        CaseDesk cd = new CaseDesk(reg, imd_, usdc_, address(new TextRules()), address(new SwarmQuestionBuilder()));
        DisputeDesk dd = new DisputeDesk(reg, imd_, usdc_, address(new TextRules()), address(new BallotChecker()));
        // a later transaction (anyone, also the deployer) cannot wire
        vm.prank(address(0xBAD));
        vm.expectRevert(WiringClosed.selector);
        cd.wire(reg, imd_, usdc_, address(cd), address(dd));
        assertEq(cd.vault(), address(0));
        // so a vault deployed in its own transaction (forge script with plain `new`) fails safe
        vm.expectRevert(WiringClosed.selector);
        IWire(address(dd)).wire(reg, imd_, usdc_, address(cd), address(dd));
        assertEq(dd.vault(), address(0));
    }
}
