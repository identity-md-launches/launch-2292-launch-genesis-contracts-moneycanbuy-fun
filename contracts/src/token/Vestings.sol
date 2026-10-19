// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ProjectVesting} from "./ProjectVesting.sol";

/// @notice The four $YOLO vestings of launch 0, each a ProjectVesting with its schedule compiled in (one address
///         argument, nothing to get wrong in the launch text). 12 months = 365 days, 24 months = 730 days; every clock
///         starts when the $YOLO arrives (YoloSplitter.split, ProjectVesting `startOf`), no cliff
///         anywhere.

/// @title IncentivesVesting: 25% of the supply (250,000,000 YOLO) for the incentives wallet
/// @notice A quarter at once (62,500,000 YOLO), the rest linear over 24 months from the split. The incentives wallet
///         is a plain wallet: no mechanic of the protocol pays from it; this contract only unlocks it.
contract IncentivesVesting is ProjectVesting {
    uint256 public constant AT_ONCE = 62_500_000e18;

    constructor(address beneficiary_) ProjectVesting(beneficiary_, AT_ONCE, 730 days) {}
}

/// @title DevVesting: 7.7777777% of the supply (77,777,777 YOLO) for the developer
/// @notice Linear over 12 months from the split.
contract DevVesting is ProjectVesting {
    constructor(address beneficiary_) ProjectVesting(beneficiary_, 0, 365 days) {}
}

/// @title TeamVesting: 5% of the supply (50,000,000 YOLO) for the future team
/// @notice Linear over 12 months from the split.
contract TeamVesting is ProjectVesting {
    constructor(address beneficiary_) ProjectVesting(beneficiary_, 0, 365 days) {}
}

/// @title TreasuryVesting: the rest of the project's share (222,222,223 YOLO and the factory's rounding) for the treasury
/// @notice A third at once (74,074,074 YOLO), the rest linear over 12 months from the split.
contract TreasuryVesting is ProjectVesting {
    uint256 public constant AT_ONCE = 74_074_074e18;

    constructor(address beneficiary_) ProjectVesting(beneficiary_, AT_ONCE, 365 days) {}
}
