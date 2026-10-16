// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Price source. It never sets a task reward: it sizes bonds, the "large task" threshold and the minimum
///         reward, converts ETH to IMD for the relayer shortfall, and sets YoloSweetener's cap on a bonus the swarm
///         did not confirm and the DareTrophy price in YOLO. `token == address(0)` means native ETH.
interface IPriceOracle {
    /// @return usd18 value of `amount` of `token` in USD, 18 decimals.
    function usdValue(address token, uint256 amount) external view returns (uint256 usd18);

    /// @return imdAmount amount of IMD (18 decimals) worth `amount` of `token`.
    function imdValue(address token, uint256 amount) external view returns (uint256 imdAmount);

    /// @return whether `token` has a price now. Only $YOLO can lack one (too few pool samples); its `usdValue` and
    ///         `imdValue` are then 0. A desk then treats the task as large: mandatory swarm check, Bonds as at the
    ///         large threshold (`Desk._priceYolo`).
    function hasPrice(address token) external view returns (bool);
}
