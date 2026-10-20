// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {DevPrices} from "../src/DevPrices.sol";
import {ETH} from "../src/VaultTypes.sol";

/// @dev The dev sets the price of one $YOLO in USD
/// directly (not derived from a total valuation divided by the supply), plus ETH and IMD in USD; none can
/// be zero, and one call moves a price at most x10 up or down (an obvious typo is refused). USDC is fixed
/// at $1.
contract DevPricesTest is Test {
    address internal dev = makeAddr("dev");
    address internal usdc = makeAddr("usdc");
    address internal imd = makeAddr("imd");
    address internal yolo = makeAddr("yolo");
    DevPrices internal prices;

    function setUp() public {
        prices = new DevPrices(dev, usdc, imd, yolo, 0.001e18, 2500e18, 6e18);
    }

    function test_YoloPriceIsThePriceOfOneToken() public view {
        assertEq(prices.yoloPriceUsd(), 0.001e18);
        assertEq(prices.priceOf(yolo), 0.001e18, "no division by a supply");
        assertEq(prices.usdValue(yolo, 1_000_000e18), 1_000e18, "1M YOLO at $0.001 = $1,000");
        assertEq(prices.yoloValue(usdc, 100e6), 100_000e18, "$100 = 100,000 YOLO");
        assertEq(prices.priceOf(usdc), 1e18);
        assertEq(prices.priceOf(ETH), 2500e18);
        assertEq(prices.priceOf(imd), 6e18);
    }

    function test_ZeroRefused_InTheConstructorAndEverySetter() public {
        vm.expectRevert(DevPrices.ZeroPrice.selector);
        new DevPrices(dev, usdc, imd, yolo, 0, 2500e18, 6e18);
        vm.startPrank(dev);
        vm.expectRevert(DevPrices.ZeroPrice.selector);
        prices.setYoloPriceUsd(0);
        vm.expectRevert(DevPrices.ZeroPrice.selector);
        prices.setEthUsd(0);
        vm.expectRevert(DevPrices.ZeroPrice.selector);
        prices.setImdUsd(0);
        vm.stopPrank();
    }

    /// Both bounds inclusive: exactly x10 and exactly /10 pass, one wei past either reverts, for each price.
    function test_TypoGuard_AtMostTenTimesPerCall_BothBounds() public {
        vm.startPrank(dev);
        // $YOLO from $0.001
        vm.expectRevert(DevPrices.PriceSanity.selector);
        prices.setYoloPriceUsd(0.01e18 + 1);
        vm.expectRevert(DevPrices.PriceSanity.selector);
        prices.setYoloPriceUsd(0.0001e18 - 1);
        prices.setYoloPriceUsd(0.01e18);
        assertEq(prices.priceOf(yolo), 0.01e18);
        prices.setYoloPriceUsd(0.001e18); // /10 back
        // ETH from $2,500
        vm.expectRevert(DevPrices.PriceSanity.selector);
        prices.setEthUsd(25_000e18 + 1);
        vm.expectRevert(DevPrices.PriceSanity.selector);
        prices.setEthUsd(250e18 - 1);
        prices.setEthUsd(250e18);
        assertEq(prices.ethUsd(), 250e18);
        // IMD from $6
        vm.expectRevert(DevPrices.PriceSanity.selector);
        prices.setImdUsd(60e18 + 1);
        vm.expectRevert(DevPrices.PriceSanity.selector);
        prices.setImdUsd(0.6e18 - 1);
        prices.setImdUsd(60e18);
        assertEq(prices.imdUsd(), 60e18);
        // a real move past x10 takes several calls
        prices.setImdUsd(600e18);
        assertEq(prices.imdUsd(), 600e18);
        vm.stopPrank();
    }

    function test_OnlyTheOwner_EmitsTheEvent() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        prices.setYoloPriceUsd(0.002e18);
        vm.expectEmit(address(prices));
        emit DevPrices.YoloPriceUsdSet(0.002e18);
        vm.prank(dev);
        prices.setYoloPriceUsd(0.002e18);
    }
}
