// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ETH} from "./VaultTypes.sol";

/// @title DevPrices
/// @notice Every price the protocol needs is a parameter the owner (dev) sets by hand, no oracle of any kind.
///         ETH is a price parameter too, so a swap's gas cost is never charged to users as a separate ETH payment.
///         Prices never decide who is paid: they only size the stake bonus's power-vs-reward comparison (CaseDesk,
///         at the submission).
///         - `yoloPriceUsd`: USD per one whole $YOLO (18 decimals), set directly as a token price (the launch price).
///         - `ethUsd`, `imdUsd`: USD per whole token (18 decimals).
///         - The owner changes each price with one transaction (an event the site shows). Zero is refused, and so is
///           an obvious typo: one call moves a price at most MAX_STEP times up or down (the
///           contract refuses an obviously wrong value); a real move further than that takes several calls.
///         - USDC is fixed at exactly $1 (`USDC_USD`), never a parameter: a depeg is the owner's problem to fix by
///           other means, not a price this contract would misreport.
///         A price is always set after deployment (constructor requires non-zero), so `hasPrice` is always true:
///         money is never blocked by a missing price. Stale or wrong
///         because the owner has not updated it is a known, accepted risk: it moves the stake bonus, never a payout.
contract DevPrices is Ownable2Step {
    uint256 public constant USDC_USD = 1e18;
    /// @notice One setter call moves a price at most this many times up or down (a typo guard, not a market rule).
    uint256 public constant MAX_STEP = 10;

    address public immutable usdc;
    address public immutable imd;
    address public immutable yolo;

    uint256 public yoloPriceUsd;
    uint256 public ethUsd;
    uint256 public imdUsd;

    event YoloPriceUsdSet(uint256 usd18);
    event EthUsdSet(uint256 usd18);
    event ImdUsdSet(uint256 usd18);

    error ZeroAddress();
    error ZeroPrice();
    /// @notice A new price more than MAX_STEP times above or below the current one (an obvious typo).
    error PriceSanity();
    error UnknownToken();

    constructor(
        address owner_,
        address usdc_,
        address imd_,
        address yolo_,
        uint256 yoloPriceUsd_,
        uint256 ethUsd_,
        uint256 imdUsd_
    ) Ownable(owner_) {
        if (usdc_ == address(0) || imd_ == address(0) || yolo_ == address(0)) revert ZeroAddress();
        if (yoloPriceUsd_ == 0 || ethUsd_ == 0 || imdUsd_ == 0) revert ZeroPrice();
        usdc = usdc_;
        imd = imd_;
        yolo = yolo_;
        yoloPriceUsd = yoloPriceUsd_;
        ethUsd = ethUsd_;
        imdUsd = imdUsd_;
        emit YoloPriceUsdSet(yoloPriceUsd_);
        emit EthUsdSet(ethUsd_);
        emit ImdUsdSet(imdUsd_);
    }

    /// @notice Owner sets the price of one $YOLO in USD (18 decimals).
    function setYoloPriceUsd(uint256 usd18) external onlyOwner {
        _check(yoloPriceUsd, usd18);
        yoloPriceUsd = usd18;
        emit YoloPriceUsdSet(usd18);
    }

    function setEthUsd(uint256 usd18) external onlyOwner {
        _check(ethUsd, usd18);
        ethUsd = usd18;
        emit EthUsdSet(usd18);
    }

    function setImdUsd(uint256 usd18) external onlyOwner {
        _check(imdUsd, usd18);
        imdUsd = usd18;
        emit ImdUsdSet(usd18);
    }

    /// @dev Not zero, and within MAX_STEP times the current price either way (both bounds inclusive).
    function _check(uint256 current, uint256 next) private pure {
        if (next == 0) revert ZeroPrice();
        if (next > current * MAX_STEP || next * MAX_STEP < current) revert PriceSanity();
    }

    /// @return usd18 price per whole token (18 decimals), 0 for an unknown token.
    function priceOf(address token) public view returns (uint256 usd18) {
        if (token == ETH) return ethUsd;
        if (token == usdc) return USDC_USD;
        if (token == imd) return imdUsd;
        if (token == yolo) return yoloPriceUsd;
        return 0;
    }

    /// @notice True for every known token (ETH, USDC, IMD, $YOLO): each has a dev-set price.
    function hasPrice(address token) external view returns (bool) {
        return token == ETH || token == usdc || token == imd || token == yolo;
    }

    /// @return usd18 value of `amount` of `token` (18-decimal tokens, except 6-decimal USDC).
    function usdValue(address token, uint256 amount) public view returns (uint256 usd18) {
        uint256 p = priceOf(token);
        if (p == 0) revert UnknownToken();
        uint256 decimals = token == usdc ? 1e6 : 1e18;
        return amount * p / decimals;
    }

    /// @return imdAmount amount of IMD (18 decimals) worth `amount` of `token`.
    function imdValue(address token, uint256 amount) external view returns (uint256 imdAmount) {
        if (token == imd) return amount;
        return usdValue(token, amount) * 1e18 / imdUsd;
    }

    /// @notice amount of $YOLO worth `amount` of `token`, at the current dev-set price (direct, not a sampled
    ///         minimum: there is no sampling window to manipulate). Used by the doer stake bonus call site
    ///         (CaseDesk._stakeBps).
    function yoloValue(address token, uint256 amount) external view returns (uint256 yoloAmount) {
        if (token == yolo) return amount;
        uint256 yoloPrice = priceOf(yolo);
        if (yoloPrice == 0) return 0;
        return usdValue(token, amount) * 1e18 / yoloPrice;
    }
}
