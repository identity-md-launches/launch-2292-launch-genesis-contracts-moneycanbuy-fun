// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SwarmQuestion} from "../../src/helpers/SwarmQuestion.sol";
import {ParamsBounds} from "../../src/VaultParams.sol";

/// @dev The swarm question length limit at maximum parameters and maximum ids.
///      The check in `ParamsBounds` promises that the fixed part of the question is at most 234 bytes (`QUESTION_FIXED`,
///      DOER CODE with the full doer address), so `questionPrefix + 2 x maxTextBytes <= 1766` keeps the question within
///      the Intake limit (2000 characters). The doer's screenshot and note sit in `definitions` and do not lengthen it.
///      The test in `TaskFields.t.sol` computes the worst case on short ids and compensates for the task number once,
///      although the number appears in the question twice (DOER CODE and CASE). Here the question is
///      built directly with ids of the limit types (`taskId`, `subId` uint64, `nonce` = `asks + 1` uint32), no guessing.
contract ReviewQuestionSize is Test {
    uint256 internal constant INTAKE_LIMIT = 2_000;
    uint256 internal constant FIXED_CLAIM = 234; // the promise of the ParamsBounds comment
    uint256 internal constant PREFIX_BOUND = INTAKE_LIMIT - FIXED_CLAIM; // ParamsBounds: prefix + 2 x maxTextBytes

    function _input(uint256 taskId, uint256 subId, uint256 nonce, string memory task, string memory proof)
        internal
        view
        returns (SwarmQuestion.Input memory q)
    {
        q.prefix = bytes(_chars("q", PREFIX_BOUND - 512)); // the limit at maxTextBytes = 256
        q.bodyFields = '"answerType":"bool"';
        q.taskUri = task;
        q.proofUri = proof;
        q.proofType = "onchain_tx"; // the longest proof type name
        q.screenshot = bytes32(type(uint256).max); // the doer's screenshot and note: in definitions, not in the question
        q.doerNote = "Reply is the 3rd one under the post";
        q.doer = 0xabCDeF0123456789AbcdEf0123456789aBCDEF01;
        q.taskId = taskId;
        q.subId = subId;
        q.nonce = nonce;
        q.kind = 2;
        q.chainId = 1;
        q.consumer = address(this);
    }

    /// @dev The whole worst case: limit prefix, two 256-byte texts, limit ids.
    function test_WorstCaseQuestionFitsIntakeLimit() public {
        SwarmQuestion.Input memory q = _input(
            type(uint64).max, type(uint64).max, uint256(type(uint32).max) + 1, _chars("c", 256), _chars("p", 256)
        );
        (bytes memory body,) = SwarmQuestion.build(q);
        bytes memory question = _question(body);
        emit log_named_uint("worst-case question bytes", question.length);
        assertLe(question.length, INTAKE_LIMIT);
    }

    /// @dev The fixed part of the question at limit ids = exactly the promised 234 bytes, not a byte more.
    function test_FixedPartIs234BytesAtMaxIds() public {
        SwarmQuestion.Input memory q = _input(
            type(uint64).max, type(uint64).max, uint256(type(uint32).max) + 1, _chars("c", 256), _chars("p", 256)
        );
        (bytes memory body,) = SwarmQuestion.build(q);
        uint256 fixedPart = _question(body).length - q.prefix.length - 256 - 256;
        emit log_named_uint("fixed part bytes at max ids", fixedPart);
        assertEq(fixedPart, FIXED_CLAIM);
        assertEq(PREFIX_BOUND + FIXED_CLAIM, 2_000);
        assertEq(FIXED_CLAIM, ParamsBounds.QUESTION_FIXED);
    }

    /// @dev The task number enters the question twice: in DOER CODE and in CASE. The fixed part grows twice as fast
    ///      with a long number as the test in `TaskFields.t.sol` assumes (it compensates once).
    function test_TaskIdCountsTwiceInFixedPart() public {
        string memory task = _chars("c", 256);
        string memory proof = _chars("p", 256);
        (bytes memory shortBody,) = SwarmQuestion.build(_input(1, 1, 1, task, proof));
        (bytes memory longBody,) = SwarmQuestion.build(_input(type(uint64).max, 1, 1, task, proof));
        uint256 grew = _question(longBody).length - _question(shortBody).length;
        emit log_named_uint("bytes added by a 20-digit task id", grew);
        assertEq(grew, 2 * (20 - 1));
    }

    function _question(bytes memory body) internal pure returns (bytes memory q) {
        bytes memory head = '{"v":1,"question":"';
        uint256 i = head.length;
        while (body[i] != '"') ++i;
        q = new bytes(i - head.length);
        for (uint256 k; k < q.length; ++k) {
            q[k] = body[head.length + k];
        }
    }

    function _chars(bytes1 ch, uint256 n) internal pure returns (string memory) {
        bytes memory b = new bytes(n);
        for (uint256 i; i < n; ++i) {
            b[i] = ch;
        }
        return string(b);
    }
}
