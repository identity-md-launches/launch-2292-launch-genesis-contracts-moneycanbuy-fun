// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LaunchPlan} from "../../script/LaunchPlan.sol";
import {ReviewLaunchForkBase} from "../fork/LaunchForkBase.sol";
import {IAggregatorRound} from "../fork/LaunchRehearsal.fork.t.sol";
import {MockPoolManager, MockFeed, MockV3Pool} from "../YoloOracle.t.sol";
import {Base} from "../Base.t.sol";
import {MockStarter} from "../mocks/MockStarter.sol";

import {ITaskVault} from "../../src/interfaces/ITaskVault.sol";
import {
    ChainlinkUniV3PriceOracle,
    IAggregatorV3,
    IUniswapV3PoolObserve
} from "../../src/oracles/ChainlinkUniV3PriceOracle.sol";
import {YoloToken} from "../../src/token/YoloToken.sol";
import {ProjectVesting} from "../../src/token/ProjectVesting.sol";
import {NftGate} from "../../src/token/NftGate.sol";
import {MockNFT} from "../mocks/MockNFT.sol";
import {MockDelegateRegistry} from "../mocks/MockDelegateRegistry.sol";
import "../../src/VaultTypes.sol";

/// @dev $YOLO: price sampling, vesting, the NFT gate and the vault's use of the price. Non-fork part first;
///      ReviewYoloFork skips without FORK_URL.
contract ReviewYoloUnit is Test {
    address constant USDC = address(0x1000);
    address constant IMD = address(0x2000);
    address constant YOLO = address(0x0500); // currency0
    MockPoolManager pm;
    MockV3Pool v3;
    ChainlinkUniV3PriceOracle oracle;

    function setUp() public {
        vm.warp(1_800_000_000);
        pm = new MockPoolManager();
        v3 = new MockV3Pool();
        oracle = new ChainlinkUniV3PriceOracle(
            USDC,
            IMD,
            IAggregatorV3(address(new MockFeed(2500e8))),
            IAggregatorV3(address(new MockFeed(1e8))),
            IUniswapV3PoolObserve(address(v3)),
            1800,
            2 hours,
            48 hours,
            YOLO,
            address(pm),
            address(0x784),
            12_500,
            60,
            0.01e18,
            15_000e18 * 1e18 / 1_000_000_000e18 // the opening price: the floor of the YOLO price
        );
    }

    function _sample(int24 tick) internal {
        pm.setTick(oracle.yoloPoolId(), tick);
        vm.prank(address(0x5EED), address(0x5EED)); // a sample must come from a plain EOA
        assertFalse(oracle.sampleYoloPrice()); // the read; stored in a later block (swarm audit #1)
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(address(0x5EED), address(0x5EED));
        assertTrue(oracle.sampleYoloPrice());
        vm.warp(block.timestamp + 15 minutes);
    }

    /// Y1 (exact sampling logic): one sample taken while the pool is pushed to its bottom tick. The price never
    /// goes below the opening price (the floor), where the factory's pool has no liquidity below, so 100M YOLO
    /// stays above $300. The YOLO price is the highest sample of the window, so the crashed one is ignored; the
    /// honest samples here sit at the floor, so the figures hold either way.
    function test_Y1_oneCrashedSampleLeavesThePriceAtTheFloor() public {
        int24 honest = -129_500; // below the floor: valued at 1.5e-5 IMD per YOLO (15,000 IMD for 1B, the launch price)
        for (uint256 i; i < 4; ++i) {
            _sample(honest);
        }
        uint256 snap = vm.snapshotState();
        _sample(honest);
        assertGt(oracle.usdValue(YOLO, 100_000_000e18), 300e18, "honest: 100M YOLO above the $300 check threshold");
        vm.revertToState(snap);
        _sample(-887_220); // the attacker's sample: swap down, sample, swap back
        for (uint256 i; i < 3; ++i) {
            _sample(honest);
        }
        assertTrue(oracle.hasPrice(YOLO));
        uint256 atFloor = oracle.usdValue(YOLO, 100_000_000e18);
        assertGt(atFloor, 300e18, "fixed: the crashed sample counts as the opening price, still above $300");
        assertApproxEqRel(oracle.imdValue(YOLO, 100_000_000e18), 1_500e18, 0.001e18, "fixed: 100M YOLO = floor");
    }

    /// Y2: an unpriced YOLO (no samples) is worth 0 without reading the IMD TWAP or Chainlink: imdValue returns 0
    /// before touching them, so an unpriced $YOLO submit does not depend on the v3 TWAP.
    function test_Y2_unpricedYoloNeedsNoTwap() public {
        assertFalse(oracle.hasPrice(YOLO));
        assertEq(oracle.imdValue(YOLO, 1e24), 0);
        vm.mockCallRevert(address(v3), abi.encodeWithSelector(IUniswapV3PoolObserve.observe.selector), "OLD");
        assertEq(oracle.imdValue(YOLO, 1e24), 0, "fixed: no TWAP read for an unpriced YOLO");
        // the IMD path itself never needs the oracle
        assertEq(oracle.imdValue(IMD, 1e24), 1e24);
    }

    /// Y3: ProjectVesting: no cliff anywhere. The unlocked part is free at once, the rest streams linearly from the
    /// token's arrival: the starter's first `release` while the vesting holds it starts the clock (audit A-03, swarm
    /// audit #2; was: from deployment). The vesting knows no token in advance since it moved to launch 0.
    function test_Y3_vestingStreamsFromArrivalWithoutACliff() public {
        YoloToken t = new YoloToken(address(0xBEEF), address(0), address(0x5AFE));
        address beneficiary = address(0xA11CE);
        // the YoloSplitter's place: the only starter (swarm audit #2)
        MockStarter st = new MockStarter(
            abi.encodePacked(type(ProjectVesting).creationCode, abi.encode(beneficiary, 150_000_000e18, 365 days))
        );
        ProjectVesting v = ProjectVesting(st.vesting());
        t.transfer(address(v), 700_000_000e18);
        assertEq(v.releasable(address(t)), 150_000_000e18);
        skip(1 days);
        assertEq(v.releasable(address(t)), 150_000_000e18, "no clock before the first release");
        st.start(address(t)); // YoloSplitter.split does this right after paying the vestings
        assertEq(t.balanceOf(beneficiary), 150_000_000e18);
        skip(1 days);
        assertEq(v.releasable(address(t)), uint256(550_000_000e18) * 1 days / 365 days);
        skip(364 days - 1);
        assertLt(v.releasable(address(t)) + t.balanceOf(beneficiary), 700_000_000e18);
        skip(1);
        assertEq(v.releasable(address(t)) + t.balanceOf(beneficiary), 700_000_000e18, "all vested at day 365");
    }

    /// Y4 (NFT gate): in the first 30 minutes the gate checks the RECEIVER of the transfer out
    /// of the PoolManager. A route that takes the output to a router first is refused even for an NFT holder (the
    /// router holds no NFT), and the reason survives as NotWhitelisted(router); the Universal Router's TAKE_ALL pays
    /// the buyer directly and passes (fork: LaunchRehearsal).
    function test_Y4_whitelistRefusesOutputTakenToARouter() public {
        address poolManager = address(0xBEEF);
        MockNFT nft = new MockNFT();
        NftGate gate = new NftGate(address(nft), address(new MockDelegateRegistry()));
        YoloToken t = new YoloToken(poolManager, address(gate), address(0x5AFE));
        t.transfer(poolManager, 200_000_000e18);
        address holder = address(0xA);
        nft.mint(holder, 7);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 7;
        vm.prank(holder);
        gate.register(ids);
        address router = address(0x5555);
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(YoloToken.NotWhitelisted.selector, router));
        t.transfer(router, 1_000e18);
        vm.prank(poolManager);
        t.transfer(holder, 1_000e18);
    }
}

/// @dev Y5 with the vault (mock oracle): the vault sizes a $YOLO submission by the number the oracle returns.
contract ReviewYoloVault is Base {
    /// The vault trusts the oracle's number: a mock oracle set to a near-zero YOLO price (hasPrice true) sizes an
    /// existing $YOLO task down (minimum Bond, no mandatory swarm check) and refuses a new $YOLO task as
    /// RewardTooSmall. The real oracle's floor (the pool's opening price) and the highest-sample rule keep a
    /// depressed price from reaching the vault: see test_Y1_oneCrashedSampleLeavesThePriceAtTheFloor above,
    /// test_Fixed_S4_aCrashedSampleNoLongerStripsTheCheck and test_Fixed_S4_oneCrashedSampleNoLongerMovesThePrice
    /// in ReviewSweetener, and test_FixQ_D9_priceIsTheHighestSampleOfTheWindow in AuditFixQ.
    function test_Y5_vaultTrustsOracle_depressedMockPriceSizesDown() public {
        uint256 R = 100_000_000e18; // $10,000 at the Base price of $0.0001
        uint256 t = _create(author, address(yolo), R);
        uint256 snap = vm.snapshotState();
        uint256 s1 = _submit(doer, t);
        Submission memory honest = _sub(s1);
        vm.revertToState(snap);

        oracle.set(address(yolo), 1, 18); // a mock price near zero: hasPrice true, value ~0
        assertTrue(oracle.hasPrice(address(yolo)));
        uint256 s2 = _submit(doer, t);
        Submission memory attacked = _sub(s2);
        console.log("doer bond IMD, normal / near-zero price:", honest.bond, attacked.bond);
        console.log("mandatory check, normal / near-zero price:", honest.large, attacked.large);
        assertTrue(honest.large && !attacked.large, "a near-zero oracle price sizes the submission as small");
        assertEq(attacked.bond, 1e18, "minimum Bond");
        assertGt(honest.bond, 30e18);

        uint256 value = 0.001 ether;
        vm.prank(alice);
        vm.expectRevert(RewardTooSmall.selector);
        vault.createTask{value: value}(address(yolo), R, 0, "Title", "c", 0, 0, "", value, _noSwap());
    }
}

interface IPM {
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256);
    function sync(address currency) external;
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
    function extsload(bytes32 slot) external view returns (bytes32);
}

/// @dev Buys YOLO, or runs the attack inside ONE v4 unlock: sell YOLO down to the price limit, sample, buy back up
///      to the starting price, settle the net.
contract V4YoloTrader {
    IPM constant PM = IPM(LaunchPlan.POOL_MANAGER);
    uint160 constant MIN_SQRT = 4_295_128_740;
    uint160 constant MAX_SQRT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;
    address immutable yolo;
    ChainlinkUniV3PriceOracle immutable oracle;
    bool immutable yoloIs0;

    constructor(address yolo_, ChainlinkUniV3PriceOracle oracle_) {
        yolo = yolo_;
        oracle = oracle_;
        yoloIs0 = yolo_ < LaunchPlan.IMD;
    }

    function _key() internal view returns (IPM.PoolKey memory) {
        return IPM.PoolKey(
            yoloIs0 ? yolo : LaunchPlan.IMD,
            yoloIs0 ? LaunchPlan.IMD : yolo,
            LaunchPlan.POOL_FEE,
            LaunchPlan.POOL_TICK_SPACING,
            LaunchPlan.POOL_GUARD
        );
    }

    function sqrtPrice() public view returns (uint160) {
        bytes32 slot = keccak256(abi.encodePacked(oracle.yoloPoolId(), bytes32(uint256(6))));
        return uint160(uint256(PM.extsload(slot)));
    }

    function buy(uint256 imdIn) external {
        PM.unlock(abi.encode(uint8(0), imdIn));
    }

    function attack() external returns (bool sampled) {
        return abi.decode(PM.unlock(abi.encode(uint8(1), uint256(0))), (bool));
    }

    /// @dev A sample needs its own EOA transaction: sell owned YOLO down to the bottom here, the
    ///      sample next, the buy-back after (a bundle).
    function sellDown() external {
        PM.unlock(abi.encode(uint8(2), uint256(0)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(PM));
        (uint8 mode, uint256 imdIn) = abi.decode(data, (uint8, uint256));
        IPM.PoolKey memory key = _key();
        int256 d0;
        int256 d1;
        bool sampled;
        if (mode == 0) {
            (d0, d1) = _swap(key, false, -int256(imdIn), yoloIs0 ? MAX_SQRT - 1 : MIN_SQRT + 1);
        } else if (mode == 2) {
            (d0, d1) = _swap(key, true, -1e30, yoloIs0 ? MIN_SQRT + 1 : MAX_SQRT - 1);
        } else {
            uint160 start = sqrtPrice();
            // sell YOLO (that the attacker need not own: flash accounting) down to the extreme price
            (int256 a0, int256 a1) = _swap(key, true, -1e30, yoloIs0 ? MIN_SQRT + 1 : MAX_SQRT - 1);
            sampled = oracle.sampleYoloPrice();
            // buy it back up to exactly the starting price
            (int256 b0, int256 b1) = _swap(key, false, -1e30, start);
            (d0, d1) = (a0 + b0, a1 + b1);
            require(sqrtPrice() == start, "price restored");
        }
        _settle(key.currency0, d0);
        _settle(key.currency1, d1);
        return abi.encode(sampled);
    }

    /// @param sellYolo true: YOLO in, IMD out
    function _swap(IPM.PoolKey memory key, bool sellYolo, int256 amount, uint160 limit)
        internal
        returns (int256 d0, int256 d1)
    {
        bool zeroForOne = sellYolo == yoloIs0;
        int256 delta = PM.swap(key, IPM.SwapParams(zeroForOne, amount, limit), "");
        d0 = int256(int128(delta >> 128));
        d1 = int256(int128(delta));
    }

    function _settle(address c, int256 d) internal {
        if (d < 0) {
            PM.sync(c);
            IERC20(c).transfer(address(PM), uint256(-d));
            PM.settle();
        } else if (d > 0) {
            PM.take(c, address(this), uint256(d));
        }
    }
}

/// @dev The attack on the live factory pool: launch 1 (custom_token, $YOLO pool opened by the factory) and launch 2
///      on a mainnet fork, honest samples every 15 minutes, buyers put IMD into the pool, then ONE transaction that
///      swaps down, samples and swaps back. Measures its cost and what a doer of a large $YOLO task gains.
contract ReviewYoloFork is ReviewLaunchForkBase {
    ITaskVault vault;
    ChainlinkUniV3PriceOracle oracle;
    V4YoloTrader trader;
    address constant KEEPER = address(0x5EED);

    function setUp() public override {
        super.setUp();
        address[] memory core = _launchCore();
        vault = ITaskVault(core[2]);
        oracle = ChainlinkUniV3PriceOracle(s.priceOracle);
        trader = new V4YoloTrader(yolo, oracle);
        // past $YOLO's first hour (NFT gate, then the buy tax)
        vm.warp(vm.getBlockTimestamp() + 61 minutes);
        vm.roll(vm.getBlockNumber() + 155);
    }

    function _fresh(address feed) internal {
        (uint80 id, int256 answer, uint256 startedAt,, uint80 answeredIn) = IAggregatorRound(feed).latestRoundData();
        vm.mockCall(
            feed,
            abi.encodeWithSelector(IAggregatorRound.latestRoundData.selector),
            abi.encode(id, answer, startedAt, vm.getBlockTimestamp(), answeredIn)
        );
    }

    /// @dev The keeper stores a sample: a read, then the store a block later with the pool unchanged (swarm audit #1).
    function _keeperSample() internal {
        vm.prank(KEEPER, KEEPER);
        assertFalse(oracle.sampleYoloPrice());
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(KEEPER, KEEPER);
        assertTrue(oracle.sampleYoloPrice());
    }

    function _next() internal {
        vm.warp(vm.getBlockTimestamp() + 15 minutes);
        vm.roll(vm.getBlockNumber() + 75);
        _fresh(LaunchPlan.CL_USDC_USD);
        _fresh(LaunchPlan.CL_ETH_USD);
    }

    function _submitLarge(uint256 taskId) internal returns (Submission memory) {
        address doer = makeAddr("yoloDoer");
        deal(LaunchPlan.IMD, doer, 1_000e18);
        vm.prank(doer);
        IERC20(LaunchPlan.IMD).approve(address(vault), type(uint256).max);
        ImdPay memory none;
        Evidence memory noEvidence;
        vm.prank(doer);
        uint256 subId = vault.submit(taskId, "https://example.com/proof", noEvidence, 0, type(uint256).max, none);
        return vault.getSubmission(subId);
    }

    function _attackAtDepth(uint256 imdBought) internal {
        // buyers: `imdBought` IMD into the pool (the IMD the attacker must sell through)
        deal(LaunchPlan.IMD, address(trader), imdBought + 10_000e18);
        if (imdBought != 0) trader.buy(imdBought);
        // a large $YOLO task, created while there is no price yet (no USD minimum)
        uint256 R = 100_000_000e18; // 10% of the supply: 1,500 IMD at the launch price
        address author = makeAddr("yoloAuthor");
        deal(yolo, author, R);
        vm.deal(author, 1 ether);
        vm.prank(author);
        IERC20(yolo).approve(address(vault), R);
        ImdPay memory none;
        vm.prank(author);
        uint256 taskId = vault.createTask{value: 0.0005 ether}(
            yolo, R, 0, "YOLO task", "Post the doer code on X", 0, 3, "", 0.0005 ether, none
        );
        // four honest samples, 15 minutes apart (from a plain EOA)
        for (uint256 i; i < 4; ++i) {
            _keeperSample();
            _next();
        }
        uint256 snap = vm.snapshotState();
        _keeperSample(); // the honest fifth sample
        Submission memory honest = _submitLarge(taskId);
        uint256 honestUsd = oracle.usdValue(yolo, R);
        vm.revertToState(snap);

        // the attack in one transaction: the oracle refuses a sample from a contract
        deal(yolo, address(trader), 400_000_000e18); // enough to sell through everything the buyers took
        vm.expectRevert();
        trader.attack();
        // the bundle variant: sell owned YOLO to the bottom, sample from an EOA, buy back. The floor holds.
        trader.sellDown();
        _keeperSample(); // held across the block (no buy back yet): stored, and the floor still holds
        assertTrue(oracle.hasPrice(yolo));
        uint256 attackedUsd = oracle.usdValue(yolo, R);
        Submission memory attacked = _submitLarge(taskId);

        console.log("pool depth: IMD bought by others", imdBought / 1e18);
        console.log("  100M YOLO in USD (1e18): honest / attacked", honestUsd, attackedUsd);
        console.log("  doer Bond IMD: honest / attacked", honest.bond, attacked.bond);
        console.log("  mandatory swarm check: honest / attacked", honest.large, attacked.large);
        assertTrue(honest.large, "honest: the task is large and checked");
        assertTrue(attacked.large, "fixed: still checked at the opening price");
        assertGt(attacked.bond, 1e18, "fixed: the Bond is sized at the opening price, not the minimum");
        // and $YOLO tasks can still be created
        address author2 = makeAddr("yoloAuthor2");
        deal(yolo, author2, R);
        vm.deal(author2, 1 ether);
        vm.prank(author2);
        IERC20(yolo).approve(address(vault), R);
        vm.prank(author2);
        vault.createTask{value: 0.0005 ether}(yolo, R, 0, "T", "c", 0, 3, "", 0.0005 ether, none);
    }

    /// Fresh pool (nobody bought yet): the attack used to cost gas only.
    function test_Y6_attack_freshPool() public {
        _attackAtDepth(0);
    }

    /// 5,000 IMD (~$40k) bought by others: the attacker sells through it and buys it back (2 x 1.25% fee).
    function test_Y6_attack_5000ImdDepth() public {
        _attackAtDepth(5_000e18);
    }
}
