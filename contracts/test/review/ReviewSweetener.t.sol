// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";

import {Base} from "../Base.t.sol";
import {MockPoolManager, MockFeed, MockV3Pool} from "../YoloOracle.t.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {YoloSweetener} from "../../src/YoloSweetener.sol";
import {ITaskVault} from "../../src/interfaces/ITaskVault.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {
    ChainlinkUniV3PriceOracle,
    IAggregatorV3,
    IUniswapV3PoolObserve
} from "../../src/oracles/ChainlinkUniV3PriceOracle.sol";
import "../../src/VaultTypes.sol";

/// @dev YoloSweetener (a $YOLO bonus on top of a task) and the vault's handling of the YOLO price.
///      `test_Fixed_*` check a rule that closes a weakness; `test_Guard_*` hold properties that were checked and
///      found sound; `test_Observation_*` pin a documented low-severity property.
contract ReviewSweetenerTest is Base {
    uint8 internal constant REJECT = 2;

    function _sweeten(address who, uint256 taskId, uint256 amount) internal {
        vm.prank(who);
        sweetener.sweeten(taskId, amount);
    }

    /// The bonus is invisible to the vault, so a $25 ETH task with a $90,000 YOLO bonus is a "small" task (Bond
    /// 1 IMD, no swarm check). The rule that makes this safe: the vault sizes the submission on the reward alone,
    /// but `payout` pays a bonus above the large threshold only to a
    /// submission the swarm confirmed. Unconfirmed, the doer gets the threshold's worth ($300 = 3M YOLO at $0.0001,
    /// minus the 10% fee) and the rest goes back to the sweetener.
    function test_Fixed_S1_bonusAboveTheLargeThresholdNeedsTheSwarm() public {
        uint256 bonus = 900_000_000e18; // $90,000 at $0.0001
        uint256 t = _create(author, ETH, 0.01 ether); // $25
        _sweeten(alice, t, bonus);

        uint256 s = _submit(doer, t);
        Submission memory sub = _sub(s);
        assertFalse(sub.large, "the vault still sees a $25 task");
        assertEq(uint8(sub.check), uint8(CheckState.None), "no swarm check");
        assertEq(sub.bond, 1e18, "minimum Bond");

        vm.warp(sub.windowEnd);
        vault.poke(t);
        uint256 before = yolo.balanceOf(doer);
        vm.expectEmit(address(sweetener));
        emit YoloSweetener.BonusCapped(t, 3_000_000e18, bonus - 3_000_000e18);
        sweetener.payout(t, s);
        assertEq(yolo.balanceOf(doer) - before, 2_700_000e18, "fixed: $300 of it, minus the fee");
        assertEq(yolo.balanceOf(treasury), 300_000e18, "the fee on what the doer got");
        assertEq(sweetener.bonusOf(t), bonus - 3_000_000e18, "the rest waits for the sweetener");
        vm.expectRevert(YoloSweetener.NothingToPay.selector);
        sweetener.payout(t, s);
        uint256 aliceBefore = yolo.balanceOf(alice);
        vm.prank(alice);
        sweetener.withdraw(t);
        assertEq(yolo.balanceOf(alice) - aliceBefore, 897_000_000e18, "back to the sweetener, no notice needed");
        _claimEverythingAndCheck();
    }

    /// A sweetener must not pull the bonus in the doer's block, right before the submission. The rule: leaving an
    /// open task takes an hour of public notice; a doer who submits within that hour
    /// locks the bonus with his submission and is paid it.
    function test_Fixed_S2_bonusCannotBePulledWithoutNotice() public {
        uint256 t = _create(author, ETH, 0.01 ether);
        _sweeten(alice, t, 2_000_000e18); // $200: below the large threshold
        assertEq(sweetener.bonusOf(t), 2_000_000e18, "what the doer sees on the card");

        vm.prank(alice); // ahead of the doer's transaction: refused
        vm.expectRevert(YoloSweetener.NoNotice.selector);
        sweetener.withdraw(t);
        vm.prank(alice);
        sweetener.announceWithdraw(t);
        (uint256 leaving, uint64 from,) = sweetener.pendingWithdraw(t, alice);
        assertEq(leaving, 2_000_000e18, "the card shows the bonus leaving");
        assertEq(from, _now() + 1 hours);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(YoloSweetener.NoticeNotDue.selector, from));
        sweetener.withdraw(t);

        uint256 s = _submit(doer, t); // the doer submits within the hour
        _warp(1 hours);
        vm.prank(alice);
        vm.expectRevert(YoloSweetener.BonusLocked.selector);
        sweetener.withdraw(t);
        vm.warp(_sub(s).windowEnd);
        vault.poke(t);
        uint256 before = yolo.balanceOf(doer);
        sweetener.payout(t, s);
        assertEq(yolo.balanceOf(doer) - before, 1_800_000e18, "fixed: the doer gets the bonus he saw");
        _claimEverythingAndCheck();
    }

    /// The module reads the stored status; it plays no timers. Nothing gets stuck because of that: an expired but
    /// not yet poked task is still withdrawable (Open, nothing active), an acceptance not yet played keeps the bonus
    /// locked (Open, active) and payout works right after a poke.
    function test_Guard_S3_lazyStatusNeverStrandsTheBonus() public {
        uint256 d = _createWithDeadline(author, ETH, 0.01 ether, uint64(_now() + 1 days));
        _warp(1 days + 1);
        _sweeten(alice, d, 10e18); // effectively expired, stored Open: accepted, harmless
        vm.prank(alice); // past the deadline nobody can submit: no notice needed
        sweetener.withdraw(d);
        assertEq(sweetener.bonusOf(d), 0);

        uint256 t = _create(author, ETH, 0.01 ether);
        _sweeten(alice, t, 10e18);
        uint256 s = _submit(doer, t);
        vm.warp(_sub(s).windowEnd + 1); // accepted by the timer, not played yet
        vm.prank(alice);
        vm.expectRevert(YoloSweetener.BonusLocked.selector);
        sweetener.withdraw(t);
        vm.expectRevert(YoloSweetener.NotAccepted.selector);
        sweetener.payout(t, s);
        vault.poke(t);
        sweetener.payout(t, s);
        assertEq(yolo.balanceOf(address(sweetener)), 0);
        _claimEverythingAndCheck();
    }

    /// A rejected submission with one queued behind it: the vault activates the next one in the same transaction,
    /// so there is no moment with the task open and idle, and the bonus goes to the second doer only.
    function test_Guard_S4_rejectionWithAQueueLeavesNoWithdrawGap() public {
        uint256 t = _create(author, ETH, 0.01 ether);
        _sweeten(alice, t, 1_000e18);
        uint256 s1 = _submit(doer, t);
        uint256 s2 = _submit(doer2, t); // queued
        _dispute(dave, s1);
        _vote(s1, 0, REJECT, 0, 120);
        _endVote(s1); // NFT decision at the vote end
        _warp(24 hours); // appeal window over: rejected, the queued one activated in the same call
        vault.poke(t);
        assertEq(uint8(_sub(s1).outcome), uint8(Outcome.Rejected));
        assertEq(vault.getTask(t).activeSub, s2, "the queued one is active at once");
        vm.prank(alice);
        vm.expectRevert(YoloSweetener.BonusLocked.selector);
        sweetener.withdraw(t);

        vm.warp(_sub(s2).windowEnd);
        vault.poke(t);
        vm.expectRevert(YoloSweetener.NotAccepted.selector);
        sweetener.payout(t, s1); // the rejected one
        uint256 before = yolo.balanceOf(doer2);
        sweetener.payout(t, s2);
        assertEq(yolo.balanceOf(doer2) - before, 900e18);
        vm.expectRevert(YoloSweetener.NothingToPay.selector);
        sweetener.payout(t, s2);
        _claimEverythingAndCheck();
    }

    /// Re-entry from the only push in a submission (the excess-ETH refund, sent while the vault holds its lock):
    /// the doer's contract sees the task open and busy, `withdraw` is locked and `payout` refused; the bonus stays.
    function test_Guard_S5_reentryFromTheEthRefundIsLocked() public {
        uint256 t = _create(author, ETH, 0.01 ether);
        ReentrantDoer bad = new ReentrantDoer(vault, sweetener, t);
        imd.mint(address(bad), 100e18);
        yolo.mint(address(bad), 1_000e18);
        bad.prepare(address(imd), address(yolo));
        bad.sweetenAndSubmit{value: 1 ether}(1_000e18); // all of the ETH comes back: refunded by a push
        assertEq(bad.withdrawError(), YoloSweetener.BonusLocked.selector, "withdraw inside the refund: locked");
        assertEq(bad.payoutError(), YoloSweetener.NotAccepted.selector, "payout inside the refund: refused");
        assertEq(sweetener.bonusOf(t), 1_000e18);
        assertEq(yolo.balanceOf(address(sweetener)), 1_000e18);

        vm.warp(_sub(bad.subId()).windowEnd);
        vault.poke(t);
        sweetener.payout(t, bad.subId());
        assertEq(yolo.balanceOf(address(bad)), 900e18, "paid once, 10% fee");
        assertEq(yolo.balanceOf(treasury), 100e18);
    }

    /// The constructor takes no `registry` or `yolo` argument to trust: the module takes only the vault and reads the vault's registry, $YOLO and CaseDesk, so no launch argument can give
    /// it a foreign token or another registry's treasury.
    function test_Fixed_S3_moduleTakesTokenAndRegistryFromTheVault() public {
        YoloSweetener fresh = new YoloSweetener(address(vault));
        assertEq(address(fresh.yolo()), vault.yolo(), "the vault's YOLO");
        assertEq(address(fresh.registry()), vault.registry(), "the vault's registry");
        assertEq(address(fresh.caseDesk()), address(caseDesk), "the vault's CaseDesk");
        vm.expectRevert(YoloSweetener.ZeroAddress.selector);
        new YoloSweetener(address(0));
    }

    /// Payout after the tie rule (no NFT decision, nobody called the swarm: accepted) works like any acceptance.
    function test_Guard_S6_tieAcceptancePaysTheBonus() public {
        uint256 t = _create(author, ETH, 0.01 ether);
        _sweeten(bob, t, 100e18);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        _warp(24 hours); // vote window over without votes
        vault.poke(t);
        _warp(24 hours); // nobody called the swarm
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        sweetener.payout(t, s);
        assertEq(sweetener.bonusOf(t), 0);
        _claimEverythingAndCheck();
    }
}

/// @dev A doer contract that re-enters the sweetener from the ETH refund of its own `submit`.
contract ReentrantDoer {
    ITaskVault immutable vault;
    YoloSweetener immutable sw;
    uint256 immutable taskId;
    uint256 public subId;
    bytes4 public withdrawError;
    bytes4 public payoutError;
    bool armed;

    constructor(ITaskVault v, YoloSweetener s, uint256 t) {
        vault = v;
        sw = s;
        taskId = t;
    }

    function prepare(address imd, address yolo) external {
        MockERC20(imd).approve(address(vault), type(uint256).max);
        MockERC20(yolo).approve(address(sw), type(uint256).max);
    }

    function sweetenAndSubmit(uint256 amount) external payable {
        sw.sweeten(taskId, amount);
        armed = true;
        ImdPay memory none;
        subId = vault.submit{value: msg.value}(
            taskId, "https://x.com/doer/status/1", Evidence(bytes32(0), false, ""), 0, type(uint256).max, none
        );
        armed = false;
    }

    receive() external payable {
        if (!armed) return;
        armed = false;
        try sw.withdraw(taskId) {}
        catch (bytes memory e) {
            withdrawError = bytes4(e);
        }
        try sw.payout(taskId, vault.submissionCount()) {}
        catch (bytes memory e) {
            payoutError = bytes4(e);
        }
    }
}

/// @dev What the vault does with every state of the YOLO price (mock oracle unless stated).
contract ReviewYoloStrictTest is Base {
    /// A price pushed down by one sample (a sell-sample-buy-back bundle) must not make 2M YOLO a small task with
    /// the minimum Bond and no check. The rule: the oracle values YOLO at the HIGHEST sample of the window. Here the real oracle replaces the mock
    /// (same address, so the registry's parameters point at it): five samples at 10x the opening price, then the
    /// attacker's sample at the bottom tick; the submission stays large with the same Bond and the check.
    function test_Fixed_S4_aCrashedSampleNoLongerStripsTheCheck() public {
        uint256 R = 2_000_000e18;
        uint256 t = _create(author, address(yolo), R); // created under the mock price: $200
        _realOracle();
        for (uint256 i; i < 5; ++i) {
            _sampleAt(-88_053); // 10x the opening price: 2M YOLO = 300 IMD = $2,400
        }
        uint256 snap = vm.snapshotState();
        uint256 s1 = _submit(doer, t);
        Submission memory honest = _sub(s1);
        vm.revertToState(snap);

        _sampleAt(-887_220); // swap down, sample, swap back
        (, int24 lowest) = ChainlinkUniV3PriceOracle(address(oracle)).lowestYoloTick();
        assertEq(lowest, -887_220, "the crashed sample is in the window");
        uint256 s2 = _submit(doer, t);
        Submission memory attacked = _sub(s2);
        console.log("bond honest / after the crashed sample", honest.bond, attacked.bond);
        assertTrue(honest.large && attacked.large, "fixed: still large");
        assertEq(attacked.bond, honest.bond, "fixed: the same Bond");
        assertEq(attacked.rewardImd, honest.rewardImd);
        assertEq(uint8(attacked.check), uint8(CheckState.Requested), "fixed: the check is asked");
    }

    /// @dev The launch oracle (ChainlinkUniV3PriceOracle, opening price 15,000 IMD per 1B, cap $0.01) etched over the
    ///      mock at the mock's address; ETH $2,500, IMD $8 as in Base.
    function _realOracle() internal {
        MockV3Pool v3 = new MockV3Pool();
        if (address(usdc) > address(imd)) vm.store(address(v3), 0, bytes32(uint256(uint24(int24(-255_529)))));
        pm = new MockPoolManager();
        ChainlinkUniV3PriceOracle real = new ChainlinkUniV3PriceOracle(
            address(usdc),
            address(imd),
            IAggregatorV3(address(new MockFeed(2500e8))),
            IAggregatorV3(address(new MockFeed(1e8))),
            IUniswapV3PoolObserve(address(v3)),
            1800,
            2 hours,
            48 hours,
            address(yolo),
            address(pm),
            address(0x784),
            12_500,
            60,
            0.01e18,
            15_000e18 * 1e18 / 1_000_000_000e18
        );
        vm.etch(address(oracle), address(real).code);
        assertApproxEqRel(IPriceOracle(address(oracle)).usdValue(address(imd), 1e18), 8e18, 0.001e18, "IMD $8");
    }

    MockPoolManager pm;

    function _sampleAt(int24 tick) internal {
        ChainlinkUniV3PriceOracle o = ChainlinkUniV3PriceOracle(address(oracle));
        int24 yoloTick = address(yolo) < address(imd) ? tick : -tick;
        pm.setTick(o.yoloPoolId(), yoloTick);
        vm.prank(address(0x5EED), address(0x5EED));
        assertFalse(o.sampleYoloPrice()); // the read; stored in a later block (swarm audit #1)
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(address(0x5EED), address(0x5EED));
        assertTrue(o.sampleYoloPrice());
        _warp(15 minutes);
    }

    /// The price vanishing between the doer's quote and his transaction cannot surprise him: the task turns large
    /// and `maxImdIn` (the quote) stops the submission.
    function test_Guard_S5_priceVanishingAfterTheQuoteIsCaughtByMaxImdIn() public {
        uint256 t = _create(author, address(yolo), 1_000_000e18); // $100 at the Base price: small
        (uint256 bond, uint256 checkFee) = vault.quoteSubmission(t);
        assertEq(checkFee, 0);
        oracle.set(address(yolo), 0, 18); // too few samples now
        vm.prank(doer);
        vm.expectRevert(CostAboveMax.selector);
        vault.submit(t, "https://x.com/doer/status/1", _noEvidence(), 0, bond, _noSwap());
        uint256 s = _submit(doer, t); // without a cap: large, threshold Bond, check asked
        assertTrue(_sub(s).large);
        assertEq(uint8(_sub(s).check), uint8(CheckState.Requested));
        assertEq(_sub(s).rewardImd, 40e18, "valued at the large threshold");
    }

    /// Partial oracle failures: price known but one read reverting = large, the IMD value never below the
    /// threshold; an IMD value read that works is kept when it is higher.
    function test_Guard_S6_partialOracleFailureIsLarge() public {
        uint256 t = _create(author, address(yolo), 1_000_000e18);
        vm.mockCallRevert(address(oracle), abi.encodeWithSelector(IPriceOracle.usdValue.selector), "down");
        uint256 s = _submit(doer, t);
        assertTrue(_sub(s).large, "usdValue reverting: large");
        assertEq(_sub(s).rewardImd, 40e18);
        vm.clearMockedCalls();

        uint256 big = _create(author, address(yolo), 900_000_000e18); // $90,000 = 11,250 IMD
        vm.mockCallRevert(address(oracle), abi.encodeWithSelector(IPriceOracle.usdValue.selector), "down");
        uint256 s2 = _submit(doer2, big);
        assertEq(_sub(s2).rewardImd, 11_250e18, "a priced IMD value above the threshold is kept");
        vm.clearMockedCalls();
    }

    /// Observation (documented, low/info): the $5 minimum reward is checked only at creation and only when the
    /// YOLO price is known. A $YOLO task created while YOLO is unpriced can carry 1 wei; once the price appears, a
    /// submission to it is small (minimum Bond, no swarm check), while a new 1-wei task is refused. Nothing of
    /// value is at stake in such a task; the author fee is its only cost.
    function test_Observation_S7_unpricedCreationSkipsTheMinimumForever() public {
        oracle.set(address(yolo), 0, 18);
        uint256 t = _create(author, address(yolo), 1);
        oracle.set(address(yolo), 0.0001e18, 18);
        uint256 s = _submit(doer, t);
        assertFalse(_sub(s).large);
        assertEq(_sub(s).bond, 1e18);
        uint256 value = 0.001 ether;
        vm.prank(alice);
        vm.expectRevert(RewardTooSmall.selector);
        vault.createTask{value: value}(address(yolo), 1, 0, "Title", "c", 0, 0, "", value, _noSwap());
    }
}

/// @dev The real oracle's highest-sample rule: one crashed sample in an honest window does not move the price.
contract ReviewYoloFloorUnit is Test {
    address constant USDC = address(0x1000);
    address constant IMD = address(0x2000);
    address constant YOLO = address(0x0500);
    MockPoolManager pm;
    ChainlinkUniV3PriceOracle oracle;

    function setUp() public {
        vm.warp(1_800_000_000);
        pm = new MockPoolManager();
        oracle = new ChainlinkUniV3PriceOracle(
            USDC,
            IMD,
            IAggregatorV3(address(new MockFeed(2500e8))),
            IAggregatorV3(address(new MockFeed(1e8))),
            IUniswapV3PoolObserve(address(new MockV3Pool())),
            1800,
            2 hours,
            48 hours,
            YOLO,
            address(pm),
            address(0x784),
            12_500,
            60,
            0.01e18,
            15_000e18 * 1e18 / 1_000_000_000e18
        );
    }

    function _sample(int24 tick) internal {
        pm.setTick(oracle.yoloPoolId(), tick);
        vm.prank(address(0x5EED), address(0x5EED));
        assertFalse(oracle.sampleYoloPrice()); // the read; stored in a later block (swarm audit #1)
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(address(0x5EED), address(0x5EED));
        assertTrue(oracle.sampleYoloPrice());
        vm.warp(vm.getBlockTimestamp() + 15 minutes);
    }

    /// One sample at the bottom tick must not take a priced 2M YOLO to the floor (30 IMD instead of 300) for two
    /// hours. The YOLO price is the highest sample of the window, so the crashed sample changes nothing;
    /// `lowestYoloTick` still shows it.
    function test_Fixed_S4_oneCrashedSampleNoLongerMovesThePrice() public {
        int24 tenX = -88_053;
        for (uint256 i; i < 5; ++i) {
            _sample(tenX);
        }
        uint256 honest = oracle.imdValue(YOLO, 2_000_000e18);
        _sample(-887_220);
        assertTrue(oracle.hasPrice(YOLO));
        uint256 crashed = oracle.imdValue(YOLO, 2_000_000e18);
        console.log("2M YOLO in IMD, honest 10x / after the crashed sample", honest, crashed);
        assertEq(crashed, honest, "fixed: the highest sample counts");
        assertApproxEqRel(honest, 300e18, 0.01e18, "10x the floor of 15,000 IMD per 1B");
        (, int24 lowest) = oracle.lowestYoloTick();
        (, int24 highest) = oracle.highestYoloTick();
        assertEq(lowest, -887_220);
        assertEq(highest, tenX);
    }
}
