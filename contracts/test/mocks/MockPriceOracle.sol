// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";

/// @dev USD prices with 18 decimals per whole token; token decimals per address.
contract MockPriceOracle is IPriceOracle {
    mapping(address => uint256) public usdPerToken; // 1e18 = $1 per 1 whole token
    mapping(address => uint8) public decimalsOf;
    address public immutable imd;

    constructor(address imd_) {
        imd = imd_;
    }

    /// @dev every read reverts while set (an unreadable TWAP or a stale feed)
    bool public broken;

    function setBroken(bool b) external {
        broken = b;
    }

    function set(address token, uint256 usd18, uint8 dec) external {
        usdPerToken[token] = usd18;
        decimalsOf[token] = dec;
    }

    function usdValue(address token, uint256 amount) public view returns (uint256) {
        require(!broken, "oracle down");
        return amount * usdPerToken[token] / (10 ** decimalsOf[token]);
    }

    /// @dev a token without a set price has none (the vault's $YOLO before its pool has enough samples)
    function hasPrice(address token) external view returns (bool) {
        require(!broken, "oracle down");
        return token == imd || usdPerToken[token] != 0;
    }

    function imdValue(address token, uint256 amount) external view returns (uint256) {
        require(!broken, "oracle down");
        if (token == imd) return amount;
        return usdValue(token, amount) * 1e18 / usdPerToken[imd];
    }
}
