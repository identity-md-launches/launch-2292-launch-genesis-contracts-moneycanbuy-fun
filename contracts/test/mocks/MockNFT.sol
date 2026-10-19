// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract MockNFT is ERC721("identity.md", "IMDID") {
    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    /// @notice Test collection only: mint `count` NFTs with ids `firstId`.. to `to` in one transaction.
    function mintBatch(address to, uint256 firstId, uint256 count) external {
        for (uint256 i; i < count; ++i) {
            _mint(to, firstId + i);
        }
    }
}
