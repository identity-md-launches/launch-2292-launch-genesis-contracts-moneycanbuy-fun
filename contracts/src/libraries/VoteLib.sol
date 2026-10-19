// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice One address's record in the vote book of a submission. As a voter: the side it voted (1 accept, 2 reject),
///         one side per wallet (more transactions for the same side add NFTs). As a payTo: its counted NFTs per side and whether its voter reward was claimed. A
///         holder voting for themselves (voter == payTo, the usual case) touches a single slot.
struct VoterRec {
    uint8 side;
    uint8 claimed;
    uint120 accept;
    uint120 reject;
}

/// @notice Per-submission vote storage: the records, and the NFT ids that voted (bit `id % 256` of word `id / 256`),
///         each id votes once per dispute.
struct VoteBook {
    mapping(address => VoterRec) recs;
    mapping(uint256 => uint256) votedIds;
}

/// @notice What the dispute desk reads of VotePower: who may vote with an NFT now (owner or delegate.xyz delegate).
interface IVotePower {
    function firstNotHeld(address who, uint256[] calldata tokenIds) external view returns (uint256);
}

/// @title VoteLib
/// @notice Constants and event of the NFT vote (DisputeDesk.vote).
library VoteLib {
    uint8 internal constant SIDE_ACCEPT = 1;
    uint8 internal constant SIDE_REJECT = 2;

    event VoteCounted(uint256 indexed subId, address indexed voter, address indexed payTo, uint8 side, uint256 counted);
}
