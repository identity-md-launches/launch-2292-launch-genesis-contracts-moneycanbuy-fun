// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";

/// @dev Uniswap SwapRouter02 (mainnet 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45), exactInput only.
interface ISwapRouter02 {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/// @title UniswapV3SwapAdapter
/// @notice Mode A payments through Uniswap v3 (SwapRouter02.exactInput). `route` is a v3 path
///         (token | fee(uint24) | token | ...) chosen by the site; for ETH input it starts with WETH (the router
///         wraps msg.value). Verified on mainnet (eth_call): USDC/IMD 0.3% pool
///         0x894D4e6d3d2Abc64Fc0de0e4e2Ea63A93BC9c520 holds ~38.4k IMD + ~31.6k USDC; the v3 WETH/IMD 1% pool is
///         empty, so ETH routes go WETH -500- USDC -3000- IMD.
///         The deep IMD/ETH pool (~$2.5M, 1%) is on Uniswap v4 and needs a separate adapter (see README).
///         Holds no funds between calls; anyone may use it; the vault measures what it receives.
contract UniswapV3SwapAdapter is ISwapAdapter {
    using SafeERC20 for IERC20;

    ISwapRouter02 public immutable router;
    address public immutable weth;

    error BadRoute();
    error Expired();
    error BadValue();

    constructor(ISwapRouter02 router_, address weth_) {
        router = router_;
        weth = weth_;
    }

    function swapExactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        uint256 deadline,
        bytes calldata route,
        address recipient
    ) external payable returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert Expired();
        if (route.length < 43 || (route.length - 20) % 23 != 0) revert BadRoute();
        address first = address(bytes20(route[0:20]));
        address last = address(bytes20(route[route.length - 20:]));
        if (first != (tokenIn == address(0) ? weth : tokenIn) || last != tokenOut) revert BadRoute();
        ISwapRouter02.ExactInputParams memory params = ISwapRouter02.ExactInputParams({
            path: route, recipient: recipient, amountIn: amountIn, amountOutMinimum: minOut
        });
        if (tokenIn == address(0)) {
            if (msg.value != amountIn) revert BadValue();
            amountOut = router.exactInput{value: amountIn}(params);
        } else {
            if (msg.value != 0) revert BadValue();
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
            IERC20(tokenIn).forceApprove(address(router), amountIn);
            amountOut = router.exactInput(params);
            IERC20(tokenIn).forceApprove(address(router), 0);
        }
    }
}
