// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";

/// @dev Swarm answers (callback only, spoofing, late / duplicate answers) and the mandatory check.
contract SwarmTest is Base {
    uint256 internal t;
    uint256 internal s;

    function setUp() public override {
        super.setUp();
        t = _create(author, address(usdc), 100e6);
        s = _submit(doer, t);
        _dispute(dave, s);
        _warp(24 hours);
        _callSwarm(erin, s); // no votes: erin pays fee + bond and calls the swarm
    }

    function test_CallbackSelectorMatchesDocs() public pure {
        assertEq(ITaskVault.onOracleResult.selector, bytes4(0x510379c7));
        assertEq(CALLBACK_SELECTOR, bytes4(0x510379c7));
    }

    function test_RequestShapeAndBody() public {
        bytes32 rid = _sub(s).request;
        assertEq(rid, keccak256(abi.encode(block.chainid, address(intake), uint256(1))));
        // the preview shows the next question exactly as it will be sent
        uint256 t2 = _create(author, address(usdc), 100e6);
        uint256 s2 = _submit(doer2, t2);
        _dispute(dave, s2);
        _warp(24 hours);
        vault.poke(t2);
        (bytes memory body,) = vault.previewSwarmBody(s2, 2);
        _callSwarm(erin, s2);
        assertLe(body.length, 16_384);
        // the sent body = the preview + the caller's own reason as "appeal" in the definitions
        assertEq(intake.lastBodyLength(), body.length + bytes(',"appeal":"ipfs://caller-reason"').length);
        // starts with the fixed header, includes the claim and the consumer
        assertEq(bytes(string(body))[0], "{");
        assertTrue(_contains(body, '"claim_1":"ipfs://reason"'));
        assertTrue(_contains(body, '"answerType":"bool"'));
        assertTrue(_contains(body, '"verifyingContract":"0x'));
    }

    function test_CallbackGasUnder100k() public {
        _answer(s, true);
        assertLt(intake.lastCallbackGasUsed(), 100_000);
        emit log_named_uint("callback gas", intake.lastCallbackGasUsed());
    }

    function test_DuplicateAnswerIgnored_FirstWins() public {
        _answer(s, false);
        bytes32 rid = _sub(s).request;
        OracleAttestation.Attestation memory a = _attestation(true);
        bytes memory sig = _sign(a, attesterKey);
        // second delivery through the real path cannot happen (Intake completes once); a direct second
        // callback from the Intake address is ignored without revert
        vm.expectEmit(address(vault));
        emit AttestationIgnored(rid, 3);
        vm.prank(address(intake));
        vault.onOracleResult(rid, a, sig);
        assertFalse(vault.requests(rid).answer);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        _claimEverythingAndCheck();
    }

    function test_SpoofedCallbackIgnored() public {
        bytes32 rid = _sub(s).request;
        OracleAttestation.Attestation memory a = _attestation(true);
        bytes memory sig = _sign(a, attesterKey);
        vm.expectEmit(address(vault));
        emit AttestationIgnored(rid, 2);
        vm.prank(dave);
        vault.onOracleResult(rid, a, sig); // not the Intake
        assertFalse(vault.requests(rid).answered);
        // unknown request id from the Intake: ignored
        vm.expectEmit(address(vault));
        emit AttestationIgnored(keccak256("other"), 1);
        vm.prank(address(intake));
        vault.onOracleResult(keccak256("other"), a, sig);
        // wrong signer from the Intake: ignored, the request stays open
        bytes memory fakeSig = _sign(a, 0xBAD);
        vm.expectEmit(address(vault));
        emit AttestationIgnored(rid, 15);
        vm.prank(address(intake));
        vault.onOracleResult(rid, a, fakeSig);
        assertFalse(vault.requests(rid).answered);
        // non-bool answer / bad quorum: ignored
        a.answerType = 3;
        sig = _sign(a, attesterKey);
        vm.expectEmit(address(vault));
        emit AttestationIgnored(rid, 12);
        vm.prank(address(intake));
        vault.onOracleResult(rid, a, sig);
        a.answerType = 0;
        a.agreed = 4;
        sig = _sign(a, attesterKey);
        vm.expectEmit(address(vault));
        emit AttestationIgnored(rid, 14);
        vm.prank(address(intake));
        vault.onOracleResult(rid, a, sig);
        assertFalse(vault.requests(rid).answered);
        // a valid one from the Intake is recorded
        a.agreed = 6;
        sig = _sign(a, attesterKey);
        vm.prank(address(intake));
        vault.onOracleResult(rid, a, sig);
        assertTrue(vault.requests(rid).answered);
    }

    function test_LateAnswerIgnored_Timeout() public {
        _warp(7 hours);
        _answer(s, false); // issuedAt after askedAt + 6h: counts as silence
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted)); // NFT tie, nobody called again
        _claimEverythingAndCheck();
    }

    function test_AnswerAfterSilenceIgnored() public {
        _warp(6 hours + SWARM_DELIVERY_GRACE); // the timeout and the delivery grace (swarm audit #7)
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        _answer(s, false); // recorded, but the question is closed
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        _claimEverythingAndCheck();
    }

    function test_RefusedBody_Status1_IsSilence() public {
        OracleAttestation.Attestation memory a;
        intake.complete(_sub(s).request, 1, a, ""); // refused by the body checks: no callback
        vault.poke(t); // the Intake reports the request completed without an answer: silence at once
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        assertEq(_sub(s).callFrom, _now());
        assertEq(vault.credits(address(imd), erin), 1e18);
        _claimEverythingAndCheck();
    }

    /// @dev A lost callback is silence (audit B-01): the signed answer cannot be handed in by anyone.
    function test_LostCallback_IsSilence_NoPublicFallback() public {
        intake.setCallbackGas(5_000); // callback runs out of gas
        bytes32 rid = _sub(s).request;
        OracleAttestation.Attestation memory a = _attestation(false);
        a.questionHash = vault.requests(rid).questionHash;
        intake.complete(rid, 0, a, _sign(a, attesterKey));
        assertFalse(intake.lastDelivered());
        assertFalse(vault.requests(rid).answered);
        _warp(3 hours);
        _expectNoFallback(rid, a, _sign(a, attesterKey));
        vault.poke(t); // the Intake reports the request completed without an answer: silence at once
        assertFalse(vault.requests(rid).answered);
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        assertEq(_sub(s).callFrom, _now());
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted)); // tie rule, not the lost "no"
        _claimEverythingAndCheck();
    }

    /// @dev The removed fallback is gone for every input: foreign, incomplete, badly signed, unknown or valid.
    function test_NoPublicFallback_ForAnyAttestation() public {
        bytes32 rid = _sub(s).request;
        OracleAttestation.Attestation memory a = _attestation(true);
        bytes memory sig = _sign(a, attesterKey);
        _expectNoFallback(rid, a, sig); // another question
        a.questionHash = vault.requests(rid).questionHash;
        sig = _sign(a, attesterKey);
        _expectNoFallback(rid, a, sig); // right question, request not completed
        intake.completeWithoutCallback(rid);
        _expectNoFallback(rid, a, _sign(a, 0xBAD)); // bad signer
        _expectNoFallback(keccak256("x"), a, sig); // unknown request
        _expectNoFallback(rid, a, sig); // completed, valid, our question
        assertFalse(vault.requests(rid).answered);
    }

    function test_AttesterRotationTimelocked() public {
        uint256 newKey = 0xC0FFEE;
        address newAttester = vm.addr(newKey);
        vm.prank(owner);
        registry.proposeAttester(newAttester, true);
        bytes32 rid = _sub(s).request;
        OracleAttestation.Attestation memory a = _attestation(true);
        bytes memory sig = _sign(a, newKey);
        vm.prank(address(intake));
        vault.onOracleResult(rid, a, sig);
        assertFalse(vault.requests(rid).answered); // not yet an attester
        vm.expectRevert(ParamsRegistry.TimelockNotPassed.selector);
        registry.executeAttester(newAttester, true);
        _warp(48 hours);
        registry.executeAttester(newAttester, true);
        assertTrue(registry.isAttester(newAttester));
        // removal of the old key also takes 48h
        vm.prank(owner);
        registry.proposeAttester(attester, false);
        _warp(48 hours);
        registry.executeAttester(attester, false);
        assertFalse(registry.isAttester(attester));
        // a new request answered by the rotated key is accepted (the set is global, old tasks included)
        uint256 t2 = _create(author, address(usdc), 100e6);
        uint256 s2 = _submit(doer2, t2);
        _dispute(dave, s2);
        _warp(24 hours);
        _callSwarm(erin, s2);
        bytes32 rid2 = _sub(s2).request;
        a = _attestation(true);
        sig = _sign(a, newKey);
        intake.complete(rid2, 0, a, sig);
        assertTrue(vault.requests(rid2).answered);
    }

    // ================================================================== mandatory check (R >= $300)

    function test_MandatoryCheck_Passes_FeeNotRefunded() public {
        uint256 tl = _create(author, address(usdc), 300e6);
        uint256 before = imd.balanceOf(doer2);
        uint256 sl = _submit(doer2, tl);
        Submission memory sub = _sub(sl);
        assertTrue(sub.large);
        assertEq(uint8(sub.check), uint8(CheckState.Requested));
        assertEq(before - imd.balanceOf(doer2), sub.bond + PRICE); // bond + check fee on top
        assertEq(sub.checkFunds, 0);
        assertEq(sub.windowEnd, 0);
        // nobody can dispute before the check answered
        vm.prank(dave);
        vm.expectRevert(WindowClosed.selector);
        vault.dispute{value: 0.001 ether}(sl, "r", 0.001 ether, _noSwap());

        _warp(10 minutes);
        _answer(sl, true);
        vault.poke(tl);
        assertEq(uint8(_sub(sl).check), uint8(CheckState.Passed));
        assertEq(_sub(sl).windowEnd, _now() + 24 hours);
        _warp(24 hours);
        vault.poke(tl);
        assertEq(uint8(_sub(sl).outcome), uint8(Outcome.Accepted));
        // fee 30 USDC all to the treasury; the doer's check fee is his own cost
        assertEq(vault.credits(address(usdc), doer2), 270e6);
        assertEq(vault.treasuryPot(address(usdc)), 30e6);
        assertEq(vault.credits(address(imd), doer2), sub.bond);
        _claimEverythingAndCheck();
    }

    function test_MandatoryCheck_Fails_Rejected_BondToTreasury() public {
        uint256 tl = _create(author, address(imd), 50e18); // IMD task above largeRewardImd (40)
        uint256 sl = _submit(doer2, tl);
        uint256 bond = _sub(sl).bond; // 0.5 + 3% x 50 = 2 IMD
        assertEq(bond, 2e18);
        _answer(sl, false);
        vault.poke(tl);
        assertEq(uint8(_sub(sl).outcome), uint8(Outcome.Rejected));
        // nobody disputed, nobody voted: no winner, the bond goes to the treasury
        assertEq(vault.treasuryPot(address(imd)), 2e18);
        assertEq(vault.getTask(tl).rejectedCount, 1);
        assertEq(vault.getTask(tl).pot, 50e18); // the reward stays in the task
        _claimEverythingAndCheck();
    }

    function test_MandatoryCheck_Silent_OptimisticWindow_Accepted() public {
        uint256 tl = _create(author, ETH, 0.2 ether); // $500
        uint256 sl = _submit(doer2, tl);
        _warp(1 hours);
        _silent(sl);
        vault.poke(tl);
        // silence: the fee is lost, the dispute window runs from the moment of silence as without a check
        assertEq(uint8(_sub(sl).check), uint8(CheckState.None));
        assertEq(_sub(sl).windowEnd, _now() + 24 hours);
        _warp(24 hours);
        vault.poke(tl);
        assertEq(uint8(_sub(sl).outcome), uint8(Outcome.Accepted));
        assertEq(vault.credits(address(imd), doer2), _sub(sl).bond); // bond back, check fee spent
        _claimEverythingAndCheck();
    }

    function test_MandatoryCheck_SilentTimeout_ThenDisputedAndRejected() public {
        uint256 tl = _create(author, ETH, 0.2 ether);
        uint256 sl = _submit(doer2, tl);
        uint256 askedAt = _now();
        _warp(6 hours + SWARM_DELIVERY_GRACE);
        _dispute(erin, sl); // the timeout and the grace open the window at askedAt + 7h, then erin disputes
        assertEq(_sub(sl).windowEnd, askedAt + 6 hours + SWARM_DELIVERY_GRACE + 24 hours);
        assertEq(uint8(_phase(sl)), uint8(Phase.Voting));
        _vote(sl, 1, 2, 120, 20);
        _warp(48 hours);
        vault.poke(tl);
        assertEq(uint8(_sub(sl).outcome), uint8(Outcome.Rejected));
        _claimEverythingAndCheck();
    }

    function test_MandatoryCheck_QueuedSubmission_AskedOnActivation() public {
        uint256 tl = _create(author, address(usdc), 400e6);
        uint256 s1 = _submit(doer2, tl);
        uint256 s2 = _submit(doer3, tl); // queued, prepays the check
        assertEq(_sub(s2).checkFunds, PRICE);
        assertEq(uint8(_sub(s2).check), uint8(CheckState.None));
        _answer(s1, false);
        vault.poke(tl); // s1 rejected by its check -> s2 active, its check asked in the same call
        assertEq(uint8(_phase(s2)), uint8(Phase.Review));
        assertEq(uint8(_sub(s2).check), uint8(CheckState.Requested));
        assertEq(_sub(s2).checkFunds, 0);
        _answer(s2, true);
        _warp(24 hours);
        vault.poke(tl);
        assertEq(uint8(_sub(s2).outcome), uint8(Outcome.Accepted));
        _claimEverythingAndCheck();
    }

    function test_MandatoryCheck_QueuedPriceRaised_CheckSkipped() public {
        uint256 tl = _create(author, address(usdc), 400e6);
        uint256 s1 = _submit(doer2, tl);
        uint256 s2 = _submit(doer3, tl);
        intake.setPrice(1e18); // above the 0.5 prepaid by doer3
        _answer(s1, false);
        vault.poke(tl);
        // cannot be asked from the prepayment: counts as silence, window now, prepayment back to the doer
        assertEq(uint8(_sub(s2).check), uint8(CheckState.None));
        assertEq(_sub(s2).windowEnd, _now() + 24 hours);
        assertEq(vault.credits(address(imd), doer3), PRICE);
        _warp(24 hours);
        vault.poke(tl);
        assertEq(uint8(_sub(s2).outcome), uint8(Outcome.Accepted));
        _claimEverythingAndCheck();
    }

    function test_MandatoryCheck_LowerPrice_DifferenceBack() public {
        uint256 tl = _create(author, address(usdc), 400e6);
        uint256 s1 = _submit(doer2, tl);
        uint256 s2 = _submit(doer3, tl);
        intake.setPrice(0.2e18);
        _answer(s1, false);
        vault.poke(tl);
        assertEq(uint8(_sub(s2).check), uint8(CheckState.Requested));
        assertEq(vault.credits(address(imd), doer3), PRICE - 0.2e18);
        _claimEverythingAndCheck();
    }

    function test_MandatoryCheck_IntakeBroken_CheckSkipped() public {
        uint256 tl = _create(author, address(usdc), 400e6);
        intake.setBroken(true); // request() reverts: the submission must still go through
        uint256 before = imd.balanceOf(doer2);
        uint256 sl = _submit(doer2, tl);
        assertEq(uint8(_sub(sl).check), uint8(CheckState.None));
        assertEq(_sub(sl).windowEnd, _now() + 24 hours);
        assertEq(vault.credits(address(imd), doer2), PRICE); // the prepaid check fee is his again
        assertEq(before - imd.balanceOf(doer2), _sub(sl).bond + PRICE);
        intake.setBroken(false);
        _warp(24 hours);
        vault.poke(tl);
        assertEq(uint8(_sub(sl).outcome), uint8(Outcome.Accepted));
        _claimEverythingAndCheck();
    }

    function test_CallSwarm_IntakeBroken_Reverts_NothingTaken() public {
        uint256 t2 = _create(author, address(usdc), 100e6);
        uint256 s2 = _submit(doer2, t2);
        _dispute(dave, s2);
        _warp(24 hours);
        intake.setBroken(true);
        uint256 before = imd.balanceOf(erin);
        vm.prank(erin);
        vm.expectRevert(SwarmUnavailable.selector);
        vault.callSwarm(s2, false, "ipfs://caller-reason", type(uint256).max, _noSwap());
        assertEq(imd.balanceOf(erin), before);
        intake.setBroken(false);
    }

    function test_MandatoryCheck_LateDelivery_WindowFromRecording() public {
        uint256 tl = _create(author, address(usdc), 300e6);
        uint256 sl = _submit(doer2, tl);
        uint256 askedAt = _now();
        _warp(5 hours);
        OracleAttestation.Attestation memory a = _attestation(true);
        a.issuedAt = uint64(askedAt + 1 minutes); // signed early, delivered 5h later
        intake.complete(_sub(sl).request, 0, a, _sign(a, attesterKey));
        vault.poke(tl);
        assertEq(uint8(_sub(sl).check), uint8(CheckState.Passed));
        assertEq(_sub(sl).windowEnd, _now() + 24 hours); // full 24h from when the answer became visible
        _claimEverythingAndCheck();
    }

    function test_MandatoryCheck_PassedThenDisputed() public {
        uint256 tl = _create(author, address(usdc), 300e6);
        uint256 sl = _submit(doer2, tl);
        _answer(sl, true);
        _dispute(erin, sl); // advances the check first, then disputes
        assertEq(uint8(_phase(sl)), uint8(Phase.Voting));
        _vote(sl, 1, 2, 120, 20);
        _warp(48 hours);
        vault.poke(tl);
        assertEq(uint8(_sub(sl).outcome), uint8(Outcome.Rejected));
        _claimEverythingAndCheck();
    }

    function test_ActionNoLongerSold_LargeSubmitReverts() public {
        intake.setPrice(0); // priceOf returns 0: the Intake does not sell the action any more
        uint256 tl = _create(author, address(usdc), 500e6);
        vm.prank(doer3);
        vm.expectRevert(ActionNotSold.selector); // a large task cannot be checked now: nothing is taken
        vault.submit(tl, "https://x.com/doer/status/1", _noEvidence(), 0, type(uint256).max, _noSwap());
        uint256 t2 = _create(author, address(usdc), 100e6);
        _submit(doer3, t2); // small tasks still work
        _claimEverythingAndCheck();
    }

    // ================================================================== helpers

    function _contains(bytes memory hay, bytes memory needle) internal pure returns (bool) {
        if (needle.length > hay.length) return false;
        for (uint256 i; i <= hay.length - needle.length; ++i) {
            bool ok = true;
            for (uint256 j; j < needle.length; ++j) {
                if (hay[i + j] != needle[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
}
