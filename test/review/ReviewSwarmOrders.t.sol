// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";

import {SwarmQuestion} from "../../src/helpers/SwarmQuestion.sol";
import {LaunchParams, Params} from "../../src/VaultParams.sol";

/// @notice The bodies of four sample swarm questions (T1-T4), built by the same
///         library and the same version-1 template the CaseDesk uses. The conditions are sample task rules,
///         the proof is a real mainnet transaction. `consumer` here is 0x...01: in a real request it is
///         the wallet that pays for it, which changes the body only there; the question and its keccak do not
///         include it. The test pins the question hashes below.
contract ReviewSwarmOrders is Test {
    /// @dev T1, T2 and T4 are built as escalation-kind questions. The kind is not part of
    ///      the question or the body (SwarmQuestion.build ignores it), so the first question of an escalation gives
    ///      the same bytes and the same pinned hashes below.
    uint8 internal constant KIND_FIRST = SwarmQuestion.KIND_ESCALATION;
    string constant ONCHAIN =
        "Ethereum mainnet tx from DOER to 0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7; calls transfer(address,uint256); transfers at least 10 tokens to any address; succeeded, mined after 2026-10-11 00:00 UTC";
    string constant LINK =
        unicode"Web page; page contains: “Ask the oracle”; https, live at check; moneycanbuy.fun on the page";
    string constant TX = "https://etherscan.io/tx/0x0f7efe38f007c795e60cc01f900e4c7eeb3a74418879e9d7dfbd5c527225fb5b";
    address constant SENDER = 0xcF472E2a100E7C97d3440F34eb21be470b8335a5; // from of TX
    address constant OTHER = 0xE132be23CE6255930556a45406075E62fb6340C0; // not the sender of TX

    function _q(string memory cond, string memory proof, string memory pType, address doer, uint8 kind)
        internal
        pure
        returns (SwarmQuestion.Input memory q)
    {
        Params memory p = LaunchParams.initial(address(1), address(1), address(1), address(1), address(1), address(1));
        q.prefix = p.questionPrefix;
        q.definitionFields = p.definitionFields;
        q.bodyFields = p.bodyFields;
        q.task = cond;
        q.taskProof = "WINDOW: made after 2026-10-11 00:00 UTC. WHO: DOER = wallet that submits. SOURCE: Etherscan";
        q.taskNo = "NO if: failed, not from DOER, outside WINDOW, any step missing, unclear";
        q.proofUri = proof;
        q.proofType = pType;
        q.doer = doer;
        q.taskId = 1;
        q.subId = 1;
        q.nonce = 1;
        q.kind = kind;
        q.chainId = 1;
        q.consumer = address(1);
    }

    function _print(string memory name, SwarmQuestion.Input memory q) internal pure returns (bytes32 qh) {
        bytes memory body;
        (body, qh) = SwarmQuestion.build(q);
        console.log(name, body.length);
        console.log(string(body));
        console.logBytes32(qh);
    }

    function test_printTestQuestions() public pure {
        // the task's rules are the definitions task / task_proof / task_no, the question only points
        // to them, so every hash below depends on it.
        // All four are built first, so a failing run prints every new hash.
        // T1: the doer sent the transaction -> expected true
        bytes32 h1 = _print("T1", _q(ONCHAIN, TX, "onchain_tx", SENDER, KIND_FIRST));
        // T2: same transaction, another doer -> expected false (not sent from DOER)
        bytes32 h2 = _print("T2", _q(ONCHAIN, TX, "onchain_tx", OTHER, KIND_FIRST));
        // T3: T1 as an escalation with a false dispute reason and the doer's note (their "why
        // honest" text, attached at submission, not a separate reply) -> expected true
        SwarmQuestion.Input memory q3 = _q(ONCHAIN, TX, "onchain_tx", SENDER, SwarmQuestion.KIND_ESCALATION);
        q3.nonce = 2; // the second question of this submission (asks + 1)
        q3.claims = new string[](1);
        q3.claims[0] = "The transaction moved only 5 IMD, less than the 10 the task requires.";
        q3.claimProofs = new string[](1);
        q3.claimProofs[0] = "https://etherscan.io/tx/0x0f7efe38f007c795e60cc01f900e4c7eeb3a74418879e9d7dfbd5c527225fb5b";
        q3.doerNote = "The Transfer log of the transaction shows 379.22 IMD sent from my address.";
        bytes32 h3 = _print("T3", q3);
        // T4: a public page without moneycanbuy.fun -> expected false
        bytes32 h4 = _print("T4", _q(LINK, "https://imd.fun/docs/", "link", SENDER, KIND_FIRST));
        assertEq(h1, HASH_T1);
        assertEq(h2, HASH_T2);
        assertEq(h3, HASH_T3);
        assertEq(h4, HASH_T4);
    }

    bytes32 constant HASH_T1 = 0xe0161177113a03c1dce7415ed9e1c076c939b5968441681ed1fdd3a3632bfed6;
    bytes32 constant HASH_T2 = 0x9adb7cd61bdff19f992b83d1a9ea1517767d60fbec90fc4c558de186b04525b4;
    bytes32 constant HASH_T3 = 0x648b6ba47fb0a9d37651b0bedc56c9409154b663f6bc5b6b38e9577ef42a244a;
    bytes32 constant HASH_T4 = 0x5d1a8eff6f36add21363c69a6355fc1ae6c261428b7091e74637bc4b9a3c032a;
}
