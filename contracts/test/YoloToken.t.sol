// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {YoloToken} from "../src/token/YoloToken.sol";
import {NftGate} from "../src/token/NftGate.sol";
import {YoloSplitter} from "../src/token/YoloSplitter.sol";
import {ProjectVesting} from "../src/token/ProjectVesting.sol";
import {IncentivesVesting, DevVesting, TeamVesting, TreasuryVesting} from "../src/token/Vestings.sol";
import {LaunchPlan, LocalFactory} from "../script/LaunchPlan.sol";
import {MockNFT} from "./mocks/MockNFT.sol";
import {MockDelegateRegistry} from "./mocks/MockDelegateRegistry.sol";
import {MockStarter} from "./mocks/MockStarter.sol";

/// @dev $YOLO's first hour (NFT gate 0-30 min, buy tax 30% -> 0 in 30-60 min) and the gate itself.
contract YoloTokenTest is Test {
    address constant PM = address(0x4444);
    uint256 constant PER_NFT = 500_000e18;

    MockNFT nft;
    MockDelegateRegistry delegates;
    NftGate gate;
    YoloToken yolo;
    address factory = address(this);
    address treasury = makeAddr("treasury"); // the project wallet: tax recipient and treasury (a single project key, EOA)
    address bot = makeAddr("bot");
    address human = makeAddr("human");
    address cold = makeAddr("cold");
    address hot = makeAddr("hot");

    function setUp() public {
        vm.warp(1_800_000_000);
        nft = new MockNFT();
        delegates = new MockDelegateRegistry();
        gate = new NftGate(address(nft), address(delegates));
        yolo = new YoloToken(PM, address(gate), treasury);
        yolo.transfer(PM, 200_000_000e18); // the pool's seed: from the factory, never limited
        nft.mint(human, 1);
        nft.mint(human, 2);
        nft.mint(cold, 3);
    }

    function _buy(address to, uint256 amount) internal {
        vm.prank(PM);
        yolo.transfer(to, amount);
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = a;
    }

    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        (ids[0], ids[1]) = (a, b);
    }

    function _at(uint256 secondsAfterStart) internal {
        vm.warp(yolo.start() + secondsAfterStart);
    }

    // ------------------------------------------------------------------ token

    function test_SupplyAndFixedSchedule() public view {
        assertEq(yolo.totalSupply(), 1_000_000_000e18);
        assertEq(yolo.balanceOf(factory), 800_000_000e18);
        assertEq(yolo.launcher(), factory);
        assertEq(yolo.gate(), address(gate));
        assertEq(yolo.taxRecipient(), treasury);
        assertEq(yolo.start(), vm.getBlockTimestamp());
        assertEq(yolo.WHITELIST_SECONDS(), 30 minutes);
        assertEq(yolo.TAX_END_SECONDS(), 60 minutes);
        assertEq(yolo.TAX_START_BPS(), 3_000);
        assertEq(yolo.decimals(), 18);
        assertTrue(yolo.whitelistActive());
    }

    function test_ConstructorRejectsZeroPoolManagerOrSafe() public {
        vm.expectRevert(YoloToken.ZeroAddress.selector);
        new YoloToken(address(0), address(gate), treasury);
        vm.expectRevert(YoloToken.ZeroAddress.selector);
        new YoloToken(PM, address(gate), address(0));
        new YoloToken(PM, address(0), treasury); // no gate: no whitelist
    }

    function test_Whitelist_UnregisteredBuyerRefused() public {
        vm.prank(PM);
        vm.expectRevert(abi.encodeWithSelector(YoloToken.NotWhitelisted.selector, bot));
        yolo.transfer(bot, 1e18);
    }

    function test_Whitelist_AllowancePerNftAndCumulative() public {
        vm.prank(human);
        gate.register(_ids(1, 2));
        assertEq(gate.allowanceOf(human), 2 * PER_NFT);
        _buy(human, 600_000e18);
        assertEq(gate.left(address(yolo), human), 400_000e18);
        vm.prank(PM);
        vm.expectRevert(
            abi.encodeWithSelector(YoloToken.NftAllowanceExceeded.selector, human, 400_000e18, 400_000e18 + 1)
        );
        yolo.transfer(human, 400_000e18 + 1);
        _buy(human, 400_000e18); // exactly the rest
        assertEq(gate.left(address(yolo), human), 0);
        // what he holds does not count, what he bought does: selling does not refill the allowance
        vm.prank(human);
        yolo.transfer(PM, 1_000_000e18);
        vm.prank(PM);
        vm.expectRevert(abi.encodeWithSelector(YoloToken.NftAllowanceExceeded.selector, human, 0, 1));
        yolo.transfer(human, 1);
        assertEq(yolo.balanceOf(treasury), 0, "no tax in the whitelist window");
    }

    function test_Whitelist_DelegateRegistersForColdWallet() public {
        vm.prank(hot);
        vm.expectRevert(abi.encodeWithSelector(NftGate.NotOwnerOrDelegate.selector, 3, cold));
        gate.register(_ids(3));
        vm.prank(cold);
        delegates.delegateAll(hot, true);
        vm.prank(hot);
        gate.register(_ids(3));
        assertEq(gate.boundTo(3), hot, "bound to the hot wallet that registered");
        assertEq(gate.allowanceOf(hot), PER_NFT);
        assertEq(gate.allowanceOf(cold), 0);
        _buy(hot, PER_NFT);
        assertEq(yolo.balanceOf(hot), PER_NFT);
    }

    function test_Gate_NftBoundForGood_TransferGivesNoSecondAllowance() public {
        vm.prank(human);
        gate.register(_ids(1));
        vm.prank(human);
        nft.transferFrom(human, bot, 1);
        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(NftGate.AlreadyRegistered.selector, 1, human));
        gate.register(_ids(1));
        assertEq(gate.allowanceOf(human), PER_NFT, "the wallet that registered keeps it");
        assertEq(gate.allowanceOf(bot), 0);
        assertEq(gate.registeredCount(), 1);
    }

    function test_Gate_RegisterChecks() public {
        vm.prank(human);
        vm.expectRevert(NftGate.NoTokens.selector);
        gate.register(new uint256[](0));
        vm.prank(human);
        vm.expectRevert(abi.encodeWithSelector(NftGate.AlreadyRegistered.selector, 1, human));
        gate.register(_ids(1, 1)); // the same NFT twice in one call
        vm.prank(human);
        vm.expectRevert(); // no such NFT: ownerOf reverts
        gate.register(_ids(999));
        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(NftGate.NotOwnerOrDelegate.selector, 1, human));
        gate.register(_ids(1));
        vm.expectEmit(address(gate));
        emit NftGate.Registered(human, 1);
        vm.prank(human);
        gate.register(_ids(1, 2));
        assertEq(gate.registeredCount(), 2);
        assertEq(gate.nftsOf(human), 2);
    }

    function test_Gate_BooksPerCallingToken() public {
        vm.prank(human);
        gate.register(_ids(1));
        // anyone calling consume only spends his own books
        vm.prank(bot);
        gate.consume(human, PER_NFT);
        assertEq(gate.used(bot, human), PER_NFT);
        assertEq(gate.left(address(yolo), human), PER_NFT);
        _buy(human, PER_NFT);
        // a buy that does not fit is not booked
        vm.prank(bot);
        (uint256 allowance, uint256 usedBefore) = gate.consume(human, 1);
        assertEq(allowance, PER_NFT);
        assertEq(usedBefore, PER_NFT);
        assertEq(gate.used(bot, human), PER_NFT);
    }

    function test_Whitelist_BoundaryAtMinute30() public {
        _at(30 minutes - 1);
        assertTrue(yolo.whitelistActive());
        assertEq(yolo.buyTaxBps(), 0);
        vm.prank(PM);
        vm.expectRevert(abi.encodeWithSelector(YoloToken.NotWhitelisted.selector, bot));
        yolo.transfer(bot, 1_000e18);
        _at(30 minutes);
        assertFalse(yolo.whitelistActive());
        assertEq(yolo.buyTaxBps(), 3_000);
        _buy(bot, 1_000e18);
        assertEq(yolo.balanceOf(bot), 700e18, "30% at minute 30");
        assertEq(yolo.balanceOf(treasury), 300e18);
    }

    function test_Tax_ExactAmounts() public {
        uint256[6] memory at = [uint256(30 minutes), 31 minutes, 45 minutes, 59 minutes, 60 minutes - 1, 60 minutes];
        uint256 v = 1_000_000e18;
        uint256 paid;
        for (uint256 i; i < at.length; ++i) {
            _at(at[i]);
            uint256 expectTax = v * 3_000 * (60 minutes - at[i]) / (10_000 * 30 minutes);
            uint256 b0 = yolo.balanceOf(bot);
            _buy(bot, v);
            assertEq(yolo.balanceOf(bot) - b0, v - expectTax, "buyer gets the rest");
            paid += expectTax;
            assertEq(yolo.balanceOf(treasury), paid, "the tax goes to the treasury");
        }
        // the figures, spelled out: 30%, 29%, 15%, 1%, 1/1800 of 30%, 0
        assertEq(paid, 300_000e18 + 290_000e18 + 150_000e18 + 10_000e18 + uint256(1_000_000e18) * 3_000 / 18_000_000);
        _at(45 minutes);
        assertEq(yolo.buyTaxBps(), 1_500);
        _at(60 minutes);
        assertEq(yolo.buyTaxBps(), 0);
    }

    function test_Tax_RoundsDownAndDustIsFree() public {
        _at(59 minutes);
        _buy(bot, 99); // 99 x 3000 x 60 / 18,000,000 = 0.99 -> 0
        assertEq(yolo.balanceOf(bot), 99);
        assertEq(yolo.balanceOf(treasury), 0);
    }

    function test_AfterMinute60_PlainErc20() public {
        _at(60 minutes);
        assertFalse(yolo.whitelistActive());
        _buy(bot, 100_000_000e18);
        assertEq(yolo.balanceOf(bot), 100_000_000e18);
        _at(400 days);
        _buy(bot, 1e18);
        assertEq(yolo.balanceOf(treasury), 0);
    }

    function test_SellsTransfersAndTheLauncherAreFree() public {
        vm.prank(human);
        gate.register(_ids(1));
        _buy(human, PER_NFT);
        // whitelist window: a sell, a wallet transfer, the factory collecting fees from the pool
        vm.prank(human);
        yolo.transfer(PM, 100_000e18);
        vm.prank(human);
        yolo.transfer(bot, 100_000e18);
        _buy(factory, 50_000_000e18);
        yolo.transfer(bot, 1_000_000e18); // from the launcher: not a buy
        // tax window: the same, untaxed
        _at(40 minutes);
        vm.prank(bot);
        yolo.transfer(PM, 100_000e18);
        vm.prank(bot);
        yolo.transfer(human, 100_000e18);
        _buy(factory, 1_000e18);
        assertEq(yolo.balanceOf(treasury), 0);
        // a zero-amount transfer out of the pool is no buy
        vm.prank(PM);
        yolo.transfer(cold, 0);
    }

    function test_GateWithoutCode_NoWhitelist_TaxStays() public {
        YoloToken bare = new YoloToken(PM, address(0xDEAD), treasury); // e.g. a chain without the gate
        bare.transfer(PM, 200_000_000e18);
        assertFalse(bare.whitelistActive());
        vm.prank(PM);
        bare.transfer(bot, 50_000_000e18);
        assertEq(bare.balanceOf(bot), 50_000_000e18);
        vm.warp(bare.start() + 30 minutes);
        vm.prank(PM);
        bare.transfer(bot, 1_000e18);
        assertEq(bare.balanceOf(treasury), 300e18);
    }

    // ------------------------------------------------------------------ vestings

    function _fund(ProjectVesting v, uint256 amount) internal {
        yolo.transfer(address(v), amount);
    }

    function test_DevVesting_Linear12Months_NoCliff() public {
        // the YoloSplitter's place: the only starter (swarm audit #2)
        MockStarter st = new MockStarter(abi.encodePacked(type(DevVesting).creationCode, abi.encode(treasury)));
        DevVesting v = DevVesting(st.vesting());
        _fund(v, 77_777_777e18);
        vm.prank(bot);
        v.release(address(yolo)); // anyone else: pays what is free (0), starts no clock
        assertEq(v.startOf(address(yolo)), 0);
        st.start(address(yolo)); // the split starts the clock when the token arrives (A-03); pays 0 here
        assertEq(v.startOf(address(yolo)), block.timestamp);
        assertEq(v.releasable(address(yolo)), 0);
        skip(1 days);
        assertEq(v.releasable(address(yolo)), uint256(77_777_777e18) * 1 days / 365 days, "streams from day one");
        skip(182 days - 1 days);
        assertEq(v.releasable(address(yolo)), uint256(77_777_777e18) * 182 days / 365 days);
        vm.prank(bot); // anyone may release, only the beneficiary is paid
        v.release(address(yolo));
        assertEq(yolo.balanceOf(treasury), uint256(77_777_777e18) * 182 days / 365 days);
        skip(183 days);
        assertEq(v.releasable(address(yolo)) + yolo.balanceOf(treasury), 77_777_777e18);
    }

    function test_IncentivesVesting_QuarterAtOnce_RestLinear24Months() public {
        MockStarter st = new MockStarter(abi.encodePacked(type(IncentivesVesting).creationCode, abi.encode(treasury)));
        IncentivesVesting v = IncentivesVesting(st.vesting());
        _fund(v, 250_000_000e18);
        assertEq(v.releasable(address(yolo)), 62_500_000e18, "a quarter at once");
        vm.prank(bot); // anyone may release, only the beneficiary is paid; only the starter starts the clock
        v.release(address(yolo));
        assertEq(yolo.balanceOf(treasury), 62_500_000e18);
        assertEq(v.startOf(address(yolo)), 0);
        st.start(address(yolo));
        assertEq(v.startOf(address(yolo)), block.timestamp);
        skip(365 days);
        assertEq(v.releasable(address(yolo)), 93_750_000e18, "half of the 187.5M stream after 12 months");
        skip(365 days - 1);
        assertLt(v.releasable(address(yolo)) + yolo.balanceOf(treasury), 250_000_000e18);
        skip(1);
        assertEq(v.releasable(address(yolo)) + yolo.balanceOf(treasury), 250_000_000e18, "all at day 730");
    }

    function test_TeamVesting_Linear12Months_NoCliff() public {
        MockStarter st = new MockStarter(abi.encodePacked(type(TeamVesting).creationCode, abi.encode(treasury)));
        TeamVesting v = TeamVesting(st.vesting());
        _fund(v, 50_000_000e18);
        st.start(address(yolo)); // the split starts the clock when the token arrives (A-03); pays 0 here
        assertEq(v.startOf(address(yolo)), block.timestamp);
        assertEq(v.releasable(address(yolo)), 0);
        skip(1 days);
        assertEq(v.releasable(address(yolo)), uint256(50_000_000e18) * 1 days / 365 days, "streams from day one");
        skip(365 days - 1 days - 1);
        assertLt(v.releasable(address(yolo)), 50_000_000e18);
        skip(1);
        assertEq(v.releasable(address(yolo)), 50_000_000e18, "all at day 365");
    }

    function test_TreasuryVesting_ThirdAtOnce_RestLinear12Months() public {
        MockStarter st = new MockStarter(abi.encodePacked(type(TreasuryVesting).creationCode, abi.encode(treasury)));
        TreasuryVesting v = TreasuryVesting(st.vesting());
        _fund(v, 222_222_223e18);
        assertEq(v.releasable(address(yolo)), 74_074_074e18, "a third at once");
        vm.prank(bot);
        v.release(address(yolo));
        assertEq(yolo.balanceOf(treasury), 74_074_074e18);
        st.start(address(yolo)); // the starter starts the clock
        skip(1 days);
        assertEq(v.releasable(address(yolo)), uint256(148_148_149e18) * 1 days / 365 days, "the rest streams, no cliff");
        skip(365 days - 1 days - 1);
        assertLt(v.releasable(address(yolo)) + yolo.balanceOf(treasury), 222_222_223e18);
        skip(1);
        assertEq(v.releasable(address(yolo)) + yolo.balanceOf(treasury), 222_222_223e18, "all at day 365");
    }

    /// A treasury a few wei short (the factory's rounding) still opens its fixed third at once; less than the third
    /// arriving opens all of it.
    function test_TreasuryVesting_ShortRemainder() public {
        TreasuryVesting v = new TreasuryVesting(treasury);
        _fund(v, 222_222_223e18 - 3);
        assertEq(v.releasable(address(yolo)), 74_074_074e18);
        TreasuryVesting w = new TreasuryVesting(treasury);
        _fund(w, 1_000e18);
        assertEq(w.releasable(address(yolo)), 1_000e18);
    }

    function test_VestingBounds() public {
        vm.expectRevert(ProjectVesting.BadSchedule.selector);
        new ProjectVesting(address(0), 0, 365 days);
        vm.expectRevert(ProjectVesting.BadSchedule.selector);
        new ProjectVesting(treasury, 0, 3651 days);
        vm.expectRevert(ProjectVesting.BadSchedule.selector);
        new ProjectVesting(treasury, 0, 0);
        vm.expectRevert(ProjectVesting.BadSchedule.selector);
        new TeamVesting(address(0));
        vm.expectRevert(ProjectVesting.BadSchedule.selector);
        new DevVesting(address(0));
    }

    // ------------------------------------------------------------------ splitter

    function _splitter() internal returns (YoloSplitter sp, address[5] memory to) {
        to = [makeAddr("incentives"), makeAddr("dev"), makeAddr("team"), makeAddr("treasuryVesting"), makeAddr("stabilizer")];
        sp = new YoloSplitter(to[0], to[1], to[2], to[3], to[4]);
    }

    function test_Splitter_FixedSharesAndDustToTreasury() public {
        (YoloSplitter sp, address[5] memory to) = _splitter();
        _buy(factory, 5e18 + 7); // the factory takes some back from the pool (exempt)
        yolo.transfer(address(sp), 527_777_777e18);
        vm.expectRevert(abi.encodeWithSelector(YoloSplitter.NotArrived.selector, 527_777_777e18));
        sp.split(address(yolo));
        yolo.transfer(address(sp), 222_222_223e18 + 7); // the factory's remainder carries rounding dust
        vm.prank(bot);
        sp.split(address(yolo));
        assertEq(yolo.balanceOf(to[0]), 250_000_000e18, "incentives 25%");
        assertEq(yolo.balanceOf(to[1]), 77_777_777e18, "dev 7.777777%");
        assertEq(yolo.balanceOf(to[2]), 50_000_000e18, "team 5%");
        assertEq(yolo.balanceOf(to[3]), 222_222_223e18 + 7, "treasury: the rest + dust");
        assertEq(yolo.balanceOf(to[4]), 150_000_000e18, "Stabilizer 15%");
        assertEq(yolo.balanceOf(address(sp)), 0);
        yolo.transfer(address(sp), 5e18); // later arrivals: the treasury's
        sp.split(address(yolo));
        assertEq(yolo.balanceOf(to[3]), 222_222_228e18 + 7);
    }

    /// A remainder a little short of 750M (the factory rounds the pool seed) still splits: the treasury takes the gap.
    function test_Splitter_RemainderShortOf750M() public {
        (YoloSplitter sp, address[5] memory to) = _splitter();
        yolo.transfer(address(sp), 750_000_000e18 - 3);
        sp.split(address(yolo));
        assertEq(yolo.balanceOf(to[3]), 222_222_223e18 - 3);
        assertEq(yolo.balanceOf(to[4]), 150_000_000e18, "the fixed shares are whole");
        assertEq(yolo.balanceOf(to[1]), 77_777_777e18, "the fixed shares are whole");
    }

    function test_Splitter_RejectsZeroAddresses() public {
        vm.expectRevert(YoloSplitter.ZeroAddress.selector);
        new YoloSplitter(address(1), address(2), address(3), address(4), address(0));
        vm.expectRevert(YoloSplitter.ZeroAddress.selector);
        new YoloSplitter(address(0), address(2), address(3), address(4), address(5));
    }

    // ------------------------------------------------------------------ launch 0 as planned

    /// The plan's launch 0 on a local factory, the token wired to its gate, the factory's 75% split: the shares of
    /// the tokenomics add up to the supply.
    function test_GenesisLaunch_SharesAddUp() public {
        LocalFactory f = new LocalFactory();
        LaunchPlan.Owners memory o =
            LaunchPlan.Owners(treasury, makeAddr("incentives"), makeAddr("stab"), makeAddr("dev"), makeAddr("team"));
        (bytes[] memory codes, bytes32[] memory names, LaunchPlan.Genesis memory g) =
            LaunchPlan.genesisLaunchWith(f, 0, o, address(nft), address(delegates));
        assertEq(codes.length, 6);
        assertEq(names[1], bytes32("IncentivesVesting"));
        assertEq(names[5], bytes32("YoloSplitter"));
        f.launchContracts(0, codes);
        YoloToken t = new YoloToken(PM, g.gate, treasury);
        t.transfer(PM, 150_000_000e18); // pool 15%
        t.transfer(makeAddr("swarm"), 100_000_000e18); // swarm 10%
        t.transfer(g.splitter, 750_000_000e18); // remainderTo
        YoloSplitter(g.splitter).split(address(t));
        // the split starts the clocks (A-03) and pays the at-once parts in the same transaction
        assertEq(t.balanceOf(g.incentives) + t.balanceOf(o.incentives), 250_000_000e18);
        assertEq(t.balanceOf(o.stabilizer), 150_000_000e18);
        assertEq(t.balanceOf(g.dev), 77_777_777e18);
        assertEq(t.balanceOf(g.team), 50_000_000e18);
        assertEq(t.balanceOf(g.treasury) + t.balanceOf(o.treasury), 222_222_223e18);
        assertEq(
            t.balanceOf(PM) + t.balanceOf(makeAddr("swarm")) + t.balanceOf(g.incentives) + t.balanceOf(o.stabilizer)
                + t.balanceOf(g.dev) + t.balanceOf(g.team) + t.balanceOf(g.treasury) + t.balanceOf(o.incentives)
                + t.balanceOf(o.treasury),
            t.totalSupply()
        );
        assertEq(ProjectVesting(g.incentives).beneficiary(), o.incentives);
        assertEq(ProjectVesting(g.dev).beneficiary(), o.dev);
        assertEq(ProjectVesting(g.team).beneficiary(), o.team);
        assertEq(ProjectVesting(g.treasury).beneficiary(), o.treasury);
        assertEq(t.balanceOf(o.incentives), 62_500_000e18, "incentives: a quarter at once");
        assertEq(t.balanceOf(o.treasury), 74_074_074e18, "treasury: a third at once");
        assertEq(ProjectVesting(g.dev).startOf(address(t)), block.timestamp, "the clocks start at the split");
        assertEq(ProjectVesting(g.incentives).releasable(address(t)), 0, "nothing more until time passes");
        assertEq(address(NftGate(g.gate).nft()), address(nft));
        vm.prank(human);
        NftGate(g.gate).register(_ids(1));
        vm.prank(PM);
        t.transfer(human, PER_NFT);
    }
}
