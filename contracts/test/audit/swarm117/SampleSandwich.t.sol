// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Swarm audit of this repository at d9a1ee5, finding #1: the report's PoC. Both tests failed on d9a1ee5 ("a
// sandwiched sample became the price: -66400 != -111000"). Changed for the fix only where a sample is taken: a sample
// is now a read in one block and its store in a later block (`_honestSample`), and the attacker's sandwiched call
// returns false (a read that the swap back voids) instead of true. The assertions are the report's.

import {Test} from "forge-std/Test.sol";
import {ChainlinkUniV3PriceOracle, IAggregatorV3, IUniswapV3PoolObserve} from "src/oracles/ChainlinkUniV3PriceOracle.sol";

/// @dev A v4 PoolManager that answers `extsload` for one pool's slot0 (sqrtPriceX96 | tick << 160).
contract ScratchPoolManager {
    mapping(bytes32 => bytes32) private _slots;

    function setTick(bytes32 poolId, int24 tick) external {
        bytes32 slot = keccak256(abi.encodePacked(poolId, bytes32(uint256(6))));
        uint256 packed = uint256(uint24(tick)) << 160 | 1; // sqrtPriceX96 = 1 (initialized), tick
        _slots[slot] = bytes32(packed);
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return _slots[slot];
    }
}

/// @dev Like ScratchPoolManager, but a swap also raises the pool's fee growth (slot0 + 1), as a v4 swap with liquidity
///      in range does: a swap and its exact swap back leave slot0 as it was, never the fee growth.
contract FeeGrowthPoolManager {
    mapping(bytes32 => bytes32) private _slots;

    function swapTo(bytes32 poolId, int24 tick) external {
        bytes32 slot = keccak256(abi.encodePacked(poolId, bytes32(uint256(6))));
        _slots[slot] = bytes32(uint256(uint24(tick)) << 160 | 1);
        bytes32 fee0 = bytes32(uint256(slot) + 1);
        _slots[fee0] = bytes32(uint256(_slots[fee0]) + 1e30);
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return _slots[slot];
    }
}

/// @dev YoloPoolSamples: "Only a plain EOA may sample, so no contract can swap the pool, sample and swap back inside one
///      transaction". Three transactions of one EOA in one block (nonce order, or a bundle) do exactly that: swap up,
///      sample, swap back. The highest sample of 2 h is the price, so one sandwiched sample is the YOLO price for the
///      next two hours: with the launch values (opening 1.5e-5 IMD per YOLO, cap $0.01) up to 87x. Expected: a sample
///      the pool does not hold past the block is not the price. Actual: it is, for 2 hours.
contract SampleSandwichTest is Test {
    address constant KEEPER = address(0xBEEF);
    address constant ATTACKER = address(0xBAD);
    int24 constant OPENING_TICK = -111_000; // ~1.5e-5 IMD per YOLO (1.0001^-111000)
    int24 constant INFLATED_TICK = -66_400; // ~87x the opening price (the $0.01 cap)
    uint256 constant T0 = 1_000_000;

    ScratchPoolManager pm;
    ChainlinkUniV3PriceOracle oracle;

    function setUp() public {
        pm = new ScratchPoolManager();
        address yolo = address(0x1001);
        address imd = address(0x2002);
        oracle = new ChainlinkUniV3PriceOracle(
            address(0x3003),
            imd,
            IAggregatorV3(address(0x4004)),
            IAggregatorV3(address(0x5005)),
            IUniswapV3PoolObserve(address(0x6006)),
            30 minutes,
            2 hours,
            48 hours,
            yolo,
            address(pm),
            address(0x7007),
            12_500,
            60,
            0.01e18,
            15_000e18 * 1e18 / 1_000_000_000e18
        );
        pm.setTick(oracle.yoloPoolId(), OPENING_TICK);
        // an honest keeper: five samples, 15 minutes apart (explicit times: via-IR may merge block.timestamp reads)
        for (uint256 i; i < 5; ++i) {
            vm.warp(T0 + i * 15 minutes);
            _honestSample();
        }
        vm.warp(T0 + 5 * 15 minutes);
        (bool ok, int24 highest) = oracle.highestYoloTick();
        assertTrue(ok);
        assertEq(highest, OPENING_TICK);
    }

    /// @dev the keeper's sample since the fix: a read, then the store in the next block
    function _honestSample() internal {
        vm.prank(KEEPER, KEEPER);
        assertFalse(oracle.sampleYoloPrice());
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(KEEPER, KEEPER);
        assertTrue(oracle.sampleYoloPrice());
    }

    function test_sampleSandwichedInOneBlockIsThePriceForTwoHours() public {
        // one block, three transactions of the attacker's EOA (nonce order or a bundle):
        pm.setTick(oracle.yoloPoolId(), INFLATED_TICK); // 1. swap IMD -> YOLO, tick up
        vm.prank(ATTACKER, ATTACKER);
        assertFalse(oracle.sampleYoloPrice()); // 2. sample (plain EOA: allowed): only a read now
        pm.setTick(oracle.yoloPoolId(), OPENING_TICK); // 3. swap back: the pool is where it was

        (bool ok, int24 highest) = oracle.highestYoloTick();
        assertTrue(ok);
        // the pool never held the inflated price past this block: the price must still be the opening tick
        assertEq(highest, OPENING_TICK, "a sandwiched sample became the price");

        // the next block: the read does not match the pool any more, so nothing is stored from it
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(ATTACKER, ATTACKER);
        assertFalse(oracle.sampleYoloPrice(), "the voided read is not stored");
        (, highest) = oracle.highestYoloTick();
        assertEq(highest, OPENING_TICK);
    }

    function test_sandwichedSampleOutlivesHonestSamples() public {
        pm.setTick(oracle.yoloPoolId(), INFLATED_TICK);
        vm.prank(ATTACKER, ATTACKER);
        oracle.sampleYoloPrice();
        pm.setTick(oracle.yoloPoolId(), OPENING_TICK);
        // honest keeper keeps sampling the real price for 1h45
        for (uint256 i = 6; i < 13; ++i) {
            vm.warp(T0 + i * 15 minutes);
            _honestSample();
        }
        (, int24 highest) = oracle.highestYoloTick();
        assertEq(highest, OPENING_TICK, "inflated sample still the price after 1h45 of honest samples");
    }
}

/// @dev Beyond the report: the attacker sandwiches the read in one block AND the store in the next one (swap up to the
///      very same slot0 before each call, swap back after). The fee growth of the swaps in between voids the read.
contract DoubleSandwichTest is Test {
    address constant KEEPER = address(0xBEEF);
    address constant ATTACKER = address(0xBAD);
    int24 constant OPENING_TICK = -111_000;
    int24 constant INFLATED_TICK = -66_400;

    FeeGrowthPoolManager pm;
    ChainlinkUniV3PriceOracle oracle;
    bytes32 id;

    function setUp() public {
        vm.warp(1_000_000);
        pm = new FeeGrowthPoolManager();
        oracle = new ChainlinkUniV3PriceOracle(
            address(0x3003),
            address(0x2002),
            IAggregatorV3(address(0x4004)),
            IAggregatorV3(address(0x5005)),
            IUniswapV3PoolObserve(address(0x6006)),
            30 minutes,
            2 hours,
            48 hours,
            address(0x1001),
            address(pm),
            address(0x7007),
            12_500,
            60,
            0.01e18,
            15_000e18 * 1e18 / 1_000_000_000e18
        );
        id = oracle.yoloPoolId();
        pm.swapTo(id, OPENING_TICK);
    }

    function _call(address who) internal returns (bool) {
        vm.prank(who, who);
        return oracle.sampleYoloPrice();
    }

    function test_readAndStoreBothSandwichedStoreNothing() public {
        for (uint256 i; i < 8; ++i) {
            // block N: swap up, read, swap back
            pm.swapTo(id, INFLATED_TICK);
            assertFalse(_call(ATTACKER));
            pm.swapTo(id, OPENING_TICK);
            vm.roll(vm.getBlockNumber() + 1);
            // block N+1: swap up to the same slot0, try to store, swap back
            pm.swapTo(id, INFLATED_TICK);
            assertFalse(_call(ATTACKER), "fee growth moved since the read: not stored");
            pm.swapTo(id, OPENING_TICK);
            vm.roll(vm.getBlockNumber() + 1);
            vm.warp(vm.getBlockTimestamp() + 15 minutes);
        }
        assertEq(oracle.sampleCount(), 0, "no inflated sample was ever stored");
        (bool ok,) = oracle.highestYoloTick();
        assertFalse(ok, "no price: a YOLO task counts as large, the safe side");
    }

    function test_anySwapBetweenReadAndStoreVoidsTheRead() public {
        assertFalse(_call(KEEPER)); // read at the opening price
        vm.roll(vm.getBlockNumber() + 1);
        pm.swapTo(id, OPENING_TICK); // a trade that ends at the same tick still moved the fee growth
        assertFalse(_call(KEEPER), "read again, not stored");
        vm.roll(vm.getBlockNumber() + 1);
        assertTrue(_call(KEEPER), "a quiet block later: stored");
        assertEq(oracle.sampleCount(), 1);
    }

    function test_readAndStoreInOneBlockStoreNothing() public {
        assertFalse(_call(KEEPER));
        assertFalse(_call(KEEPER), "same block: a fresh read, never a store");
        assertEq(oracle.sampleCount(), 0);
    }

    function test_sampleStepTellsWhatACallDoes() public {
        assertEq(oracle.sampleStep(), 1, "a call now reads");
        _call(KEEPER);
        assertEq(oracle.sampleStep(), 1, "same block: another read");
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(oracle.sampleStep(), 2, "next block, pool unchanged: a call stores");
        assertTrue(_call(KEEPER));
        assertEq(oracle.sampleStep(), 0, "then nothing until the spacing passed");
        vm.warp(vm.getBlockTimestamp() + 15 minutes);
        assertEq(oracle.sampleStep(), 1);
    }

    function test_priceHeldAcrossTheBlockCounts() public {
        // documented limit: a price actually held across the block boundary (the holder carries the inventory and
        // the arbitrage risk) is a sample like any other
        pm.swapTo(id, INFLATED_TICK);
        assertFalse(_call(ATTACKER));
        vm.roll(vm.getBlockNumber() + 1);
        assertTrue(_call(KEEPER));
        assertEq(oracle.sampleCount(), 1);
        (, int24 stored) = oracle.samples(0);
        assertEq(stored, INFLATED_TICK);
        (bool ok,) = oracle.highestYoloTick();
        assertFalse(ok, "and it still needs four more to be a price");
    }
}
