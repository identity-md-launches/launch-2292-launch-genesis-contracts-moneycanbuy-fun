// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {YoloLockHub} from "src/YoloLockHub.sol";

contract MockYoloRelock is ERC20 {
    constructor() ERC20("YOLO", "YOLO") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice A lock that ended and is set again without a withdrawal is a new lock (a new `epoch`): `stakePower(doer,
///         since)` answers 0 for a submission made under the ended lock, as after a withdraw + new lock
///         (desks/DeskApi.sol IDoerStake: "0 once that lock ended or was withdrawn").
contract StakePowerRelockTest is Test {
    MockYoloRelock yolo;
    YoloLockHub hub;
    address doer = address(0xD0E7);

    function setUp() public {
        yolo = new MockYoloRelock();
        hub = new YoloLockHub(address(yolo));
        yolo.mint(doer, 1_000e18);
        vm.prank(doer);
        yolo.approve(address(hub), type(uint256).max);
        vm.warp(1_000_000);
    }

    function test_RelockOfAnEndedLockGivesNoStakePower() public {
        // t0: one-week lock, power = 1000 * 1 / 52
        vm.prank(doer);
        hub.lock(1_000e18, 1);
        uint64 since = uint64(block.timestamp + 6 days); // the submission, inside the term
        uint256 atSubmission = hub.powerAt(doer, since);
        assertEq(atSubmission, uint256(1_000e18) / 52, "power read at the submission");

        // the lock ends at t0 + 7d; without any new lock the payout rule returns 0
        vm.warp(block.timestamp + 7 days);
        assertEq(hub.stakePower(doer, since), 0, "ended lock pays no bonus");

        // the doer starts a new one-week term on the same tokens (no withdrawal in between)
        vm.prank(doer);
        hub.lock(0, 1);

        // the lock behind the submission ended: the payout check must still be 0 (it is 0 after withdraw + lock)
        assertEq(hub.stakePower(doer, since), 0, "re-locked ended lock must not revive the old power");
    }

    function test_WithdrawThenLockGivesZero_reference() public {
        vm.prank(doer);
        hub.lock(1_000e18, 1);
        uint64 since = uint64(block.timestamp + 6 days);
        vm.warp(block.timestamp + 7 days);
        vm.startPrank(doer);
        hub.withdraw();
        hub.lock(1_000e18, 1);
        vm.stopPrank();
        assertEq(hub.stakePower(doer, since), 0, "epoch bumped by the withdrawal");
    }
}