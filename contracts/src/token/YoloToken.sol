// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice What the token asks the NFT gate (NftGate, launch 0).
interface INftGate {
    function consume(address buyer, uint256 amount) external returns (uint256 allowance, uint256 usedBefore);
}

/// @title YoloToken ($YOLO)
/// @notice The project token: 1,000,000,000 YOLO minted once to the deployer (the IMD launch factory, which seeds the
///         YOLO/IMD pool and hands out the rest). No owner, no pause, no minting or burning, no list anyone can edit.
///         A buy is a transfer out of the Uniswap v4 PoolManager; for one hour after deployment (the pool opens in
///         the same transaction) buys follow a fixed schedule that ends by itself:
///         - minutes 0-30: only identity.md NFT holders buy. The receiver of the buy must have NFTs registered in
///           the gate (500,000 YOLO per NFT for the whole window); `NotWhitelisted` / `NftAllowanceExceeded`
///           otherwise. If the gate address holds no code (a chain without the gate), there is no whitelist.
///         - minutes 30-60: anyone buys, with a buy tax that falls linearly from 30% at minute 30 to 0 at minute 60,
///           paid in YOLO to the project wallet fixed at deployment.
///         - from minute 60: a plain ERC-20 for good.
///         Sells, transfers between wallets and everything into the pool are never touched. The deployer (the
///         factory: seeding, its fee claims) and the PoolManager itself are exempt.
///         Known limits, accepted: the gate and the tax see only ERC-20 transfers out of the PoolManager. A buy
///         kept as an ERC-6909 claim inside the PoolManager is no transfer until it is taken out (then the rule of
///         that moment applies). The NFT gate checks the buyer address of a transfer; contract buyers that keep
///         claims are not gated or taxed.
///         Acknowledged, see docs/AUDIT-INTERNAL.md A-01.
///         In minutes 0-30 a route whose output goes to a router first is refused, since the router holds no NFT
///         (the Universal Router's TAKE_ALL pays the buyer directly).
contract YoloToken is ERC20 {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 public constant WHITELIST_SECONDS = 30 minutes;
    uint256 public constant TAX_END_SECONDS = 60 minutes;
    /// @notice the buy tax at minute 30, in basis points; it reaches 0 at minute 60
    uint256 public constant TAX_START_BPS = 3_000;

    address public immutable poolManager;
    /// @notice the deployer (the launch factory): never gated or taxed
    address public immutable launcher;
    /// @notice NftGate of launch 0; no code there = no whitelist
    address public immutable gate;
    /// @notice the project wallet (the treasury): receives the buy tax
    address public immutable taxRecipient;
    /// @notice deployment time = the pool's opening
    uint256 public immutable start;

    error NotWhitelisted(address buyer);
    error NftAllowanceExceeded(address buyer, uint256 left, uint256 wanted);
    error ZeroAddress();

    /// @param poolManager_ the Uniswap v4 PoolManager (every v4 buy is a transfer from it)
    /// @param gate_ NftGate (launch 0)
    /// @param taxRecipient_ the project wallet (the treasury)
    constructor(address poolManager_, address gate_, address taxRecipient_) ERC20("YOLO", "YOLO") {
        if (poolManager_ == address(0) || taxRecipient_ == address(0)) revert ZeroAddress();
        poolManager = poolManager_;
        launcher = msg.sender;
        gate = gate_;
        taxRecipient = taxRecipient_;
        start = block.timestamp;
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    /// @notice The buy tax now, in basis points (0 outside minutes 30-60).
    function buyTaxBps() public view returns (uint256) {
        uint256 e = block.timestamp - start;
        if (e < WHITELIST_SECONDS || e >= TAX_END_SECONDS) return 0;
        return TAX_START_BPS * (TAX_END_SECONDS - e) / (TAX_END_SECONDS - WHITELIST_SECONDS);
    }

    /// @notice Whether buys are for registered NFT holders only right now.
    function whitelistActive() public view returns (bool) {
        return block.timestamp - start < WHITELIST_SECONDS && gate.code.length != 0;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == poolManager && value != 0 && to != poolManager && to != launcher) {
            uint256 e = block.timestamp - start;
            if (e < WHITELIST_SECONDS) {
                if (gate.code.length != 0) {
                    (uint256 allowance, uint256 usedBefore) = INftGate(gate).consume(to, value);
                    if (allowance == 0) revert NotWhitelisted(to);
                    if (value > allowance - usedBefore) {
                        revert NftAllowanceExceeded(to, allowance - usedBefore, value);
                    }
                }
            } else if (e < TAX_END_SECONDS) {
                // value x 30% x (60 min - e) / 30 min, rounded down
                uint256 tax =
                    value * TAX_START_BPS * (TAX_END_SECONDS - e) / (10_000 * (TAX_END_SECONDS - WHITELIST_SECONDS));
                if (tax != 0) {
                    super._update(from, taxRecipient, tax);
                    value -= tax;
                }
            }
        }
        super._update(from, to, value);
    }
}
