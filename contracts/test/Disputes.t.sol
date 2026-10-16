// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";

/// @dev Disputes, NFT votes, decisions, paid swarm calls without an NFT decision, appeals, swarm silence.
///      Standard case: USDC task R = 100 (12.5 IMD): doer bond 1 IMD, dispute bond 1 IMD, swarm fee 0.5 IMD.
///      Rules: the loser bond goes 50/50 to the winning side and to the NFT
///      votes on the final side when the NFT decided right, all of it to the winners otherwise; NFT tie and nobody
///      called the swarm: accepted, disputer bonds 50/50 to the doer and the treasury. Fee 10%: 6% to correct NFT
///      votes + 4% treasury when accepted after a dispute the NFT decided right, else all to the treasury.
contract DisputesTest is Base {
    uint8 internal constant ACCEPT = 1;
    uint8 internal constant REJECT = 2;

    uint256 internal t;
    uint256 internal s;

    function setUp() public override {
        super.setUp();
        t = _create(author, address(usdc), 100e6);
        s = _submit(doer, t);
    }

    // ================================================================== NFT decides

    function test_Dispute_NftRejects_BondSplit5050() public {
        _dispute(dave, s);
        _dispute(erin, s);
        assertEq(uint8(_phase(s)), uint8(Phase.Voting));
        _vote(s, 1, REJECT, 120, 20);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Open));
        assertEq(vault.getTask(t).rejectedCount, 1);
        assertEq(vault.getTask(t).pot, 100e6); // the reward stays in the task, never to the disputers

        // doer bond 1 IMD: 0.5 to the two disputers, 0.5 to the 20 correct NFT votes
        _claimAs(dave);
        _claimAs(erin);
        assertEq(_imdGain(dave), 0.25e18);
        assertEq(_imdGain(erin), 0.25e18);
        assertEq(vault.credits(address(imd), doer), 0);
        vault.claimVoterReward(s, voters[1]);
        assertEq(imd.balanceOf(voters[1]) - 10_000e18, 0.5e18);
        assertEq(usdc.balanceOf(voters[1]), 1_000_000e6); // no fee on a rejection
        assertEq(dave.balance, 100 ether); // dispute pot fully back (no gas price in this test)
        _claimEverythingAndCheck();
    }

    function test_Dispute_NftAccepts_Fee6To4_Bond5050() public {
        _dispute(dave, s);
        _dispute(erin, s);
        _vote(s, 1, ACCEPT, 120, 20);
        _warp(48 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(vault.credits(address(usdc), doer), 90e6);
        assertEq(vault.credits(address(imd), doer), 1e18 + 1e18); // bond + 50% of 2 IMD
        // accepted after a dispute the NFT decided right: 6% to the correct votes, 4% to the treasury
        assertEq(vault.treasuryPot(address(usdc)), 4e6);
        assertEq(vault.getSettlement(s).voterFee, 6e6);
        vault.claimVoterReward(s, voters[1]);
        assertEq(imd.balanceOf(voters[1]) - 10_000e18, 1e18);
        assertEq(usdc.balanceOf(voters[1]) - 1_000_000e6, 6e6);
        vm.expectRevert(NothingToClaim.selector);
        vault.claimVoterReward(s, voters[1]);
        _claimAs(dave);
        assertEq(_imdGain(dave), -1e18);
        _claimEverythingAndCheck();
    }

    function test_ClaimsPlayTimersThemselves_NoPokeNeeded() public {
        _dispute(dave, s);
        _vote(s, 1, REJECT, 120, 20);
        _warp(48 hours); // nobody poked: vote end and appeal window passed
        vm.expectEmit(address(disputeDesk));
        emit DisputerClaimed(s, dave, 1e18 + 0.5e18, 0.001 ether);
        vm.prank(dave);
        vault.claimDisputer(s);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        vault.claimVoterReward(s, voters[1]);
        uint256[] memory ids = _ids(119, 3);
        bool[] memory voted = vault.tokensVoted(s, ids);
        assertFalse(voted[0]);
        assertTrue(voted[1]);
        assertTrue(voted[2]);
        _claimEverythingAndCheck();
    }

    /// @dev There is no instant decision (audit C-02): even a margin of 100 (the removed `instantDelta`)
    ///      waits for the vote end; votes keep being counted until then, and the decision uses the final count.
    function test_NoInstantDecision_DecidesAtVoteEnd() public {
        _dispute(dave, s);
        _vote(s, 0, ACCEPT, 0, 99);
        assertEq(uint8(_phase(s)), uint8(Phase.Voting));
        _vote(s, 0, ACCEPT, 99, 1); // 100: would have decided at once under the removed instant rule
        assertEq(uint8(_phase(s)), uint8(Phase.Voting), "no decision on a partial count");
        assertEq(_sub(s).decidedAt, 0);
        // voting stays open until the vote end
        _vote(s, 1, REJECT, 120, 20);
        assertEq(vault.getDispute(s).votesReject, 20);
        _warp(_sub(s).voteEnd - _now() - 1);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.Voting), "still voting one second before the end");
        _warp(1);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.Decided)); // 100 vs 20 >= endDelta
        assertEq(_sub(s).decidedAt, _sub(s).voteEnd);
        assertEq(_sub(s).callFrom, _sub(s).voteEnd);
        // voting is closed at the vote end
        Ballot[] memory bs = new Ballot[](1);
        bs[0] = _ballot(s, 2, REJECT, _ids(140, 10), voters[2]);
        vm.prank(relayer);
        vm.expectRevert(WrongPhase.selector);
        vault.submitVotes(s, bs);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        _claimEverythingAndCheck();
    }

    function test_NoDecision_NobodyCalls_Accepted_DisputerBonds5050DoerTreasury() public {
        _dispute(dave, s);
        _dispute(erin, s);
        _vote(s, 1, ACCEPT, 120, 20);
        _vote(s, 2, REJECT, 140, 10);
        _vote(s, 4, REJECT, 155, 2); // 20 vs 12: delta 8
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        assertEq(_sub(s).callFrom, _sub(s).voteEnd);
        _warp(24 hours - 1);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        _warp(1);
        vault.poke(t);
        // nobody called the swarm: accepted; disputer bonds 50/50 to the doer and the treasury; fee all treasury
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Completed));
        assertFalse(vault.getSettlement(s).neutral);
        assertEq(vault.credits(address(usdc), doer), 90e6);
        assertEq(vault.credits(address(imd), doer), 1e18 + 1e18);
        assertEq(vault.treasuryPot(address(usdc)), 10e6);
        assertEq(vault.treasuryPot(address(imd)), 1e18);
        _claimAs(dave);
        _claimAs(erin);
        assertEq(_imdGain(dave), -1e18);
        assertEq(_imdGain(erin), -1e18);
        assertEq(dave.balance, 100 ether); // dispute pot back
        vm.expectRevert(NothingToClaim.selector); // the NFT did not decide: votes are not looked at
        vault.claimVoterReward(s, voters[1]);
        _claimEverythingAndCheck();
    }

    function test_DisputeWindowClosedAndLimits() public {
        _warp(24 hours);
        vm.prank(dave);
        vm.expectRevert(WrongPhase.selector); // accepted by the lazy timer first
        vault.dispute{value: 0.001 ether}(s, "r", 0.001 ether, _noSwap());

        uint256 t2 = _create(author, address(usdc), 100e6);
        uint256 s2 = _submit(doer2, t2);
        _warp(1 hours); // the vote (24h from the first dispute) outlives the dispute window (24h from activation)
        vm.startPrank(dave);
        vm.expectRevert(FeeOutOfRange.selector);
        vault.dispute{value: 0.0001 ether}(s2, "r", 0.0001 ether, _noSwap());
        vm.expectRevert(FeeOutOfRange.selector);
        vault.dispute{value: 0.02 ether}(s2, "r", 0.02 ether, _noSwap());
        vault.dispute{value: 0.001 ether}(s2, "r", 0.001 ether, _noSwap());
        vm.expectRevert(AlreadyDisputed.selector);
        vault.dispute{value: 0.001 ether}(s2, "r", 0.001 ether, _noSwap());
        vm.stopPrank();
        // joining is allowed until the dispute window (24h) closes, even while voting runs
        _warp(22 hours);
        _dispute(erin, s2);
        _warp(1 hours);
        vm.prank(bob);
        vm.expectRevert(WindowClosed.selector);
        vault.dispute{value: 0.001 ether}(s2, "r", 0.001 ether, _noSwap());
    }

    function test_DoerReply() public {
        _dispute(dave, s);
        vm.prank(dave);
        vm.expectRevert(NotDoer.selector);
        vault.reply(s, "x");
        vm.prank(doer);
        vault.reply(s, "ipfs://my-answer");
        vm.prank(doer);
        vm.expectRevert(AlreadyReplied.selector);
        vault.reply(s, "again");
        assertEq(_sub(s).doerReply, "ipfs://my-answer");
        uint256 t2 = _create(author, address(usdc), 100e6);
        uint256 s2 = _submit(doer2, t2);
        _dispute(dave, s2);
        _warp(12 hours);
        vm.prank(doer2);
        vm.expectRevert(WindowClosed.selector);
        vault.reply(s2, "late");
    }

    // ================================================================== contributors in the case

    function test_ContributorDisputerWins_HisShareGoesToCorrectVotes() public {
        _topUp(alice, t, 10e6); // pending, but alice is a contributor of this task now
        _dispute(alice, s);
        _dispute(dave, s);
        _vote(s, 1, REJECT, 120, 20);
        _warp(48 hours);
        vault.poke(t);
        // doer bond 1: 0.5 to the votes, 0.5 to the winners: alice's 0.25 -> the votes, dave 0.25
        assertEq(vault.getSettlement(s).voterImd, 0.75e18);
        _claimAs(alice);
        _claimAs(dave);
        assertEq(_imdGain(alice), 0); // only her bond back
        assertEq(_imdGain(dave), 0.25e18);
        vault.claimVoterReward(s, voters[1]);
        assertEq(imd.balanceOf(voters[1]) - 10_000e18, 0.75e18);
        _claimEverythingAndCheck();
    }

    function test_ContributorDoerWins_OnlyOwnBond() public {
        uint256 t2 = _create(author, address(usdc), 100e6);
        uint256 s2 = _submit(author, t2); // the author submits to his own task
        _dispute(dave, s2);
        _vote(s2, 1, ACCEPT, 120, 20);
        _warp(48 hours);
        vault.poke(t2);
        assertEq(uint8(_sub(s2).outcome), uint8(Outcome.Accepted));
        assertEq(vault.credits(address(imd), author), 1e18); // own bond only
        assertEq(vault.getSettlement(s2).voterImd, 1e18); // his half goes to the correct votes too
        _claimEverythingAndCheck();
    }

    function test_DisputerWhoTopsUpLater_StillGetsOnlyHisBond() public {
        _dispute(dave, s);
        _topUp(dave, t, 1e6); // becomes a contributor after disputing
        _vote(s, 1, REJECT, 120, 20);
        _warp(48 hours);
        vault.poke(t);
        _claimAs(dave);
        assertEq(_imdGain(dave), 0);
        assertEq(vault.treasuryPot(address(imd)), 0.5e18);
        _claimEverythingAndCheck();
    }

    // ================================================================== NFT undecided: anyone calls the swarm, paying

    function test_NoDecision_CallSwarm_Rejects_CallerReimbursedByLoser() public {
        _dispute(dave, s);
        _dispute(erin, s);
        _vote(s, 3, REJECT, 150, 5); // delta 5 < 10
        _warp(24 hours);
        uint256 bobBefore = imd.balanceOf(bob);
        _callSwarm(bob, s); // advances to NoDecision, then asks at once
        assertEq(uint8(_phase(s)), uint8(Phase.Asked));
        assertEq(bobBefore - imd.balanceOf(bob), 1e18 + PRICE); // dispute bond + fee
        assertEq(imd.balanceOf(swarmPayee), PRICE);
        Appeal memory a = vault.getAppeal(s);
        assertEq(a.appellant, bob);
        assertFalse(a.sidesDoer);
        assertEq(a.spent, PRICE);
        _answer(s, false);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        // penalty = doer bond 1: 0.5 fee back to bob, the rest 0.5 all to the winners (no NFT decision)
        // pro rata dave 1, erin 1, bob 1
        uint256 third = uint256(0.5e18) / 3;
        assertEq(vault.credits(address(imd), bob), 1e18 + PRICE + third);
        assertEq(vault.treasuryPot(address(imd)), 0);
        assertEq(vault.credits(address(imd), doer), 0);
        _claimAs(dave);
        assertEq(_imdGain(dave), int256((0.5e18 - third) / 2));
        vm.expectRevert(NothingToClaim.selector); // NFT undecided: no voter reward
        vault.claimVoterReward(s, voters[3]);
        _claimEverythingAndCheck();
    }

    function test_NoDecision_CallSwarm_Accepts_CallerLosesBondAndFee() public {
        _dispute(dave, s);
        _dispute(erin, s);
        _warp(24 hours); // nobody voted
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        _callSwarm(dave, s); // a disputer calls
        _answer(s, true);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        // losers: disputers 2 + caller 1 = 3 IMD, all to the doer (NFT undecided); the fee is the caller's loss
        assertEq(vault.credits(address(imd), doer), 1e18 + 3e18);
        assertEq(vault.treasuryPot(address(imd)), 0);
        assertEq(vault.treasuryPot(address(usdc)), 10e6);
        _claimAs(dave);
        assertEq(_imdGain(dave), -int256(2e18 + PRICE));
        _claimEverythingAndCheck();
    }

    function test_NoDecision_DoerCallsSwarm_Confirmed() public {
        _dispute(dave, s);
        _dispute(erin, s);
        _warp(24 hours);
        _callSwarm(doer, s, true); // the doer calls to take the full disputer bonds instead of the tie split
        assertTrue(vault.getAppeal(s).sidesDoer);
        _answer(s, true);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        // penalty 2: 0.5 fee back, 1.5 to the winners (doer bond 1 + caller bond 1, both the doer)
        assertEq(vault.credits(address(imd), doer), 1e18 + 1e18 + PRICE + 1.5e18);
        assertEq(_imdGain(doer), 1.5e18);
        _claimEverythingAndCheck();
    }

    function test_NoDecision_DoerCallsSwarm_Rejected() public {
        _dispute(dave, s);
        _warp(24 hours);
        _callSwarm(doer, s, true);
        _answer(s, false);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        // losers: doer bond 1 + caller bond 1 = 2, all to dave
        _claimAs(dave);
        assertEq(_imdGain(dave), 2e18);
        assertEq(_imdGain(doer), -int256(2e18 + PRICE));
        _claimEverythingAndCheck();
    }

    function test_NoDecision_SilentStatus2_NobodyCallsAgain_TieRule() public {
        _dispute(dave, s);
        _warp(24 hours);
        _callSwarm(erin, s);
        _warp(1 hours);
        _silent(s); // status 2: no callback, the Intake reports the request completed
        vault.poke(t);
        // back to the undecided state at once, a new window from the moment of silence; erin's bond is hers
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        assertEq(_sub(s).callFrom, _now());
        assertEq(vault.credits(address(imd), erin), 1e18);
        assertEq(vault.getAppeal(s).appellant, address(0));
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        _claimAs(dave);
        assertEq(_imdGain(dave), -1e18); // tie rule: half to the doer, half to the treasury
        assertEq(_imdGain(erin), -int256(PRICE)); // only her fee is lost
        assertEq(vault.credits(address(imd), doer), 1e18 + 0.5e18);
        assertEq(vault.treasuryPot(address(imd)), 0.5e18);
        _claimEverythingAndCheck();
    }

    function test_NoDecision_SilentTimeout_WindowFromSilence() public {
        _dispute(dave, s);
        _warp(24 hours);
        _callSwarm(erin, s);
        uint256 askedAt = _now();
        // silence only after the timeout and the delivery grace (swarm audit #7)
        _warp(6 hours + SWARM_DELIVERY_GRACE - 1);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.Asked));
        _warp(1);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        assertEq(_sub(s).callFrom, askedAt + 6 hours + SWARM_DELIVERY_GRACE);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        _claimEverythingAndCheck();
    }

    function test_NoDecision_Silent_CalledAgain_Answers() public {
        _dispute(dave, s);
        _warp(24 hours);
        _callSwarm(erin, s);
        bytes32 first = _sub(s).request;
        _warp(6 hours + 23 hours); // timeout, then inside the new window
        _callSwarm(bob, s);
        assertEq(_sub(s).asks, 2);
        assertTrue(_sub(s).request != first);
        _answer(s, false);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        // penalty 1: 0.5 fee back to bob, 0.5 to dave and bob (bonds 1 / 1)
        assertEq(vault.credits(address(imd), bob), 1e18 + PRICE + 0.25e18);
        _claimAs(dave);
        assertEq(_imdGain(dave), 0.25e18);
        assertEq(_imdGain(erin), -int256(PRICE));
        assertEq(imd.balanceOf(swarmPayee), 2 * PRICE);
        _claimEverythingAndCheck();
    }

    function test_SilenceLoop_EveryCallCostsItsFee() public {
        _dispute(dave, s);
        _warp(24 hours);
        for (uint256 i; i < 3; ++i) {
            _callSwarm(erin, s);
            _silent(s);
            vault.poke(t);
            assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        }
        assertEq(imd.balanceOf(swarmPayee), 3 * PRICE);
        assertEq(vault.credits(address(imd), erin), 3e18); // three bonds back
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(_imdGain(erin), -int256(3 * PRICE));
        _claimEverythingAndCheck();
    }

    function test_NoDecision_CallAfterWindow_Reverts() public {
        _dispute(dave, s);
        _warp(48 hours);
        vm.prank(erin);
        vm.expectRevert(WrongPhase.selector); // the lazy timer accepts the submission first
        vault.callSwarm(s, false, "ipfs://caller-reason", type(uint256).max, _noSwap());
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        _claimEverythingAndCheck();
    }

    function test_CallSwarm_ActionNotSold_DefaultStands() public {
        _dispute(dave, s);
        _warp(24 hours);
        intake.setPrice(0); // priceOf returns 0: the Intake does not sell the action any more
        vm.prank(erin);
        vm.expectRevert(ActionNotSold.selector);
        vault.callSwarm(s, false, "ipfs://caller-reason", type(uint256).max, _noSwap());
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        _claimEverythingAndCheck();
    }

    function test_CallSwarm_LowerPrice_ReimbursedWhatWasPaid() public {
        _dispute(dave, s);
        _warp(24 hours);
        intake.setPrice(0.2e18);
        _callSwarm(erin, s);
        _answer(s, false);
        vault.poke(t);
        // penalty 1: 0.2 fee back to erin, 0.8 to dave / erin
        assertEq(vault.credits(address(imd), erin), 1e18 + 0.2e18 + 0.4e18);
        _claimAs(dave);
        assertEq(_imdGain(dave), 0.4e18);
        _claimEverythingAndCheck();
    }

    function test_CallSwarm_WrongPhase() public {
        vm.expectRevert(WrongPhase.selector);
        vault.callSwarm(s, false, "ipfs://caller-reason", type(uint256).max, _noSwap());
        _dispute(dave, s);
        vm.expectRevert(WrongPhase.selector); // still voting
        vault.callSwarm(s, false, "ipfs://caller-reason", type(uint256).max, _noSwap());
    }

    // ================================================================== appeals

    function test_Appeal_SwarmAgrees() public {
        _decideAccept();
        uint256 before = imd.balanceOf(dave);
        _appeal(dave, s); // dave appeals the "accept" decision
        assertEq(before - imd.balanceOf(dave), 1e18 + PRICE); // bond + fee, paid now
        assertEq(uint8(_phase(s)), uint8(Phase.Appealed));
        assertEq(vault.getAppeal(s).funds, PRICE);
        vault.poke(t); // reply window still open: nothing is asked
        assertEq(uint8(_phase(s)), uint8(Phase.Appealed));
        _warp(12 hours);
        vault.poke(t); // the prepaid question is asked lazily
        assertEq(uint8(_phase(s)), uint8(Phase.Asked));
        _answer(s, true); // agrees with the NFT
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        // losers: dave (dispute 1 + appeal 1) and erin (1) = 3 IMD: 1.5 to the doer, 1.5 to accept voters
        assertEq(vault.credits(address(imd), doer), 1e18 + 1.5e18);
        assertEq(vault.credits(address(imd), dave), 0); // bond and fee lost
        vault.claimVoterReward(s, voters[1]);
        assertEq(imd.balanceOf(voters[1]) - 10_000e18, 1.5e18);
        assertEq(usdc.balanceOf(voters[1]) - 1_000_000e6, 6e6);
        _claimEverythingAndCheck();
    }

    function test_Appeal_SwarmFlips_FeeReimbursedByLoser_WinnerTakesAll() public {
        _decideAccept();
        _appeal(dave, s);
        vm.prank(doer);
        vault.appealReply(s, "ipfs://doer-appeal-reply");
        vault.poke(t); // asked at once after the reply
        assertEq(uint8(_phase(s)), uint8(Phase.Asked));
        _answer(s, false); // flips: rejected
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        // penalty = doer bond 1: 0.5 fee back to dave from it (not from the treasury); the NFT was wrong, so the
        // rest 0.5 all to the winners pro rata (dave appeal 1, dave dispute 1, erin 1)
        uint256 appPart = uint256(0.5e18) / 3;
        assertEq(vault.credits(address(imd), dave), 1e18 + PRICE + appPart);
        assertEq(vault.treasuryPot(address(imd)), 0);
        _claimAs(erin);
        assertEq(_imdGain(erin), int256((0.5e18 - appPart) / 2));
        vm.expectRevert(NothingToClaim.selector); // wrong NFT votes get nothing
        vault.claimVoterReward(s, voters[1]);
        _claimEverythingAndCheck();
    }

    function test_Appeal_ByDoerSide_Flip() public {
        _dispute(dave, s);
        _vote(s, 1, REJECT, 120, 20);
        _warp(24 hours);
        vault.poke(t);
        _appeal(doer, s); // the doer appeals the "reject" decision
        assertTrue(vault.getAppeal(s).sidesDoer);
        vm.prank(doer);
        vm.expectRevert(NotOpponent.selector);
        vault.appealReply(s, "x");
        vm.prank(dave);
        vault.appealReply(s, "ipfs://disputer-reply");
        vault.poke(t);
        _answer(s, true); // flip to accepted
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        // loser dave 1 IMD: 0.5 fee back to the doer-appellant, 0.5 to doer bond 1 + appeal bond 1 (all doer)
        assertEq(vault.credits(address(usdc), doer), 90e6);
        assertEq(vault.treasuryPot(address(usdc)), 10e6); // the NFT was wrong: the whole fee to the treasury
        assertEq(vault.credits(address(imd), doer), 1e18 + 1e18 + PRICE + 0.5e18);
        _claimEverythingAndCheck();
    }

    function test_Appeal_Silent_DecisionStands_NewWindow() public {
        _decideAccept();
        _appeal(dave, s);
        _warp(12 hours);
        vault.poke(t);
        _warp(1 hours);
        _silent(s);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
        assertEq(_sub(s).callFrom, _now());
        assertEq(vault.credits(address(imd), dave), 1e18); // appeal bond back, fee lost
        assertEq(vault.getAppeal(s).appellant, address(0));
        _warp(24 hours - 1);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
        _warp(1);
        vault.poke(t); // nobody appealed again: the NFT decision is final
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        // losers dave and erin (2 IMD): 1 to the doer, 1 to the accept voters
        assertEq(vault.credits(address(imd), doer), 1e18 + 1e18);
        _claimAs(dave);
        assertEq(_imdGain(dave), -int256(1e18 + PRICE));
        _claimEverythingAndCheck();
    }

    function test_Appeal_Silent_ReappealFlips() public {
        _decideAccept();
        _appeal(dave, s);
        _warp(12 hours);
        vault.poke(t);
        _silent(s);
        _warp(1 hours);
        _appeal(erin, s); // advances to Decided (silence), then appeals in the new window
        assertEq(vault.getAppeal(s).appellant, erin);
        vm.prank(doer);
        vault.appealReply(s, "ipfs://second-reply");
        vault.poke(t);
        assertEq(_sub(s).asks, 2);
        _answer(s, false);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        // penalty 1: 0.5 fee back to erin, 0.5 pro rata (dave 1, erin dispute 1, erin appeal 1)
        uint256 appPart = uint256(0.5e18) / 3;
        assertEq(vault.credits(address(imd), erin), 1e18 + PRICE + appPart);
        _claimAs(dave);
        assertEq(_imdGain(dave), int256((0.5e18 - appPart) / 2) - int256(PRICE));
        _claimEverythingAndCheck();
    }

    function test_Appeal_LateAnswerAfterSilenceIgnored() public {
        _decideAccept();
        _appeal(dave, s);
        _warp(12 hours);
        vault.poke(t);
        bytes32 first = _sub(s).request;
        _warp(6 hours + SWARM_DELIVERY_GRACE); // the timeout and the delivery grace (swarm audit #7)
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
        OracleAttestation.Attestation memory a = _attestation(false);
        intake.complete(first, 0, a, _sign(a, attesterKey)); // recorded, but too late
        assertTrue(vault.requests(first).answered);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        _claimEverythingAndCheck();
    }

    function test_Appeal_PriceRaised_AppealVoided() public {
        _decideAccept();
        _appeal(dave, s);
        _warp(12 hours);
        intake.setPrice(2e18);
        vault.poke(t); // the prepaid fee no longer covers the price: nothing is asked
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
        assertEq(_sub(s).callFrom, _now());
        assertEq(vault.credits(address(imd), dave), 1e18 + PRICE); // bond + unspent fee
        assertEq(imd.balanceOf(swarmPayee), 0);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        _claimEverythingAndCheck();
    }

    function test_Appeal_IntakeReverts_AppealVoided() public {
        _decideAccept();
        _appeal(dave, s);
        _warp(12 hours);
        intake.setBroken(true); // request() reverts: the machine must not get stuck
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
        assertEq(vault.credits(address(imd), dave), 1e18 + PRICE);
        intake.setBroken(false);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        _claimEverythingAndCheck();
    }

    function test_Appeal_WindowClosed() public {
        _decideAccept();
        _warp(24 hours);
        vm.prank(dave);
        vm.expectRevert(WrongPhase.selector);
        vault.appeal(s, "late", type(uint256).max, _noSwap());
    }

    function test_Appeal_ActionNotSold() public {
        _decideAccept();
        intake.setPrice(0);
        vm.prank(dave);
        vm.expectRevert(ActionNotSold.selector);
        vault.appeal(s, "ipfs://appeal", type(uint256).max, _noSwap());
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        _claimEverythingAndCheck();
    }

    // ================================================================== helpers

    function _decideAccept() internal {
        _dispute(dave, s);
        _dispute(erin, s);
        _vote(s, 1, ACCEPT, 120, 20);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
    }

    function _claimAs(address who) internal {
        vm.prank(who);
        vault.claimDisputer(s);
        vm.startPrank(who);
        if (vault.credits(address(imd), who) != 0) vault.withdraw(address(imd));
        vm.stopPrank();
    }

    /// @dev IMD gained by `who` since setUp funding (10,000 IMD), after withdrawing credits.
    function _imdGain(address who) internal returns (int256) {
        if (vault.credits(address(imd), who) != 0) {
            vm.prank(who);
            vault.withdraw(address(imd));
        }
        return int256(imd.balanceOf(who)) - int256(10_000e18);
    }
}
