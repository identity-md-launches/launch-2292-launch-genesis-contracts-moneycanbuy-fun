// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Launch 0 (the genesis contracts: NftGate, the four vestings, YoloSplitter) as adapted for the IMD evm_contracts
// launch: the launch rules the six must meet, and the five findings of the imported audit reproduced against the code
// as it arrived. None of the findings required a change (ADAPTATION.md); these tests pin the behaviour each one
// describes so that a later change to it is a deliberate one.

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {NftGate} from "src/token/NftGate.sol";
import {ProjectVesting} from "src/token/ProjectVesting.sol";
import {IncentivesVesting, DevVesting, TeamVesting, TreasuryVesting} from "src/token/Vestings.sol";
import {YoloSplitter} from "src/token/YoloSplitter.sol";
import {YoloToken} from "src/token/YoloToken.sol";
import {LaunchPlan, LocalFactory} from "../../../script/LaunchPlan.sol";

contract PlainToken is ERC20 {
    constructor() ERC20("T", "T") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice The launch rules of an evm_contracts launch, checked on launch 0 as LaunchPlan.genesisLaunch builds it
///         with the mainnet arguments of docs/LAUNCH-TASK.md.
contract GenesisLaunchRulesTest is Test {
    uint256 constant EIP170 = 24_576;

    /// @dev The plan's codes with the mainnet arguments, deployed by CREATE2 in ONE call on an empty chain, as the
    ///      launch factory and the protected rehearsal do (ContractsDeploymentProbe.deployAll): the transient binding
    ///      flag of a vesting lives for the whole call, so the splitter deployed last binds itself.
    function _deploy() internal returns (address[] memory a, bytes32[] memory names) {
        LocalFactory f = new LocalFactory();
        bytes[] memory codes;
        LaunchPlan.Genesis memory g;
        (codes, names, g) = LaunchPlan.genesisLaunch(f, 0, LaunchPlan.projectOwners());
        assertEq(codes.length, 6);
        a = f.launchContracts(0, codes);
        assertEq(a[0], g.gate, "predicted gate");
        assertEq(a[5], g.splitter, "predicted splitter");
        for (uint256 i; i < 6; ++i) {
            assertGt(a[i].code.length, 0, "constructor failed");
        }
    }

    function _codes() internal returns (bytes[] memory codes) {
        (codes,,) = LaunchPlan.genesisLaunch(new LocalFactory(), 0, LaunchPlan.projectOwners());
    }

    /// The six deploy in one call on an empty chain (nothing else exists), each with a nonpayable constructor that
    /// takes only addresses; the only external call is the splitter's bindStarter on the four vestings of the same
    /// call, which makes it their one starter.
    function test_sixConstructorsRunInOneCallOnAnEmptyChain() public {
        (address[] memory a, bytes32[] memory names) = _deploy();
        assertEq(names[0], bytes32("NftGate"));
        assertEq(NftGate(a[0]).writer(), LaunchPlan.PROJECT_TREASURY, "the project wallet writes the snapshot");
        assertEq(NftGate(a[0]).nft(), LaunchPlan.NFT);
        assertEq(NftGate(a[0]).sealedAt(), 0);
        address[4] memory beneficiaries = [
            LaunchPlan.PROJECT_INCENTIVES, LaunchPlan.PROJECT_DEV, LaunchPlan.PROJECT_TEAM, LaunchPlan.PROJECT_TREASURY
        ];
        for (uint256 i; i < 4; ++i) {
            ProjectVesting v = ProjectVesting(a[1 + i]);
            assertEq(v.beneficiary(), beneficiaries[i], "beneficiary of the doc");
            assertEq(v.starter(), a[5], "the splitter of this call is the one starter");
            vm.expectRevert(ProjectVesting.BindingClosed.selector);
            v.bindStarter(); // nobody rebinds later
        }
        assertEq(IncentivesVesting(a[1]).unlocked(), 62_500_000e18);
        assertEq(IncentivesVesting(a[1]).duration(), 730 days);
        assertEq(DevVesting(a[2]).unlocked(), 0);
        assertEq(DevVesting(a[2]).duration(), 365 days);
        assertEq(TeamVesting(a[3]).unlocked(), 0);
        assertEq(TeamVesting(a[3]).duration(), 365 days);
        assertEq(TreasuryVesting(a[4]).unlocked(), 74_074_074e18);
        assertEq(TreasuryVesting(a[4]).duration(), 365 days);
        YoloSplitter s = YoloSplitter(a[5]);
        assertEq(s.incentivesVesting(), a[1]);
        assertEq(s.devVesting(), a[2]);
        assertEq(s.teamVesting(), a[3]);
        assertEq(s.treasuryVesting(), a[4]);
        assertEq(s.stabilizer(), LaunchPlan.PROJECT_STABILIZER);
    }

    /// Every runtime is present, under EIP-170 and free of DELEGATECALL, CALLCODE and SELFDESTRUCT (the protected
    /// rehearsal's scan); no contract answers owner(): there is no owner, admin, pause or upgrade path.
    function test_runtimesBoundedNoEscapeOpcodesNoOwner() public {
        (address[] memory a,) = _deploy();
        for (uint256 i; i < a.length; ++i) {
            bytes memory code = a[i].code;
            assertGt(code.length, 0, "missing runtime");
            assertLe(code.length, EIP170, "runtime exceeds EIP-170");
            for (uint256 j; j < code.length; ++j) {
                uint8 op = uint8(code[j]);
                if (op >= 0x60 && op <= 0x7f) {
                    j += op - 0x5f;
                    continue;
                }
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden application opcode");
            }
            (bool ok,) = a[i].call(abi.encodeWithSignature("owner()"));
            assertFalse(ok, "no owner()");
            (ok,) = a[i].call(abi.encodeWithSignature("paused()"));
            assertFalse(ok, "no pause");
            (ok,) = a[i].call{value: 0}("");
            assertFalse(ok, "no receive or fallback: holds nothing");
        }
    }

    /// A constructor rehearsed alone (the launch checks run each on an empty chain): the splitter's does not require
    /// its vesting addresses to have code, and a vesting's needs nothing at all.
    function test_eachConstructorAloneNeedsNoOtherContract() public {
        address none1 = makeAddr("v1");
        address none2 = makeAddr("v2");
        address none3 = makeAddr("v3");
        address none4 = makeAddr("v4");
        YoloSplitter s = new YoloSplitter(none1, none2, none3, none4, LaunchPlan.PROJECT_STABILIZER);
        assertEq(s.treasuryVesting(), none4);
        new NftGate(LaunchPlan.NFT, LaunchPlan.PROJECT_TREASURY);
        new IncentivesVesting(LaunchPlan.PROJECT_INCENTIVES);
        new DevVesting(LaunchPlan.PROJECT_DEV);
        new TeamVesting(LaunchPlan.PROJECT_TEAM);
        new TreasuryVesting(LaunchPlan.PROJECT_TREASURY);
    }

    /// Deployment sends no ETH and the constructors are nonpayable: a creation with value fails.
    function test_constructorsAreNonpayable() public {
        bytes[] memory codes = _codes();
        vm.deal(address(this), 6);
        for (uint256 i; i < codes.length; ++i) {
            bytes memory code = codes[i];
            address a;
            assembly ("memory-safe") {
                a := create(1, add(code, 0x20), mload(code))
            }
            assertEq(a, address(0), "a payable constructor");
        }
    }
}

/// @notice The five findings of the imported audit, reproduced on the code as it arrived. Each passes as the finding
///         describes the behaviour; none changed the code (ADAPTATION.md says why).
contract GenesisAuditFindingsTest is Test {
    address constant PM = address(0x4444);
    address writer = makeAddr("projectWallet");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    PlainToken yolo;

    function setUp() public {
        vm.warp(1_800_000_000);
        yolo = new PlainToken();
    }

    function _one(address a, uint256 c) internal pure returns (address[] memory w, uint256[] memory n) {
        w = new address[](1);
        n = new uint256[](1);
        (w[0], n[0]) = (a, c);
    }

    // ---- finding 1 [low]: no correction of a snapshot entry before the seal; the only remedy, never sealing, closes
    //      minutes 0-30 to everyone. Reproduced; accepted as the brief's own rules ("each wallet once", "after the
    //      seal nobody can change it"): the writer checks snapshotHash against the published json before sealing.

    function test_F1_wrongEntryCannotBeLoweredOrRemovedBeforeTheSeal() public {
        NftGate gate = new NftGate(LaunchPlan.NFT, writer);
        (address[] memory w, uint256[] memory n) = _one(alice, 5); // alice really held 1
        vm.prank(writer);
        gate.record(w, n);
        (w, n) = _one(alice, 1);
        vm.prank(writer);
        vm.expectRevert(abi.encodeWithSelector(NftGate.AlreadyRecorded.selector, alice));
        gate.record(w, n); // no overwrite
        assertEq(gate.nftsOf(alice), 5, "the first entry stands");
        // no other write path: only record and seal change state
        vm.prank(writer);
        gate.seal(0); // seal takes any block value, even 0: nothing checks it on chain
        assertEq(gate.snapshotBlock(), 0);
        assertEq(gate.allowanceOf(alice), 5 * gate.ALLOWANCE_PER_NFT(), "an inflated allowance, for good");
        (w, n) = _one(alice, 1);
        vm.prank(writer);
        vm.expectRevert(NftGate.AlreadySealed.selector);
        gate.record(w, n);
    }

    function test_F1_theOnlyRemedyNeverSealingClosesTheWindowToEveryone() public {
        NftGate gate = new NftGate(LaunchPlan.NFT, writer);
        YoloToken t = new YoloToken(PM, address(gate), writer, block.timestamp + 1 hours);
        t.transfer(PM, 200_000_000e18);
        (address[] memory w, uint256[] memory n) = _one(bob, 1); // bob is right, alice would be wrong: no seal
        vm.prank(writer);
        gate.record(w, n);
        vm.warp(t.openAt() + 10 minutes);
        vm.expectRevert(NftGate.NotSealed.selector);
        gate.consume(bob, 1);
        vm.prank(PM);
        vm.expectRevert(YoloToken.SnapshotNotSealed.selector);
        t.transfer(bob, 1e18); // the correct wallet cannot buy either
        // a seal after trading opened does not count: the window stays closed for its whole 30 minutes
        vm.prank(writer);
        gate.seal(1);
        vm.prank(PM);
        vm.expectRevert(YoloToken.SnapshotNotSealed.selector);
        t.transfer(bob, 1e18);
        vm.warp(t.openAt() + 30 minutes);
        vm.prank(PM);
        t.transfer(bob, 1e18); // from minute 30 anyone buys (taxed)
    }

    // ---- finding 2 [info]: tokens that arrive after a clock started vest pro rata to the elapsed share.

    function test_F2_laterArrivalsThroughTheSplitterVestProRataToTheElapsedTime() public {
        TreasuryVesting tv = new TreasuryVesting(writer);
        YoloSplitter sp = new YoloSplitter(makeAddr("i"), makeAddr("d"), makeAddr("t"), address(tv), makeAddr("s"));
        yolo.mint(address(sp), 750_000_000e18);
        sp.split(address(yolo)); // T0: the clock starts, 74,074,074 paid at once
        uint64 t0 = tv.startOf(address(yolo));
        assertEq(t0, uint64(block.timestamp));
        assertEq(yolo.balanceOf(writer), 74_074_074e18);
        vm.warp(t0 + 300 days);
        uint256 before = tv.releasable(address(yolo));
        yolo.mint(address(sp), 1_000e18);
        sp.split(address(yolo)); // the second call forwards everything to the treasury vesting
        assertEq(yolo.balanceOf(address(tv)) + tv.released(address(yolo)), 222_222_223e18 + 1_000e18);
        uint256 freed = tv.releasable(address(yolo)) - before;
        assertApproxEqAbs(freed, uint256(1_000e18) * 300 days / 365 days, 1, "pro rata to the 300 days elapsed");
        vm.warp(t0 + 365 days);
        yolo.mint(address(sp), 500e18);
        sp.split(address(yolo));
        assertEq(tv.releasable(address(yolo)), 222_222_223e18 + 1_500e18 - 74_074_074e18, "free in full after day 365");
        vm.prank(bob);
        tv.release(address(yolo)); // anyone releases, only the beneficiary is paid
        assertEq(yolo.balanceOf(writer), 222_222_223e18 + 1_500e18);
    }

    // ---- finding 3 [info]: a token sent straight to a vesting (not through the splitter) never gets a clock.

    function test_F3_tokenSentStraightToAVestingHasNoClock() public {
        DevVesting dev = new DevVesting(writer);
        YoloSplitter sp = new YoloSplitter(makeAddr("i"), address(dev), makeAddr("t"), makeAddr("tr"), makeAddr("s"));
        assertEq(dev.starter(), address(sp));
        PlainToken x = new PlainToken();
        x.mint(address(dev), 100e18);
        vm.prank(bob);
        dev.release(address(x));
        assertEq(dev.startOf(address(x)), 0, "no clock: the caller is not the starter");
        assertEq(dev.releasable(address(x)), 0);
        assertEq(x.balanceOf(writer), 0);
        vm.expectRevert(abi.encodeWithSelector(YoloSplitter.NotArrived.selector, 0));
        sp.split(address(x)); // the starter path cannot be reached either
        skip(400 days);
        assertEq(dev.releasable(address(x)), 0, "locked for good");
        // a vesting with an at-once part frees that part of any token, and no more
        IncentivesVesting inc = new IncentivesVesting(writer);
        x.mint(address(inc), 100_000_000e18);
        inc.release(address(x));
        assertEq(x.balanceOf(writer), 62_500_000e18);
        assertEq(inc.releasable(address(x)), 0);
    }

    // ---- finding 4 [info, launch 1]: the token's constructor refuses a real openAt on a chain whose clock is far
    //      behind it. Not one of the six; pinned for the adapter of launch 1.

    function test_F4_yoloTokenConstructorNeedsARealisticChainTime() public {
        NftGate gate = new NftGate(LaunchPlan.NFT, writer);
        uint256 openAt = 1_765_000_000;
        vm.warp(1);
        vm.expectRevert(abi.encodeWithSelector(YoloToken.BadOpenAt.selector, openAt));
        new YoloToken(LaunchPlan.POOL_MANAGER, address(gate), writer, openAt);
        vm.warp(openAt - 1 days);
        YoloToken t = new YoloToken(LaunchPlan.POOL_MANAGER, address(gate), writer, openAt);
        assertEq(t.openAt(), openAt);
    }

    // ---- finding 5 (coverage): the split of the whole launch as the factory leaves it, run end to end here.

    function test_F5_firstSplitPaysEveryShareOnceAndStartsEveryClock() public {
        LocalFactory f = new LocalFactory();
        LaunchPlan.Owners memory o =
            LaunchPlan.Owners(writer, makeAddr("inc"), makeAddr("stab"), makeAddr("dev"), makeAddr("team"));
        (bytes[] memory codes,, LaunchPlan.Genesis memory g) = LaunchPlan.genesisLaunchWith(f, 7, o, LaunchPlan.NFT);
        f.launchContracts(7, codes);
        YoloSplitter sp = YoloSplitter(g.splitter);
        // nothing to split before the factory's remainder: not with the fixed shares exactly
        yolo.mint(g.splitter, 527_777_777e18);
        vm.expectRevert(abi.encodeWithSelector(YoloSplitter.NotArrived.selector, 527_777_777e18));
        sp.split(address(yolo));
        yolo.mint(g.splitter, 222_222_223e18 - 5); // the factory's rounding of the pool seed
        vm.prank(bob);
        sp.split(address(yolo));
        assertTrue(sp.done(address(yolo)));
        assertEq(yolo.balanceOf(g.splitter), 0);
        assertEq(yolo.balanceOf(g.incentives), 250_000_000e18 - 62_500_000e18);
        assertEq(yolo.balanceOf(o.incentives), 62_500_000e18);
        assertEq(yolo.balanceOf(o.stabilizer), 150_000_000e18);
        assertEq(yolo.balanceOf(g.dev), 77_777_777e18);
        assertEq(yolo.balanceOf(g.team), 50_000_000e18);
        assertEq(yolo.balanceOf(g.treasury), 222_222_223e18 - 5 - 74_074_074e18);
        assertEq(yolo.balanceOf(o.treasury), 74_074_074e18);
        address[4] memory vs = [g.incentives, g.dev, g.team, g.treasury];
        for (uint256 i; i < 4; ++i) {
            assertEq(
                ProjectVesting(vs[i]).startOf(address(yolo)), uint64(block.timestamp), "clock started at the split"
            );
        }
        // a second call right away pays nothing twice
        sp.split(address(yolo));
        assertEq(yolo.balanceOf(o.stabilizer), 150_000_000e18);
        assertEq(yolo.balanceOf(g.treasury), 222_222_223e18 - 5 - 74_074_074e18);
        // after a year every vesting has opened the whole share to its beneficiary, and only to it
        skip(365 days);
        for (uint256 i; i < 4; ++i) {
            vm.prank(bob);
            ProjectVesting(vs[i]).release(address(yolo));
        }
        assertEq(yolo.balanceOf(o.dev), 77_777_777e18);
        assertEq(yolo.balanceOf(o.team), 50_000_000e18);
        assertEq(yolo.balanceOf(o.treasury), 222_222_223e18 - 5);
        assertEq(yolo.balanceOf(o.incentives), 62_500_000e18 + 93_750_000e18, "half of the stream at 12 of 24 months");
        assertEq(yolo.balanceOf(bob), 0);
    }
}
