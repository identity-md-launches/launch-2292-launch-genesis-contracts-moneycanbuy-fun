// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {Submission, Task} from "../VaultTypes.sol";

/// @title SwarmQuestion
/// @notice Builds the Intake JSON body (action oracle.request(at)oracle-1, docs "Ask the oracle") on-chain from stored data,
///         so no party can smuggle its own question:
///         {"v":1,"question":"<prefix>TASK: .. | PROOF: .. | PROOF TYPE: x_post | DOER: 0x..
///                             | DOER CODE: IMD-<task>-<DOER> | CASE: t/s/n",
///          "definitions":{<template definitions>,"claim_1":"..",...,"doer_reply":"..","doer_note":"..",
///                         "doer_shot":"https://ipfs.io/ipfs/<CIDv1>","appeal":"..","appeal_reply":".."},
///          <bodyFields: chainId, window, answerType "bool", evidence, panelSize, quorum, validForSeconds, ...>,
///          "consumer":{"chainId":<chain>,"verifyingContract":"<vault>"}}
///         The question stays short (Intake limit 2000 chars); party texts go to `definitions` (values <= 512)
///         and the template must tell the panel they are untrusted claims. All strings were checked at input to
///         contain no quote, backslash or control characters, so they are embedded verbatim.
///         `questionHash` returned here is keccak256(question): the real derivation used by the IMD plane is
///         not verified. It is only recorded (SwarmAsked, SwarmRequest): the public fallback that checked
///         it was removed (audit B-01) and the callback path does not use it.
library SwarmQuestion {
    uint8 internal constant KIND_CHECK = 1; // = SWARM_KIND_CHECK
    uint8 internal constant KIND_ESCALATION = 2; // = SWARM_KIND_ESCALATION
    uint8 internal constant KIND_APPEAL = 3; // = SWARM_KIND_APPEAL
    /// @dev Public gateway the panel opens the doer's screenshot through (the CID is the picture's hash: any gateway
    ///      serves the same bytes or nothing). `,"doer_shot":"` 14 + this 21 + CID 59 + `"` 1 = 95 bytes of the body.
    bytes internal constant SCREENSHOT_GATEWAY = "https://ipfs.io/ipfs/";
    bytes internal constant BASE32 = "abcdefghijklmnopqrstuvwxyz234567";

    struct Input {
        bytes prefix;
        bytes definitionFields; // template definitions: compact JSON members, may be empty
        bytes bodyFields;
        string taskUri;
        string proofUri;
        string proofType; // x_post | video | onchain_tx | link
        bytes32 screenshot; // Evidence: 0 = none
        bool screenshotRaw;
        string doerNote;
        address doer;
        uint256 taskId;
        uint256 subId;
        uint256 nonce;
        uint8 kind;
        string[] claims; // dispute reasons, in filing order
        string doerReply;
        string appealReason;
        string appealReply;
        uint256 chainId;
        address consumer;
    }

    function build(Input memory q) internal pure returns (bytes memory body, bytes32 questionHash) {
        bytes memory question = bytes.concat(
            q.prefix,
            "TASK: ",
            bytes(q.taskUri),
            " | PROOF: ",
            bytes(q.proofUri),
            " | PROOF TYPE: ",
            bytes(q.proofType),
            " | DOER: ",
            bytes(Strings.toHexString(q.doer)),
            " | DOER CODE: ",
            doerCode(q.taskId, q.doer),
            " | CASE: ",
            bytes(Strings.toString(q.taskId)),
            "/",
            bytes(Strings.toString(q.subId)),
            "/",
            bytes(Strings.toString(q.nonce))
        );
        questionHash = keccak256(question);

        bytes memory defs = q.definitionFields;
        for (uint256 i; i < q.claims.length; ++i) {
            defs = _member(defs, bytes.concat("claim_", bytes(Strings.toString(i + 1))), bytes(q.claims[i]));
        }
        // the doer's side together: his reply to the disputes, then what he attached to the proof
        defs = _member(defs, "doer_reply", bytes(q.doerReply));
        defs = _member(defs, "doer_note", bytes(q.doerNote));
        if (q.screenshot != 0) {
            defs = _member(defs, "doer_shot", bytes.concat(SCREENSHOT_GATEWAY, cid(q.screenshot, q.screenshotRaw)));
        }
        defs = _member(defs, "appeal", bytes(q.appealReason));
        defs = _member(defs, "appeal_reply", bytes(q.appealReply));

        body = bytes.concat('{"v":1,"question":"', question, '"');
        if (defs.length != 0) body = bytes.concat(body, ',"definitions":{', defs, "}");
        body = bytes.concat(
            body,
            ",",
            q.bodyFields,
            ',"consumer":{"chainId":',
            bytes(Strings.toString(q.chainId)),
            ',"verifyingContract":"',
            bytes(Strings.toHexString(q.consumer)),
            '"}}'
        );
    }

    /// @dev The code that binds a proof to its doer: `IMD-<taskId>-<doer address, 0x + 40 hex lowercase>`, byte for
    ///      byte what the site shows the doer (the doerCode of the site's task templates). The whole address: any shorter
    ///      part can be ground out (6 hex take seconds to grind), so a thief cannot hand in an honest doer's post
    ///      first. The prefix tells the panel it must appear in the post / video description / page (onchain_tx: the
    ///      transaction must be sent from DOER instead).
    function doerCode(uint256 taskId, address doer) internal pure returns (bytes memory) {
        return bytes.concat("IMD-", bytes(Strings.toString(taskId)), "-", bytes(Strings.toHexString(doer)));
    }

    /// @dev CIDv1 of an IPFS block with sha2-256 `digest`: multibase "b" + base32 (RFC 4648 lower case, no padding)
    ///      of <version 1><codec raw 0x55 | dag-pb 0x70><0x12 sha2-256><0x20 length><digest>, 59 characters.
    ///      The 4 header bytes are 6 fixed characters ("afkrei" / "afybei") and 2 zero bits that lead the digest:
    ///      character k of the digest part takes bits [253 - 5k, 258 - 5k) of it, the last one its 3 low bits + 2 zeros.
    function cid(bytes32 digest, bool raw) internal pure returns (bytes memory out) {
        out = bytes.concat(raw ? bytes("bafkrei") : bytes("bafybei"), new bytes(52));
        uint256 d = uint256(digest);
        bytes memory alphabet = BASE32;
        unchecked {
            for (uint256 k; k < 51; ++k) {
                out[7 + k] = alphabet[(d >> (253 - 5 * k)) & 31];
            }
            out[58] = alphabet[(d << 2) & 31];
        }
    }

    /// @dev Name of a proof type in the question (the same words the site and the templates use).
    function proofTypeName(uint8 proofType) internal pure returns (string memory) {
        if (proofType == 0) return "x_post";
        if (proofType == 1) return "video";
        if (proofType == 2) return "onchain_tx";
        return "link";
    }

    /// @dev Appends `"key":"value"` to a list of JSON members; empty values are skipped.
    function _member(bytes memory list, bytes memory key, bytes memory value) private pure returns (bytes memory) {
        if (value.length == 0) return list;
        bytes memory m = bytes.concat('"', key, '":"', value, '"');
        return list.length == 0 ? m : bytes.concat(list, ",", m);
    }
}

/// @title SwarmQuestionBuilder
/// @notice Stateless helper of the CaseDesk: assembles the question of a submission from what the vault's desks
///         store (their public views) and builds the Intake body. Read-only; the vault pays and sends it.
contract SwarmQuestionBuilder {
    /// @param maxClaims how many dispute reasons go into the question (the task's parameter version)
    function buildFor(address vault, uint256 subId, uint8 kind, uint256 maxClaims)
        external
        view
        returns (bytes memory body, bytes32 questionHash)
    {
        IQuestionSources v = IQuestionSources(vault);
        Submission memory s = IQuestionSources(v.caseDesk()).getSubmission(subId);
        Task memory t = v.getTask(s.taskId);
        SwarmQuestion.Input memory q;
        (q.prefix, q.definitionFields, q.bodyFields) = IQuestionSources(v.registry()).template(t.paramsVersion);
        q.taskUri = t.condition;
        q.proofType = SwarmQuestion.proofTypeName(t.proofType);
        q.proofUri = s.proofUri;
        q.screenshot = s.screenshot;
        q.screenshotRaw = s.screenshotRaw;
        q.doerNote = s.doerNote;
        q.doer = s.doer;
        q.taskId = s.taskId;
        q.subId = subId;
        q.nonce = uint256(s.asks) + 1; // unique per question of this submission
        q.kind = kind;
        if (kind != SwarmQuestion.KIND_CHECK) {
            // disputers are unlimited; the question carries the first maxClaims reasons (the caller's own reason
            // always goes in as "appeal", so a crowd of early disputers cannot silence him)
            (q.claims, q.appealReason, q.appealReply) = IQuestionSources(v.disputeDesk()).questionPart(subId, maxClaims);
            q.doerReply = s.doerReply;
        }
        q.chainId = block.chainid;
        q.consumer = vault;
        return SwarmQuestion.build(q);
    }
}

/// @dev The views the builder reads: the vault's tasks and desk addresses, the desks' records, the registry's template.
interface IQuestionSources {
    function registry() external view returns (address);
    function caseDesk() external view returns (address);
    function disputeDesk() external view returns (address);
    function getSubmission(uint256 subId) external view returns (Submission memory);
    function getTask(uint256 taskId) external view returns (Task memory);
    function template(uint32 version) external view returns (bytes memory, bytes memory, bytes memory);
    function questionPart(uint256 subId, uint256 maxClaims)
        external
        view
        returns (string[] memory claims, string memory appealReason, string memory appealReply);
}
