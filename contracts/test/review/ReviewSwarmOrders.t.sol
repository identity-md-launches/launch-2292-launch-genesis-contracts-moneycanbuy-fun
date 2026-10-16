// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";

import {SwarmQuestion} from "../../src/helpers/SwarmQuestion.sol";
import {LaunchParams, Params} from "../../src/VaultParams.sol";

/// @notice Swarm questions built from the contracts: four example questions (T1-T4: an on-chain check with the
///         right doer and with another doer, an escalation with a dispute reason and the doer's reply, a page check
///         without the DOER CODE), built by the same library and the same version-1 template the CaseDesk uses.
///         The conditions are in the form the task templates write them, the proof is a real mainnet transaction.
///         `consumer` here is 0x…01; it changes the body only in that field, and the question and its keccak do
///         not include it. The test prints each body and pins its question hash, so any change to the template or
///         the builder shows up here.
contract ReviewSwarmOrders is Test {
    string constant ONCHAIN =
        "Ethereum mainnet tx from DOER to 0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7; calls transfer(address,uint256); transfers at least 10 tokens to any address; succeeded, mined after 2026-10-11 00:00 UTC";
    string constant LINK =
        unicode"Web page; page contains: “Ask the oracle”; https, live at check; DOER CODE on the page";
    string constant TX = "https://etherscan.io/tx/0x0f7efe38f007c795e60cc01f900e4c7eeb3a74418879e9d7dfbd5c527225fb5b";
    address constant SENDER = 0xcF472E2a100E7C97d3440F34eb21be470b8335a5; // from of TX
    address constant OTHER = address(uint160(uint256(keccak256("other")))); // deterministic, not the sender of TX

    function _q(string memory cond, string memory proof, string memory pType, address doer, uint8 kind)
        internal
        pure
        returns (SwarmQuestion.Input memory q)
    {
        Params memory p = LaunchParams.initial(address(1), address(1), address(1), address(1), address(1), address(1));
        q.prefix = p.questionPrefix;
        q.definitionFields = p.definitionFields;
        q.bodyFields = p.bodyFields;
        q.taskUri = cond;
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
        // T1: the doer sent the transaction -> expected true
        assertEq(
            _print("T1", _q(ONCHAIN, TX, "onchain_tx", SENDER, SwarmQuestion.KIND_CHECK)),
            0xa81fa477fd236abd81da4a7aa7567db3f3af1258d95f5127029cdd2f5e60d1ab
        );
        // T2: same transaction, another doer -> expected false (not sent from DOER)
        assertEq(
            _print("T2", _q(ONCHAIN, TX, "onchain_tx", OTHER, SwarmQuestion.KIND_CHECK)),
            0x16d8833fce2cbf129f8f05b535e8493cc8e70ec8d0e31987a967ddb1f0ad7235
        );
        // T3: T1 as an escalation with a false dispute reason and the doer's reply -> expected true
        SwarmQuestion.Input memory q3 = _q(ONCHAIN, TX, "onchain_tx", SENDER, SwarmQuestion.KIND_ESCALATION);
        q3.nonce = 2; // the second question of this submission (asks + 1)
        q3.claims = new string[](1);
        q3.claims[0] = "The transaction moved only 5 IMD, less than the 10 the task requires.";
        q3.doerReply = "The Transfer log of the transaction shows 379.22 IMD sent from my address.";
        assertEq(_print("T3", q3), 0x715022536a4488fe0e7e95f8ffddee7221f336ff8a3386c2ef7fdb108d9c857a);
        // T4: a public page without the DOER CODE -> expected false
        assertEq(
            _print("T4", _q(LINK, "https://imd.fun/docs/", "link", SENDER, SwarmQuestion.KIND_CHECK)),
            0xd51c5b49f2bf4fa5c8403a242289574134d2a435c5f87dae9a0ddf2f7451f885
        );
    }
}
