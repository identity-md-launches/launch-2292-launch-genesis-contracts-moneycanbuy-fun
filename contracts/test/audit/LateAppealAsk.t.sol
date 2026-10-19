// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ITaskVault} from "src/interfaces/ITaskVault.sol";
import {ParamsRegistry} from "src/ParamsRegistry.sol";
import {DevPrices} from "src/DevPrices.sol";
import {VoteLib} from "src/libraries/VoteLib.sol";
import "src/VaultTypes.sol";
import {AuditTok, AuditNft, AuditIntake, AuditDeploy} from "./MaxImdInCap.t.sol";

/// @dev Finding (swarm code audit fb6f02ff, medium): DisputeDesk.askAppealSwarm played no timers, so an appeal past
///      its swarmTimeout (6 h) ask deadline was still asked if nobody poked first. MECHANICS: such an appeal is void,
///      bond and fee refunded. The ask must play the task's timers first and revert WrongPhase.
contract LateAppealAskTest is Test, AuditDeploy {
    AuditTok imd;
    AuditIntake intake;
    ITaskVault vault;

    address author = makeAddr("author");
    address doer = makeAddr("doer");
    address dave = makeAddr("dave");
    address erin = makeAddr("erin");
    address voter = makeAddr("voter");

    function setUp() public {
        vm.warp(1_800_000_000);
        imd = new AuditTok("IMD", 18);
        AuditTok usdc = new AuditTok("USDC", 6);
        AuditTok yolo = new AuditTok("YOLO", 18);
        AuditNft nft = new AuditNft();
        intake = new AuditIntake(address(imd), 0.5e18);
        DevPrices prices = new DevPrices(
            makeAddr("devWallet"), address(usdc), address(imd), address(yolo), 0.0001e18, 2500e18, 8e18
        );
        ParamsRegistry registry = new ParamsRegistry(
            makeAddr("multisig"),
            address(intake),
            address(prices),
            makeAddr("swapAdapter"),
            address(nft),
            makeAddr("delegates"),
            makeAddr("treasury"),
            makeAddr("attester")
        );
        (,,, address v) =
            _deployCore(address(registry), address(imd), address(usdc), address(yolo), address(prices), address(nft));
        vault = ITaskVault(v);
        address[4] memory people = [author, doer, dave, erin];
        for (uint256 i; i < 4; ++i) {
            imd.mint(people[i], 10_000e18);
            vm.prank(people[i]);
            imd.approve(address(vault), type(uint256).max);
        }
        for (uint256 id; id < 20; ++id) {
            nft.mint(voter, id);
        }
    }

    function _noSwap() internal pure returns (ImdPay memory p) {}

    function _rt() internal pure returns (RuleTexts memory) {
        return RuleTexts(
            "ipfs://task-condition",
            "PROOF: one https link, DOER CODE on the page",
            "NO if: unclear",
            "ipfs://reason",
            "ipfs://reason-proof"
        );
    }

    /// @dev IMD task 1000 IMD -> submission -> dispute -> 20 NFTs reject (Decided) -> stranger erin appeals.
    function _appealed() internal returns (uint256 taskId, uint256 subId) {
        vm.prank(author);
        taskId = vault.createTask(
            address(imd),
            1_000e18,
            uint64(block.timestamp + 365 days),
            "Title",
            TaskRules("ipfs://task-condition", "PROOF: one https link, DOER CODE on the page", "NO if: unclear"),
            0,
            PROOF_LINK,
            "",
            _noSwap()
        );
        vm.prank(doer);
        subId = vault.submit(taskId, "https://x.com/doer/status/1", Evidence("", ""), 0, type(uint256).max, _noSwap());
        vm.prank(dave);
        vault.dispute(subId, "ipfs://reason", "ipfs://reason-proof", _noSwap());
        uint256[] memory ids = new uint256[](20);
        for (uint256 i; i < 20; ++i) {
            ids[i] = i;
        }
        vm.prank(voter);
        vault.vote(subId, VoteLib.SIDE_REJECT, voter, ids);
        assertEq(uint8(vault.getSubmission(subId).phase), uint8(Phase.Decided), "not decided");
        vm.prank(erin);
        vault.appeal(subId, type(uint256).max, _noSwap());
        assertEq(uint8(vault.getSubmission(subId).phase), uint8(Phase.Appealed), "not appealed");
    }

    /// @dev Past 6 h with no poke: the ask reverts WrongPhase, the Intake gets nothing; a poke voids the appeal and
    ///      credits erin her bond (0.5 + 10 IMD) and fee (0.5 IMD) back.
    function test_LateAppealAskReverts() public {
        (uint256 taskId, uint256 subId) = _appealed();
        vm.warp(vault.getSubmission(subId).appealedAt + 6 hours + 1);

        vm.expectRevert(WrongPhase.selector);
        vault.askAppealSwarm(subId, _rt());
        assertEq(imd.balanceOf(address(intake)), 0, "the Intake was paid for a void appeal");

        vault.poke(taskId);
        assertEq(uint8(vault.getSubmission(subId).phase), uint8(Phase.Decided), "appeal not voided");
        assertEq(vault.credits(address(imd), erin), 11e18, "bond + fee not credited back");
    }

    /// @dev Control: inside the 6 h the ask still goes to the swarm.
    function test_TimelyAppealAskIsAsked() public {
        (, uint256 subId) = _appealed();
        vm.warp(vault.getSubmission(subId).appealedAt + 6 hours - 1);
        vault.askAppealSwarm(subId, _rt());
        assertEq(uint8(vault.getSubmission(subId).phase), uint8(Phase.Asked), "not asked");
        assertEq(imd.balanceOf(address(intake)), 0.5e18, "fee not paid to the Intake");
    }
}
