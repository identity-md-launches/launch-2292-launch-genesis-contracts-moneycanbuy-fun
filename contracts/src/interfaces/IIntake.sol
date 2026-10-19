// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice IMD Intake (swarm oracle payment entry point), Ethereum mainnet: version 2
///         0xa43e6f75ee006411f79ac1c84120606c2330de82 (the launch's; it keeps every function, event and getter of
///         version 1), version 1
///         0x1397434cd35e8a9c8ac312a61d3a285eb31dea56 still served (source verified on Sourcify/Blockscout, selectors
///         checked against the bytecode). Only the version 1 functions are used here. `action` is the right-padded ASCII bytes32 of
///         "oracle.request(at)oracle-1". `request` is payable but must get msg.value == 0 for ERC-20 payment.
///         `request` pulls `amount` of `asset` from msg.sender (transferFrom) and forwards it to the
///         Intake payee; the control plane reads the `Requested` event, runs the panel, and the Intake
///         writer later calls `complete`, which (status 0 only) calls
///         `callback.target` with `callback.selector ++ abi.encode(requestId, attestation, signature)`
///         and a fixed gas budget (200,000 at the time of writing), inside a try.
interface IIntake {
    struct Callback {
        address target;
        bytes4 selector;
    }

    function request(bytes32 action, bytes calldata body, Callback calldata callback, address asset, uint256 amount)
        external
        returns (bytes32 requestId);

    /// @notice Live price of `action` paid in `asset`. The Intake price may differ at call time.
    function priceOf(bytes32 action, address asset) external view returns (uint256);

    /// @notice Stored request; `completed` turns true when the writer called `complete` (any status).
    function requests(bytes32 requestId)
        external
        view
        returns (address payer, address callbackTarget, bytes4 callbackSelector, bool completed);
}
