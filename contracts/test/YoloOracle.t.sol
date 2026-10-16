// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    ChainlinkUniV3PriceOracle,
    IAggregatorV3,
    IUniswapV3PoolObserve
} from "../src/oracles/ChainlinkUniV3PriceOracle.sol";
import {YoloPoolSamples} from "../src/oracles/YoloPoolSamples.sol";

/// @dev A v4 PoolManager that answers `extsload` for one pool's slot0.
contract MockPoolManager {
    mapping(bytes32 => bytes32) public slots;

    function setTick(bytes32 poolId, int24 tick) external {
        bytes32 slot = keccak256(abi.encodePacked(poolId, bytes32(uint256(6))));
        // sqrtPriceX96 only has to be nonzero here; the sampler reads the tick
        slots[slot] = bytes32((uint256(uint24(tick)) << 160) | (1 << 96));
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return slots[slot];
    }
}

/// @dev Chainlink feed with a fixed answer that is always fresh.
contract MockFeed {
    int256 public answer;

    constructor(int256 a) {
        answer = a;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}

/// @dev A Uniswap v3 USDC/IMD pool whose TWAP tick is constant: IMD = $8 means 0.125 IMD per USDC,
///      i.e. raw IMD per raw USDC = 1.25e11 = 1.0001^tick, tick = 255_529 (USDC token0).
contract MockV3Pool {
    int24 public tick = 255_529;

    function observe(uint32[] calldata ago) external view returns (int56[] memory cum, uint160[] memory) {
        cum = new int56[](2);
        cum[0] = 0;
        cum[1] = int56(tick) * int56(uint56(ago[0]));
        return (cum, new uint160[](2));
    }
}

/// @dev $YOLO's price from samples of its v4 pool: the highest of two hours, at
///      least five samples, capped in USD, never below the opening price.
contract YoloOracleTest is Test {
    address constant USDC = address(0x1000);
    address constant IMD = address(0x2000);
    address constant YOLO_LOW = address(0x0500); // below IMD: YOLO is currency0
    address constant YOLO_HIGH = address(0x3000); // above IMD: YOLO is currency1
    address constant HOOKS = address(0x784);
    uint256 constant MAX_USD = 0.01e18;
    // the opening price of the tests: 2,000 IMD for 1B (the honest samples at tick -128,999 are 2,500 IMD)
    uint256 constant FLOOR_IMD = 2e12;
    address constant KEEPER = address(0x5EED);

    MockPoolManager pm;
    ChainlinkUniV3PriceOracle oracle; // YOLO = currency0
    ChainlinkUniV3PriceOracle oracleHigh; // YOLO = currency1

    function setUp() public {
        vm.warp(1_800_000_000);
        pm = new MockPoolManager();
        oracle = _oracle(YOLO_LOW);
        oracleHigh = _oracle(YOLO_HIGH);
    }

    function _oracle(address yolo) internal returns (ChainlinkUniV3PriceOracle) {
        return new ChainlinkUniV3PriceOracle(
            USDC,
            IMD,
            IAggregatorV3(address(new MockFeed(2500e8))),
            IAggregatorV3(address(new MockFeed(1e8))),
            IUniswapV3PoolObserve(address(new MockV3Pool())),
            1800,
            2 hours,
            48 hours,
            yolo,
            address(pm),
            HOOKS,
            12_500,
            60,
            MAX_USD,
            FLOOR_IMD
        );
    }

    /// @dev a keeper (anyone can run one): a plain EOA that sends the call itself (tx.origin == msg.sender), twice:
    ///      it reads the pool in one block and stores the read in the next one, the pool unchanged in between (swarm audit #1)
    function _sample(ChainlinkUniV3PriceOracle o) internal returns (bool) {
        vm.prank(KEEPER, KEEPER);
        if (o.sampleYoloPrice()) return true;
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(KEEPER, KEEPER);
        return o.sampleYoloPrice();
    }

    function test_PoolIdIsTheFactoryKey() public view {
        assertEq(oracle.yoloPoolId(), keccak256(abi.encode(YOLO_LOW, IMD, uint24(12_500), int24(60), HOOKS)));
        assertEq(oracleHigh.yoloPoolId(), keccak256(abi.encode(IMD, YOLO_HIGH, uint24(12_500), int24(60), HOOKS)));
    }

    function test_NoPriceUntilFiveSamples() public {
        pm.setTick(oracle.yoloPoolId(), -128_999);
        for (uint256 i; i < 4; ++i) {
            assertTrue(_sample(oracle));
            assertFalse(oracle.hasPrice(YOLO_LOW));
            assertEq(oracle.usdValue(YOLO_LOW, 1_000_000e18), 0);
            assertEq(oracle.imdValue(YOLO_LOW, 1_000_000e18), 0);
            skip(15 minutes);
        }
        _sample(oracle);
        assertTrue(oracle.hasPrice(YOLO_LOW));
        // 1.0001^-128999 = 2.5e-6 IMD per YOLO (a 2,500 IMD valuation): 1M YOLO = 2.5 IMD = $20
        assertApproxEqRel(oracle.imdValue(YOLO_LOW, 1_000_000e18), 2.5e18, 0.001e18);
        assertApproxEqRel(oracle.usdValue(YOLO_LOW, 1_000_000e18), 20e18, 0.001e18);
    }

    function test_OneSamplePerSpacing() public {
        pm.setTick(oracle.yoloPoolId(), -128_999);
        assertTrue(_sample(oracle));
        skip(15 minutes - 1);
        assertFalse(_sample(oracle));
        assertEq(oracle.sampleCount(), 1);
        skip(1);
        assertTrue(_sample(oracle));
    }

    function test_UninitializedPoolStoresNothing() public {
        assertFalse(_sample(oracle));
        assertEq(oracle.sampleCount(), 0);
    }

    /// @dev The window keeps both ends: `lowestYoloTick` (a view for front-ends) and `highestYoloTick`, the price
    ///      (a depressed sample never lowers a reward's value, an inflated one only makes a submission dearer).
    function test_LowestAndHighestSampleOfTheWindow() public {
        bytes32 id = oracle.yoloPoolId();
        int24[6] memory ticks = [int24(-128_999), -110_000, -100_000, -128_000, -129_500, -90_000];
        for (uint256 i; i < ticks.length; ++i) {
            pm.setTick(id, ticks[i]);
            _sample(oracle);
            skip(15 minutes);
        }
        (bool ok, int24 lowest) = oracle.lowestYoloTick();
        assertTrue(ok);
        assertEq(lowest, -129_500);
        (bool okHigh, int24 highest) = oracle.highestYoloTick();
        assertTrue(okHigh);
        assertEq(highest, -90_000);
        // the price is the highest sample: 1.0001^-90000 = 1.234e-4 IMD per YOLO, 1M YOLO = 123.4 IMD
        assertApproxEqRel(oracle.imdValue(YOLO_LOW, 1_000_000e18), 123.4e18, 0.001e18);
        // the low sample is gone once eight newer ones replaced it
        for (uint256 i; i < 8; ++i) {
            pm.setTick(id, -100_000);
            _sample(oracle);
            skip(15 minutes);
        }
        (ok, lowest) = oracle.lowestYoloTick();
        assertTrue(ok);
        assertEq(lowest, -100_000);
        (, highest) = oracle.highestYoloTick();
        assertEq(highest, -100_000, "and so is the high one");
    }

    function test_SamplesGoStaleWithoutKeeper() public {
        pm.setTick(oracle.yoloPoolId(), -128_999);
        for (uint256 i; i < 6; ++i) {
            _sample(oracle);
            skip(15 minutes);
        }
        assertTrue(oracle.hasPrice(YOLO_LOW));
        skip(60 minutes); // the 2 oldest of 6 fall out of the two hours: 4 left
        assertFalse(oracle.hasPrice(YOLO_LOW));
        assertEq(oracle.usdValue(YOLO_LOW, 1e24), 0);
    }

    function test_TokenOrderMirrorsTheTick() public {
        // YOLO as currency1: the pool tick is IMD-per-YOLO inverted
        pm.setTick(oracleHigh.yoloPoolId(), 128_999);
        for (uint256 i; i < 5; ++i) {
            _sample(oracleHigh);
            skip(15 minutes);
        }
        (, int24 lowest) = oracleHigh.lowestYoloTick();
        assertEq(lowest, -128_999);
        (, int24 highest) = oracleHigh.highestYoloTick();
        assertEq(highest, -128_999);
        assertApproxEqRel(oracleHigh.imdValue(YOLO_HIGH, 1_000_000e18), 2.5e18, 0.001e18);
    }

    function test_UsdCap() public {
        // 1 YOLO = 1 IMD = $8 >> the $0.01 cap
        pm.setTick(oracle.yoloPoolId(), 0);
        for (uint256 i; i < 5; ++i) {
            _sample(oracle);
            skip(15 minutes);
        }
        assertEq(oracle.usdValue(YOLO_LOW, 1_000e18), 1_000 * MAX_USD);
        assertApproxEqRel(oracle.imdValue(YOLO_LOW, 1_000e18), 1_000 * MAX_USD / 8, 0.001e18);
        // beyond the tick range of the power function the cap still answers, and a dead token is worth nothing
        pm.setTick(oracle.yoloPoolId(), 600_000);
        skip(3 hours);
        for (uint256 i; i < 5; ++i) {
            _sample(oracle);
            skip(15 minutes);
        }
        assertEq(oracle.usdValue(YOLO_LOW, 1e18), MAX_USD);
        pm.setTick(oracle.yoloPoolId(), -600_000);
        skip(3 hours);
        for (uint256 i; i < 5; ++i) {
            _sample(oracle);
            skip(15 minutes);
        }
        assertTrue(oracle.hasPrice(YOLO_LOW));
        // below the opening price the factory's pool has no liquidity: the floor, 1M YOLO = 2 IMD = $16
        assertApproxEqRel(oracle.usdValue(YOLO_LOW, 1e24), 16e18, 0.001e18);
    }

    /// @dev One crashed sample among honest ones changes nothing (the highest
    ///      sample counts; the floor of the opening price is checked in test_UsdCap), and a contract can't sample
    ///      between two swaps of one transaction.
    function test_CrashedSampleChangesNothing() public {
        bytes32 id = oracle.yoloPoolId();
        pm.setTick(id, -887_220); // swapped down to the bottom of the range
        _sample(oracle);
        skip(15 minutes);
        pm.setTick(id, -128_999);
        for (uint256 i; i < 4; ++i) {
            _sample(oracle);
            skip(15 minutes);
        }
        assertTrue(oracle.hasPrice(YOLO_LOW));
        assertApproxEqRel(oracle.imdValue(YOLO_LOW, 1_000_000e18), 2.5e18, 0.001e18, "the honest price, not the floor");
        (, int24 lowest) = oracle.lowestYoloTick();
        assertEq(lowest, -887_220, "the crashed sample is still in the window");
        vm.expectRevert(YoloPoolSamples.SamplerNotEoa.selector); // a contract (this test) calling directly
        oracle.sampleYoloPrice();
        address delegated = address(0x7702);
        vm.etch(delegated, hex"ef0100000000000000000000000000000000000000beef"); // an EIP-7702 delegated account
        vm.prank(delegated, delegated);
        vm.expectRevert(YoloPoolSamples.SamplerNotEoa.selector);
        oracle.sampleYoloPrice();
    }

    function test_UnpricedYoloNeedsNoImdPrice() public {
        vm.mockCallRevert(
            address(oracle.usdcImdPool()), abi.encodeWithSelector(IUniswapV3PoolObserve.observe.selector), "OLD"
        );
        assertEq(oracle.imdValue(YOLO_LOW, 1e24), 0, "no samples: 0 without reading the TWAP");
    }

    function test_OtherTokensUnchanged() public view {
        assertTrue(oracle.hasPrice(address(0)));
        assertTrue(oracle.hasPrice(USDC));
        assertTrue(oracle.hasPrice(IMD));
        assertFalse(oracle.hasPrice(address(0xBEEF)));
        assertEq(oracle.usdValue(address(0), 1e18), 2500e18);
        assertApproxEqRel(oracle.usdValue(IMD, 1e18), 8e18, 0.001e18);
    }
}
