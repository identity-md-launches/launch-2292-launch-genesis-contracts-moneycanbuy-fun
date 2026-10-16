// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {YoloPoolSamples} from "./YoloPoolSamples.sol";

interface IAggregatorV3 {
    function latestRoundData() external view returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80);
    function decimals() external view returns (uint8);
}

interface IUniswapV3PoolObserve {
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

/// @title ChainlinkUniV3PriceOracle
/// @notice Price source. It never sets a task reward: it sizes bonds, the "large task" threshold and the minimum
///         reward, converts ETH to IMD for the relayer shortfall, and sets YoloSweetener's cap and the trophy price:
///         ETH/USD and USDC/USD from Chainlink (staleness-checked), IMD from the time-weighted average tick of the
///         Uniswap v3 USDC/IMD pool (mainnet 0x894D4e6d3d2Abc64Fc0de0e4e2Ea63A93BC9c520, token0 = USDC,
///         token1 = IMD). A TWAP costs a manipulator the whole window, unlike the spot price.
///         Production notes: the deep IMD liquidity is on Uniswap v4 (no TWAP oracle there by default); the v3 pool
///         (~$340k) is the only on-chain IMD TWAP found. The window and the staleness limit are constructor args.
///         $YOLO (the project token, a reward currency): the highest sample of its v4 YOLO/IMD pool over two hours
///         (YoloPoolSamples: a depressed sample never lowers a reward's value; each sample is read
///         in one block and stored in a later one only if no swap happened in between), never below the
///         pool's opening price `yoloFloorImd`, times the IMD price, never above `yoloMaxUsd` per whole token; 0 while
///         there are too few samples (`hasPrice(yolo)` false).
contract ChainlinkUniV3PriceOracle is IPriceOracle, YoloPoolSamples {
    address public immutable usdc;
    address public immutable imd;
    IAggregatorV3 public immutable ethUsd;
    IAggregatorV3 public immutable usdcUsd;
    IUniswapV3PoolObserve public immutable usdcImdPool;
    bool public immutable usdcIsToken0;
    uint32 public immutable twapWindow;
    uint256 public immutable ethMaxStaleness; // ETH/USD heartbeat 1h
    uint256 public immutable usdcMaxStaleness; // USDC/USD heartbeat 24h
    uint256 public immutable yoloMaxUsd; // 18 decimals per whole YOLO: the highest value ever given to it
    /// @notice IMD wei per whole YOLO at the pool's opening price: the factory seeds the pool single-sided above it,
    ///         so there is no liquidity below it and a sample there means nothing (or a manipulation)
    uint256 public immutable yoloFloorImd;

    error StalePrice();
    error BadPrice();
    error UnknownToken();

    constructor(
        address usdc_,
        address imd_,
        IAggregatorV3 ethUsd_,
        IAggregatorV3 usdcUsd_,
        IUniswapV3PoolObserve pool_,
        uint32 twapWindow_,
        uint256 ethMaxStaleness_,
        uint256 usdcMaxStaleness_,
        address yolo_,
        address poolManager_,
        address yoloHooks_,
        uint24 yoloFee_,
        int24 yoloTickSpacing_,
        uint256 yoloMaxUsd_,
        uint256 yoloFloorImd_
    ) YoloPoolSamples(yolo_, imd_, poolManager_, yoloHooks_, yoloFee_, yoloTickSpacing_) {
        usdc = usdc_;
        imd = imd_;
        ethUsd = ethUsd_;
        usdcUsd = usdcUsd_;
        usdcImdPool = pool_;
        usdcIsToken0 = usdc_ < imd_;
        twapWindow = twapWindow_;
        ethMaxStaleness = ethMaxStaleness_;
        usdcMaxStaleness = usdcMaxStaleness_;
        yoloMaxUsd = yoloMaxUsd_;
        yoloFloorImd = yoloFloorImd_;
    }

    /// @inheritdoc IPriceOracle
    function usdValue(address token, uint256 amount) public view returns (uint256) {
        if (token == address(0)) return amount * _chainlink(ethUsd) / 1e18;
        if (token == usdc) return amount * _chainlink(usdcUsd) / 1e6;
        if (token == imd) return _imdToUsd(amount);
        if (token == yolo) return _yoloUsd(amount);
        revert UnknownToken();
    }

    /// @inheritdoc IPriceOracle
    function hasPrice(address token) external view returns (bool) {
        if (token == yolo) {
            (bool ok,) = highestYoloTick();
            return ok;
        }
        return token == address(0) || token == usdc || token == imd;
    }

    /// @inheritdoc IPriceOracle
    function imdValue(address token, uint256 amount) external view returns (uint256) {
        if (token == imd) return amount;
        uint256 usd = usdValue(token, amount); // 18 decimals
        if (usd == 0) return 0; // an unpriced $YOLO needs no IMD or USDC price
        // USD -> USDC units (6 decimals) -> IMD
        uint256 usdcUnits = usd * 1e6 / _chainlink(usdcUsd);
        return usdcUnits * imdWeiPerUsdc() / 1e6;
    }

    /// @dev via USDC units
    function _imdToUsd(uint256 amount) internal view returns (uint256) {
        return (amount * 1e6 / imdWeiPerUsdc()) * _chainlink(usdcUsd) / 1e6;
    }

    /// @dev The highest sampled IMD value of `amount` YOLO, at least the opening price, in USD, capped at yoloMaxUsd
    ///      per token; 0 without a price. Above tick +2^19 the cap applies anyway; below -2^19 the floor does.
    function _yoloUsd(uint256 amount) internal view returns (uint256 usd) {
        (bool ok, int24 tick) = highestYoloTick();
        if (!ok) return 0;
        uint256 cap = amount * yoloMaxUsd / 1e18;
        int24 bound = int24(1 << 19);
        if (tick >= bound) return cap;
        uint256 imdPerYolo = tick <= -bound ? 0 : _pow10001(tick);
        if (imdPerYolo < yoloFloorImd) imdPerYolo = yoloFloorImd;
        usd = _imdToUsd(amount * imdPerYolo / 1e18);
        if (usd > cap) usd = cap;
    }

    /// @notice IMD wei per 1 USDC (1e6 units), from the TWAP tick: price(token1/token0) = 1.0001^tick.
    function imdWeiPerUsdc() public view returns (uint256) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = twapWindow;
        (int56[] memory cum,) = usdcImdPool.observe(ago);
        int56 delta = cum[1] - cum[0];
        int24 tick = int24(delta / int56(uint56(twapWindow)));
        if (delta < 0 && (delta % int56(uint56(twapWindow)) != 0)) tick--; // round toward negative infinity
        if (!usdcIsToken0) tick = -tick;
        // raw IMD per raw USDC = 1.0001^tick (1e18 fixed point); per 1 USDC = x 1e6
        return _pow10001(tick) * 1e6 / 1e18;
    }

    /// @dev 1.0001^tick in 1e18 fixed point by binary exponentiation, ~1e-12 relative error (review test against an
    ///      80-digit reference). Valid for |tick| < 2^19: beyond that the 1e27 intermediates overflow uint256, so the
    ///      range is checked here and an out-of-range price reverts with BadPrice instead of a panic. For the USDC/IMD
    ///      pool the tick is ~ +256 000 (IMD ~ $7.6); 2^19 means IMD below ~$1e-11, never a real price.
    function _pow10001(int24 tick) internal pure returns (uint256) {
        uint256 n = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        if (n >= 1 << 19) revert BadPrice();
        uint256 base = 1.0001e27; // 1e27 precision while multiplying
        uint256 r = 1e27;
        while (n != 0) {
            if (n & 1 == 1) r = r * base / 1e27;
            base = base * base / 1e27;
            n >>= 1;
        }
        return tick < 0 ? 1e45 / r : r / 1e9;
    }

    /// @return 18-decimal USD price per whole token
    function _chainlink(IAggregatorV3 feed) internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0) revert BadPrice();
        if (block.timestamp - updatedAt > (feed == ethUsd ? ethMaxStaleness : usdcMaxStaleness)) revert StalePrice();
        return uint256(answer) * 10 ** (18 - feed.decimals());
    }
}
