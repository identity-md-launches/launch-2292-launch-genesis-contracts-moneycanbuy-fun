// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice The two reads of the Uniswap v4 PoolManager this needs (`extsload` of a pool's slot0).
interface IPoolManagerExtsload {
    function extsload(bytes32 slot) external view returns (bytes32 value);
}

/// @title YoloPoolSamples
/// @notice An IMD price of $YOLO from its Uniswap v4 YOLO/IMD pool. A v4 pool keeps no price history (the launch
///         factory's pool hook, PoolInitializationGuard, records none), so anyone may store a sample of the pool's
///         tick at most once per `SAMPLE_SPACING`; the last `SAMPLES` of them are kept.
///         A sample takes two calls in two different blocks (swarm audit #1): the first reads the pool (its
///         slot0 and both fee growth counters) and keeps the read pending; a later call in a LATER block stores the
///         pending tick only if the pool is exactly as it was read: same slot0, same fee growth. Every swap with
///         liquidity in range raises a fee growth counter (the pool's LP fee is 1.25% and never 0) and fee growth
///         never goes down, so any swap after the read, the swap back of a same-block sandwich included, voids it
///         (the next call reads afresh). A stored price was therefore held from the read to the end of its block and
///         into a later one with no trade in between: a manipulator has to carry the moved price across a block
///         boundary, open to every arbitrageur, instead of moving it and back inside one block for two LP fees.
///         What this does not stop: a price held across the block boundary (whoever holds it carries the inventory
///         and loses it to arbitrage), and moves through a range with no liquidity, which cost nothing and leave no
///         fee growth (below the opening price there is none, but the floor below bounds such a sample).
///         The price is the HIGHEST sample of the last `WINDOW` and exists only with
///         at least `MIN_SAMPLES` there. The price values rewards for the large threshold and the Bond, so a sample
///         pushed DOWN never lowers the value of a reward (the other samples of the window still count); one pushed
///         UP, and held across a block, makes a submission dearer (bigger Bond, mandatory swarm check) and lowers
///         YOLO amounts priced in USD (the sweetener's cap, never below 30,000 YOLO at the $0.01 cap; the trophy
///         price) for up to `WINDOW`. The USD value is capped (`yoloMaxUsd`) and never below the pool's opening
///         price (ChainlinkUniV3PriceOracle `yoloFloorImd`). Only a plain EOA may sample, so no contract can read and
///         confirm in one transaction. Without enough samples there is no price: a $YOLO task then counts as large
///         (`Desk._priceYolo`). `lowestYoloTick` stays as a view for the site.
///         The pool key is fixed at construction: YOLO/IMD, `fee`, `tickSpacing`, `hooks` as the factory opened it.
abstract contract YoloPoolSamples {
    uint256 public constant SAMPLES = 8;
    uint256 public constant MIN_SAMPLES = 5;
    uint256 public constant SAMPLE_SPACING = 15 minutes;
    uint256 public constant WINDOW = 2 hours;
    /// @dev v4 PoolManager storage: `mapping(PoolId => Pool.State) _pools` at slot 6, slot0 first in Pool.State
    bytes32 private constant POOLS_SLOT = bytes32(uint256(6));

    struct Sample {
        uint64 time;
        int24 yoloTick; // IMD per YOLO = 1.0001^yoloTick (both tokens have 18 decimals)
    }

    address public immutable yolo;
    IPoolManagerExtsload public immutable poolManager;
    bytes32 public immutable yoloPoolId;
    bool private immutable _yoloIsToken0;

    /// @notice A read of the pool waiting to be confirmed in a later block (`blockNumber` 0 = none).
    struct PendingRead {
        uint64 blockNumber;
        int24 yoloTick;
        bytes32 poolState; // keccak256(slot0, feeGrowthGlobal0X128, feeGrowthGlobal1X128) at the read
    }

    Sample[SAMPLES] public samples;
    uint256 public sampleCount; // samples ever stored; the next one goes to sampleCount % SAMPLES
    PendingRead public pendingRead;

    event YoloPriceSampled(int24 yoloTick, uint64 time);
    /// @notice A read of the pool kept for confirmation: a call in a later block stores it if the pool is unchanged.
    event YoloPriceRead(int24 yoloTick, uint64 blockNumber);

    error SamplerNotEoa();

    constructor(address yolo_, address imd_, address poolManager_, address hooks_, uint24 fee_, int24 tickSpacing_) {
        yolo = yolo_;
        poolManager = IPoolManagerExtsload(poolManager_);
        _yoloIsToken0 = yolo_ < imd_;
        (address c0, address c1) = _yoloIsToken0 ? (yolo_, imd_) : (imd_, yolo_);
        yoloPoolId = keccak256(abi.encode(c0, c1, fee_, tickSpacing_, hooks_));
    }

    /// @notice One step of a sample, if the last stored sample is at least SAMPLE_SPACING old and the pool is open:
    ///         stores the pending read when it was made in an earlier block and the pool's slot0 and fee growth are
    ///         still exactly as read (returns true); otherwise reads the pool now and keeps that read pending
    ///         (returns false). A keeper therefore calls twice, in two blocks (anyone may run one on a timer).
    ///         Any plain EOA may call; a contract or an EIP-7702 delegated account may not.
    function sampleYoloPrice() external returns (bool stored) {
        if (msg.sender != tx.origin || msg.sender.code.length != 0) revert SamplerNotEoa();
        (uint8 step, int24 yoloTick, bytes32 state) = _step();
        if (step == 0) return false; // too early, or the pool is not open yet
        uint256 n = sampleCount;
        if (step == 2) {
            int24 tick = pendingRead.yoloTick;
            delete pendingRead;
            samples[n % SAMPLES] = Sample(uint64(block.timestamp), tick);
            sampleCount = n + 1;
            emit YoloPriceSampled(tick, uint64(block.timestamp));
            return true;
        }
        pendingRead = PendingRead(uint64(block.number), yoloTick, state);
        emit YoloPriceRead(yoloTick, uint64(block.number));
        return false;
    }

    /// @notice What `sampleYoloPrice` would do now: 0 nothing (the last sample is younger than SAMPLE_SPACING, or the
    ///         pool is not open), 1 read the pool (a call in a later block then stores it if no swap came between),
    ///         2 store the pending read.
    function sampleStep() external view returns (uint8 step) {
        (step,,) = _step();
    }

    function _step() private view returns (uint8 step, int24 yoloTick, bytes32 state) {
        uint256 n = sampleCount;
        if (n != 0 && block.timestamp < samples[(n - 1) % SAMPLES].time + SAMPLE_SPACING) return (0, 0, 0);
        bool open;
        (open, yoloTick, state) = _readPool();
        if (!open) return (0, 0, 0);
        PendingRead memory p = pendingRead;
        step = p.blockNumber != 0 && p.blockNumber < block.number && p.poolState == state ? 2 : 1;
    }

    /// @dev The pool's tick (as YOLO's) and a digest of everything a swap changes: slot0 (price, tick, fees) and both
    ///      fee growth counters (Pool.State: slot0, feeGrowthGlobal0X128, feeGrowthGlobal1X128, liquidity, ...).
    function _readPool() private view returns (bool open, int24 yoloTick, bytes32 state) {
        bytes32 base = keccak256(abi.encodePacked(yoloPoolId, POOLS_SLOT));
        bytes32 slot0 = poolManager.extsload(base);
        if (uint160(uint256(slot0)) == 0) return (false, 0, 0);
        bytes32 fee0 = poolManager.extsload(bytes32(uint256(base) + 1));
        bytes32 fee1 = poolManager.extsload(bytes32(uint256(base) + 2));
        int24 tick = int24(int256(uint256(slot0) >> 160));
        return (true, _yoloIsToken0 ? tick : -tick, keccak256(abi.encode(slot0, fee0, fee1)));
    }

    /// @notice The lowest sampled tick of the last WINDOW; `ok` false with fewer than MIN_SAMPLES samples there.
    function lowestYoloTick() public view returns (bool ok, int24 lowest) {
        (ok, lowest,) = _windowTicks();
    }

    /// @notice The highest sampled tick of the last WINDOW (the price the oracle uses); `ok` false with fewer than
    ///         MIN_SAMPLES samples there.
    function highestYoloTick() public view returns (bool ok, int24 highest) {
        (ok,, highest) = _windowTicks();
    }

    function _windowTicks() private view returns (bool ok, int24 lowest, int24 highest) {
        uint256 n = sampleCount;
        uint256 found;
        lowest = type(int24).max;
        highest = type(int24).min;
        for (uint256 i; i < SAMPLES && i < n; ++i) {
            Sample memory s = samples[(n - 1 - i) % SAMPLES];
            if (s.time + WINDOW < block.timestamp) break; // newest first: the rest are older
            ++found;
            if (s.yoloTick < lowest) lowest = s.yoloTick;
            if (s.yoloTick > highest) highest = s.yoloTick;
        }
        ok = found >= MIN_SAMPLES;
    }
}
