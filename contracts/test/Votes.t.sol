// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";

/// @dev Signed NFT votes: replay / double vote / sold NFT / delegation / bad signatures / relayer reimbursement.
contract VotesTest is Base {
    uint8 internal constant ACCEPT = 1;
    uint8 internal constant REJECT = 2;

    uint256 internal t;
    uint256 internal s;

    function setUp() public override {
        super.setUp();
        t = _create(author, address(usdc), 100e6);
        s = _submit(doer, t);
        _dispute(dave, s);
    }

    function test_ReplayAndDoubleVote_CountOnce() public {
        Ballot[] memory bs = new Ballot[](2);
        bs[0] = _ballot(s, 1, REJECT, _ids(120, 20), voters[1]);
        bs[1] = bs[0]; // same ballot twice in one batch
        vm.prank(relayer);
        vault.submitVotes(s, bs);
        assertEq(vault.getDispute(s).votesReject, 20);
        // replay in a new batch: nothing counted, nothing reimbursed
        Ballot[] memory again = new Ballot[](1);
        again[0] = bs[0];
        vm.fee(10 gwei);
        vm.prank(relayer);
        vault.submitVotes(s, again);
        assertEq(vault.getDispute(s).votesReject, 20);
        assertEq(vault.credits(ETH, relayer), 0);
        // the same NFTs on the other side: skipped
        Ballot[] memory flip = new Ballot[](1);
        flip[0] = _ballot(s, 1, ACCEPT, _ids(120, 20), voters[1]);
        vm.prank(relayer);
        vault.submitVotes(s, flip);
        assertEq(vault.getDispute(s).votesAccept, 0);
        assertEq(vault.getDispute(s).walletsReject, 1);
    }

    function test_SoldNft_OwnershipCheckedAtSubmission() public {
        Ballot[] memory bs = new Ballot[](1);
        bs[0] = _ballot(s, 1, REJECT, _ids(120, 20), voters[1]);
        // voter1 sells 10 of the 20 before the batch is relayed
        for (uint256 id = 120; id < 130; ++id) {
            vm.prank(voters[1]);
            nft.transferFrom(voters[1], voters[4], id);
        }
        vm.prank(relayer);
        vault.submitVotes(s, bs);
        assertEq(vault.getDispute(s).votesReject, 10);
        // the buyer can still vote with the 10 unused NFTs
        _vote(s, 4, ACCEPT, 120, 10);
        assertEq(vault.getDispute(s).votesAccept, 10);
        // after voting, the NFTs move again: the new owner cannot vote them a second time
        for (uint256 id = 130; id < 140; ++id) {
            vm.prank(voters[1]);
            nft.transferFrom(voters[1], voters[3], id);
        }
        _vote(s, 3, ACCEPT, 130, 10);
        assertEq(vault.getDispute(s).votesAccept, 10);
    }

    function test_DelegateXyz_HotWalletVotesForColdWallet() public {
        uint256 hotKey = 0x407;
        address hot = vm.addr(hotKey);
        // without delegation: skipped
        Ballot[] memory bs = new Ballot[](1);
        bs[0] = _ballotByKey(s, hotKey, REJECT, _ids(120, 20), hot, _sub(s).voteEnd);
        vm.prank(relayer);
        vault.submitVotes(s, bs);
        assertEq(vault.getDispute(s).votesReject, 0);
        vm.prank(voters[1]);
        delegates.delegateAll(hot, true);
        vm.prank(relayer);
        vault.submitVotes(s, bs);
        assertEq(vault.getDispute(s).votesReject, 20);
        (, uint256 rej) = vault.votesOf(s, hot);
        assertEq(rej, 20);
    }

    function test_BadBallotsSkipped() public {
        Ballot[] memory bs = new Ballot[](4);
        // signed by someone else
        bs[0] = _ballot(s, 1, REJECT, _ids(120, 5), voters[1]);
        bs[0].voter = voters[2];
        // wrong side value
        bs[1] = _ballot(s, 1, 3, _ids(125, 5), voters[1]);
        // signed for another voteEnd
        bs[2] = _ballotByKey(s, voterKeys[1], REJECT, _ids(130, 5), voters[1], _sub(s).voteEnd + 1);
        // payTo changed after signing
        bs[3] = _ballot(s, 1, REJECT, _ids(135, 5), voters[1]);
        bs[3].payTo = relayer;
        vm.prank(relayer);
        vault.submitVotes(s, bs);
        assertEq(vault.getDispute(s).votesReject, 0);
        // nonexistent token ids are skipped without revert
        _vote(s, 1, REJECT, 5000, 3);
        assertEq(vault.getDispute(s).votesReject, 0);
    }

    function test_VotesAfterVoteEndRevert() public {
        Ballot[] memory bs = new Ballot[](1);
        bs[0] = _ballot(s, 1, REJECT, _ids(120, 20), voters[1]);
        _warp(24 hours);
        vm.prank(relayer);
        vm.expectRevert(WrongPhase.selector);
        vault.submitVotes(s, bs);
    }

    function test_RelayerReimbursedFromPot_ShortfallFromLoserPenalty() public {
        vm.fee(50 gwei);
        Ballot[] memory bs = new Ballot[](1);
        bs[0] = _ballot(s, 1, REJECT, _ids(120, 20), voters[1]);
        vm.prank(relayer);
        vault.submitVotes(s, bs);
        // the pot (0.001 ETH) is not enough at 50 gwei: all of it to the relayer, the rest recorded in IMD
        assertEq(vault.credits(ETH, relayer), 0.001 ether);
        assertEq(vault.getDispute(s).ethPot, 0);
        uint256 shortImd = vault.relayerShortfall(s, relayer);
        assertGt(shortImd, 0);
        emit log_named_uint("shortfall IMD", shortImd);
        _warp(48 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        // loser penalty 1 IMD pays the shortfall first, at most 20% of it (swarm audit #3), the rest is split 50/50
        // (winners / correct votes)
        uint256 cap = 1e18 * disputeDesk.MAX_SHORTFALL_BPS() / 10_000;
        uint256 paid = shortImd < cap ? shortImd : cap;
        uint256 before = imd.balanceOf(relayer);
        vm.prank(relayer);
        vault.claimRelayerShortfall(s);
        assertEq(imd.balanceOf(relayer) - before, paid);
        uint256 rest = 1e18 - paid;
        before = imd.balanceOf(dave);
        vm.prank(dave);
        vault.claimDisputer(s);
        assertEq(imd.balanceOf(dave) - before, 1e18 + (rest - (rest - rest * 5_000 / 10_000)));
        _claimEverythingAndCheck();
    }

    function test_RelayerShortfallPaidFromTieBond() public {
        vm.fee(50 gwei);
        _vote(s, 3, REJECT, 150, 5); // no decision
        uint256 shortImd = vault.relayerShortfall(s, relayer);
        assertGt(shortImd, 0);
        _warp(48 hours); // nobody called the swarm: accepted, the disputer bond is the loser penalty
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        uint256 before = imd.balanceOf(relayer);
        vm.prank(relayer);
        vault.claimRelayerShortfall(s);
        uint256 cap = 1e18 * disputeDesk.MAX_SHORTFALL_BPS() / 10_000; // 20% of the penalty (swarm audit #3)
        assertEq(imd.balanceOf(relayer) - before, shortImd < cap ? shortImd : cap);
        _claimEverythingAndCheck();
    }

    function test_RelayerShortfallUnpaidOnEmergencyExit() public {
        vm.fee(50 gwei);
        _vote(s, 3, REJECT, 150, 5);
        assertGt(vault.relayerShortfall(s, relayer), 0);
        _warp(24 hours);
        intake.setBroken(true);
        vm.mockCallRevert(address(vault), abi.encodeWithSelector(TaskVault.advanceFromSelf.selector, t), "");
        _warp(24 hours + 30 days);
        vault.emergencyExit(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Unwound));
        vm.prank(relayer);
        vm.expectRevert(NothingToClaim.selector);
        vault.claimRelayerShortfall(s);
        vm.clearMockedCalls();
        intake.setBroken(false);
        _claimEverythingAndCheck();
    }

    function test_RelayerPartiallyFromPot() public {
        vm.fee(0.2 gwei);
        _vote(s, 1, REJECT, 120, 20);
        uint256 got = vault.credits(ETH, relayer);
        assertGt(got, 0);
        assertLt(got, 0.001 ether);
        assertEq(vault.relayerShortfall(s, relayer), 0);
        assertEq(vault.getDispute(s).ethPot, 0.001 ether - got);
        _warp(48 hours);
        vault.poke(t);
        // dave gets the pot leftover
        uint256 before = dave.balance;
        vm.prank(dave);
        vault.claimDisputer(s);
        assertEq(dave.balance - before, 0.001 ether - got);
        _claimEverythingAndCheck();
    }

    function test_MinWinnerWallets() public {
        Params memory p = defaultParams();
        p.minWinnerWallets = 2;
        vm.prank(owner);
        registry.proposeParams(p);
        _warp(48 hours);
        registry.activateParams();
        uint256 t2 = _create(author, address(usdc), 100e6);
        uint256 s2 = _submit(doer2, t2);
        _dispute(dave, s2);
        _vote(s2, 0, ACCEPT, 0, 110); // one wallet, delta 110: below minWinnerWallets = 2 at the vote end
        assertEq(uint8(_phase(s2)), uint8(Phase.Voting));
        _warp(24 hours);
        vault.poke(t2);
        assertEq(uint8(_phase(s2)), uint8(Phase.NoDecision));
    }

    function test_VoterRewardSplitByCorrectVotes() public {
        // 20 + 10 correct accept votes, 5 wrong reject votes
        _vote(s, 1, ACCEPT, 120, 20);
        _vote(s, 2, ACCEPT, 140, 10);
        _vote(s, 3, REJECT, 150, 5);
        _warp(48 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        Settlement memory st = vault.getSettlement(s);
        assertEq(st.voterVotesLeft, 30);
        assertEq(st.voterFee, 6e6); // 6% of R in USDC
        assertEq(st.voterImd, 0.5e18); // half of dave's bond
        vm.expectRevert(NothingToClaim.selector);
        vault.claimVoterReward(s, voters[3]); // wrong side
        vault.claimVoterReward(s, voters[1]);
        vault.claimVoterReward(s, voters[2]);
        assertEq(usdc.balanceOf(voters[1]) - 1_000_000e6, 4e6);
        assertEq(usdc.balanceOf(voters[2]) - 1_000_000e6, 2e6);
        assertEq(imd.balanceOf(voters[1]) - 10_000e18, uint256(0.5e18) * 20 / 30);
        assertEq(imd.balanceOf(voters[2]) - 10_000e18, 0.5e18 - uint256(0.5e18) * 20 / 30); // exact rest
        assertTrue(vault.voterClaimed(s, voters[1]));
        assertTrue(vault.tokenVoted(s, 120));
        assertFalse(vault.tokenVoted(s, 0));
        vm.expectRevert(NothingToClaim.selector);
        vault.claimVoterReward(s, voters[1]);
        _claimEverythingAndCheck();
    }
}
