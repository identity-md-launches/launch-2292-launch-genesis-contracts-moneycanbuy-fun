// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IDelegateRegistry} from "../../src/interfaces/IDelegateRegistry.sol";

/// @dev delegate.xyz v2 subset: wallet-level delegation only.
contract MockDelegateRegistry is IDelegateRegistry {
    mapping(address => mapping(address => bool)) public delegated; // from => to

    function delegateAll(address to, bool on) external {
        delegated[msg.sender][to] = on;
    }

    function checkDelegateForERC721(address to, address from, address, uint256, bytes32) external view returns (bool) {
        return delegated[from][to];
    }
}
