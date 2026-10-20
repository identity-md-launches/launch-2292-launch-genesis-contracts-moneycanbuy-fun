// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Test double for DevPrices, with test setters (`set`, `setYolo`, `setBroken`): USD
///      prices with 18 decimals per whole token; token decimals per address.
contract MockPriceOracle {
    mapping(address => uint256) public usdPerToken; // 1e18 = $1 per 1 whole token
    mapping(address => uint8) public decimalsOf;
    address public immutable imd;

    /// @dev the dev wallet (DevPrices is Ownable2Step: its owner sets the prices and may cancel a task)
    address public owner;

    constructor(address imd_) {
        imd = imd_;
        owner = msg.sender;
    }

    function setOwner(address o) external {
        owner = o;
    }

    /// @dev every read reverts while set (a test simulating the dev not having set a price yet)
    bool public broken;

    function setBroken(bool b) external {
        broken = b;
    }

    function set(address token, uint256 usd18, uint8 dec) external {
        usdPerToken[token] = usd18;
        decimalsOf[token] = dec;
    }

    /// @dev USD per whole token, 18 decimals (DevPrices.priceOf shape).
    function priceOf(address token) external view returns (uint256) {
        require(!broken, "oracle down");
        return usdPerToken[token];
    }

    function usdValue(address token, uint256 amount) public view returns (uint256) {
        require(!broken, "oracle down");
        return amount * usdPerToken[token] / (10 ** decimalsOf[token]);
    }

    /// @dev a token without a set price has none (a test simulating the dev not having set a price yet)
    function hasPrice(address token) external view returns (bool) {
        require(!broken, "oracle down");
        return token == imd || usdPerToken[token] != 0;
    }

    function imdValue(address token, uint256 amount) external view returns (uint256) {
        require(!broken, "oracle down");
        if (token == imd) return amount;
        return usdValue(token, amount) * 1e18 / usdPerToken[imd];
    }

    /// @dev the token `yoloValue` converts into and its set price (0 = fall back to `usdPerToken`)
    address public yoloToken;
    uint256 public yoloLowUsd;

    function setYolo(address yolo_, uint256 lowUsd18) external {
        yoloToken = yolo_;
        yoloLowUsd = lowUsd18;
    }

    function yoloValue(address token, uint256 amount) external view returns (uint256) {
        require(!broken, "oracle down");
        if (token == yoloToken) return amount;
        uint256 price = yoloLowUsd != 0 ? yoloLowUsd : usdPerToken[yoloToken];
        if (yoloToken == address(0) || price == 0) return 0;
        return usdValue(token, amount) * 1e18 / price;
    }
}
