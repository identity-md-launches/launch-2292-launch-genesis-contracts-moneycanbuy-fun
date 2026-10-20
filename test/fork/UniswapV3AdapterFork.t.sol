// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UniswapV3SwapAdapter, ISwapRouter02} from "../../src/adapters/UniswapV3SwapAdapter.sol";

/// @dev Local simulation on a mainnet fork (read-only RPC, nothing is sent). Skipped unless FORK_URL is set:
///      FORK_URL=https://mainnet.gateway.tenderly.co forge test --match-contract UniswapV3AdapterFork
contract UniswapV3AdapterFork is Test {
    address constant ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;

    function test_Fork_EthToImd() public {
        string memory url = vm.envOr("FORK_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url);
        UniswapV3SwapAdapter a = new UniswapV3SwapAdapter(ISwapRouter02(ROUTER), WETH);
        bytes memory path = abi.encodePacked(WETH, uint24(500), USDC, uint24(3000), IMD);
        address me = makeAddr("payer");
        vm.deal(me, 1 ether);
        vm.prank(me);
        uint256 out = a.swapExactIn{value: 0.01 ether}(address(0), IMD, 0.01 ether, 1, block.timestamp, path, me);
        assertEq(IERC20(IMD).balanceOf(me), out);
        emit log_named_uint("IMD for 0.01 ETH", out);
        // a route that does not end in IMD is refused
        bytes memory bad = abi.encodePacked(WETH, uint24(500), USDC);
        vm.prank(me);
        vm.expectRevert(UniswapV3SwapAdapter.BadRoute.selector);
        a.swapExactIn{value: 0.01 ether}(address(0), IMD, 0.01 ether, 1, block.timestamp, bad, me);
    }
}
