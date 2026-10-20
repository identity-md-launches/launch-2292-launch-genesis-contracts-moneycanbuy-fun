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
import {MockStarter} from "./mocks/MockStarter.sol";

/// @dev $YOLO's opening (no buy before openAt), its first hour after openAt (snapshot wallets 0-30 min,
///      buy tax 30% -> 0 in 30-60 min, sell tax 30% in 0-30 min and 30% -> 0 in 30-60 min) and the snapshot gate.
contract YoloTokenTest is Test {
    address constant PM = address(0x4444);
    uint256 constant PER_NFT = 500_000e18;
    uint256 constant OPEN_DELAY = 40 minutes;

    MockNFT nft;
    NftGate gate;
    YoloToken yolo;
    address factory = address(this);
    address safe = makeAddr("treasury"); // the project wallet: tax recipient, treasury, snapshot writer
    address bot = makeAddr("bot");
    address human = makeAddr("human");
    address small = makeAddr("small");
    address router = makeAddr("router");

    function setUp() public {
        vm.warp(1_800_000_000);
        nft = new MockNFT();
        gate = new NftGate(address(nft), safe);
        yolo = new YoloToken(PM, address(gate), safe, block.timestamp + OPEN_DELAY);
        yolo.transfer(PM, 200_000_000e18); // the pool's seed: from the factory, never limited
        nft.mint(human, 1);
        nft.mint(human, 2);
        nft.mint(small, 3);
    }

    function _buy(address to, uint256 amount) internal {
        vm.prank(PM);
        yolo.transfer(to, amount);
    }

    /// @dev the snapshot as the script writes it: human 2 NFTs, small 1; sealed by the project wallet
    function _snapshot() internal {
        address[] memory w = new address[](2);
        uint256[] memory n = new uint256[](2);
        (w[0], n[0], w[1], n[1]) = (human, 2, small, 1);
        vm.prank(safe);
        gate.record(w, n);
        vm.prank(safe);
        gate.seal(12_345);
    }

    function _at(uint256 secondsAfterOpen) internal {
        vm.warp(yolo.openAt() + secondsAfterOpen);
    }

    function _one(address a, uint256 c) internal pure returns (address[] memory w, uint256[] memory n) {
        w = new address[](1);
        n = new uint256[](1);
        (w[0], n[0]) = (a, c);
    }

    // ------------------------------------------------------------------ token

    function test_SupplyAndFixedSchedule() public view {
        assertEq(yolo.totalSupply(), 1_000_000_000e18);
        assertEq(yolo.balanceOf(factory), 800_000_000e18);
        assertEq(yolo.launcher(), factory);
        assertEq(yolo.gate(), address(gate));
        assertEq(yolo.taxRecipient(), safe);
        assertEq(yolo.openAt(), vm.getBlockTimestamp() + OPEN_DELAY);
        assertEq(yolo.WHITELIST_SECONDS(), 30 minutes);
        assertEq(yolo.TAX_END_SECONDS(), 60 minutes);
        assertEq(yolo.TAX_START_BPS(), 3_000);
        assertEq(yolo.MAX_OPEN_DELAY(), 30 days);
        assertEq(yolo.decimals(), 18);
        assertFalse(yolo.tradingOpen());
        assertFalse(yolo.whitelistActive(), "the window starts at openAt");
        assertEq(yolo.buyTaxBps(), 0);
        assertEq(yolo.sellTaxBps(), 0);
    }

    function test_ConstructorRejectsZeroPoolManagerOrSafe() public {
        vm.expectRevert(YoloToken.ZeroAddress.selector);
        new YoloToken(address(0), address(gate), safe, block.timestamp);
        vm.expectRevert(YoloToken.ZeroAddress.selector);
        new YoloToken(PM, address(gate), address(0), block.timestamp);
        new YoloToken(PM, address(0), safe, block.timestamp); // no gate: no whitelist
    }

    /// openAt is fixed at deployment: not in the past, at most 30 days ahead.
    function test_OpenAtBounds() public {
        vm.expectRevert(abi.encodeWithSelector(YoloToken.BadOpenAt.selector, block.timestamp - 1));
        new YoloToken(PM, address(gate), safe, block.timestamp - 1);
        vm.expectRevert(abi.encodeWithSelector(YoloToken.BadOpenAt.selector, block.timestamp + 30 days + 1));
        new YoloToken(PM, address(gate), safe, block.timestamp + 30 days + 1);
        assertEq(new YoloToken(PM, address(gate), safe, block.timestamp).openAt(), block.timestamp);
        assertEq(new YoloToken(PM, address(gate), safe, block.timestamp + 30 days).openAt(), block.timestamp + 30 days);
    }

    /// Before openAt nobody buys from the pool, a snapshot wallet neither; the pool is seeded and sells, transfers
    /// and the launcher work.
    function test_BeforeOpenAt_NobodyBuys() public {
        _snapshot();
        uint256 openAt = yolo.openAt();
        uint256[3] memory at = [uint256(0), 1, OPEN_DELAY - 1];
        for (uint256 i; i < at.length; ++i) {
            vm.warp(1_800_000_000 + at[i]);
            vm.prank(PM);
            vm.expectRevert(abi.encodeWithSelector(YoloToken.TradingNotOpen.selector, openAt));
            yolo.transfer(human, 1e18);
            vm.prank(PM);
            vm.expectRevert(abi.encodeWithSelector(YoloToken.TradingNotOpen.selector, openAt));
            yolo.transfer(bot, 1e18);
        }
        assertFalse(yolo.tradingOpen());
        assertEq(yolo.buyTaxBps(), 0);
        // the launcher adds liquidity and takes from the pool (its fee claims), anyone sells or sends
        yolo.transfer(PM, 1_000e18);
        _buy(factory, 1_000e18);
        yolo.transfer(human, 10_000e18);
        vm.prank(human);
        yolo.transfer(PM, 5_000e18);
        vm.prank(human);
        yolo.transfer(bot, 1_000e18);
        vm.prank(PM);
        yolo.transfer(human, 0); // zero is no buy
        _at(0);
        assertTrue(yolo.tradingOpen());
        assertTrue(yolo.whitelistActive());
        _buy(human, 1e18);
    }

    function test_Whitelist_WalletOutsideSnapshotRefused() public {
        _snapshot();
        _at(0);
        vm.prank(PM);
        vm.expectRevert(abi.encodeWithSelector(YoloToken.NotWhitelisted.selector, bot));
        yolo.transfer(bot, 1e18);
    }

    function test_Whitelist_AllowancePerNftAndCumulative() public {
        _snapshot();
        assertEq(gate.allowanceOf(human), 2 * PER_NFT);
        _at(5);
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
        yolo.transfer(PM, 700_000e18); // the whole 1M of the wallet: 700k into the pool, 300k sell tax
        vm.prank(PM);
        vm.expectRevert(abi.encodeWithSelector(YoloToken.NftAllowanceExceeded.selector, human, 0, 1));
        yolo.transfer(human, 1);
        _buy(small, PER_NFT);
        assertEq(yolo.balanceOf(safe), 300_000e18, "buys untaxed in the window, the one sell paid 30%");
    }

    /// The snapshot is what counts: an NFT moved after it gives the new owner nothing and takes nothing from the
    /// wallet listed. A wallet that held none at the snapshot and buys one later is refused.
    function test_Snapshot_NftMovedAfterSnapshotGivesNothing() public {
        _snapshot();
        vm.prank(human);
        nft.transferFrom(human, bot, 1);
        nft.mint(bot, 77);
        _at(1);
        vm.prank(PM);
        vm.expectRevert(abi.encodeWithSelector(YoloToken.NotWhitelisted.selector, bot));
        yolo.transfer(bot, 1e18);
        assertEq(gate.allowanceOf(human), 2 * PER_NFT, "the listed wallet keeps its two NFTs' allowance");
        _buy(human, 2 * PER_NFT);
    }

    /// A route paying a router or another contract first is refused in the window: it is not in the snapshot.
    function test_Whitelist_IntermediaryRefused() public {
        _snapshot();
        _at(1);
        vm.prank(PM);
        vm.expectRevert(abi.encodeWithSelector(YoloToken.NotWhitelisted.selector, router));
        yolo.transfer(router, 1_000e18);
        _buy(human, 1_000e18); // the same buy straight to the wallet (TAKE_ALL)
    }

    /// No snapshot sealed before openAt: nobody buys in minutes 0-30 (`SnapshotNotSealed`), the tax window follows.
    function test_UnsealedSnapshot_WindowClosedToAll() public {
        address[] memory w;
        uint256[] memory n;
        (w, n) = _one(human, 2);
        vm.prank(safe);
        gate.record(w, n);
        _at(0);
        vm.prank(PM);
        vm.expectRevert(YoloToken.SnapshotNotSealed.selector);
        yolo.transfer(human, 1e18);
        vm.prank(PM);
        vm.expectRevert(YoloToken.SnapshotNotSealed.selector);
        yolo.transfer(bot, 1e18);
        // sealed only after openAt: still closed for the whole window
        vm.prank(safe);
        gate.seal(1);
        _at(29 minutes);
        vm.prank(PM);
        vm.expectRevert(YoloToken.SnapshotNotSealed.selector);
        yolo.transfer(human, 1e18);
        _at(30 minutes);
        _buy(bot, 1_000e18);
        assertEq(yolo.balanceOf(bot), 700e18, "the tax window as always");
    }

    /// The snapshot must be sealed strictly before openAt: a seal in the opening second does not count.
    function test_SealAtOpenAtDoesNotCount() public {
        address[] memory w;
        uint256[] memory n;
        (w, n) = _one(human, 1);
        vm.prank(safe);
        gate.record(w, n);
        _at(0);
        vm.prank(safe);
        gate.seal(1);
        vm.prank(PM);
        vm.expectRevert(YoloToken.SnapshotNotSealed.selector);
        yolo.transfer(human, 1e18);
    }

    // ------------------------------------------------------------------ gate (snapshot)

    function test_Gate_OnlyWriterRecordsAndSeals() public {
        (address[] memory w, uint256[] memory n) = _one(human, 2);
        vm.prank(bot);
        vm.expectRevert(NftGate.NotWriter.selector);
        gate.record(w, n);
        vm.expectRevert(NftGate.NotWriter.selector); // not even the token's launcher
        gate.record(w, n);
        vm.prank(safe);
        gate.record(w, n);
        vm.prank(bot);
        vm.expectRevert(NftGate.NotWriter.selector);
        gate.seal(1);
        assertEq(gate.writer(), safe);
        assertEq(gate.nft(), address(nft));
        vm.expectRevert(NftGate.NotWriter.selector);
        new NftGate(address(nft), address(0));
    }

    function test_Gate_RecordChecksAndEvents() public {
        vm.startPrank(safe);
        vm.expectRevert(NftGate.BadBatch.selector);
        gate.record(new address[](0), new uint256[](0));
        vm.expectRevert(NftGate.BadBatch.selector);
        gate.record(new address[](2), new uint256[](1));
        (address[] memory w, uint256[] memory n) = _one(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(NftGate.ZeroEntry.selector, 0));
        gate.record(w, n);
        (w, n) = _one(human, 0);
        vm.expectRevert(abi.encodeWithSelector(NftGate.ZeroEntry.selector, 0));
        gate.record(w, n);
        vm.expectRevert(NftGate.EmptySnapshot.selector);
        gate.seal(1);
        (w, n) = _one(human, 2);
        vm.expectEmit(address(gate));
        emit NftGate.Recorded(human, 2);
        gate.record(w, n);
        vm.expectRevert(abi.encodeWithSelector(NftGate.AlreadyRecorded.selector, human));
        gate.record(w, n); // each wallet once
        address[] memory w2 = new address[](2);
        uint256[] memory n2 = new uint256[](2);
        (w2[0], n2[0], w2[1], n2[1]) = (small, 1, small, 1);
        vm.expectRevert(abi.encodeWithSelector(NftGate.AlreadyRecorded.selector, small));
        gate.record(w2, n2); // twice in one batch
        (w2[1], n2[1]) = (bot, 5);
        gate.record(w2, n2);
        bytes32 h = keccak256(abi.encode(keccak256(abi.encode(bytes32(0), human, 2)), small, 1));
        h = keccak256(abi.encode(h, bot, 5));
        assertEq(gate.snapshotHash(), h, "running hash of the list in order");
        assertEq(gate.totalNfts(), 8);
        assertEq(gate.walletCount(), 3);
        assertEq(gate.allowanceOf(bot), 5 * PER_NFT);
        vm.expectEmit(address(gate));
        emit NftGate.Sealed(3, 8, 23_456_789, h);
        gate.seal(23_456_789);
        vm.stopPrank();
        assertEq(gate.sealedAt(), block.timestamp);
        assertEq(gate.snapshotBlock(), 23_456_789);
    }

    /// The seal is for good: no record, no second seal, by anyone, at any time.
    function test_Gate_SealIsIrreversible() public {
        _snapshot();
        uint256 sealedAt = gate.sealedAt();
        (address[] memory w, uint256[] memory n) = _one(bot, 1);
        vm.prank(safe);
        vm.expectRevert(NftGate.AlreadySealed.selector);
        gate.record(w, n);
        vm.prank(safe);
        vm.expectRevert(NftGate.AlreadySealed.selector);
        gate.seal(1);
        skip(400 days);
        vm.prank(safe);
        vm.expectRevert(NftGate.AlreadySealed.selector);
        gate.record(w, n);
        assertEq(gate.sealedAt(), sealedAt);
        assertEq(gate.allowanceOf(bot), 0);
        assertEq(gate.walletCount(), 2);
        assertEq(gate.totalNfts(), 3);
    }

    function test_Gate_ConsumeNeedsSealAndBooksPerCallingToken() public {
        vm.prank(bot);
        vm.expectRevert(NftGate.NotSealed.selector);
        gate.consume(human, 1);
        _snapshot();
        // anyone calling consume only spends his own books
        vm.prank(bot);
        gate.consume(human, PER_NFT);
        assertEq(gate.used(bot, human), PER_NFT);
        assertEq(gate.left(address(yolo), human), 2 * PER_NFT);
        _at(0);
        _buy(human, 2 * PER_NFT);
        // a buy that does not fit is not booked
        vm.prank(bot);
        (uint256 allowance, uint256 usedBefore) = gate.consume(human, 2 * PER_NFT);
        assertEq(allowance, 2 * PER_NFT);
        assertEq(usedBefore, PER_NFT);
        assertEq(gate.used(bot, human), PER_NFT);
    }

    function test_Whitelist_BoundaryAtMinute30() public {
        _snapshot();
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
        assertEq(yolo.balanceOf(bot), 700e18, "30% at minute 30 after openAt");
        assertEq(yolo.balanceOf(safe), 300e18);
    }

    /// The tax counts from openAt, not from the deployment.
    function test_Tax_ExactAmounts() public {
        _snapshot();
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
            assertEq(yolo.balanceOf(safe), paid, "the tax goes to the treasury");
        }
        // the figures, spelled out: 30%, 29%, 15%, 1%, 1/1800 of 30%, 0
        assertEq(paid, 300_000e18 + 290_000e18 + 150_000e18 + 10_000e18 + uint256(1_000_000e18) * 3_000 / 18_000_000);
        _at(45 minutes);
        assertEq(yolo.buyTaxBps(), 1_500);
        _at(60 minutes);
        assertEq(yolo.buyTaxBps(), 0);
        // 30 minutes after the DEPLOYMENT (10 minutes before openAt) there is no tax: there is no buy at all
        vm.warp(1_800_000_000 + 30 minutes);
        assertEq(yolo.buyTaxBps(), 0);
    }

    function test_Tax_RoundsDownAndDustIsFree() public {
        _at(59 minutes);
        _buy(bot, 99); // 99 x 3000 x 60 / 18,000,000 = 0.99 -> 0
        assertEq(yolo.balanceOf(bot), 99);
        assertEq(yolo.balanceOf(safe), 0);
    }

    function test_AfterMinute60_PlainErc20() public {
        _at(60 minutes);
        assertFalse(yolo.whitelistActive());
        _buy(bot, 100_000_000e18);
        assertEq(yolo.balanceOf(bot), 100_000_000e18);
        _at(400 days);
        _buy(bot, 1e18);
        assertEq(yolo.balanceOf(safe), 0);
    }

    /// Transfers between wallets and everything of the launcher are never taxed, in any window; a sell before
    /// openAt neither.
    function test_TransfersAndTheLauncherAreFree() public {
        _snapshot();
        yolo.transfer(human, 1_000_000e18);
        vm.prank(human);
        yolo.transfer(PM, 10_000e18); // before openAt: no tax
        _at(1);
        _buy(human, PER_NFT);
        vm.prank(human);
        yolo.transfer(bot, 100_000e18);
        yolo.transfer(PM, 1_000_000e18); // the factory adds liquidity
        _buy(factory, 50_000_000e18); // the factory collects fees from the pool
        yolo.transfer(bot, 1_000_000e18); // from the launcher: not a buy
        _at(40 minutes);
        vm.prank(bot);
        yolo.transfer(human, 100_000e18);
        yolo.transfer(PM, 1_000e18);
        _buy(factory, 1_000e18);
        assertEq(yolo.balanceOf(safe), 0);
        // zero-amount transfers out of and into the pool are no trade
        vm.prank(PM);
        yolo.transfer(small, 0);
        vm.prank(bot);
        yolo.transfer(PM, 0);
        assertEq(yolo.balanceOf(safe), 0);
    }

    /// Minutes 0-30 every sell pays 30%, minutes 30-60 30% -> 0, then none. The tax is
    /// taken on top of what goes into the pool and is that share of all the seller parts with.
    function test_SellTax_ExactAmounts() public {
        _snapshot();
        yolo.transfer(bot, 10_000_000e18);
        uint256[7] memory at = [uint256(0), 1, 30 minutes - 1, 30 minutes, 45 minutes, 60 minutes - 1, 60 minutes];
        uint256[7] memory bps = [uint256(3_000), 3_000, 3_000, 3_000, 1_500, 1, 0];
        uint256 v = 700_000e18;
        uint256 paid;
        for (uint256 i; i < at.length; ++i) {
            _at(at[i]);
            assertEq(yolo.sellTaxBps(), bps[i], "sell tax bps");
            uint256 num = at[i] < 30 minutes ? 3_000 * 30 minutes : 3_000 * (60 minutes - at[i]);
            uint256 expectTax = v * num / (10_000 * 30 minutes - num);
            assertEq(yolo.sellTax(v), expectTax);
            uint256 b0 = yolo.balanceOf(bot);
            uint256 p0 = yolo.balanceOf(PM);
            vm.prank(bot);
            yolo.transfer(PM, v);
            assertEq(yolo.balanceOf(PM) - p0, v, "the pool gets exactly what the swap settles");
            assertEq(b0 - yolo.balanceOf(bot), v + expectTax, "the seller pays the tax on top");
            paid += expectTax;
            assertEq(yolo.balanceOf(safe), paid, "the tax goes to the treasury");
        }
        // the figures, spelled out: 700k into the pool at 30% = 300k tax (30% of 1M), at 15% = 123,529.41...
        assertEq(uint256(700_000e18) * 3_000 / 7_000, 300_000e18);
        assertEq(uint256(700_000e18) * 1_500 / 8_500, uint256(700_000e18) * 3_000 * 15 minutes / (10_000 * 30 minutes - 3_000 * 15 minutes));
        // the share of all the seller parted with: 30% and 15%
        _at(10 minutes);
        uint256 t = yolo.sellTax(700_000e18);
        assertEq(t * 10_000 / (700_000e18 + t), 3_000);
        _at(45 minutes);
        t = yolo.sellTax(850_000e18);
        assertEq(t, 150_000e18, "sell 1M at minute 45: 850k into the pool, 150k (15%) to the treasury");
        _at(60 minutes);
        assertEq(yolo.sellTax(1e24), 0);
        // before openAt: no sell tax
        vm.warp(1_800_000_000);
        assertEq(yolo.sellTaxBps(), 0);
        assertEq(yolo.sellTax(1e24), 0);
    }

    /// Both sides in one window: a snapshot buy in minutes 0-30 is untaxed, its sell pays 30%; at minute 45 a buy
    /// and a sell both pay 15%.
    function test_SellTax_BuyFreeSellTaxedInWindow_BothAt45() public {
        _snapshot();
        _at(5);
        _buy(human, 1_000_000e18);
        assertEq(yolo.balanceOf(human), 1_000_000e18, "a snapshot buy in the window is untaxed");
        assertEq(yolo.balanceOf(safe), 0);
        vm.prank(human);
        yolo.transfer(PM, 700_000e18);
        assertEq(yolo.balanceOf(human), 0, "selling 1M of the wallet: 700k into the pool, 300k tax");
        assertEq(yolo.balanceOf(safe), 300_000e18);
        _at(45 minutes);
        _buy(bot, 1_000_000e18);
        assertEq(yolo.balanceOf(bot), 850_000e18, "a buy at minute 45 pays 15%");
        assertEq(yolo.balanceOf(safe), 450_000e18);
        vm.prank(bot);
        yolo.transfer(PM, 722_500e18); // 850k of the wallet: 722.5k into the pool, 127.5k (15%) tax
        assertEq(yolo.balanceOf(bot), 0);
        assertEq(yolo.balanceOf(safe), 577_500e18);
    }

    /// The tax is on top: a wallet cannot put its whole balance into the pool in the window, only 70% of it; a
    /// router pulling with an allowance takes the tax beyond the allowance (as Permit2 settles a v4 sell).
    function test_SellTax_OnTopOfBalanceAndAllowance() public {
        _snapshot();
        yolo.transfer(bot, 1_000e18);
        _at(10);
        vm.prank(bot);
        vm.expectRevert(); // ERC20InsufficientBalance: 1,000 + 428.57 tax
        yolo.transfer(PM, 1_000e18);
        vm.prank(bot);
        yolo.approve(router, 700e18);
        vm.prank(router);
        yolo.transferFrom(bot, PM, 700e18);
        assertEq(yolo.balanceOf(bot), 0);
        assertEq(yolo.balanceOf(safe), 300e18);
        assertEq(yolo.allowance(bot, router), 0, "the allowance covers what goes into the pool");
    }

    function test_SellTax_RoundsDownAndDustIsFree() public {
        yolo.transfer(bot, 1_000);
        _at(59 minutes); // 1% : 99 x 1/99 = 1 -> 98 x ... = 0
        vm.prank(bot);
        yolo.transfer(PM, 98);
        assertEq(yolo.balanceOf(safe), 0);
        assertEq(yolo.balanceOf(bot), 902);
    }

    function test_GateWithoutCode_NoWhitelist_TaxStays() public {
        YoloToken bare = new YoloToken(PM, address(0xDEAD), safe, block.timestamp + 10); // a chain without the gate
        bare.transfer(PM, 200_000_000e18);
        vm.prank(PM);
        vm.expectRevert(abi.encodeWithSelector(YoloToken.TradingNotOpen.selector, block.timestamp + 10));
        bare.transfer(bot, 1);
        vm.warp(bare.openAt());
        assertFalse(bare.whitelistActive());
        vm.prank(PM);
        bare.transfer(bot, 50_000_000e18);
        assertEq(bare.balanceOf(bot), 50_000_000e18);
        vm.warp(bare.openAt() + 30 minutes);
        vm.prank(PM);
        bare.transfer(bot, 1_000e18);
        assertEq(bare.balanceOf(safe), 300e18);
    }

    // ------------------------------------------------------------------ vestings

    function _fund(ProjectVesting v, uint256 amount) internal {
        yolo.transfer(address(v), amount);
    }

    function test_DevVesting_Linear12Months_NoCliff() public {
        // the YoloSplitter's place: the only starter (swarm audit 117cf05a #2)
        MockStarter st = new MockStarter(abi.encodePacked(type(DevVesting).creationCode, abi.encode(safe)));
        DevVesting v = DevVesting(st.vesting());
        _fund(v, 77_777_777e18);
        vm.prank(bot);
        v.release(address(yolo)); // anyone else: pays what is free (0), starts no clock
        assertEq(v.startOf(address(yolo)), 0);
        st.start(address(yolo)); // the split starts the clock when the token arrives; pays 0 here
        assertEq(v.startOf(address(yolo)), block.timestamp);
        assertEq(v.releasable(address(yolo)), 0);
        skip(1 days);
        assertEq(v.releasable(address(yolo)), uint256(77_777_777e18) * 1 days / 365 days, "streams from day one");
        skip(182 days - 1 days);
        assertEq(v.releasable(address(yolo)), uint256(77_777_777e18) * 182 days / 365 days);
        vm.prank(bot); // anyone may release, only the beneficiary is paid
        v.release(address(yolo));
        assertEq(yolo.balanceOf(safe), uint256(77_777_777e18) * 182 days / 365 days);
        skip(183 days);
        assertEq(v.releasable(address(yolo)) + yolo.balanceOf(safe), 77_777_777e18);
    }

    function test_IncentivesVesting_QuarterAtOnce_RestLinear24Months() public {
        MockStarter st = new MockStarter(abi.encodePacked(type(IncentivesVesting).creationCode, abi.encode(safe)));
        IncentivesVesting v = IncentivesVesting(st.vesting());
        _fund(v, 250_000_000e18);
        assertEq(v.releasable(address(yolo)), 62_500_000e18, "a quarter at once");
        vm.prank(bot); // anyone may release, only the beneficiary is paid; only the starter starts the clock
        v.release(address(yolo));
        assertEq(yolo.balanceOf(safe), 62_500_000e18);
        assertEq(v.startOf(address(yolo)), 0);
        st.start(address(yolo));
        assertEq(v.startOf(address(yolo)), block.timestamp);
        skip(365 days);
        assertEq(v.releasable(address(yolo)), 93_750_000e18, "half of the 187.5M stream after 12 months");
        skip(365 days - 1);
        assertLt(v.releasable(address(yolo)) + yolo.balanceOf(safe), 250_000_000e18);
        skip(1);
        assertEq(v.releasable(address(yolo)) + yolo.balanceOf(safe), 250_000_000e18, "all at day 730");
    }

    function test_TeamVesting_Linear12Months_NoCliff() public {
        MockStarter st = new MockStarter(abi.encodePacked(type(TeamVesting).creationCode, abi.encode(safe)));
        TeamVesting v = TeamVesting(st.vesting());
        _fund(v, 50_000_000e18);
        st.start(address(yolo)); // the split starts the clock when the token arrives; pays 0 here
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
        MockStarter st = new MockStarter(abi.encodePacked(type(TreasuryVesting).creationCode, abi.encode(safe)));
        TreasuryVesting v = TreasuryVesting(st.vesting());
        _fund(v, 222_222_223e18);
        assertEq(v.releasable(address(yolo)), 74_074_074e18, "a third at once");
        vm.prank(bot);
        v.release(address(yolo));
        assertEq(yolo.balanceOf(safe), 74_074_074e18);
        st.start(address(yolo)); // the starter starts the clock
        skip(1 days);
        assertEq(v.releasable(address(yolo)), uint256(148_148_149e18) * 1 days / 365 days, "the rest streams, no cliff");
        skip(365 days - 1 days - 1);
        assertLt(v.releasable(address(yolo)) + yolo.balanceOf(safe), 222_222_223e18);
        skip(1);
        assertEq(v.releasable(address(yolo)) + yolo.balanceOf(safe), 222_222_223e18, "all at day 365");
    }

    /// A treasury a few wei short (the factory's rounding) still opens its fixed third at once; less than the third
    /// arriving opens all of it.
    function test_TreasuryVesting_ShortRemainder() public {
        TreasuryVesting v = new TreasuryVesting(safe);
        _fund(v, 222_222_223e18 - 3);
        assertEq(v.releasable(address(yolo)), 74_074_074e18);
        TreasuryVesting w = new TreasuryVesting(safe);
        _fund(w, 1_000e18);
        assertEq(w.releasable(address(yolo)), 1_000e18);
    }

    function test_VestingBounds() public {
        vm.expectRevert(ProjectVesting.BadSchedule.selector);
        new ProjectVesting(address(0), 0, 365 days);
        vm.expectRevert(ProjectVesting.BadSchedule.selector);
        new ProjectVesting(safe, 0, 3651 days);
        vm.expectRevert(ProjectVesting.BadSchedule.selector);
        new ProjectVesting(safe, 0, 0);
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
            LaunchPlan.Owners(safe, makeAddr("incentives"), makeAddr("stab"), makeAddr("dev"), makeAddr("team"));
        (bytes[] memory codes, bytes32[] memory names, LaunchPlan.Genesis memory g) =
            LaunchPlan.genesisLaunchWith(f, 0, o, address(nft));
        assertEq(codes.length, 6);
        assertEq(names[1], bytes32("IncentivesVesting"));
        assertEq(names[5], bytes32("YoloSplitter"));
        f.launchContracts(0, codes);
        YoloToken t = new YoloToken(PM, g.gate, safe, block.timestamp + 1 hours);
        t.transfer(PM, 150_000_000e18); // pool 15%
        t.transfer(makeAddr("swarm"), 100_000_000e18); // swarm 10%
        t.transfer(g.splitter, 750_000_000e18); // remainderTo
        YoloSplitter(g.splitter).split(address(t));
        // the split starts the clocks and pays the at-once parts in the same transaction
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
        assertEq(NftGate(g.gate).nft(), address(nft));
        assertEq(NftGate(g.gate).writer(), safe, "the project wallet writes the snapshot");
        (address[] memory w, uint256[] memory n) = _one(human, 1);
        vm.prank(safe);
        NftGate(g.gate).record(w, n);
        vm.prank(safe);
        NftGate(g.gate).seal(block.number);
        vm.warp(t.openAt());
        vm.prank(PM);
        t.transfer(human, PER_NFT);
    }
}
