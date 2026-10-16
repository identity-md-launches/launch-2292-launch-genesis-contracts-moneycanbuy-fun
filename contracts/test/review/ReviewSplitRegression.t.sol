// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import "../Base.t.sol";

/// @dev Regression of the core split: the earlier single-contract vault (TaskVault + external libraries) was
///      split into TaskVault + CaseDesk + DisputeDesk + helpers. The scenarios below use only `vault` and the Base
///      helpers, so the same functions also ran on the pre-split monolith (same registry and mocks): the "golden"
///      ledger hashes (credits, treasury, liabilities, balances after all payouts) were taken from the old code and
///      must match on the new one. Plus what the split changed on purpose or in gas.
abstract contract SplitScenarios is Base {
    /// @dev All the money a user sees: participants' credits and balances in three currencies, the vault's balances,
    ///      treasury and liabilities. Contract addresses are left out (the old and new vault differ).
    function _ledger() internal view returns (bytes32 h) {
        address[13] memory who = [
            author, alice, bob, doer, doer2, dave, erin, relayer, voters[0], voters[1], voters[2], treasury, swarmPayee
        ];
        address[3] memory ts = [ETH, address(usdc), address(imd)];
        for (uint256 k; k < 3; ++k) {
            h = keccak256(
                abi.encode(h, vault.liabilities(ts[k]), vault.treasuryPot(ts[k]), _bal(ts[k], address(vault)))
            );
            for (uint256 i; i < who.length; ++i) {
                h = keccak256(abi.encode(h, vault.credits(ts[k], who[i]), _bal(ts[k], who[i])));
            }
        }
    }

    function _bal(address t, address a) internal view returns (uint256) {
        return t == ETH ? a.balance : IERC20(t).balanceOf(a);
    }

    /// @dev The Intake request id hashes the Intake address, which depends on the test deployment: left out.
    function _settled(uint256 s) internal view returns (bytes32) {
        Submission memory sb = vault.getSubmission(s);
        sb.request = bytes32(0);
        return keccak256(abi.encode(vault.getSettlement(s), sb, vault.getDispute(s)));
    }

    /// @dev The record of a case whose NFT decision the pre-split monolith made instantly with the vote batch, relayed
    ///      right after the dispute (decidedAt = callFrom = voteEnd - voteWindow). The current code (audit C-02) has
    ///      the same votes decide at the vote end; only these two times differ, so they are moved back before hashing
    ///      and the golden ledgers recorded from the pre-split vault still apply (the ledgers need no adjustment:
    ///      basefee 0).
    function _settledAsInstant(uint256 s) internal view returns (bytes32) {
        Submission memory sb = vault.getSubmission(s);
        sb.request = bytes32(0);
        assertEq(sb.decidedAt, sb.voteEnd, "decided at the vote end");
        sb.decidedAt = sb.voteEnd - 24 hours;
        sb.callFrom = sb.decidedAt;
        return keccak256(abi.encode(vault.getSettlement(s), sb, vault.getDispute(s)));
    }

    /// @return a ledger right after settlement, b the submission's settlement, c ledger after all payouts and withdrawals
    function _s1AcceptedNftRight() internal returns (bytes32 a, bytes32 b, bytes32 c) {
        uint256 t = _create(author, address(usdc), 100e6);
        _topUp(alice, t, 50e6);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        _dispute(erin, s);
        vm.prank(doer);
        vault.reply(s, "my reply");
        _vote(s, 0, 1, 0, 120); // +120 accept
        _endVote(s); // decided at the vote end (audit C-02; the pre-split vault decided instantly)
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(uint8(_sub(s).nftDecision), uint8(Verdict.Accept));
        (a, b) = (_ledger(), _settledAsInstant(s));
        _claimEverythingAndCheck();
        c = _ledger();
    }

    function _s2AppealSwarmOverturns() internal returns (bytes32 a, bytes32 b, bytes32 c) {
        uint256 t = _create(author, address(imd), 30e18);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        _vote(s, 0, 1, 0, 120); // NFT: accept
        _endVote(s); // decided at the vote end (audit C-02; the pre-split vault decided instantly)
        _appeal(erin, s); // against the doer
        vm.prank(doer);
        vault.appealReply(s, "appeal reply");
        vault.poke(t); // asked
        _answer(s, false); // swarm: rejected, NFT was wrong, the caller wins
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        (a, b) = (_ledger(), _settledAsInstant(s));
        _claimEverythingAndCheck();
        c = _ledger();
    }

    function _s3TieNobodyCalls() internal returns (bytes32 a, bytes32 b, bytes32 c) {
        uint256 t = _create(author, ETH, 0.02 ether);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        _dispute(erin, s);
        _vote(s, 2, 1, 140, 10);
        _vote(s, 1, 2, 120, 10);
        _warp(24 hours);
        vault.poke(t); // NoDecision
        _warp(24 hours);
        vault.poke(t); // accepted by the tie rule
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(uint8(_sub(s).nftDecision), uint8(Verdict.None));
        (a, b) = (_ledger(), _settled(s));
        _claimEverythingAndCheck();
        c = _ledger();
    }

    function _s4LargeCheckNoThenQueued() internal returns (bytes32 a, bytes32 b, bytes32 c) {
        uint256 t = _create(author, address(imd), 50e18); // large: mandatory check
        uint256 s = _submit(doer, t);
        uint256 s2 = _submit(doer2, t); // queued, bond doubled
        _topUp(bob, t, 5e18); // pending
        _answer(s, false);
        vault.poke(t); // rejected; s2 activated, its check asked
        _answer(s2, true);
        _warp(24 hours);
        vault.poke(t); // accepted
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        assertEq(uint8(_sub(s2).outcome), uint8(Outcome.Accepted));
        assertEq(_sub(s2).bond, _sub(s).bond * 2, "queued bond doubled");
        (a, b) = (_ledger(), keccak256(abi.encode(_settled(s), _settled(s2))));
        _claimEverythingAndCheck();
        c = _ledger();
    }

    function _s5CallSwarmSilentThenCalledAgain() internal returns (bytes32 a, bytes32 b, bytes32 c) {
        uint256 t = _create(author, address(usdc), 60e6);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        _vote(s, 3, 1, 150, 5); // too few to decide (endDelta 10)
        _warp(24 hours);
        vault.poke(t); // NoDecision
        _callSwarm(bob, s, true);
        _silent(s);
        vault.poke(t); // silence: bob's fee lost, bond back, new window
        _callSwarm(erin, s, false);
        _answer(s, false); // rejected, erin wins
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        assertEq(_sub(s).asks, 2);
        (a, b) = (_ledger(), _settled(s));
        _claimEverythingAndCheck();
        c = _ledger();
    }

    function _s6Unwind() internal returns (bytes32 a, bytes32 b, bytes32 c) {
        allowEmergency = true;
        uint256 t = _create(author, address(usdc), 100e6);
        _topUp(alice, t, 50e6);
        uint256 s = _submit(doer, t);
        _submit(doer2, t); // queued
        _topUp(bob, t, 20e6); // pending
        _dispute(dave, s);
        _vote(s, 1, 1, 120, 20);
        _warp(24 hours);
        vault.poke(t);
        _appeal(erin, s);
        vm.mockCallRevert(address(vault), abi.encodeWithSignature("advanceFromSelf(uint256)", t), "");
        _warp(12 hours + 30 days);
        vault.emergencyExit(t);
        vm.clearMockedCalls();
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Unwound));
        (a, b) = (_ledger(), _settled(s));
        _claimEverythingAndCheck();
        c = _ledger();
    }
}

contract ReviewSplitRegression is SplitScenarios {
    // ---------------------------------------------------------------- golden ledgers
    // Pinned keccak hashes of `_ledger()` / `_settled()` at three points of every scenario (A: after the main step,
    // B: the settlement record, C: after everyone claimed). Any change in who ends up with how much money, in the
    // treasury pots, the liabilities or the settlement record of these scenarios changes a hash and fails the test,
    // so a refactor of the vault, the desks or the libraries must leave every scenario's money flow bit for bit the
    // same (basefee 0, see the relayer test for basefee > 0).

    bytes32 internal constant S1_A = 0x22d5763e9f8196a2a1728814e4c403d3fc069b72229a00a5f91c871682e06c48;
    bytes32 internal constant S1_B = 0xd736f3ef9f022708292e1f1c9e1424ed295eef9cb403fab2527bc00e977734c2;
    bytes32 internal constant S1_C = 0xa20148f4c6babeaeb66d8cf435cccc37166a13a108829e62840045c73651f28e;
    bytes32 internal constant S2_A = 0x518a235f0c1526b9d512ca92d93ba32f67135a1371006d51d0a537834839e687;
    bytes32 internal constant S2_B = 0x3d831530fbbdd66cdea1556a417cd5fe5037491de67979a57b61500a96969156;
    bytes32 internal constant S2_C = 0x4b85e28628427b3e55a0f72dd0f099da71fe271d88facc1c7b8d1ddb6f9d6681;
    bytes32 internal constant S3_A = 0xfb4d4f6c04789d4fdc73bdd4a0e6548d37b7ffb4cae451abfdaaeb3d25e40614;
    bytes32 internal constant S3_B = 0xb921bbe8f3476495cb7bd1befbba652a4489251ed4f67280a954ddb2a1d4c989;
    bytes32 internal constant S3_C = 0x78b1d4a46abd4aade8a8cc600c5978e6bc39e1863af33a4ce2345106251139ba;
    bytes32 internal constant S4_A = 0x7b66f0e6533755140b835236e87b74253feda02b39770fd6f27acc68916850e3;
    bytes32 internal constant S4_B = 0x30d8acb7d798adbc68c9b2ef707768ac73dd01f885f728f8a3bde2bc9baeed9f;
    bytes32 internal constant S4_C = 0xf8636d3c3c6242c928e1b95ed1e0314cfbff07b4bb9ad6475692db311c139c12;
    bytes32 internal constant S5_A = 0x09cf7be8609b435dd53d97898c7d8827a47005512ed8d6d77c99c4e67e08de53;
    bytes32 internal constant S5_B = 0x843161a8350e8523cd695ad8fb6ad171135d8a1e29245ea9cf8127c3eb43e344;
    bytes32 internal constant S5_C = 0x53a88094f0abc423ec26d36c9172fc8e9e0f3c0de5d921019491ad5e0c1f34b7;
    bytes32 internal constant S6_A = 0xd373d87c45d06ea10f296ffb8b159c605b2f93d591641e657166d371512fec5f;
    bytes32 internal constant S6_B = 0xff5fb91a665cedafa7a6de69019fa9499bf74b748a85798b0505e303cee661bd;
    bytes32 internal constant S6_C = 0x329674609d70d3cf59f09a2c933128810d6e7853171d23ab6be0702d229ddc3b;

    function _golden(bytes32[3] memory got, bytes32[3] memory want) internal {
        emit log_named_bytes32("ledger after settlement", got[0]);
        emit log_named_bytes32("settlement record", got[1]);
        emit log_named_bytes32("ledger after every payout", got[2]);
        assertEq(got[0], want[0], "ledger after settlement differs from the pre-split vault");
        assertEq(got[1], want[1], "settlement record differs from the pre-split vault");
        assertEq(got[2], want[2], "ledger after payouts differs from the pre-split vault");
    }

    function test_golden_AcceptedAfterDispute_NftRight() public {
        (bytes32 a, bytes32 b, bytes32 c) = _s1AcceptedNftRight();
        _golden([a, b, c], [S1_A, S1_B, S1_C]);
    }

    function test_golden_AppealSwarmOverturnsNft() public {
        (bytes32 a, bytes32 b, bytes32 c) = _s2AppealSwarmOverturns();
        _golden([a, b, c], [S2_A, S2_B, S2_C]);
    }

    function test_golden_TieNobodyCallsSwarm() public {
        (bytes32 a, bytes32 b, bytes32 c) = _s3TieNobodyCalls();
        _golden([a, b, c], [S3_A, S3_B, S3_C]);
    }

    function test_golden_LargeCheckNoThenQueuedAccepted() public {
        (bytes32 a, bytes32 b, bytes32 c) = _s4LargeCheckNoThenQueued();
        _golden([a, b, c], [S4_A, S4_B, S4_C]);
    }

    function test_golden_CallSwarmSilentThenCalledAgain() public {
        (bytes32 a, bytes32 b, bytes32 c) = _s5CallSwarmSilentThenCalledAgain();
        _golden([a, b, c], [S5_A, S5_B, S5_C]);
    }

    function test_golden_EmergencyUnwind() public {
        (bytes32 a, bytes32 b, bytes32 c) = _s6Unwind();
        _golden([a, b, c], [S6_A, S6_B, S6_C]);
    }

    // ---------------------------------------------------------------- what the split changed

    string internal constant R256 =
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    /// @dev Minor (gas -> money). The relayer reimbursement is measured inside DisputeDesk and now includes the hops
    ///      DisputeDesk -> CaseDesk -> vault, the BallotChecker call and reading all of ParamsCore from the registry
    ///      (about 19 cold slots per call). A batch of 10 NFTs at basefee 1 gwei: the pre-split monolith reimbursed
    ///      216 448 gas, the new code 309 556 (+43%). The disputers pay (the dispute's ETH pot); what the pot did not
    ///      cover goes to relayerShortfall and is paid from the loser's bond. No overpayment above the actual cost.
    function test_minor_RelayerReimbursementGrewWithTheSplit() public {
        uint256 t = _create(author, address(usdc), 50e6);
        uint256 s = _submit(doer, t);
        _dispute(dave, s); // pot 0.001 ETH
        Ballot[] memory bs = new Ballot[](1);
        bs[0] = _ballot(s, 2, 1, _ids(140, 10), voters[2]);
        bytes memory cd = abi.encodeCall(ITaskVault.submitVotes, (s, bs));
        uint256 cdGas;
        for (uint256 i; i < cd.length; ++i) {
            cdGas += cd[i] == 0 ? 4 : 16;
        }
        vm.fee(1 gwei);
        vm.prank(relayer);
        uint256 g0 = gasleft();
        (bool ok,) = address(vault).call(cd);
        uint256 used = g0 - gasleft();
        assertTrue(ok);
        uint256 reimbursedGas = vault.credits(ETH, relayer) * BPS / (BPS + 1_000) / 1 gwei;
        emit log_named_uint("reimbursed gas (pre-split monolith: 216448)", reimbursedGas);
        emit log_named_uint("gas of the call + 21000 + calldata", used + 21_000 + cdGas);
        assertGt(reimbursedGas, 280_000, "the split made a vote batch ~93k gas dearer for the disputers");
        assertLe(reimbursedGas, used + 21_000 + cdGas, "never more than the batch really cost");
    }

    /// @dev Minor (gas). Lazy steps cost more: the step that asks an appeal question with 16 reasons of 256 bytes
    ///      cost ~0.99M gas in the monolith, now ~1.11M; "swarm said no -> next large submission activated and
    ///      asked" 0.51M -> 0.66M (mock Intake). The heaviest step still fits the emergencyExit budget (2.5M for the
    ///      advanceFromSelf self-call), i.e. "a working machine always beats the emergency exit".
    function test_minor_HeaviestLazyStepStillFitsTheEmergencyBudget() public {
        uint256 t = _create(author, address(usdc), 50e6);
        uint256 s = _submit(doer3, t);
        for (uint256 i; i < 16; ++i) {
            address d = makeAddr(string.concat("disputer", vm.toString(i)));
            vm.deal(d, 1 ether);
            imd.mint(d, 100e18);
            vm.startPrank(d);
            imd.approve(address(vault), type(uint256).max);
            vault.dispute{value: 0.001 ether}(s, R256, 0.001 ether, _noSwap());
            vm.stopPrank();
        }
        vm.prank(doer3);
        vault.reply(s, R256);
        _vote(s, 0, 2, 0, 120);
        _endVote(s); // reject at the vote end
        vm.prank(doer3);
        vault.appeal(s, R256, type(uint256).max, _noSwap());
        vm.prank(makeAddr("disputer0"));
        vault.appealReply(s, R256);
        uint256 g0 = gasleft();
        vm.prank(address(vault));
        TaskVault(payable(address(vault))).advanceFromSelf{gas: 2_500_000}(t);
        emit log_named_uint("gas of the heaviest lazy step (monolith ~985k)", g0 - gasleft());
        assertEq(uint8(_phase(s)), uint8(Phase.Asked), "asked inside the emergency budget");
    }

    /// @dev On purpose: event names and arguments are the same (the vault ABI did not change, 33 events), but
    ///      submission, dispute, vote and settlement events now come from CaseDesk and DisputeDesk, so an indexer
    ///      must read all three addresses. The test pins the "event -> address" map so that moving an event between
    ///      contracts cannot slip past an indexer silently.
    function test_events_EmitterMap() public {
        vm.recordLogs();
        _s2AppealSwarmOverturns();
        _s3TieNobodyCalls();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32[12] memory fromVault = [
            TaskCreated.selector,
            TaskStatusChanged.selector,
            Credited.selector,
            Paid.selector,
            SwarmAsked.selector,
            SwarmAnswered.selector,
            TreasurySwept.selector,
            ParamsCached.selector,
            ContributionWithdrawn.selector,
            ToppedUp.selector,
            AttestationIgnored.selector,
            WithdrawAnnounced.selector // swarm audit #8: the notice on an active share
        ];
        bytes32[9] memory fromCase = [
            Submitted.selector,
            Activated.selector,
            NftDecided.selector,
            NoNftDecision.selector,
            SubmissionFinal.selector,
            CheckPassed.selector,
            SwarmSilent.selector,
            AppealVoided.selector,
            DoerReplied.selector
        ];
        bytes32[9] memory fromDispute = [
            Disputed.selector,
            VotesSubmitted.selector,
            VoteLib.VoteCounted.selector,
            VoteLib.BallotSkipped.selector,
            Appealed.selector,
            AppealReplied.selector,
            SubmissionSettled.selector,
            DisputerClaimed.selector,
            VoterRewardClaimed.selector
        ];
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            address e = logs[i].emitter;
            if (e != address(vault) && e != address(caseDesk) && e != address(disputeDesk)) continue;
            bytes32 t0 = logs[i].topics[0];
            address want;
            for (uint256 k; k < fromVault.length; ++k) {
                if (t0 == fromVault[k]) want = address(vault);
            }
            for (uint256 k; k < fromCase.length; ++k) {
                if (t0 == fromCase[k]) want = address(caseDesk);
            }
            for (uint256 k; k < fromDispute.length; ++k) {
                if (t0 == fromDispute[k]) want = address(disputeDesk);
            }
            assertTrue(want != address(0), "an event outside the map");
            assertEq(e, want, "event moved to another contract: an indexer reads vault + caseDesk + disputeDesk");
            ++seen;
        }
        assertGt(seen, 40);
    }
}
