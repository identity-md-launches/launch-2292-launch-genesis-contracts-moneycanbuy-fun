// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../Base.t.sol";

/// @dev Regression tests of the rule changes for audit B-01, C-02 and C-01. Each test fails on the code before
///      the change and passes after it. Errors that exist only after the change are matched by signature, so the
///      file also compiles against the old sources.
contract AuditFixPTest is Base {
    uint8 internal constant ACCEPT = 1;
    uint8 internal constant REJECT = 2;

    /// @dev D1 (B-01): no public fallback for swarm answers. The swarm caller's question gets a "no", but the Intake
    ///      callback fails (out of gas). Before, anyone could hand the signed answer in with `submitAttestation` once
    ///      the Intake reported the request completed, and the case ended Rejected. Now the selector is unknown, the
    ///      lost callback is silence and the tie rule accepts.
    function test_FixP_D1_LostCallbackIsSilence_NoPublicFallback() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        _callSwarm(erin, s); // against the doer
        bytes32 rid = _sub(s).request;

        intake.setCallbackGas(5_000); // the callback runs out of gas
        OracleAttestation.Attestation memory a = _attestation(false);
        a.questionHash = vault.requests(rid).questionHash; // bound to our exact question
        bytes memory sig = _sign(a, attesterKey);
        intake.complete(rid, 0, a, sig);
        assertFalse(intake.lastDelivered());

        (bool ok, bytes memory ret) =
            address(vault).call(abi.encodeCall(IRemovedFallback.submitAttestation, (rid, a, sig)));
        assertFalse(ok, "the public fallback is gone");
        assertEq(bytes4(ret), UnknownFunction.selector);
        assertFalse(vault.requests(rid).answered, "the lost answer is not recorded");

        vault.poke(t); // the Intake reports the request completed without an answer: silence
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted), "tie rule, not the undelivered no");
        _claimEverythingAndCheck();
    }

    /// @dev D2 (C-02): the NFT decides only at the vote end. A batch with a margin of 120 (>= the old instantDelta
    ///      100) used to decide at once and close the vote; now it only counts, the other side's 115 votes still
    ///      land, and the vote end applies endDelta / minWinnerWallets to the full count (margin 5 < 10: no decision).
    function test_FixP_D2_NoDecisionOnAPartialCount() public {
        uint256 rKey = 0xB0B6;
        address rVoter = vm.addr(rKey);
        for (uint256 id = 1000; id < 1115; ++id) {
            nft.mint(rVoter, id);
        }
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);

        _vote(s, 0, ACCEPT, 0, 120);
        assertEq(uint8(_phase(s)), uint8(Phase.Voting), "no decision on a partial count");
        assertEq(uint8(_sub(s).nftDecision), uint8(Verdict.None));

        Ballot[] memory bs = new Ballot[](1);
        bs[0] = _ballotByKey(s, rKey, REJECT, _ids(1000, 115), rVoter, _sub(s).voteEnd);
        vm.prank(relayer);
        vault.submitVotes(s, bs); // accepted until the vote end
        assertEq(vault.getDispute(s).votesReject, 115);

        vm.warp(_sub(s).voteEnd - 1);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.Voting));
        _endVote(s);
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision), "the full count decides: margin 5 < endDelta");
        _claimEverythingAndCheck();
    }

    /// @dev D3 (C-01): the doer cannot dispute his own submission, so he can never answer an appeal "as a disputer".
    ///      Before, his self-dispute let him spend the one appeal reply in the name of the real disputers.
    function test_FixP_D3_DoerCannotDispute() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        vm.prank(doer);
        vm.expectRevert(abi.encodeWithSignature("DoerCannotDispute()"));
        vault.dispute{value: 0.001 ether}(s, "placeholder", 0.001 ether, _noSwap());
        assertEq(vault.getDisputer(s, doer).bond, 0);
        assertEq(uint8(_phase(s)), uint8(Phase.Review), "no vote started by the doer");

        _dispute(dave, s);
        _vote(s, 0, REJECT, 0, 120);
        if (_phase(s) == Phase.Voting) _endVote(s); // independent of D2: decided either way
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
        _appeal(doer, s); // sides with the doer: the opponents are the disputers
        vm.prank(doer);
        vm.expectRevert(NotOpponent.selector);
        vault.appealReply(s, "Disputers agree the proof is valid");
        vm.prank(dave);
        vault.appealReply(s, "The post predates the task");
        assertEq(vault.getAppeal(s).reply, "The post predates the task");
        _claimEverythingAndCheck();
    }
}
