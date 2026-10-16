// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {UniswapV3SwapAdapter, ISwapRouter02} from "../../src/adapters/UniswapV3SwapAdapter.sol";

interface IPoolCardinality {
    function increaseObservationCardinalityNext(uint16 next) external;
}
import {
    ChainlinkUniV3PriceOracle,
    IAggregatorV3,
    IUniswapV3PoolObserve
} from "../../src/oracles/ChainlinkUniV3PriceOracle.sol";

/// @dev Local simulation on a mainnet fork (read-only). Skipped unless FORK_URL is set.
contract PriceOracleFork is Test {
    function test_Fork_Prices() public {
        string memory url = vm.envOr("FORK_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url);
        // the live pool keeps 1 observation: simulate the one-time setup transaction and two
        // swaps 30 minutes apart so a TWAP exists (local fork only, nothing is sent)
        address pool = 0x894D4e6d3d2Abc64Fc0de0e4e2Ea63A93BC9c520;
        IPoolCardinality(pool).increaseObservationCardinalityNext(50);
        UniswapV3SwapAdapter a = new UniswapV3SwapAdapter(
            ISwapRouter02(0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45), 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
        );
        bytes memory path = abi.encodePacked(
            address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2),
            uint24(500),
            address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48),
            uint24(3000),
            address(0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7)
        );
        vm.deal(address(this), 1 ether);
        a.swapExactIn{value: 0.001 ether}(
            address(0), 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7, 0.001 ether, 1, block.timestamp, path, address(this)
        );
        vm.warp(block.timestamp + 1800);
        vm.roll(block.number + 150);
        a.swapExactIn{value: 0.001 ether}(
            address(0), 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7, 0.001 ether, 1, block.timestamp, path, address(this)
        );
        vm.warp(block.timestamp + 60);
        ChainlinkUniV3PriceOracle o = new ChainlinkUniV3PriceOracle(
            0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,
            0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7,
            IAggregatorV3(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419), // ETH/USD
            IAggregatorV3(0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6), // USDC/USD
            IUniswapV3PoolObserve(0x894D4e6d3d2Abc64Fc0de0e4e2Ea63A93BC9c520),
            1800,
            30 days, // the fork is warped forward; production: ~2h for ETH/USD (1h heartbeat)
            30 days, // production: ~26h for USDC/USD (24h heartbeat)
            // a live IMD-paired pool on mainnet stands in for YOLO/IMD: same factory, same pool key
            REF_TOKEN,
            0x000000000004444c5dc75cB358380D2e3dE08A90,
            0x784FF9a3ac5d88A30bfff6F7f2a270161FBE6000,
            12_500,
            60,
            1e18, // no cap that matters here
            0 // no floor: the stand-in pool's live price is already above zero
        );
        uint256 ethUsd = o.usdValue(address(0), 1e18);
        uint256 imdUsd = o.usdValue(0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7, 1e18);
        uint256 imdPerEth = o.imdValue(address(0), 1e18);
        uint256 imdFor300 = o.imdValue(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, 300e6);
        emit log_named_decimal_uint("ETH/USD", ethUsd, 18);
        emit log_named_decimal_uint("IMD/USD (30 min TWAP)", imdUsd, 18);
        emit log_named_decimal_uint("IMD per ETH", imdPerEth, 18);
        emit log_named_decimal_uint("IMD for 300 USDC", imdFor300, 18);
        assertGt(ethUsd, 500e18);
        assertGt(imdUsd, 0.5e18);
        assertLt(imdUsd, 100e18);

        // the pool sampler reads the v4 slot0 of a real factory pool: no price before MIN_SAMPLES samples
        assertFalse(o.hasPrice(REF_TOKEN));
        assertEq(o.usdValue(REF_TOKEN, 1e18), 0);
        for (uint256 i; i < o.MIN_SAMPLES(); ++i) {
            vm.prank(address(0x5EED), address(0x5EED)); // a plain EOA samples: a read ...
            assertFalse(o.sampleYoloPrice());
            vm.roll(vm.getBlockNumber() + 1);
            vm.prank(address(0x5EED), address(0x5EED)); // ... stored a block later, the pool unchanged (swarm #1)
            assertTrue(o.sampleYoloPrice());
            vm.prank(address(0x5EED), address(0x5EED));
            assertFalse(o.sampleYoloPrice(), "one sample per spacing");
            vm.warp(vm.getBlockTimestamp() + o.SAMPLE_SPACING());
        }
        assertTrue(o.hasPrice(REF_TOKEN));
        (, int24 tick) = o.lowestYoloTick();
        uint256 refUsd = o.usdValue(REF_TOKEN, 1e18);
        uint256 refImd = o.imdValue(REF_TOKEN, 1_000_000e18);
        emit log_named_int("REF_TOKEN tick (IMD per REF_TOKEN = 1.0001^tick)", tick);
        emit log_named_decimal_uint("REF_TOKEN/USD (highest sample x IMD TWAP)", refUsd, 18);
        emit log_named_decimal_uint("IMD for 1M REF_TOKEN", refImd, 18);
        assertGt(refUsd, 0);
        assertLt(refImd, 1_000_000e18);
        // two hours later without new samples the price is gone again
        vm.warp(vm.getBlockTimestamp() + o.WINDOW());
        assertFalse(o.hasPrice(REF_TOKEN));
    }

    address constant REF_TOKEN = 0x53d0eA0A685220718Dc6a0a6e4617194C6F37921;
}
