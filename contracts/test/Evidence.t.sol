// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";
import {Vm} from "forge-std/Vm.sol";
import {ParamsBounds} from "../src/VaultParams.sol";
import {SwarmQuestion} from "../src/helpers/SwarmQuestion.sol";

/// @dev A submission = proof link + optional screenshot (IPFS digest) + optional doer note
///      ("a submission in three parts"): stored, emitted, sent to the swarm, and the worst question still fits.
contract EvidenceTest is Base {
    // CIDv1 of "IMD screenshot" (one chunk: raw leaf) and of a 300 000-byte file (dag-pb root)
    bytes32 internal constant SMALL = 0x238ececb173c03f79a0787fdd56f733d5373c3ed804450dea4eb3ef4d9552bf7;
    string internal constant SMALL_CID = "bafkreibdr3hmwfz4ap3zub4h7xkw64z5knz4h3mairin5jhlh32nsvjl64";
    bytes32 internal constant BIG = 0xff367aaad4dac80a1fd684f2327c785c99975b3d1b89a8db0c06d15036eb1e24;
    string internal constant BIG_CID = "bafybeih7gz5kvvg2zafb7vue6izhy6c4tglvwpi3rgunwdag2fidn2y6eq";
    string internal constant PROOF = "https://x.com/doer/status/1";
    string internal constant NOTE = "Reply is the 3rd one under the post, sort by Latest";

    function _submitWith(address who, uint256 taskId, Evidence memory e) internal returns (uint256 subId) {
        vm.prank(who);
        subId = vault.submit(taskId, PROOF, e, 0, type(uint256).max, _noSwap());
    }

    function _body(uint256 subId, uint8 kind) internal view returns (bytes memory body) {
        (body,) = vault.previewSwarmBody(subId, kind);
    }

    function test_Cid_MatchesReference() public pure {
        assertEq(string(SwarmQuestion.cid(SMALL, true)), SMALL_CID);
        assertEq(string(SwarmQuestion.cid(BIG, false)), BIG_CID);
    }

    function test_StoredEmittedAndAsked() public {
        uint256 t = _create(author, address(usdc), 50e6);
        vm.expectEmit(true, false, false, true, address(caseDesk));
        emit EvidenceAttached(1, SMALL, true, NOTE);
        uint256 s = _submitWith(doer, t, Evidence(SMALL, true, NOTE));

        Submission memory sub = _sub(s);
        assertEq(sub.screenshot, SMALL);
        assertTrue(sub.screenshotRaw);
        assertEq(sub.doerNote, NOTE);

        _dispute(dave, s);
        vm.prank(doer);
        vault.reply(s, "ipfs://reply");
        bytes memory body = _body(s, SWARM_KIND_ESCALATION);
        // both are the doer's statements: in definitions next to his reply, never in the question itself
        assertTrue(
            _has(
                body,
                bytes(
                    string.concat(
                        '"claim_1":"ipfs://reason","doer_reply":"ipfs://reply","doer_note":"',
                        NOTE,
                        '","doer_shot":"https://ipfs.io/ipfs/',
                        SMALL_CID,
                        '"'
                    )
                )
            )
        );
        bytes memory question = _question(body);
        assertFalse(_has(question, bytes(SMALL_CID)));
        assertFalse(_has(question, bytes(NOTE)));
        assertTrue(_has(body, bytes("doer_reply, doer_note, appeal")));
        assertTrue(_has(body, bytes("doer_shot is the doer's untrusted screenshot")));
    }

    /// @dev A large submission's check is asked inside `submit`: the evidence is already stored and in the question.
    function test_LargeCheckQuestionCarriesEvidence() public {
        uint256 t = _create(author, address(usdc), 500e6);
        uint256 s = _submitWith(doer, t, Evidence(BIG, false, NOTE));
        assertEq(uint8(_sub(s).check), uint8(CheckState.Requested));
        bytes memory body = _body(s, SWARM_KIND_CHECK);
        // preview with the same nonce as the asked question: one ask already happened
        assertTrue(
            _has(
                body, bytes(string.concat('"doer_note":"', NOTE, '","doer_shot":"https://ipfs.io/ipfs/', BIG_CID, '"}'))
            )
        );
    }

    function test_NoEvidence_NothingAddedNoEvent() public {
        uint256 t = _create(author, address(usdc), 50e6);
        vm.recordLogs();
        uint256 s = _submitWith(doer, t, _noEvidence());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != EvidenceAttached.selector);
        }
        _dispute(dave, s);
        bytes memory body = _body(s, SWARM_KIND_ESCALATION);
        assertFalse(_has(body, '"doer_shot":'));
        assertFalse(_has(body, '"doer_note":'));
    }

    function test_OnlyOnePart() public {
        uint256 t = _create(author, address(usdc), 50e6);
        uint256 s = _submitWith(doer, t, Evidence(bytes32(0), false, NOTE));
        _dispute(dave, s);
        bytes memory body = _body(s, SWARM_KIND_ESCALATION);
        assertFalse(_has(body, '"doer_shot":'));
        assertTrue(_has(body, '"doer_note":'));

        uint256 t2 = _create(author, address(usdc), 50e6);
        uint256 s2 = _submitWith(doer2, t2, Evidence(BIG, false, ""));
        _dispute(dave, s2);
        body = _body(s2, SWARM_KIND_ESCALATION);
        assertTrue(_has(body, bytes(BIG_CID)));
        assertFalse(_has(body, '"doer_note":'));
    }

    function test_BadEvidenceReverts() public {
        uint256 t = _create(author, address(usdc), 50e6);
        string[5] memory bad = [
            string(_chars("n", MAX_NOTE_BYTES + 1)), // too long
            'say "yes"', // quote breaks the swarm JSON
            "line\nbreak", // control character
            "back\\slash",
            string(bytes.concat(hex"c0", hex"af")) // overlong UTF-8
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(doer);
            vm.expectRevert(BadEvidence.selector);
            vault.submit(t, PROOF, Evidence(bytes32(0), false, bad[i]), 0, type(uint256).max, _noSwap());
        }
        vm.prank(doer);
        vm.expectRevert(BadEvidence.selector); // a codec without a picture
        vault.submit(t, PROOF, Evidence(bytes32(0), true, ""), 0, type(uint256).max, _noSwap());

        // at the limit, Greek and emoji are fine
        _submitWith(doer, t, Evidence(SMALL, true, string(_chars("n", MAX_NOTE_BYTES))));
        uint256 t2 = _create(author, address(usdc), 50e6);
        _submitWith(
            doer,
            t2,
            Evidence(bytes32(0), false, unicode"Τρίτο σχόλιο κορυφή, ταξινόμηση Latest 👀")
        );
    }

    /// @dev The longest question the bounds allow: prefix at its bound, condition and proof of maxTextBytes, the
    ///      longest proof type name and ids of their full types (the task id twice: DOER CODE and CASE). Exactly 2000
    ///      (the Intake limit); the screenshot and the note are in definitions and add nothing to it.
    function test_WorstQuestionFitsIntakeLimit() public {
        Params memory p = defaultParams();
        SwarmQuestion.Input memory q = _worstInput(p);
        (bytes memory body,) = SwarmQuestion.build(q);
        bytes memory question = _question(body);
        emit log_named_uint("worst question bytes", question.length);
        emit log_named_string("worst question", string(question));
        assertEq(question.length, 2_000);

        // the same prefix is the bound ParamsBounds accepts, one more byte is refused
        p.questionPrefix = q.prefix;
        vm.prank(owner);
        registry.proposeParams(p);
        p.questionPrefix = bytes.concat(q.prefix, "q");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ParamsBounds.ParamOutOfBounds.selector, "questionPrefix"));
        registry.proposeParams(p);
    }

    /// @dev The whole JSON body at the largest parameters the bounds accept: maxTextBytes 512, the prefix at its
    ///      bound, the most claims `bodySize` lets through, every party text at its limit (claims, doer reply, note,
    ///      screenshot, appeal and its reply), ids and chain id of their full types. Stays under 16 384 bytes.
    function test_WorstBodyFitsIntakeLimit() public {
        Params memory p = defaultParams();
        p.maxTextBytes = 512;
        p.questionPrefix = _chars("q", 2_000 - ParamsBounds.QUESTION_FIXED - 2 * 512);
        p.maxClaims = 32;
        while (!_accepted(p)) --p.maxClaims;
        assertGt(p.maxClaims, 0);
        p.questionPrefix = _chars("q", 2_000 - ParamsBounds.QUESTION_FIXED - 2 * 512);

        SwarmQuestion.Input memory q = _worstInput(p);
        q.prefix = p.questionPrefix;
        q.definitionFields = p.definitionFields;
        q.bodyFields = p.bodyFields;
        string memory text = string(_chars("t", p.maxTextBytes));
        q.claims = new string[](p.maxClaims);
        for (uint256 i; i < q.claims.length; ++i) {
            q.claims[i] = text;
        }
        q.doerReply = text;
        q.appealReason = text;
        q.appealReply = text;
        q.chainId = type(uint256).max;
        (bytes memory body,) = SwarmQuestion.build(q);
        emit log_named_uint("max claims accepted at maxTextBytes 512", p.maxClaims);
        emit log_named_uint("worst body bytes", body.length);
        assertEq(_question(body).length, 2_000);
        assertLe(body.length, 16_384);

        // one more claim than the bound accepts would be refused, and that body could exceed the limit
        ++p.maxClaims;
        assertFalse(_accepted(p));
    }

    function _accepted(Params memory p) internal returns (bool ok) {
        vm.prank(owner);
        try registry.proposeParams(p) {
            ok = true;
        } catch {}
    }

    function _worstInput(Params memory p) internal view returns (SwarmQuestion.Input memory q) {
        q.prefix = _chars("q", 2_000 - ParamsBounds.QUESTION_FIXED - 2 * uint256(p.maxTextBytes));
        q.bodyFields = '"answerType":"bool"';
        q.taskUri = string(_chars("c", p.maxTextBytes));
        q.proofUri = string(_chars("p", p.maxTextBytes));
        q.proofType = "onchain_tx";
        q.screenshot = BIG;
        q.doerNote = string(_chars("n", MAX_NOTE_BYTES));
        q.doer = 0xabCDeF0123456789AbcdEf0123456789aBCDEF01;
        q.taskId = type(uint64).max;
        q.subId = type(uint64).max;
        q.nonce = uint256(type(uint32).max) + 1;
        q.kind = SWARM_KIND_APPEAL;
        q.chainId = 1;
        q.consumer = address(vault);
    }

    // ================================================================== helpers

    function _question(bytes memory body) internal pure returns (bytes memory q) {
        bytes memory head = '{"v":1,"question":"';
        uint256 i = head.length;
        while (body[i] != '"') ++i;
        q = new bytes(i - head.length);
        for (uint256 k; k < q.length; ++k) {
            q[k] = body[head.length + k];
        }
    }

    function _chars(bytes1 ch, uint256 n) internal pure returns (bytes memory b) {
        b = new bytes(n);
        for (uint256 i; i < n; ++i) {
            b[i] = ch;
        }
    }

    function _has(bytes memory hay, bytes memory needle) internal pure returns (bool) {
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
