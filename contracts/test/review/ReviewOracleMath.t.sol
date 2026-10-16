// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    ChainlinkUniV3PriceOracle,
    IAggregatorV3,
    IUniswapV3PoolObserve
} from "../../src/oracles/ChainlinkUniV3PriceOracle.sol";

contract PowHarness is ChainlinkUniV3PriceOracle {
    constructor()
        ChainlinkUniV3PriceOracle(
            address(1),
            address(2),
            IAggregatorV3(address(3)),
            IAggregatorV3(address(4)),
            IUniswapV3PoolObserve(address(5)),
            1800,
            1,
            1,
            address(6),
            address(7),
            address(8),
            12_500,
            60,
            0.01e18,
            0
        )
    {}

    function pow(int24 t) external pure returns (uint256) {
        return _pow10001(t);
    }
}

/// @dev 1.0001^tick (1e18) against an exact computation (Python decimal, 80 digits).
contract ReviewOracleMath is Test {
    PowHarness h = new PowHarness();

    function _close(int24 t, uint256 exact) internal view {
        uint256 got = h.pow(t);
        uint256 diff = got > exact ? got - exact : exact - got;
        assertLe(diff, exact / 1e12 + 1, "relative error above 1e-12");
    }

    function test_PowMatchesExact() public view {
        _close(0, 1000000000000000000);
        _close(1, 1000100000000000000);
        _close(-1, 999900009999000099);
        _close(100, 1010049662092876568);
        _close(-100, 990050328741209481);
        _close(12345, 3436447654033286777);
        _close(-12345, 290998176220237460);
        _close(200000, 484680305025733588332716006);
        _close(276324, 999997356176039153113976863680); // ~ IMD/USDC raw range
    }

    /// The range is checked: the limit is honestly 2^19 (beyond it intermediate values overflow uint256), past it a clear
    /// BadPrice revert instead of an overflow panic. For the USDC/IMD pool the real tick is ~ +256 000.
    function test_PowRangeIsChecked() public {
        h.pow(524287);
        h.pow(-524287);
        vm.expectRevert(ChainlinkUniV3PriceOracle.BadPrice.selector);
        h.pow(524288);
        vm.expectRevert(ChainlinkUniV3PriceOracle.BadPrice.selector);
        h.pow(-524288);
        vm.expectRevert(ChainlinkUniV3PriceOracle.BadPrice.selector);
        h.pow(887272);
    }
}
