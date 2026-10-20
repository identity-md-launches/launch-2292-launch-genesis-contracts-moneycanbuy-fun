// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {YoloToken} from "../../src/token/YoloToken.sol";
import {NftGate} from "../../src/token/NftGate.sol";
import {YoloSplitter} from "../../src/token/YoloSplitter.sol";
import {ProjectVesting} from "../../src/token/ProjectVesting.sol";
import {IncentivesVesting, DevVesting, TeamVesting, TreasuryVesting} from "../../src/token/Vestings.sol";
import {LaunchPlan, LocalFactory} from "../../script/LaunchPlan.sol";
import {MockNFT} from "../mocks/MockNFT.sol";

/// @notice Token and launch checks: regression tests and guards. Unit part: no fork needed.
contract AuditAUnit is Test {
    address constant PM = address(0x4444);
    uint256 constant PER_NFT = 500_000e18;

    MockNFT nft;
    NftGate gate;
    YoloToken yolo;
    address treasury = makeAddr("treasury");
    address bot = makeAddr("bot");
    address alice = makeAddr("alice");

    function setUp() public {
        vm.warp(1_800_000_000);
        nft = new MockNFT();
        gate = new NftGate(address(nft), treasury);
    }

    function _ids(uint256 n, uint256 first) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = first + i;
        }
    }

    // ------------------------------------------------------------------ vesting clocks

    /// A vesting's clock starts at the first `release` while it holds the token, and the split
    /// calls `release` on all four, so the gap between the launches unlocks nothing: Day 0 is exactly the at-once
    /// parts (62.5M incentives, 74,074,074 treasury), paid in the split's transaction.
    function test_Guard_vestingClocksStartAtTheSplit() public {
        LocalFactory f = new LocalFactory();
        LaunchPlan.Owners memory o =
            LaunchPlan.Owners(treasury, makeAddr("inc"), makeAddr("stab"), makeAddr("dev"), makeAddr("team"));
        (bytes[] memory codes,, LaunchPlan.Genesis memory g) =
            LaunchPlan.genesisLaunchWith(f, 0, o, address(nft));
        f.launchContracts(0, codes); // launch 0
        skip(14 days); // the swarm takes launch 1 two weeks later
        yolo = new YoloToken(PM, g.gate, treasury, block.timestamp); // launch 1: the token, the pool and the remainder
        yolo.transfer(PM, 150_000_000e18);
        yolo.transfer(makeAddr("swarm"), 100_000_000e18);
        yolo.transfer(g.splitter, 750_000_000e18);
        YoloSplitter(g.splitter).split(address(yolo));

        address[4] memory vs = [g.dev, g.team, g.incentives, g.treasury];
        for (uint256 i; i < 4; ++i) {
            assertEq(ProjectVesting(vs[i]).startOf(address(yolo)), block.timestamp, "the clock starts at the split");
            assertEq(ProjectVesting(vs[i]).releasable(address(yolo)), 0, "fixed: nothing vested in the gap");
        }
        assertEq(yolo.balanceOf(o.dev), 0, "fixed: dev gets nothing at the token's first block");
        assertEq(yolo.balanceOf(o.team), 0, "fixed: team gets nothing at the token's first block");
        assertEq(yolo.balanceOf(o.incentives), 62_500_000e18, "the published at-once part only");
        assertEq(yolo.balanceOf(o.treasury), 74_074_074e18, "the published at-once part only");
        // then the schedules run from the split: 14 days later
        skip(14 days);
        assertEq(ProjectVesting(g.dev).releasable(address(yolo)), uint256(77_777_777e18) * 14 days / 365 days);
        assertEq(ProjectVesting(g.incentives).releasable(address(yolo)), uint256(187_500_000e18) * 14 days / 730 days);
        ProjectVesting(g.dev).release(address(yolo));
        assertEq(yolo.balanceOf(o.dev), uint256(77_777_777e18) * 14 days / 365 days);
    }
}
