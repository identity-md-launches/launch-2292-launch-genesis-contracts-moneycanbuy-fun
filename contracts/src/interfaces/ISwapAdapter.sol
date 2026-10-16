// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Payment mode A: the vault buys IMD for the user in the same transaction.
///         Contract with the vault:
///         - exact input: the adapter consumes exactly `amountIn` of `tokenIn` (ETH via msg.value, ERC-20 via
///           transferFrom from the vault, which approves exactly `amountIn` beforehand);
///         - it sends at least `minOut` of `tokenOut` to `recipient` or reverts;
///         - it reverts after `deadline`;
///         - `route` is opaque, built off-chain by the site (pool/fee/path), the adapter validates it.
///         The vault measures the IMD it actually received (balance difference) and never trusts the return value.
interface ISwapAdapter {
    function swapExactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        uint256 deadline,
        bytes calldata route,
        address recipient
    ) external payable returns (uint256 amountOut);
}
