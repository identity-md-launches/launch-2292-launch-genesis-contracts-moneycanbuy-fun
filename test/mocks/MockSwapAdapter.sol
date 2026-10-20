// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapAdapter} from "../../src/interfaces/ISwapAdapter.sol";
import {MockERC20} from "./MockERC20.sol";

/// @dev Exact-input swap at a fixed rate (out per 1e18 of input units), mints the output token.
contract MockSwapAdapter is ISwapAdapter {
    mapping(address => uint256) public rate; // tokenIn => tokenOut units per 1 input unit, 1e18 scaled

    function setRate(address tokenIn, uint256 r) external {
        rate[tokenIn] = r;
    }

    function swapExactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        uint256 deadline,
        bytes calldata,
        address recipient
    ) external payable returns (uint256 amountOut) {
        require(block.timestamp <= deadline, "expired");
        if (tokenIn == address(0)) require(msg.value == amountIn, "value");
        else IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        amountOut = amountIn * rate[tokenIn] / 1e18;
        require(amountOut >= minOut, "minOut");
        MockERC20(tokenOut).mint(recipient, amountOut);
    }
}
