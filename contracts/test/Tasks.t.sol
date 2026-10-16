// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";
import {ParamsBounds} from "../src/VaultParams.sol";

/// @dev Tasks, contributions, withdrawals, deadlines, the queue and bond doubling, parameter versions.
contract TasksTest is Base {
    // ================================================================== creation

    function test_CreateTask_AllCurrencies() public {
        uint256 t1 = _create(author, ETH, 0.01 ether); // $25
        uint256 t2 = _create(author, address(usdc), 50e6);
        uint256 t3 = _create(author, address(imd), 5e18);
        assertEq(vault.getTask(t1).pot, 0.01 ether);
        assertEq(vault.getTask(t2).pot, 50e6);
        assertEq(vault.getTask(t3).pot, 5e18);
        // author fees (0.001 ETH each) sit in the treasury pot
        assertEq(vault.treasuryPot(ETH), 0.003 ether);
        assertEq(vault.liabilities(ETH), 0.013 ether);
        assertEq(vault.liabilities(address(usdc)), 50e6);
        assertEq(vault.liabilities(address(imd)), 5e18);
        _assertSolvent();
        _claimEverythingAndCheck();
    }

    function test_CreateTask_Reverts() public {
        vm.startPrank(author);
        vm.expectRevert(RewardTooSmall.selector); // $4 < $5
        vault.createTask(address(usdc), 4e6, 0, "Title", "ipfs://c", 0, 0, "", 0.001 ether, _noSwap());
        vm.expectRevert(RewardTooSmall.selector);
        vault.createTask(address(imd), 0.4e18, 0, "Title", "ipfs://c", 0, 0, "", 0.001 ether, _noSwap());
        vm.expectRevert(BadCurrency.selector);
        vault.createTask(address(nft), 10e18, 0, "Title", "ipfs://c", 0, 0, "", 0.001 ether, _noSwap());
        vm.expectRevert(FeeTooLow.selector);
        vault.createTask{value: 0.0001 ether}(
            address(usdc), 10e6, 0, "Title", "ipfs://c", 0, 0, "", 0.0001 ether, _noSwap()
        );
        vm.expectRevert(NotEnoughEth.selector);
        vault.createTask{value: 0.0005 ether}(
            address(usdc), 10e6, 0, "Title", "ipfs://c", 0, 0, "", 0.001 ether, _noSwap()
        );
        vm.expectRevert(BadText.selector);
        vault.createTask{value: 0.001 ether}(
            address(usdc), 10e6, 0, "Title", 'ipfs://"x', 0, 0, "", 0.001 ether, _noSwap()
        );
        vm.expectRevert(BadText.selector);
        vault.createTask{value: 0.001 ether}(address(usdc), 10e6, 0, "Title", "", 0, 0, "", 0.001 ether, _noSwap());
        vm.expectRevert(BadDeadline.selector);
        vault.createTask{value: 0.001 ether}(
            address(usdc), 10e6, uint64(_now()), "Title", "c", 0, 0, "", 0.001 ether, _noSwap()
        );
        vm.stopPrank();
    }

    function test_PauseStopsOnlyNewTasks() public {
        uint256 t = _create(author, address(usdc), 50e6);
        vm.prank(owner);
        registry.setNewTasksPaused(true);
        vm.expectRevert(Paused.selector);
        vm.prank(author);
        vault.createTask{value: 0.001 ether}(address(usdc), 50e6, 0, "Title", "c", 0, 0, "", 0.001 ether, _noSwap());
        // existing task still works end to end
        uint256 s = _submit(doer, t);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        vm.expectRevert();
        vm.prank(author);
        registry.setNewTasksPaused(false); // not the owner
    }

    function test_ExcessEthRefunded() public {
        uint256 before = author.balance;
        vm.prank(author);
        vault.createTask{value: 1 ether}(address(usdc), 50e6, 0, "Title", "c", 0, 0, "", 0.001 ether, _noSwap());
        assertEq(before - author.balance, 0.001 ether);
    }

    // ================================================================== no dispute

    function test_NoDispute_AuthorOnly_24hWindow_USDC() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 imdBefore = imd.balanceOf(doer);
        uint256 s = _submit(doer, t);
        assertEq(_sub(s).bond, 1e18); // max(1, 0.5 + 3% x 12.5 IMD)
        assertEq(_sub(s).windowEnd, _now() + 24 hours); // 24h for every task, even author-only money

        _warp(24 hours - 1);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.Review));
        _warp(1);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Completed));

        // R - 10% to the doer; without a dispute the whole 10% goes to the treasury (in USDC)
        assertEq(vault.credits(address(usdc), doer), 90e6);
        assertEq(vault.treasuryPot(address(usdc)), 10e6);
        assertEq(vault.credits(address(imd), doer), 1e18); // bond back
        vm.startPrank(doer);
        vault.withdraw(address(usdc));
        vault.withdraw(address(imd));
        vm.stopPrank();
        assertEq(imd.balanceOf(doer), imdBefore);
        _claimEverythingAndCheck();
    }

    function test_NoDispute_ForeignMoney_24hWindow_ETH() public {
        uint256 t = _create(author, ETH, 0.02 ether); // $50
        _topUp(alice, t, 0.02 ether);
        uint256 s = _submit(doer, t);
        assertEq(_sub(s).windowEnd, _now() + 24 hours);
        assertEq(_sub(s).reward, 0.04 ether);
        _warp(12 hours);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.Review));
        _warp(12 hours);
        vault.poke(t);
        assertEq(vault.credits(ETH, doer), 0.036 ether);
        assertEq(vault.treasuryPot(ETH), 0.004 ether + 0.001 ether); // 10% + author fee
        _claimEverythingAndCheck();
    }

    function test_NoDispute_IMDReward() public {
        uint256 t = _create(author, address(imd), 20e18); // $160
        uint256 s = _submit(doer, t);
        assertEq(_sub(s).bond, 1.1e18); // 0.5 + 3% x 20 = 1.1
        _warp(24 hours);
        vault.poke(t);
        assertEq(vault.credits(address(imd), doer), 18e18 + 1.1e18);
        assertEq(vault.treasuryPot(address(imd)), 2e18);
        _claimEverythingAndCheck();
    }

    // ================================================================== contributions

    function test_TopUpDuringSubmission_RefundedOnAcceptance() public {
        uint256 t = _create(author, address(usdc), 50e6);
        uint256 s = _submit(doer, t);
        _topUp(alice, t, 500e6);
        assertEq(vault.getTask(t).pending, 500e6);
        assertEq(vault.getTask(t).pot, 50e6);
        assertEq(_sub(s).reward, 50e6);
        _warp(24 hours);
        vault.poke(t);
        assertEq(vault.credits(address(usdc), doer), 45e6);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdrawContribution(t);
        assertEq(usdc.balanceOf(alice) - before, 500e6);
        vm.prank(author);
        vm.expectRevert(NothingToClaim.selector);
        vault.withdrawContribution(t);
        _claimEverythingAndCheck();
    }

    function test_TopUpDuringSubmission_JoinsNextRoundAfterRejection() public {
        uint256 t = _create(author, address(usdc), 50e6);
        uint256 s = _submit(doer, t);
        _topUp(alice, t, 100e6);
        _rejectByVote(s);
        Task memory tk = vault.getTask(t);
        assertEq(tk.pot, 150e6);
        assertEq(tk.pending, 0);
        assertEq(vault.getContribution(t, alice).pending, 100e6); // lazily synced
        uint256 s2 = _submit(doer2, t);
        assertEq(_sub(s2).reward, 150e6);
        // alice's share is now at stake: she cannot withdraw it during the active submission
        vm.prank(alice);
        vm.expectRevert(NothingToClaim.selector);
        vault.withdrawContribution(t);
        _claimEverythingAndCheck();
    }

    function test_WithdrawRules() public {
        uint256 t = _create(author, address(usdc), 50e6);
        _topUp(alice, t, 30e6);
        // idle: alice takes her share back after an hour of public notice (swarm audit #8)
        vm.prank(alice);
        vm.expectRevert(NoNotice.selector);
        vault.withdrawContribution(t);
        _announceWithdraw(alice, t);
        vm.prank(alice);
        vault.withdrawContribution(t);
        assertEq(vault.getTask(t).pot, 50e6);
        _topUp(alice, t, 30e6);
        uint256 s = _submit(doer, t);
        // active submission: active shares locked, pending ones free
        vm.prank(alice);
        vm.expectRevert(NothingToClaim.selector);
        vault.withdrawContribution(t);
        _topUp(bob, t, 10e6);
        vm.prank(bob);
        vault.withdrawContribution(t); // pending top-up comes back at any time
        assertEq(vault.getTask(t).pending, 0);
        // after the submission ends without acceptance the author can leave (with notice)
        _rejectByVote(s);
        _announceWithdraw(author, t);
        vm.prank(author);
        vault.withdrawContribution(t);
        assertEq(vault.getTask(t).pot, 30e6);
        _claimEverythingAndCheck();
    }

    function test_AuthorWithdrawsEverything_ThenSubmitReverts() public {
        uint256 t = _create(author, address(usdc), 50e6);
        _announceWithdraw(author, t);
        vm.prank(author);
        vault.withdrawContribution(t);
        vm.prank(doer);
        vm.expectRevert(RewardTooSmall.selector);
        vault.submit(t, "https://x.com/doer/status/1", _noEvidence(), 0, type(uint256).max, _noSwap());
        _claimEverythingAndCheck();
    }

    // ================================================================== deadline

    function test_DeadlineRefund() public {
        uint256 t = _createWithDeadline(author, ETH, 0.01 ether, uint64(_now() + 3 days));
        _topUp(alice, t, 0.02 ether);
        _warp(3 days);
        vm.prank(doer);
        vm.expectRevert(TaskNotOpen.selector); // the lazy timer expires the task first
        vault.submit(t, "https://x.com/doer/status/1", _noEvidence(), 0, type(uint256).max, _noSwap());
        uint256 a0 = alice.balance;
        vm.prank(alice);
        vault.withdrawContribution(t);
        assertEq(alice.balance - a0, 0.02 ether);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Expired));
        vm.prank(alice);
        vm.expectRevert(TaskNotOpen.selector);
        vault.topUp{value: 1}(t, 1, _noSwap());
        _claimEverythingAndCheck();
    }

    function test_DeadlineDuringSubmission_SubmissionStillRuns() public {
        uint256 t = _createWithDeadline(author, address(usdc), 50e6, uint64(_now() + 1 hours));
        uint256 s = _submit(doer, t);
        uint256 s2 = _submit(doer2, t); // queued before the deadline
        _warp(2 hours);
        vault.poke(t);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Open));
        _rejectByVote(s);
        assertEq(uint8(_phase(s2)), uint8(Phase.Review)); // queued one is still judged
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s2).outcome), uint8(Outcome.Accepted));
        _claimEverythingAndCheck();
    }

    function test_DeadlineDuringSubmission_ExpiresAfterRejection() public {
        uint256 t = _createWithDeadline(author, address(usdc), 50e6, uint64(_now() + 1 hours));
        uint256 s = _submit(doer, t);
        _warp(2 hours);
        _rejectByVote(s);
        vault.poke(t);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Expired));
        _claimEverythingAndCheck();
    }

    // ================================================================== queue and doubling

    function test_QueueDoublingAndVoidRefund() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s1 = _submit(doer, t);
        uint256 s2 = _submit(doer2, t);
        uint256 s3 = _submit(doer3, t);
        assertEq(_sub(s1).bond, 1e18);
        assertEq(_sub(s2).bond, 2e18); // one ahead
        assertEq(_sub(s3).bond, 4e18); // two ahead
        assertEq(uint8(_phase(s2)), uint8(Phase.Queued));

        _rejectByVote(s1); // s2 becomes active
        assertEq(uint8(_phase(s2)), uint8(Phase.Review));
        assertEq(vault.getTask(t).rejectedCount, 1);
        (uint256 quote,) = vault.quoteSubmission(t);
        assertEq(quote, 8e18); // 1 rejected + 2 ahead (s2 active, s3 queued)

        _warp(24 hours); // s2 accepted
        vault.poke(t);
        assertEq(uint8(_sub(s2).outcome), uint8(Outcome.Accepted));
        // s3 is void: its bond comes back in full
        uint256 before = imd.balanceOf(doer3);
        vault.claimVoidSubmission(s3);
        assertEq(imd.balanceOf(doer3) - before, 4e18);
        vm.expectRevert(NothingToClaim.selector);
        vault.claimVoidSubmission(s3);
        _claimEverythingAndCheck();
    }

    function test_DoublingCappedByMaxDoublings() public {
        uint256 t = _create(author, address(usdc), 100e6);
        for (uint256 i; i < 10; ++i) {
            _submit(doer, t);
        }
        (uint256 quote,) = vault.quoteSubmission(t);
        assertEq(quote, 1e18 << 8);
    }

    function test_QuoteBondFormula() public {
        uint256 t = _create(author, address(usdc), 299e6); // just under the large threshold
        (uint256 bond, uint256 checkFee) = vault.quoteSubmission(t);
        // 299 USD = 37.375 IMD; 0.5 + 3% = 1.62125 IMD
        assertEq(bond, 1.62125e18);
        assertEq(checkFee, 0);
        uint256 t2 = _create(author, address(usdc), 300e6);
        (, checkFee) = vault.quoteSubmission(t2);
        assertEq(checkFee, PRICE);
    }

    // ================================================================== parameter versions

    function test_ParamChange_DoesNotAffectExistingTasks() public {
        uint256 tOld = _create(author, address(usdc), 100e6);
        Params memory p = defaultParams();
        p.disputeWindow = 36 hours;
        p.feeBps = 1_500;
        p.nftFeeBps = 900;
        vm.prank(owner);
        registry.proposeParams(p);
        vm.expectRevert(ParamsRegistry.TimelockNotPassed.selector);
        registry.activateParams();
        _warp(48 hours);
        registry.activateParams();
        assertEq(registry.currentVersion(), 2);

        uint256 tNew = _create(author, address(usdc), 100e6);
        assertEq(vault.getTask(tOld).paramsVersion, 1);
        assertEq(vault.getTask(tNew).paramsVersion, 2);

        uint256 sOld = _submit(doer, tOld);
        uint256 sNew = _submit(doer2, tNew);
        assertEq(_sub(sOld).windowEnd, _now() + 24 hours);
        assertEq(_sub(sNew).windowEnd, _now() + 36 hours);
        _warp(24 hours);
        vault.poke(tOld);
        vault.poke(tNew);
        assertEq(uint8(_phase(sNew)), uint8(Phase.Review)); // v2 window still open
        _warp(12 hours);
        vault.poke(tNew);
        assertEq(vault.credits(address(usdc), doer), 90e6); // 10% under v1
        assertEq(vault.credits(address(usdc), doer2), 85e6); // 15% under v2
        _claimEverythingAndCheck();
    }

    function test_ParamBounds() public {
        Params memory p = defaultParams();
        p.feeBps = 1_600;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ParamsBounds.ParamOutOfBounds.selector, "feeBps"));
        registry.proposeParams(p);
        p = defaultParams();
        p.swarmTimeout = 5 minutes;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ParamsBounds.ParamOutOfBounds.selector, "swarmTimeout"));
        registry.proposeParams(p);
        p = defaultParams();
        p.disputeWindow = 23 hours; // the dispute window is never below 24h
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ParamsBounds.ParamOutOfBounds.selector, "disputeWindow"));
        registry.proposeParams(p);
        p = defaultParams();
        p.maxTextBytes = 600;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ParamsBounds.ParamOutOfBounds.selector, "maxTextBytes"));
        registry.proposeParams(p);
        vm.expectRevert(); // not the owner
        registry.proposeParams(defaultParams());
    }

    function test_ParamProposalCancel() public {
        vm.startPrank(owner);
        registry.proposeParams(defaultParams());
        registry.cancelParams();
        vm.stopPrank();
        _warp(3 days);
        vm.expectRevert(ParamsRegistry.NothingPending.selector);
        registry.activateParams();
    }

    // ================================================================== helpers

    /// @dev Dispute and reject `s` through the NFT vote (no appeal).
    function _rejectByVote(uint256 s) internal {
        _dispute(dave, s);
        _vote(s, 1, 2, 120, 20); // 20 NFTs reject
        _warp(24 hours);
        vault.poke(_sub(s).taskId); // decided (delta 20 >= 10)
        _warp(24 hours);
        vault.poke(_sub(s).taskId); // appeal window over
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
    }
}
