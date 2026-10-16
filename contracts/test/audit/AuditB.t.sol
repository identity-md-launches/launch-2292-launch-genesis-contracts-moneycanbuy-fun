// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../Base.t.sol";
import {IIntake} from "../../src/interfaces/IIntake.sol";

/// @dev Internal audit B (core: TaskVault, VaultParams, VaultTypes, ParamsRegistry, ProtocolDirectory,
///      OracleAttestation, AttestationChecker, interfaces). One test per finding (`test_Bxx_*` reproduces it,
///      `test_Fix_Bxx_*` fails on the original code and passes with the fix, `test_Fixed_Bxx_*` is a former PoC
///      turned into a guard after a rule change) plus guards for what was checked.
///      Acknowledged findings are described in docs/AUDIT-INTERNAL.md; each lists its impact and why it was accepted.
contract AuditBTest is Base {
    // ================================================================== helpers

    /// @dev USDC task of 100 USDC, a doer, one disputer (dave), no votes: NoDecision after the vote.
    function _noDecisionCase() internal returns (uint256 t, uint256 s) {
        t = _create(author, address(usdc), 100e6);
        s = _submit(doer, t);
        _dispute(dave, s);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
    }

    /// @dev The `question` member of a body built by SwarmQuestion: it starts after `{"v":1,"question":"` (19 bytes)
    ///      and ends at the next quote (user texts never contain one).
    function _questionOf(bytes memory body) internal pure returns (bytes memory q) {
        uint256 start = 19;
        uint256 end = start;
        while (body[end] != '"') ++end;
        q = new bytes(end - start);
        for (uint256 i; i < q.length; ++i) {
            q[i] = body[start + i];
        }
    }

    // ================================================================== B-01

    /// @notice B-01 (fixed: the public fallback `submitAttestation` was removed). It bound an attestation to
    ///         our request only by `questionHash` = keccak256(question). The question is public and deterministic
    ///         (`previewSwarmBody`, or the `Requested` event) and leaves out every party text (claims, replies,
    ///         appeal: they are `definitions`). A third party orders the same question with one-sided definitions in
    ///         his own Intake request naming the vault as consumer; the panel's answer to HIS request passed every
    ///         check for OUR request once ours completed without a delivered answer. Now an answer reaches the vault
    ///         only through the Intake callback of our own request id: the copied answer cannot be handed in, our
    ///         "no consensus" stays silence and the tie rule accepts (doer paid 90 USDC).
    function test_Fixed_B01_ThirdPartyAnswerToACopiedQuestionCannotDecideOurCase() public {
        (uint256 t, uint256 s) = _noDecisionCase();

        // erin (who is about to call the swarm against the doer) reads the next question; its hash is what the
        // vault will store (nonce = asks + 1 is known in advance)
        (bytes memory preview, bytes32 qh) = vault.previewSwarmBody(s, SWARM_KIND_ESCALATION);
        bytes memory question = _questionOf(preview);
        assertEq(keccak256(question), qh, "question hash reproducible by anyone");

        // her own request: the same question, her own one-sided "definitions", consumer = the vault
        bytes memory forgedBody = bytes.concat(
            '{"v":1,"question":"',
            question,
            '","definitions":{"claim_1":"the doer admitted the post is not his","appeal":"confirmed fake"},',
            '"chainId":1,"answerType":"bool","evidence":"panel","panelSize":7,"quorum":5,',
            '"consumer":{"chainId":31337,"verifyingContract":"',
            bytes(vm.toString(address(vault))),
            '"}}'
        );
        assertTrue(keccak256(forgedBody) != keccak256(preview), "a different body");
        vm.startPrank(erin);
        imd.approve(address(intake), PRICE);
        bytes32 herRid = intake.request(ACTION, forgedBody, IIntake.Callback(erin, bytes4(0)), address(imd), PRICE);
        vm.stopPrank();

        // the panel answers HER request "no" (consumer = vault, so the EIP-712 domain is the vault's)
        OracleAttestation.Attestation memory a = _attestation(false);
        a.requestId = bytes32(bytes16(keccak256("her-uuid")));
        a.questionHash = qh;
        bytes memory sig = _sign(a, attesterKey);
        intake.complete(herRid, 0, a, sig);

        // now she calls the swarm for real (bond 1 IMD + fee 0.5 IMD)
        _callSwarm(erin, s, false);
        bytes32 ourRid = _sub(s).request;
        assertTrue(ourRid != herRid);
        assertEq(vault.requests(ourRid).questionHash, qh);

        // our request: the panel finds no consensus (status 2, no callback) - the honest outcome is silence
        OracleAttestation.Attestation memory none;
        intake.complete(ourRid, 2, none, "");

        // --- attack: before anyone pokes, erin tries to relay the answer to HER request as the answer to OURS:
        //     the fallback is gone, and the callback refuses anyone but our Intake
        _expectNoFallback(ourRid, a, sig);
        vm.prank(erin);
        vault.onOracleResult(ourRid, a, sig);
        assertFalse(vault.requests(ourRid).answered, "the copied answer is not recorded");

        // --- the honest outcome stands: silence, nobody calls again, the tie rule accepts after 24 h
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(vault.credits(address(usdc), doer), 90e6, "doer paid 90 USDC");
        _claimEverythingAndCheck();
    }

    // ================================================================== B-02

    /// @notice B-02 (design): removing an attester waits the same 48 h as adding one. Before the B-01 fix a leaked attester
    ///         key kept deciding every case whose request completed without a delivered answer for 48 h after the
    ///         owner reacted, through the public fallback. With the fallback removed (B-01) the key alone decides
    ///         nothing: an answer must come as the Intake's own callback for our request id.
    function test_Fixed_B02_LeakedAttesterKeyAloneCannotDecideDuringTheRemovalTimelock() public {
        (uint256 t, uint256 s) = _noDecisionCase();
        _callSwarm(erin, s, true);
        bytes32 rid = _sub(s).request;
        OracleAttestation.Attestation memory none;
        intake.complete(rid, 1, none, ""); // the plane refused the body: no answer

        vm.startPrank(owner);
        registry.proposeAttester(makeAddr("newAttester"), true); // the owner reacts at once: a new key ...
        registry.proposeAttester(attester, false); // ... and the leaked one out (never the last one: swarm audit #10)
        vm.stopPrank();
        _warp(47 hours);
        OracleAttestation.Attestation memory a = _attestation(false);
        a.questionHash = vault.requests(rid).questionHash;
        a.issuedAt = vault.requests(rid).askedAt; // anything inside the 6 h window (clamped anyway)
        // the thief holding the leaked key signs whatever he wants, but has no way to hand it in
        bytes memory sig = _sign(a, attesterKey);
        _expectNoFallback(rid, a, sig);
        vault.onOracleResult(rid, a, sig); // not from the Intake: ignored
        assertFalse(vault.requests(rid).answered);
        assertTrue(registry.isAttester(attester), "still an attester 47 h after the owner acted");
        vault.poke(t);
        // the refused request was silence (at the 6 h timeout), nobody called again: the tie rule accepts
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted), "no reject from the leaked key");
    }

    // ================================================================== guards (checked and found correct)

    /// @dev A contract that rejects ETH and blocked token holders never lose money: every failed push becomes a
    ///      credit, `withdrawTo` moves it elsewhere, and the books close at zero.
    function test_Guard_FailedPushesBecomeCreditsAndBooksClose() public {
        EthRejecter r = new EthRejecter(vault);
        vm.deal(address(r), 10 ether);
        imd.mint(address(r), 100e18);
        // author is the rejecter: excess ETH refund fails -> credited
        uint256 t = r.create{value: 0.1 ether}(0.05 ether, 0.001 ether);
        trackedTasks.push(t);
        assertEq(vault.credits(ETH, address(r)), 0.1 ether - 0.05 ether - 0.001 ether);
        // the doer gets blocked by IMD (OFT `blocked`): his void bond is credited, not lost
        uint256 s1 = _submit(doer, t);
        uint256 s2 = _submit(doer2, t);
        imd.setBlocked(doer2, true);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s1).outcome), uint8(Outcome.Accepted));
        vault.claimVoidSubmission(s2);
        assertEq(vault.credits(address(imd), doer2), _sub(s2).bond);
        vm.prank(doer2);
        vault.withdrawTo(address(imd), makeAddr("doer2-new"));
        assertEq(imd.balanceOf(makeAddr("doer2-new")), _sub(s2).bond);
        // the rejecter withdraws its ETH credit to an EOA
        r.withdrawTo(makeAddr("r-new"));
        assertEq(makeAddr("r-new").balance, 0.049 ether);
        imd.setBlocked(doer2, false);
        _claimEverythingAndCheck();
    }

    /// @dev Payment mode A (swap) books exactly what is needed whatever the user overpays: the IMD surplus and the
    ///      excess ETH go back, USDC never stays, and the vault ends at zero after everything is claimed.
    function testFuzz_Guard_ModeAPaymentsBookExactly(uint256 amt, uint96 extraEth, uint96 extraIn, bool usdcIn) public {
        uint256 amount = bound(amt, 1e18, 39e18); // below the 40 IMD check threshold: the dispute opens at once
        uint256 extra = bound(extraEth, 0, 1 ether);
        ImdPay memory pay;
        uint256 value = 0.001 ether + extra;
        if (usdcIn) {
            pay.tokenIn = address(usdc);
            pay.amountIn = amount * 8 / 1e12 + 1 + bound(extraIn, 0, 1_000e6); // 1 USDC = 0.125 IMD
        } else {
            pay.tokenIn = ETH;
            pay.amountIn = amount * 1e18 / 312.5e18 + 1 + bound(extraIn, 0, 1 ether);
            value += pay.amountIn;
        }
        pay.minImdOut = amount;
        pay.deadline = uint64(_now() + 600);
        uint256 imdBefore = imd.balanceOf(author);
        uint256 usdcBefore = usdc.balanceOf(author);
        uint256 ethBefore = author.balance;
        vm.prank(author);
        uint256 t = vault.createTask{value: value}(
            address(imd), amount, 0, "Title", "ipfs://task-condition", 0, 0, "", 0.001 ether, pay
        );
        trackedTasks.push(t);
        uint256 got = usdcIn ? pay.amountIn * 0.125e30 / 1e18 : pay.amountIn * 312.5e18 / 1e18;
        assertEq(imd.balanceOf(author) - imdBefore, got - amount, "IMD surplus returned");
        assertEq(usdcBefore - usdc.balanceOf(author), usdcIn ? pay.amountIn : 0, "USDC: exactly amountIn");
        assertEq(ethBefore - author.balance, 0.001 ether + (usdcIn ? 0 : pay.amountIn), "excess ETH returned");
        assertEq(vault.liabilities(address(imd)), amount);
        assertEq(imd.balanceOf(address(vault)), amount);
        assertEq(usdc.balanceOf(address(vault)), 0);
        _assertSolvent();
        // the doer pays bond (+ check) through the same swap path
        (uint256 bond, uint256 fee) = vault.quoteSubmission(t);
        ImdPay memory p2 = ImdPay(ETH, (bond + fee) * 1e18 / 312.5e18 + 1e15, bond + fee, uint64(_now() + 600), "");
        vm.prank(doer);
        uint256 s = vault.submit{value: p2.amountIn + extra}(
            t, "https://x.com/doer/status/1", _noEvidence(), 0, type(uint256).max, p2
        );
        _assertSolvent();
        _dispute(dave, s);
        _assertSolvent();
        _claimEverythingAndCheck();
    }

    /// @dev Pinned dependencies (info, B-06): a task keeps its version's oracle and Intake for good. If the pinned
    ///      oracle dies, contributors still take their money back. (That new submissions are then refused is the
    ///      acknowledged finding B-06, docs/AUDIT-INTERNAL.md.)
    function test_Guard_DeadPinnedOracleNeverBlocksWithdrawals() public {
        uint256 t = _create(author, address(usdc), 100e6);
        oracle.setBroken(true);
        uint256 before = usdc.balanceOf(author);
        _announceWithdraw(author, t);
        vm.prank(author);
        vault.withdrawContribution(t);
        assertEq(usdc.balanceOf(author) - before, 100e6);
        oracle.setBroken(false);
        _claimEverythingAndCheck();
    }

    /// @dev Bank functions refuse users; a user cannot reach them through the forwarder either (the vault routes only
    ///      ITaskVault selectors to the desks, and the desks read the sender the vault appended).
    function test_Guard_BankOnlyForDesks() public {
        ImdPay memory none;
        vm.startPrank(alice);
        vm.expectRevert(NotAuthorized.selector);
        TaskVault(payable(address(vault))).credit(ETH, alice, 1);
        vm.expectRevert(NotAuthorized.selector);
        TaskVault(payable(address(vault))).pay(ETH, alice, 1);
        vm.expectRevert(NotAuthorized.selector);
        TaskVault(payable(address(vault))).bookEth(1, true);
        vm.expectRevert(NotAuthorized.selector);
        TaskVault(payable(address(vault))).addTreasury(ETH, 1);
        vm.expectRevert(NotAuthorized.selector);
        TaskVault(payable(address(vault))).collectImd(bob, 0, 1e18, address(0), none);
        vm.expectRevert(NotAuthorized.selector);
        TaskVault(payable(address(vault))).closeSubmission(1, Outcome.Accepted, 0);
        vm.expectRevert(OnlySelf.selector);
        TaskVault(payable(address(vault))).advanceFromSelf(1);
        vm.stopPrank();
    }

    /// @dev Every pinned snapshot stays byte-identical after a new version is activated; only the attester set and
    ///      the sweep's treasury follow the registry live.
    function testFuzz_Guard_PinnedVersionNeverChanges(uint16 fee, uint32 window) public {
        uint256 t = _create(author, address(usdc), 100e6);
        bytes32 before = keccak256(abi.encode(registry.params(1)));
        Params memory p = defaultParams();
        p.feeBps = uint16(bound(fee, 0, 1_500));
        p.nftFeeBps = 0;
        p.disputeWindow = uint32(bound(window, 24 hours, 7 days));
        p.treasury = makeAddr("newTreasury");
        vm.prank(owner);
        registry.proposeParams(p);
        _warp(48 hours);
        registry.activateParams();
        assertEq(keccak256(abi.encode(registry.params(1))), before);
        assertEq(vault.getTask(t).paramsVersion, 1);
    }

    /// @dev Lazy timers: the longest chain of due transitions in one call is far below the 8-step bound (a queued
    ///      submission starts its own timers at activation, so one call cannot run through two submissions' timers).
    function test_Guard_LongestDueChainFitsOneCall() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s1 = _submit(doer, t);
        uint256 s2 = _submit(doer2, t);
        _dispute(dave, s1);
        _vote(s1, 0, 2, 0, 120); // reject (decided at the vote end)
        _warp(LONG); // vote and appeal windows long over
        vault.poke(t); // Voting -> Decided -> Final(Rejected) -> s2 active (Review) in one call
        assertEq(uint8(_sub(s1).outcome), uint8(Outcome.Rejected));
        assertEq(uint8(_phase(s2)), uint8(Phase.Review));
        assertEq(_sub(s2).windowEnd, _now() + 24 hours, "the next submission's window starts now");
        _claimEverythingAndCheck();
    }
}

/// @dev Author / contributor that refuses ETH (refunds and payouts to it fail).
contract EthRejecter {
    ITaskVault internal immutable vault;

    constructor(ITaskVault v) {
        vault = v;
    }

    function create(uint256 amount, uint256 fee) external payable returns (uint256) {
        ImdPay memory none;
        return vault.createTask{value: msg.value}(ETH, amount, 0, "Title", "cond", 0, 0, "", fee, none);
    }

    function withdrawTo(address to) external {
        vault.withdrawTo(ETH, to);
    }

    receive() external payable {
        revert("no ETH");
    }
}
