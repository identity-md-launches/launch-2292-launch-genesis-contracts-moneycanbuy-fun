// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract SafeCastProbe {
    function toUint16(uint256 v) external pure returns (uint16) {
        return SafeCast.toUint16(v);
    }

    function toUint32(uint256 v) external pure returns (uint32) {
        return SafeCast.toUint32(v);
    }
}

/// @dev Dispute.votesAccept/votesReject/walletsAccept/walletsReject are uint32, written by DisputeDesk.vote
///      through SafeCast.toUint32, which reverts rather than wraps. Votes are bounded by the identity.md
///      MAX_SUPPLY (2,000 NFTs, VotePower: 1 NFT = 1 vote), but that bound lives in the NFT contract, not here:
///      a uint16 count would make every vote() on a dispute revert once 65,535 is crossed; uint32 round-trips
///      such a value, with headroom many orders above any NFT supply.
contract VoteCountWidthTest is Test {
    SafeCastProbe internal probe = new SafeCastProbe();

    function test_PastUint16Limit_StuckBefore_FineAfter() public {
        uint256 v = 70_000; // > type(uint16).max (65,535), well under type(uint32).max
        vm.expectRevert();
        probe.toUint16(v); // a uint16 field: vote() would revert on every call past this point
        assertEq(probe.toUint32(v), v); // the uint32 field: round-trips exactly
    }
}
