// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IDelegateRegistry} from "../../src/interfaces/IDelegateRegistry.sol";

/// @dev delegate.xyz v2 subset: wallet-level delegation and one-token delegation.
contract MockDelegateRegistry is IDelegateRegistry {
    mapping(address => mapping(address => bool)) public delegated; // from => to
    mapping(address => mapping(address => mapping(address => mapping(uint256 => bool)))) public delegatedToken;

    function delegateAll(address to, bool on) external {
        delegated[msg.sender][to] = on;
    }

    function delegateERC721(address to, address contract_, uint256 tokenId, bool on) external {
        delegatedToken[msg.sender][to][contract_][tokenId] = on;
    }

    function checkDelegateForERC721(address to, address from, address contract_, uint256 tokenId, bytes32)
        external
        view
        returns (bool)
    {
        return delegated[from][to] || delegatedToken[from][to][contract_][tokenId];
    }
}
