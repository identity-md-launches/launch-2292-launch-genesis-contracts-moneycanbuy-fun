// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../Base.t.sol";

/// @dev Swarm audit of this repository at d9a1ee5: regressions of findings #3 to #10 (the report gave no source for
///      these; each test follows the report's reproduction and fails on d9a1ee5). #1 and #2: SampleSandwich.t.sol,
///      VestingClockPreStart.t.sol. #11 (Intake version 2): ReviewLaunch.test_L2 against docs/LAUNCH-TASK.md.
contract SwarmAudit117Test is Base {
    uint8 internal constant ACCEPT = 1;
    uint8 internal constant REJECT = 2;

    // ------------------------------------------------------------------ #3 relayer shortfall vs winners and voters

    /// The report: a losing voter relays his own 20 reject ballots one NFT per batch at 20 gwei: 12.4 IMD shortfall
    /// against a 1 IMD penalty; on d9a1ee5 the whole penalty went to him, the correct votes got 0.
    function test_losingVoterDrainsPenaltyByRelayingOwnBallots() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        _dispute(dave, s); // bond 1 IMD, 0.001 ETH into the dispute pot
        vm.fee(1 gwei);
        _vote(s, 0, ACCEPT, 0, 120); // honest batch by the relayer
        vm.fee(20 gwei);
        for (uint256 i; i < 20; ++i) {
            Ballot[] memory one = new Ballot[](1);
            one[0] = _ballot(s, 1, REJECT, _ids(120 + i, 1), voters[1]);
            vm.prank(voters[1]);
            vault.submitVotes(s, one);
        }
        assertGt(vault.relayerShortfall(s, voters[1]), 1e18, "metered far above the 1 IMD penalty");
        _endVote(s); // accept 120 : reject 20, decided
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        Settlement memory st = vault.getSettlement(s);
        // penalty 1 IMD: relayers together at most 20%, the rest 50/50 to the doer and the correct votes
        assertLe(st.shortfallPay, 0.2e18, "relayers never take more than 20% of the penalty");
        assertGe(st.voterImd, 0.4e18, "the correct votes keep their half of the rest");
        uint256 before = imd.balanceOf(voters[1]);
        vm.prank(voters[1]);
        vault.claimRelayerShortfall(s);
        assertLe(imd.balanceOf(voters[1]) - before, 0.2e18);
        assertGe(vault.credits(address(imd), doer), 1e18 + 0.4e18, "the doer's bond back plus his share");
        _claimEverythingAndCheck();
    }

    // ------------------------------------------------------------------ #4 the doer appeals his own acceptance

    function _decidedAccept() internal returns (uint256 t, uint256 s) {
        t = _create(author, address(usdc), 100e6);
        s = _submit(doer, t);
        _dispute(dave, s);
        _vote(s, 0, ACCEPT, 0, 120);
        _endVote(s);
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
    }

    function test_doerAppealsAgainstOwnAcceptance() public {
        (, uint256 s) = _decidedAccept();
        vm.prank(doer);
        vm.expectRevert(DoerCannotDispute.selector);
        vault.appeal(s, "ipfs://weak-argument", type(uint256).max, _noSwap());
        // the slot stays free for an honest disputer, and the doer is his opponent
        _appeal(dave, s);
        assertEq(vault.getAppeal(s).appellant, dave);
        vm.prank(doer);
        vault.appealReply(s, "ipfs://doer-reply");
        _claimEverythingAndCheck();
    }

    function test_doerMayStillAppealARejection() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        _vote(s, 0, REJECT, 0, 120);
        _endVote(s);
        _appeal(doer, s); // in his own favour
        assertTrue(vault.getAppeal(s).sidesDoer);
        _claimEverythingAndCheck();
    }

    function test_doerCannotCallTheSwarmAgainstHimself() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        _warp(24 hours); // no votes: NoDecision
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        vm.prank(doer);
        vm.expectRevert(DoerCannotDispute.selector);
        vault.callSwarm(s, false, "ipfs://against-myself", type(uint256).max, _noSwap());
        _callSwarm(doer, s, true); // for himself: fine
        assertEq(uint8(_phase(s)), uint8(Phase.Asked));
        _claimEverythingAndCheck();
    }

    // ------------------------------------------------------------------ #5 one wallet, both sides

    function test_walletVotesBothSidesAndIsPaid() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        Ballot[] memory bs = new Ballot[](2);
        bs[0] = _ballot(s, 1, ACCEPT, _ids(120, 10), voters[1]);
        bs[1] = _ballot(s, 1, REJECT, _ids(130, 10), voters[1]);
        vm.prank(relayer);
        vault.submitVotes(s, bs);
        (uint256 acc, uint256 rej) = vault.votesOf(s, voters[1]);
        assertEq(acc, 10);
        assertEq(rej, 0, "the second side of the same wallet is skipped");
        Dispute memory d = vault.getDispute(s);
        assertEq(d.walletsAccept, 1);
        assertEq(d.walletsReject, 0);
        assertFalse(vault.tokenVoted(s, 130), "the skipped NFTs stay unused");
        // a later batch cannot add the other side either
        Ballot[] memory later = new Ballot[](1);
        later[0] = _ballot(s, 1, REJECT, _ids(130, 10), voters[1]);
        vm.prank(relayer);
        vault.submitVotes(s, later);
        (, rej) = vault.votesOf(s, voters[1]);
        assertEq(rej, 0);
        // the same side again is fine
        later[0] = _ballot(s, 1, ACCEPT, _ids(130, 10), voters[1]);
        vm.prank(relayer);
        vault.submitVotes(s, later);
        (acc,) = vault.votesOf(s, voters[1]);
        assertEq(acc, 20);
        _claimEverythingAndCheck();
    }

    // ------------------------------------------------------------------ #6 sweetener payout without a price

    function _completedSweetened(uint256 bonus) internal returns (uint256 t, uint256 s) {
        t = _create(author, address(usdc), 100e6);
        vm.prank(alice);
        sweetener.sweeten(t, bonus);
        s = _submit(doer, t);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Completed));
    }

    function test_sweetenerPayoutWithoutPriceReturnsAllToSweetener() public {
        (uint256 t, uint256 s) = _completedSweetened(100_000e18);
        oracle.set(address(yolo), 0, 18); // the keeper lapsed: no YOLO price
        uint256 before = yolo.balanceOf(doer);
        vm.prank(alice);
        sweetener.payout(t, s);
        assertEq(yolo.balanceOf(doer), before, "nothing moves without a price");
        assertEq(sweetener.returnBase(t), 0, "nothing goes back to the sweetener");
        assertEq(sweetener.bonusOf(t), 100_000e18);
        vm.prank(alice);
        vm.expectRevert(YoloSweetener.BonusLocked.selector);
        sweetener.withdraw(t);
        // a price again ($0.0001: 100,000 YOLO = $10, below the $300 cap): the doer gets it all minus the fee
        oracle.set(address(yolo), 0.0001e18, 18);
        sweetener.payout(t, s);
        assertEq(yolo.balanceOf(doer) - before, 90_000e18);
        _claimEverythingAndCheck();
    }

    function test_sweetenerPayoutAfterAWeekWithoutPricePaysInFull() public {
        (uint256 t, uint256 s) = _completedSweetened(10_000_000e18); // $1,000 at the last price: above the cap
        oracle.set(address(yolo), 0, 18);
        uint256 before = yolo.balanceOf(doer);
        sweetener.payout(t, s);
        assertEq(sweetener.noPriceSince(t), _now());
        _warp(sweetener.NO_PRICE_WAIT() - 1);
        sweetener.payout(t, s);
        assertEq(yolo.balanceOf(doer), before, "still waiting");
        _warp(1);
        sweetener.payout(t, s);
        assertEq(yolo.balanceOf(doer) - before, 9_000_000e18, "a week with no price at all: in full");
        _claimEverythingAndCheck();
    }

    function test_sweetenerCapStillAppliesWithAPrice() public {
        (uint256 t, uint256 s) = _completedSweetened(10_000_000e18); // $1,000 > $300
        uint256 before = yolo.balanceOf(doer);
        sweetener.payout(t, s);
        assertEq(yolo.balanceOf(doer) - before, 2_700_000e18, "3,000,000 YOLO = $300, minus 10%");
        assertEq(sweetener.returnBase(t), 10_000_000e18);
        _claimEverythingAndCheck();
    }

    // ------------------------------------------------------------------ #7 a late answer vs the poke order

    function _largeAsked() internal returns (uint256 t, uint256 s, uint256 askedAt) {
        t = _create(author, address(usdc), 300e6);
        s = _submit(doer, t);
        assertEq(uint8(_sub(s).check), uint8(CheckState.Requested));
        askedAt = _now();
    }

    function _deliver(uint256 s, bool answer, uint256 issuedAt) internal {
        OracleAttestation.Attestation memory a = _attestation(answer);
        a.issuedAt = uint64(issuedAt);
        intake.complete(_sub(s).request, 0, a, _sign(a, attesterKey));
    }

    /// The report: sequence A (poke at the deadline, then a "no" signed at T+1h delivered at T+6h+60s) ended
    /// Accepted, sequence B (no poke) Rejected. Both end Rejected now.
    function test_pokeAtDeadlineTurnsLateAnswerIntoSilence() public {
        (uint256 t, uint256 s, uint256 askedAt) = _largeAsked();
        uint256 snap = vm.snapshotState();
        // A: someone pokes right at the timeout
        vm.warp(askedAt + 6 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).check), uint8(CheckState.Requested), "not silent while the answer may still come");
        vm.warp(askedAt + 6 hours + 60);
        _deliver(s, false, askedAt + 1 hours);
        _warp(24 hours);
        vault.poke(t);
        Outcome a = _sub(s).outcome;
        vm.revertToState(snap);
        // B: nobody pokes
        vm.warp(askedAt + 6 hours + 60);
        _deliver(s, false, askedAt + 1 hours);
        _warp(24 hours);
        vault.poke(t);
        Outcome b = _sub(s).outcome;
        assertEq(uint8(a), uint8(Outcome.Rejected));
        assertEq(uint8(b), uint8(a), "the same answer, the same outcome, whoever poked");
        _claimEverythingAndCheck();
    }

    function test_answerAfterTheGraceIgnoredWhoeverPoked() public {
        (uint256 t, uint256 s, uint256 askedAt) = _largeAsked();
        vm.warp(askedAt + 6 hours + SWARM_DELIVERY_GRACE);
        vault.poke(t); // past the grace: silence, the window opens at the end of the grace
        assertEq(uint8(_sub(s).check), uint8(CheckState.None));
        assertEq(_sub(s).windowEnd, askedAt + 6 hours + SWARM_DELIVERY_GRACE + 24 hours);
        uint256 snap = vm.snapshotState();
        _deliver(s, false, askedAt + 1 hours); // after the grace: ignored, whoever poked
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        vm.revertToState(snap);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        _claimEverythingAndCheck();
    }

    function test_answerDeliveredAfterTheGraceIgnoredEvenUnpoked() public {
        (uint256 t, uint256 s, uint256 askedAt) = _largeAsked();
        vm.warp(askedAt + 6 hours + SWARM_DELIVERY_GRACE + 1);
        _deliver(s, false, askedAt + 1 hours); // signed in time, delivered past the grace, nobody poked before
        vault.poke(t);
        assertEq(uint8(_sub(s).check), uint8(CheckState.None), "silence: the answer came too late");
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        _claimEverythingAndCheck();
    }

    function test_answerSignedAfterTheTimeoutIsSilenceAtTheEndOfTheGrace() public {
        (uint256 t, uint256 s, uint256 askedAt) = _largeAsked();
        vm.warp(askedAt + 6 hours + 10 minutes);
        _deliver(s, false, askedAt + 6 hours + 5 minutes); // signed late
        vault.poke(t);
        assertEq(uint8(_sub(s).check), uint8(CheckState.Requested), "decided only at the end of the grace");
        vm.warp(askedAt + 6 hours + SWARM_DELIVERY_GRACE);
        vault.poke(t);
        assertEq(uint8(_sub(s).check), uint8(CheckState.None));
        assertEq(_sub(s).windowEnd, askedAt + 6 hours + SWARM_DELIVERY_GRACE + 24 hours);
        _claimEverythingAndCheck();
    }

    // ------------------------------------------------------------------ #8 the author pulls the reward

    function test_authorFrontRunsSubmitWithWithdrawal() public {
        uint256 t = _create(author, ETH, 0.01 ether);
        // the proof is public; the author tries to pull the reward before the doer's submit lands
        vm.prank(author);
        vm.expectRevert(NoNotice.selector);
        vault.withdrawContribution(t);
        vm.prank(doer);
        vault.submit(t, "https://x.com/doer/status/1", _noEvidence(), 0.01 ether, type(uint256).max, _noSwap());
        assertEq(vault.getTask(t).pot, 0.01 ether);
        _claimEverythingAndCheck();
    }

    function test_announcedWithdrawalGivesTheDoerAnHour() public {
        uint256 t = _create(author, ETH, 0.01 ether);
        vm.prank(author);
        vault.announceWithdraw(t);
        assertEq(vault.withdrawNoticeAt(t, author), _now() + 1 hours);
        _warp(1 hours - 1);
        vm.prank(author);
        vm.expectRevert(abi.encodeWithSelector(NoticeNotDue.selector, uint64(_now() + 1)));
        vault.withdrawContribution(t);
        // the doer, warned, submits inside the hour: the share is at stake now
        uint256 s = _submit(doer, t);
        _warp(1);
        vm.prank(author);
        vm.expectRevert(NothingToClaim.selector);
        vault.withdrawContribution(t);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        _claimEverythingAndCheck();
    }

    function test_noticeExpiresAfterADay() public {
        uint256 t = _create(author, ETH, 0.01 ether);
        vm.prank(author);
        vault.announceWithdraw(t);
        _warp(1 hours + 1 days + 1);
        vm.prank(author);
        vm.expectRevert(NoNotice.selector);
        vault.withdrawContribution(t);
        _announceWithdraw(author, t);
        uint256 before = author.balance;
        vm.prank(author);
        vault.withdrawContribution(t);
        assertEq(author.balance - before, 0.01 ether);
        assertEq(vault.withdrawNoticeAt(t, author), 0, "a notice is used once");
        _claimEverythingAndCheck();
    }

    function test_noNoticeNeededAfterExpiry() public {
        uint256 t = _createWithDeadline(author, ETH, 0.01 ether, uint64(_now() + 1 days));
        _warp(1 days);
        uint256 before = author.balance;
        vm.prank(author);
        vault.withdrawContribution(t);
        assertEq(author.balance - before, 0.01 ether);
        _claimEverythingAndCheck();
    }

    // ------------------------------------------------------------------ #9 expired attestation

    function test_expiredAttestationIsIgnored() public {
        (uint256 t, uint256 s,) = _largeAsked();
        bytes32 rid = _sub(s).request;
        OracleAttestation.Attestation memory a = _attestation(false);
        a.expiresAt = uint64(_now() - 1);
        vm.expectEmit(address(vault));
        emit AttestationIgnored(rid, 16);
        intake.complete(rid, 0, a, _sign(a, attesterKey));
        assertFalse(vault.requests(rid).answered, "an expired answer is not recorded");
        a.expiresAt = 0; // no expiry: accepted
        AttestationChecker checker = AttestationChecker(vault.attestationChecker());
        assertEq(checker.check(address(vault), 7, 5, a, _sign(a, attesterKey)), 0);
        vault.poke(t);
        _claimEverythingAndCheck();
    }

    // ------------------------------------------------------------------ #10 the last attester

    function test_lastAttesterCannotBeRemoved() public {
        assertEq(registry.attesterCount(), 1);
        vm.prank(owner);
        registry.proposeAttester(attester, false);
        _warp(48 hours);
        vm.expectRevert(ParamsRegistry.LastAttester.selector);
        registry.executeAttester(attester, false);
        assertTrue(registry.isAttester(attester));
        // a second one first: then either may go, but never both
        address second = makeAddr("attester2");
        vm.prank(owner);
        registry.proposeAttester(second, true);
        _warp(48 hours);
        registry.executeAttester(second, true);
        assertEq(registry.attesterCount(), 2);
        vm.startPrank(owner);
        registry.proposeAttester(attester, false);
        registry.proposeAttester(second, false);
        vm.stopPrank();
        _warp(48 hours);
        registry.executeAttester(attester, false);
        assertEq(registry.attesterCount(), 1);
        assertFalse(registry.isAttester(attester));
        vm.expectRevert(ParamsRegistry.LastAttester.selector);
        registry.executeAttester(second, false);
        assertTrue(registry.isAttester(second));
    }
}
