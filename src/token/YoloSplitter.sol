// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev ProjectVesting: `release` from its starter starts the vesting clock of a token it holds (and pays what is
///      free); `bindStarter` makes the caller that starter, only in the vesting's deployment transaction.
interface IVestingRelease {
    function release(address token) external;
    function bindStarter() external;
}

/// @title YoloSplitter: the `remainderTo` of the $YOLO launch
/// @notice The launch factory sends the project's 75% of $YOLO here (the swarm keeps 10%, the pool takes 15%). The
///         first `split(token)` once more than the fixed 527,777,777 have arrived hands them out: incentives vesting
///         250M, the YOLO Stabilizer wallet 150M, dev vesting 77,777,777, team vesting 50M, and the treasury vesting
///         the rest (222,222,223 give or take the factory's rounding of the pool seed, so a remainder a few wei short
///         of 750M never locks the split). The factory sends the remainder in the launch transaction, so everything
///         has arrived before anyone can call. Anything that arrives later goes to the treasury vesting.
///         Right after paying, the split calls `release(token)` on the four vestings: their clocks start at the split,
///         when the token has arrived, not at launch 0; the at-once parts go to their
///         beneficiaries in the same transaction. The constructor binds this splitter as the only starter of the
///         four vestings (`bindStarter`, which they accept only in their own deployment transaction: launch 0 deploys
///         them and this splitter in one), so no one else can start a clock before the split (swarm audit 117cf05a #2).
///         Anyone may call it; it pays only these five addresses, fixed at deployment. Like the vestings it knows no
///         token in advance (launch 0 comes before the token). No owner.
contract YoloSplitter {
    using SafeERC20 for IERC20;

    uint256 public constant INCENTIVES = 250_000_000e18;
    uint256 public constant STABILIZER = 150_000_000e18;
    uint256 public constant DEV = 77_777_777e18;
    uint256 public constant TEAM = 50_000_000e18;
    /// @notice what the four fixed shares add up to; the treasury vesting gets the rest (about 222,222,223)
    uint256 public constant FIXED = 527_777_777e18;

    address public immutable incentivesVesting;
    address public immutable devVesting;
    address public immutable teamVesting;
    address public immutable treasuryVesting;
    address public immutable stabilizer;

    mapping(address token => bool) public done;

    event Split(address indexed token, uint256 total);

    error ZeroAddress();
    error NotArrived(uint256 balance);

    constructor(
        address incentivesVesting_,
        address devVesting_,
        address teamVesting_,
        address treasuryVesting_,
        address stabilizer_
    ) {
        if (
            incentivesVesting_ == address(0) || devVesting_ == address(0) || teamVesting_ == address(0)
                || treasuryVesting_ == address(0) || stabilizer_ == address(0)
        ) revert ZeroAddress();
        incentivesVesting = incentivesVesting_;
        devVesting = devVesting_;
        teamVesting = teamVesting_;
        treasuryVesting = treasuryVesting_;
        stabilizer = stabilizer_;
        _bind(incentivesVesting_);
        _bind(devVesting_);
        _bind(teamVesting_);
        _bind(treasuryVesting_);
    }

    function split(address token) external {
        IERC20 t = IERC20(token);
        uint256 bal = t.balanceOf(address(this));
        if (done[token]) {
            if (bal != 0) t.safeTransfer(treasuryVesting, bal);
            return;
        }
        if (bal <= FIXED) revert NotArrived(bal);
        done[token] = true;
        t.safeTransfer(incentivesVesting, INCENTIVES);
        t.safeTransfer(stabilizer, STABILIZER);
        t.safeTransfer(devVesting, DEV);
        t.safeTransfer(teamVesting, TEAM);
        t.safeTransfer(treasuryVesting, bal - FIXED);
        emit Split(token, bal);
        _start(incentivesVesting, token);
        _start(devVesting, token);
        _start(teamVesting, token);
        _start(treasuryVesting, token);
    }

    /// @dev Becomes the starter of a vesting; a recipient without code (a plain wallet, unit tests) has no clock.
    function _bind(address vesting) private {
        if (vesting.code.length != 0) IVestingRelease(vesting).bindStarter();
    }

    /// @dev Starts a vesting's clock; a recipient without code (a plain wallet, unit tests) has none to start.
    function _start(address vesting, address token) private {
        if (vesting.code.length != 0) IVestingRelease(vesting).release(token);
    }
}
