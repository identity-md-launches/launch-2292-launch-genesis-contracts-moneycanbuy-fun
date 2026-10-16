// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice EIP-712 attestation signed by the IMD oracle (docs "Oracle answers" -> "The attestation",
///         domain version 2, in force since 2026-09-30).
///         Domain: {name: "IdentityMD Oracle", version: "2", chainId, verifyingContract = the consumer}.
///         `answerType`: bool 0, address 1, bytes32 2, uint256 3, address[] 4, bytes32[] 5;
///         `answer` is abi.encode of the value. `requestId` / `panelJobId` are UUIDs as 16 raw bytes, left-aligned.
///         Field order below is confirmed by the documented callback selector 0x510379c7.
library OracleAttestation {
    struct Attestation {
        bytes32 requestId;
        uint256 chainId;
        bytes32 questionHash;
        uint8 answerType;
        bytes answer;
        uint256 figure;
        uint64 fromBlock;
        uint64 toBlock;
        bytes32 blockHash;
        bytes32 panelJobId;
        uint16 panelSize;
        uint16 quorum;
        uint16 agreed;
        uint64 issuedAt;
        uint64 expiresAt;
    }

    bytes32 internal constant TYPEHASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,"
        "bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,"
        "uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
    );

    string internal constant DOMAIN_NAME = "IdentityMD Oracle";
    string internal constant DOMAIN_VERSION = "2";

    uint8 internal constant ANSWER_BOOL = 0;

    function hashStruct(Attestation calldata a) internal pure returns (bytes32) {
        // Two-step encoding to keep stack depth manageable (15 fields + typehash).
        bytes memory head = abi.encode(
            TYPEHASH,
            a.requestId,
            a.chainId,
            a.questionHash,
            a.answerType,
            keccak256(a.answer),
            a.figure,
            a.fromBlock,
            a.toBlock
        );
        bytes memory tail =
            abi.encode(a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt);
        return keccak256(bytes.concat(head, tail));
    }
}
