// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {Base} from "../Base.t.sol";
import {YoloSweetener} from "../../src/YoloSweetener.sol";
import {MockPoolManager, MockFeed, MockV3Pool} from "../YoloOracle.t.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockNFT} from "../mocks/MockNFT.sol";
import {MockDelegateRegistry} from "../mocks/MockDelegateRegistry.sol";
import {MockStarter} from "../mocks/MockStarter.sol";
import {YoloToken} from "../../src/token/YoloToken.sol";
import {YoloSplitter} from "../../src/token/YoloSplitter.sol";
import {ProjectVesting} from "../../src/token/ProjectVesting.sol";
import {LaunchPlan, LocalFactory} from "../../script/LaunchPlan.sol";
import {
    ChainlinkUniV3PriceOracle,
    IAggregatorV3,
    IUniswapV3PoolObserve
} from "../../src/oracles/ChainlinkUniV3PriceOracle.sol";
import "../../src/VaultTypes.sol";

/// @dev The API the four rules below add, declared here so these regression tests also compile against the code
///      before the fix (and fail there, at run time).
interface IFixQSweetener {
    function announceWithdraw(uint256 taskId) external;
    function pendingWithdraw(uint256 taskId, address who)
        external
        view
        returns (uint256 amount, uint64 from, uint64 until);
    function returnBase(uint256 taskId) external view returns (uint256);
}

interface IFixQVesting {
    function startOf(address token) external view returns (uint64);
}

interface IFixQSamples {
    function highestYoloTick() external view returns (bool ok, int24 highest);
}

/// @notice Regression tests of four rules: D6 = audit A-03 (vesting clocks start at the split), D8 = the sweetener
///         bonus above the large threshold needs the swarm, D9 = the YOLO price is the highest sample of the window,
///         D10 = withdrawing a bonus from an open task needs an hour of notice. Each `test_FixQ_*` fails on the code
///         before the fix.
contract AuditFixQSweetener is Base {
    bytes4 constant NO_NOTICE = bytes4(keccak256("NoNotice()"));
    bytes4 constant NOTICE_NOT_DUE = bytes4(keccak256("NoticeNotDue(uint64)"));
    bytes4 constant BONUS_LOCKED = bytes4(keccak256("BonusLocked()"));
    bytes4 constant NOTHING_TO_PAY = bytes4(keccak256("NothingToPay()"));

    function _fq() internal view returns (IFixQSweetener) {
        return IFixQSweetener(address(sweetener));
    }

    function _sweeten(address who, uint256 taskId, uint256 amount) internal {
        vm.prank(who);
        sweetener.sweeten(taskId, amount);
    }

    function _withdraw(address who, uint256 taskId) internal returns (uint256 got) {
        uint256 before = yolo.balanceOf(who);
        vm.prank(who);
        sweetener.withdraw(taskId);
        got = yolo.balanceOf(who) - before;
    }

    function _acceptByTimer(uint256 t, uint256 s) internal {
        vm.warp(_sub(s).windowEnd);
        vault.poke(t);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Completed));
    }

    // ================================================================== D8 (bonus cap)

    /// D8: an accepted submission the swarm never saw gets the bonus up to the large threshold ($300 = 3M YOLO at
    /// $0.0001) minus the fee; the rest goes back to the three sweeteners pro rata, exactly (odd amounts: each within
    /// 1 wei of his exact share, the last takes what is left, nothing stays).
    function test_FixQ_D8_unconfirmedBonusIsCappedAndTheRestReturnsProRata() public {
        uint256 t = _create(author, ETH, 0.01 ether);
        uint256 a = 600_000_000e18 + 7;
        uint256 b = 300_000_000e18 + 1;
        uint256 c = 3_333_333e18 + 3;
        _sweeten(alice, t, a);
        _sweeten(bob, t, b);
        _sweeten(dave, t, c);
        uint256 bonus = a + b + c;
        uint256 s = _submit(doer, t);
        _acceptByTimer(t, s);

        uint256 before = yolo.balanceOf(doer);
        sweetener.payout(t, s);
        uint256 cap = 3_000_000e18;
        assertEq(yolo.balanceOf(doer) - before, cap * 9 / 10, "the doer: the threshold's worth minus 10%");
        assertEq(yolo.balanceOf(treasury), cap / 10, "the fee on what the doer got only");
        uint256 rest = bonus - cap;
        assertEq(sweetener.bonusOf(t), rest);
        assertEq(_fq().returnBase(t), bonus);
        vm.expectRevert(NOTHING_TO_PAY);
        sweetener.payout(t, s);

        uint256 gotA = _withdraw(alice, t); // no notice: the task is completed
        uint256 gotB = _withdraw(bob, t);
        uint256 gotC = _withdraw(dave, t);
        assertApproxEqAbs(gotA, rest * a / bonus, 1);
        assertApproxEqAbs(gotB, rest * b / bonus, 1);
        assertApproxEqAbs(gotC, rest * c / bonus, 1);
        assertEq(gotA + gotB + gotC, rest, "exactly the rest");
        assertEq(sweetener.bonusOf(t), 0);
        assertEq(yolo.balanceOf(address(sweetener)), 0, "no dust");
        vm.prank(alice);
        vm.expectRevert(); // nothing more
        sweetener.withdraw(t);
        _claimEverythingAndCheck();
    }

    /// D8: a mandatory check that went silent confirms nothing: capped as well.
    function test_FixQ_D8_silentMandatoryCheckIsNotAConfirmation() public {
        uint256 t = _create(author, ETH, 0.2 ether); // $500: large, mandatory check
        _sweeten(alice, t, 10_000_000e18); // $1,000
        uint256 s = _submit(doer, t);
        assertEq(uint8(_sub(s).check), uint8(CheckState.Requested));
        _silent(s);
        vault.poke(t);
        _acceptByTimer(t, s);
        uint256 before = yolo.balanceOf(doer);
        sweetener.payout(t, s);
        assertEq(yolo.balanceOf(doer) - before, 2_700_000e18, "capped: the swarm never said yes");
        assertEq(_withdraw(alice, t), 7_000_000e18);
        _claimEverythingAndCheck();
    }

    /// D8 was: no reliable YOLO price at payout = a cap of 0: an unconfirmed doer gets nothing, all of it goes back.
    /// D8 as changed by the swarm audit #6: no price no longer means "nothing to the doer,
    /// all back"; the payout waits for a price (nothing moves), then pays by the cap as usual.
    function test_FixQ_D8_noPriceDefersThePayout() public {
        uint256 t = _create(author, ETH, 0.01 ether);
        _sweeten(alice, t, 1_000e18); // $0.10 at the price of the sweetening
        uint256 s = _submit(doer, t);
        _acceptByTimer(t, s);
        oracle.set(address(yolo), 0, 18); // too few samples now
        uint256 before = yolo.balanceOf(doer);
        sweetener.payout(t, s);
        assertEq(yolo.balanceOf(doer), before, "nothing moves without a price");
        assertEq(yolo.balanceOf(treasury), 0, "no fee on nothing");
        assertEq(sweetener.bonusOf(t), 1_000e18, "the bonus waits");
        vm.prank(alice);
        vm.expectRevert(YoloSweetener.BonusLocked.selector);
        sweetener.withdraw(t);
        oracle.set(address(yolo), 0.0001e18, 18); // a price again: $0.10, below the threshold, all to the doer
        sweetener.payout(t, s);
        assertEq(yolo.balanceOf(doer) - before, 900e18);
        _claimEverythingAndCheck();
    }

    /// D8: a confirmed submission gets the whole bonus: the mandatory check answered "yes", or an escalation the
    /// swarm decided for the doer.
    function test_FixQ_D8_swarmConfirmedSubmissionGetsTheWholeBonus() public {
        uint256 t = _create(author, ETH, 0.2 ether); // large: mandatory check
        _sweeten(alice, t, 100_000_000e18); // $10,000
        uint256 s = _submit(doer, t);
        _answer(s, true);
        vault.poke(t);
        _acceptByTimer(t, s);
        uint256 before = yolo.balanceOf(doer);
        sweetener.payout(t, s);
        assertEq(yolo.balanceOf(doer) - before, 90_000_000e18, "all of it minus the fee");
        assertEq(sweetener.bonusOf(t), 0);

        uint256 t2 = _create(author, ETH, 0.01 ether); // small: no check, but disputed and escalated
        _sweeten(bob, t2, 100_000_000e18);
        uint256 s2 = _submit(doer2, t2);
        _dispute(dave, s2);
        _warp(24 hours); // no NFT votes
        _callSwarm(erin, s2);
        _answer(s2, true); // the swarm: the doer is right
        vault.poke(t2);
        assertEq(uint8(_sub(s2).outcome), uint8(Outcome.Accepted));
        before = yolo.balanceOf(doer2);
        sweetener.payout(t2, s2);
        assertEq(yolo.balanceOf(doer2) - before, 90_000_000e18, "escalation answered yes: all of it");
        vm.prank(bob);
        vm.expectRevert(BONUS_LOCKED);
        sweetener.withdraw(t2);
        _claimEverythingAndCheck();
    }

    // ================================================================== D10 (withdrawal notice)

    /// D10: leaving an open task takes an announced hour; the notice holds a day after it matures, then must be
    /// renewed; a sweetening after the notice is covered by it; the view shows the pending notice.
    function test_FixQ_D10_withdrawFromAnOpenTaskNeedsAnHourOfNotice() public {
        uint256 t = _create(author, ETH, 0.01 ether);
        _sweeten(alice, t, 1_000e18);
        vm.prank(alice);
        vm.expectRevert(NO_NOTICE);
        sweetener.withdraw(t);

        vm.prank(alice);
        _fq().announceWithdraw(t);
        uint64 due = uint64(_now() + 1 hours);
        (uint256 amount, uint64 from, uint64 until) = _fq().pendingWithdraw(t, alice);
        assertEq(amount, 1_000e18);
        assertEq(from, due);
        assertEq(until, due + 1 days);
        _warp(1 hours - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NOTICE_NOT_DUE, due));
        sweetener.withdraw(t);

        _warp(1 + 1 days + 1); // matured, then more than a day old: expired
        (amount,,) = _fq().pendingWithdraw(t, alice);
        assertEq(amount, 0, "an expired notice is not shown");
        vm.prank(alice);
        vm.expectRevert(NO_NOTICE);
        sweetener.withdraw(t);

        vm.prank(alice); // renewed
        _fq().announceWithdraw(t);
        _sweeten(alice, t, 500e18); // more after the notice: the notice covers the whole share
        _warp(1 hours);
        assertEq(_withdraw(alice, t), 1_500e18);
        (amount, from,) = _fq().pendingWithdraw(t, alice);
        assertEq(from, 0, "the notice is used up");
        assertEq(sweetener.bonusOf(t), 0);
        _claimEverythingAndCheck();
    }

    /// D10: expired and unwound tasks need no notice (nor does a stored-Open task past its deadline: nobody can
    /// submit any more).
    function test_FixQ_D10_noNoticeOnceNobodyCanSubmit() public {
        uint256 d = _createWithDeadline(author, ETH, 0.01 ether, uint64(_now() + 1 days));
        _sweeten(alice, d, 10e18);
        _sweeten(bob, d, 20e18);
        _warp(1 days + 1);
        assertEq(_withdraw(alice, d), 10e18, "past the deadline, not poked yet");
        vault.poke(d);
        assertEq(uint8(vault.getTask(d).status), uint8(TaskStatus.Expired));
        assertEq(_withdraw(bob, d), 20e18, "expired");

        allowEmergency = true;
        uint256 t = _create(author, ETH, 0.01 ether);
        _sweeten(alice, t, 7e18);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        vm.mockCallRevert(address(vault), abi.encodeWithSignature("advanceFromSelf(uint256)", t), "");
        _warp(LONG);
        vault.emergencyExit(t);
        vm.clearMockedCalls();
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Unwound));
        assertEq(_withdraw(alice, t), 7e18, "unwound");
        _claimEverythingAndCheck();
    }
}

/// @notice D9 (the highest sample of the window) with the real oracle.
contract AuditFixQOracle is Test {
    address constant USDC = address(0x1000);
    address constant IMD = address(0x2000);
    address constant YOLO = address(0x0500); // currency0: the pool tick is the YOLO tick
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
        assertFalse(oracle.sampleYoloPrice()); // the read (swarm audit #1: stored in a later block)
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(address(0x5EED), address(0x5EED));
        assertTrue(oracle.sampleYoloPrice());
        skip(15 minutes);
    }

    /// D9: the price is the highest sample of the window: a depressed sample never lowers the value of a reward, a
    /// inflated one raises it (bigger Bond, the check: only dearer); the cap and the floor still apply.
    function test_FixQ_D9_priceIsTheHighestSampleOfTheWindow() public {
        int24 tenX = -88_053; // 10x the opening price
        for (uint256 i; i < 5; ++i) {
            _sample(tenX);
        }
        uint256 honest = oracle.usdValue(YOLO, 2_000_000e18);
        _sample(-887_220); // the attacker's bundle: swap down, sample, swap back
        assertTrue(oracle.hasPrice(YOLO));
        assertEq(oracle.usdValue(YOLO, 2_000_000e18), honest, "a depressed sample changes nothing");
        (bool ok, int24 highest) = IFixQSamples(address(oracle)).highestYoloTick();
        (, int24 lowest) = oracle.lowestYoloTick();
        assertTrue(ok);
        assertEq(highest, tenX);
        assertEq(lowest, -887_220, "the lowest stays readable as a view");

        _sample(tenX + 10_000); // a inflated sample: e^1 = 2.7x
        assertGt(oracle.usdValue(YOLO, 2_000_000e18), honest * 27 / 10, "a inflated sample only raises the value");
        _sample(600_000); // far above the cap
        assertEq(oracle.usdValue(YOLO, 1e18), 0.01e18, "never above yoloMaxUsd");
    }
}

/// @notice D6 (A-03): the vesting clocks start when the tokens arrive.
contract AuditFixQVesting is Test {
    address constant PM = address(0x4444);
    address treasury = makeAddr("treasury");

    /// D6: launch 1 thirty days after launch 0: the split starts every clock, the gap unlocks nothing, Day 0 is
    /// exactly the at-once parts.
    function test_FixQ_D6_splitStartsTheClocks() public {
        vm.warp(1_800_000_000);
        MockNFT nft = new MockNFT();
        MockDelegateRegistry delegates = new MockDelegateRegistry();
        LocalFactory f = new LocalFactory();
        LaunchPlan.Owners memory o =
            LaunchPlan.Owners(treasury, makeAddr("inc"), makeAddr("stab"), makeAddr("dev"), makeAddr("team"));
        (bytes[] memory codes,, LaunchPlan.Genesis memory g) =
            LaunchPlan.genesisLaunchWith(f, 0, o, address(nft), address(delegates));
        f.launchContracts(0, codes);
        skip(30 days);
        YoloToken yolo = new YoloToken(PM, g.gate, treasury);
        yolo.transfer(PM, 150_000_000e18);
        yolo.transfer(makeAddr("swarm"), 100_000_000e18);
        yolo.transfer(g.splitter, 750_000_000e18);
        YoloSplitter(g.splitter).split(address(yolo));
        uint256 splitAt = block.timestamp;
        assertEq(ProjectVesting(g.dev).releasable(address(yolo)), 0, "dev: nothing at the token's first block");
        assertEq(ProjectVesting(g.team).releasable(address(yolo)), 0, "team: nothing at the token's first block");
        assertEq(yolo.balanceOf(o.incentives), 62_500_000e18, "incentives: the at-once quarter, paid by the split");
        assertEq(yolo.balanceOf(o.treasury), 74_074_074e18, "treasury: the at-once third, paid by the split");
        assertEq(IFixQVesting(g.team).startOf(address(yolo)), splitAt);
        skip(365 days);
        assertEq(ProjectVesting(g.team).releasable(address(yolo)), 50_000_000e18, "a full year after the split");
        assertEq(
            ProjectVesting(g.incentives).releasable(address(yolo)), 93_750_000e18, "half the stream after 12 months"
        );
    }

    /// D6: any token, any order. A release before anything arrived pays 0, never reverts and starts no clock; the
    /// first release while the vesting holds the token starts it; later arrivals ride on the same clock; the sum of
    /// releases is what arrived.
    function test_FixQ_D6_clockStartsAtTheFirstReleaseWithABalance() public {
        vm.warp(1_800_000_000);
        MockERC20 tok = new MockERC20("T", "T", 18);
        address ben = makeAddr("ben");
        // the YoloSplitter's place: the only starter (swarm audit #2)
        MockStarter st =
            new MockStarter(abi.encodePacked(type(ProjectVesting).creationCode, abi.encode(ben, 100e18, 100 days)));
        ProjectVesting v = ProjectVesting(st.vesting());
        skip(50 days);
        st.start(address(tok)); // nothing here yet
        assertEq(IFixQVesting(address(v)).startOf(address(tok)), 0, "no clock without the token");
        tok.mint(address(v), 1_100e18);
        assertEq(v.releasable(address(tok)), 100e18, "only the at-once part before the clock starts");
        skip(10 days);
        assertEq(v.releasable(address(tok)), 100e18, "still: the clock has not started");
        vm.prank(makeAddr("anyone"));
        v.release(address(tok)); // pays the at-once part, starts nothing: only the starter does
        assertEq(IFixQVesting(address(v)).startOf(address(tok)), 0, "no clock from anyone else");
        assertEq(tok.balanceOf(ben), 100e18);
        st.start(address(tok));
        assertEq(IFixQVesting(address(v)).startOf(address(tok)), block.timestamp);
        assertEq(tok.balanceOf(ben), 100e18);
        v.release(address(tok)); // 0, no revert
        skip(50 days);
        assertEq(v.releasable(address(tok)), 500e18, "half of the 1,000 stream");
        tok.mint(address(v), 200e18); // a later arrival vests on the same clock
        assertEq(v.releasable(address(tok)), 600e18);
        skip(50 days);
        v.release(address(tok));
        assertEq(tok.balanceOf(ben), 1_300e18, "everything that arrived");
        assertEq(tok.balanceOf(address(v)), 0);
    }
}
