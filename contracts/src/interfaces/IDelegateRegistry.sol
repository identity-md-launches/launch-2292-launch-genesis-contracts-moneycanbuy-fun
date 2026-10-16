// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice delegate.xyz v2 registry (0x00000000000000447e69651d841bD8D104Bed493), subset we read.
///         Returns true if `from` delegated to `to` for the whole wallet, the NFT contract, or this tokenId
///         (rights = 0 means "all rights").
interface IDelegateRegistry {
    function checkDelegateForERC721(address to, address from, address contract_, uint256 tokenId, bytes32 rights)
        external
        view
        returns (bool);
}
