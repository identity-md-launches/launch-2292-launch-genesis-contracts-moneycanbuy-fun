// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Launch 0 (the genesis contracts) under random call sequences: the YoloSplitter and the four vestings are the
// contracts of this launch that hold value, the NftGate keeps per-token books. The handlers drive them with bounded
// inputs and several callers; the invariants are what must hold after every sequence. Beside them, failure paths and
// boundaries the earlier suites do not pin.

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {NftGate} from "src/token/NftGate.sol";
import {ProjectVesting} from "src/token/ProjectVesting.sol";
import {IncentivesVesting, DevVesting, TeamVesting, TreasuryVesting} from "src/token/Vestings.sol";
import {YoloSplitter} from "src/token/YoloSplitter.sol";
import {LaunchPlan, LocalFactory} from "../../script/LaunchPlan.sol";

contract GenesisToken is ERC20 {
    constructor() ERC20("Y", "Y") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Deploys launch 0 with the mainnet arguments through the local factory in one call, as the launch does.
library GenesisDeploy {
    function deploy() internal returns (LaunchPlan.Genesis memory g) {
        LocalFactory f = new LocalFactory();
        bytes[] memory codes;
        (codes,, g) = LaunchPlan.genesisLaunch(f, 0, LaunchPlan.projectOwners());
        f.launchContracts(0, codes);
    }
}

// ------------------------------------------------------------------------------------------------------------------
// Splitter + vestings
// ------------------------------------------------------------------------------------------------------------------

contract SplitHandler is Test {
    uint256 constant FIXED = 527_777_777e18;

    GenesisToken public immutable yolo;
    YoloSplitter public immutable sp;
    ProjectVesting[4] public vs;
    address[4] public bens;
    address[3] public actors;

    // ghosts
    uint256 public minted; // everything ever created (to the splitter or straight to a vesting)
    uint256 public toSplitter; // everything ever sent to the splitter
    uint256[4] public inflow; // everything ever sent to each vesting (by the splitter or by a third party)
    uint256 public splitAt; // timestamp of the first split (0: not yet)
    uint256[4] public lastVested; // vestedAmount at the last check, per vesting: never goes down
    uint256 public violations; // calls that broke a rule inside the handler (a revert where none is allowed, ...)
    uint256 public splits;
    uint256 public releases;

    constructor(GenesisToken y, LaunchPlan.Genesis memory g) {
        yolo = y;
        sp = YoloSplitter(g.splitter);
        vs = [ProjectVesting(g.incentives), ProjectVesting(g.dev), ProjectVesting(g.team), ProjectVesting(g.treasury)];
        for (uint256 i; i < 4; ++i) {
            bens[i] = vs[i].beneficiary();
        }
        actors = [makeAddr("anyone1"), makeAddr("anyone2"), makeAddr("anyone3")];
    }

    function vesting(uint256 i) external view returns (ProjectVesting) {
        return vs[i];
    }

    function ben(uint256 i) external view returns (address) {
        return bens[i];
    }

    function actor(uint256 i) external view returns (address) {
        return actors[i];
    }

    /// The factory's remainder, or anything arriving later.
    function arrive(uint256 amount) external {
        amount = bound(amount, 0, 800_000_000e18);
        yolo.mint(address(sp), amount);
        minted += amount;
        toSplitter += amount;
    }

    /// A third party sends the token straight to a vesting.
    function donate(uint256 i, uint256 amount) external {
        i = bound(i, 0, 3);
        amount = bound(amount, 0, 10_000_000e18);
        yolo.mint(address(vs[i]), amount);
        minted += amount;
        inflow[i] += amount;
    }

    function split(uint256 who) external {
        address caller = actors[bound(who, 0, 2)];
        uint256 bal = yolo.balanceOf(address(sp));
        bool wasDone = sp.done(address(yolo));
        uint256[4] memory before;
        for (uint256 i; i < 4; ++i) {
            before[i] = yolo.balanceOf(address(vs[i])) + vs[i].released(address(yolo));
        }
        vm.prank(caller);
        try sp.split(address(yolo)) {
            if (!wasDone && bal <= FIXED) violations++; // split before the fixed shares arrived
            if (!wasDone) splitAt = block.timestamp;
            splits++;
        } catch {
            if (wasDone || bal > FIXED) violations++; // a split that must go through was refused
            return;
        }
        for (uint256 i; i < 4; ++i) {
            inflow[i] += yolo.balanceOf(address(vs[i])) + vs[i].released(address(yolo)) - before[i];
        }
    }

    function release(uint256 i, uint256 who) external {
        i = bound(i, 0, 3);
        address caller = actors[bound(who, 0, 2)];
        uint256 due = vs[i].releasable(address(yolo));
        uint256 benBefore = yolo.balanceOf(bens[i]);
        vm.prank(caller);
        try vs[i].release(address(yolo)) {
            if (yolo.balanceOf(bens[i]) - benBefore != due) violations++; // paid other than what was open
            releases++;
        } catch {
            violations++; // release never reverts for a plain token
        }
    }

    function warp(uint256 dt) external {
        dt = bound(dt, 0, 120 days);
        vm.warp(block.timestamp + dt);
    }

    /// Records vestedAmount for the monotonicity check (it is a view, so it is also called from the invariant).
    function touch() public {
        for (uint256 i; i < 4; ++i) {
            uint256 v = vs[i].vestedAmount(address(yolo), block.timestamp);
            if (v < lastVested[i]) violations++;
            lastVested[i] = v;
        }
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 60
contract SplitterVestingInvariantTest is Test {
    GenesisToken yolo;
    LaunchPlan.Genesis g;
    SplitHandler h;
    YoloSplitter sp;

    function setUp() public {
        vm.warp(1_800_000_000);
        g = GenesisDeploy.deploy();
        yolo = new GenesisToken();
        sp = YoloSplitter(g.splitter);
        h = new SplitHandler(yolo, g);
        targetContract(address(h));
        bytes4[] memory sel = new bytes4[](6);
        sel[0] = SplitHandler.arrive.selector;
        sel[1] = SplitHandler.donate.selector;
        sel[2] = SplitHandler.split.selector;
        sel[3] = SplitHandler.release.selector;
        sel[4] = SplitHandler.warp.selector;
        sel[5] = SplitHandler.touch.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: sel}));
    }

    /// No rule broken inside a call: splits go through exactly when they may, releases never revert and pay exactly
    /// what was open, vested amounts never go down.
    function invariant_noHandlerViolation() public {
        h.touch();
        assertEq(h.violations(), 0);
    }

    /// Nothing is lost and nobody but the five fixed recipients is ever paid: what was created sits in the splitter,
    /// the vestings, the four beneficiaries and the stabilizer.
    function invariant_conservation() public view {
        uint256 sum = yolo.balanceOf(address(sp)) + yolo.balanceOf(LaunchPlan.PROJECT_STABILIZER);
        for (uint256 i; i < 4; ++i) {
            sum += yolo.balanceOf(address(h.vesting(i))) + yolo.balanceOf(h.ben(i));
        }
        assertEq(sum, h.minted());
        for (uint256 i; i < 3; ++i) {
            assertEq(yolo.balanceOf(h.actor(i)), 0, "a caller was paid");
        }
    }

    /// Each vesting: what it holds plus what it released equals what it received; the beneficiary holds exactly what
    /// was released; released never exceeds what the schedule opened, nor what arrived.
    function invariant_vestingBooks() public view {
        for (uint256 i; i < 4; ++i) {
            ProjectVesting v = h.vesting(i);
            uint256 rel = v.released(address(yolo));
            uint256 total = yolo.balanceOf(address(v)) + rel;
            assertEq(total, h.inflow(i), "held + released != received");
            assertEq(yolo.balanceOf(h.ben(i)), rel, "beneficiary != released");
            uint256 vested = v.vestedAmount(address(yolo), block.timestamp);
            assertLe(rel, vested, "released beyond the schedule");
            assertLe(vested, total, "vested beyond what arrived");
            uint256 free = total < v.unlocked() ? total : v.unlocked();
            assertGe(vested, free, "at-once part not free");
        }
    }

    /// The fixed shares are paid once, exactly, at the first split; the treasury vesting takes everything else that
    /// reached the splitter and left it; before the split nothing left the splitter and no clock runs.
    function invariant_sharesAndClocks() public view {
        bool done = sp.done(address(yolo));
        uint256 stab = yolo.balanceOf(LaunchPlan.PROJECT_STABILIZER);
        if (!done) {
            assertEq(h.splitAt(), 0);
            assertEq(stab, 0);
            assertEq(yolo.balanceOf(address(sp)), h.toSplitter(), "left the splitter before the split");
            for (uint256 i; i < 4; ++i) {
                assertEq(h.vesting(i).startOf(address(yolo)), 0, "a clock before the split");
            }
            return;
        }
        assertEq(stab, 150_000_000e18, "stabilizer share");
        uint256 out = h.toSplitter() - yolo.balanceOf(address(sp));
        uint256[4] memory fixedShare = [uint256(250_000_000e18), 77_777_777e18, 50_000_000e18, 0];
        uint256 sumFixed;
        for (uint256 i; i < 4; ++i) {
            ProjectVesting v = h.vesting(i);
            assertEq(v.startOf(address(yolo)), h.splitAt(), "clock starts at the first split, once");
            sumFixed += fixedShare[i];
        }
        // what each vesting got from the splitter = inflow minus third-party donations; checked through the totals
        uint256 fromSplitterToVestings = out - 150_000_000e18;
        assertGe(fromSplitterToVestings, sumFixed);
        // treasury's take from the splitter is everything above the fixed 527,777,777
        assertGe(out, 527_777_777e18 + 1);
        // a vesting is fully open one full duration after the split
        for (uint256 i; i < 4; ++i) {
            ProjectVesting v = h.vesting(i);
            if (block.timestamp >= h.splitAt() + v.duration()) {
                assertEq(
                    v.vestedAmount(address(yolo), block.timestamp),
                    yolo.balanceOf(address(v)) + v.released(address(yolo)),
                    "not fully open after its duration"
                );
            }
        }
    }
}

// ------------------------------------------------------------------------------------------------------------------
// NftGate
// ------------------------------------------------------------------------------------------------------------------

contract GateCaller {
    function consume(NftGate g, address buyer, uint256 amount) external returns (uint256, uint256) {
        return g.consume(buyer, amount);
    }
}

contract GateHandler is Test {
    uint256 constant PER = 500_000e18;
    NftGate public immutable gate;
    address public immutable writer;
    GateCaller[2] public tokens;
    address[6] public wallets;

    // ghosts
    mapping(address => uint256) public nfts;
    mapping(address => mapping(address => uint256)) public usedG;
    uint256 public totalNfts;
    uint256 public count;
    bytes32 public hash;
    bool public sealed_;
    uint256 public sealedAt;
    bytes32 public sealedHash;
    uint256 public violations;
    uint256 public accepted;

    constructor(NftGate g) {
        gate = g;
        writer = g.writer();
        tokens = [new GateCaller(), new GateCaller()];
        for (uint256 i; i < 6; ++i) {
            wallets[i] = address(uint160(uint256(keccak256(abi.encode("wallet", i)))));
        }
    }

    function wallet(uint256 i) external view returns (address) {
        return wallets[i];
    }

    function token(uint256 i) external view returns (address) {
        return address(tokens[i]);
    }

    function record(uint256 w, uint256 c, bool asWriter) external {
        address a = wallets[bound(w, 0, 5)];
        c = bound(c, 0, 30);
        address[] memory acc = new address[](1);
        uint256[] memory n = new uint256[](1);
        (acc[0], n[0]) = (a, c);
        vm.prank(asWriter ? writer : wallets[0]);
        try gate.record(acc, n) {
            if (!asWriter || sealed_ || c == 0 || nfts[a] != 0) violations++;
            nfts[a] = c;
            totalNfts += c;
            count++;
            hash = keccak256(abi.encode(hash, a, c));
        } catch {
            if (asWriter && !sealed_ && c != 0 && nfts[a] == 0) violations++;
        }
    }

    function seal(uint256 blockNo, bool asWriter) external {
        vm.prank(asWriter ? writer : wallets[1]);
        try gate.seal(blockNo) {
            if (!asWriter || sealed_ || count == 0) violations++;
            sealed_ = true;
            sealedAt = block.timestamp;
            sealedHash = hash;
        } catch {
            if (asWriter && !sealed_ && count != 0) violations++;
        }
    }

    function consume(uint256 t, uint256 w, uint256 amount) external {
        GateCaller tk = tokens[bound(t, 0, 1)];
        address b = wallets[bound(w, 0, 5)];
        uint256 allowance = nfts[b] * PER;
        // around the edge of what is left, sometimes far above
        amount = bound(amount, 0, allowance + 2 * PER);
        try tk.consume(gate, b, amount) returns (uint256 al, uint256 before) {
            if (!sealed_) violations++;
            if (al != allowance || before != usedG[address(tk)][b]) violations++;
            if (amount <= allowance - before) {
                usedG[address(tk)][b] = before + amount;
                accepted++;
            }
        } catch {
            if (sealed_) violations++;
        }
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 1 hours));
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 60
contract NftGateInvariantTest is Test {
    NftGate gate;
    GateHandler h;

    function setUp() public {
        vm.warp(1_800_000_000);
        gate = NftGate(GenesisDeploy.deploy().gate);
        h = new GateHandler(gate);
        targetContract(address(h));
    }

    function invariant_noHandlerViolation() public view {
        assertEq(h.violations(), 0);
    }

    /// The snapshot as written: counts, total, wallet count and the running hash snapshot.py recomputes.
    function invariant_snapshotMatchesWhatWasWritten() public view {
        assertEq(gate.totalNfts(), h.totalNfts());
        assertEq(gate.walletCount(), h.count());
        assertEq(gate.snapshotHash(), h.hash());
        for (uint256 i; i < 6; ++i) {
            address w = h.wallet(i);
            assertEq(gate.nftsOf(w), h.nfts(w));
            assertEq(gate.allowanceOf(w), h.nfts(w) * 500_000e18);
        }
    }

    /// A sealed snapshot never reopens and never changes.
    function invariant_sealIsFinal() public view {
        if (!h.sealed_()) {
            assertEq(gate.sealedAt(), 0);
            return;
        }
        assertEq(gate.sealedAt(), h.sealedAt());
        assertEq(gate.snapshotHash(), h.sealedHash());
    }

    /// No buyer is ever booked beyond its allowance, by any calling token, and each token's books are its own.
    function invariant_usedWithinAllowance() public view {
        for (uint256 t; t < 2; ++t) {
            address tk = h.token(t);
            for (uint256 i; i < 6; ++i) {
                address w = h.wallet(i);
                uint256 u = gate.used(tk, w);
                assertEq(u, h.usedG(tk, w), "books differ from the accepted buys");
                assertLe(u, gate.allowanceOf(w), "booked beyond the allowance");
                assertEq(gate.left(tk, w), gate.allowanceOf(w) - u);
            }
        }
        // the gate holds nothing
        assertEq(address(gate).balance, 0);
    }
}

// ------------------------------------------------------------------------------------------------------------------
// Failure paths and boundaries
// ------------------------------------------------------------------------------------------------------------------

contract GenesisEdgesTest is Test {
    uint256 constant FIXED = 527_777_777e18;
    GenesisToken yolo;
    LaunchPlan.Genesis g;
    YoloSplitter sp;
    address writer = LaunchPlan.PROJECT_TREASURY;

    function setUp() public {
        vm.warp(1_800_000_000);
        g = GenesisDeploy.deploy();
        sp = YoloSplitter(g.splitter);
        yolo = new GenesisToken();
    }

    function _vs() internal view returns (ProjectVesting[4] memory) {
        return [ProjectVesting(g.incentives), ProjectVesting(g.dev), ProjectVesting(g.team), ProjectVesting(g.treasury)];
    }

    // ---- splitter

    /// Exactly the fixed shares is not enough; one wei more splits, the treasury vesting takes that wei and frees it
    /// at once (it is below its at-once part).
    function test_split_boundaryAtFixedPlusOneWei() public {
        yolo.mint(address(sp), FIXED);
        vm.expectRevert(abi.encodeWithSelector(YoloSplitter.NotArrived.selector, FIXED));
        sp.split(address(yolo));
        yolo.mint(address(sp), 1);
        sp.split(address(yolo));
        assertEq(yolo.balanceOf(LaunchPlan.PROJECT_TREASURY), 1);
        assertEq(yolo.balanceOf(g.treasury), 0);
        assertEq(ProjectVesting(g.treasury).startOf(address(yolo)), block.timestamp);
    }

    /// An empty splitter refuses, for any token, and nothing is marked done.
    function test_split_emptyRefusesAndMarksNothing() public {
        vm.expectRevert(abi.encodeWithSelector(YoloSplitter.NotArrived.selector, 0));
        sp.split(address(yolo));
        assertFalse(sp.done(address(yolo)));
    }

    /// A call on an address that is not a token reverts and changes nothing.
    function test_split_nonTokenReverts() public {
        vm.expectRevert();
        sp.split(address(0xBEEF));
        vm.expectRevert();
        sp.split(address(0));
    }

    /// After the split, a later call with nothing new is a no-op; later arrivals all go to the treasury vesting and
    /// the fixed recipients get nothing more.
    function testFuzz_split_laterArrivalsOnlyToTreasury(uint256 first, uint256 later) public {
        first = bound(first, FIXED + 1, 1_000_000_000e18);
        later = bound(later, 0, 1_000_000_000e18);
        yolo.mint(address(sp), first);
        sp.split(address(yolo));
        uint256 tv = yolo.balanceOf(g.treasury) + yolo.balanceOf(LaunchPlan.PROJECT_TREASURY);
        assertEq(tv, first - FIXED);
        sp.split(address(yolo));
        yolo.mint(address(sp), later);
        vm.prank(makeAddr("anyone"));
        sp.split(address(yolo));
        assertEq(yolo.balanceOf(address(sp)), 0);
        assertEq(yolo.balanceOf(g.treasury) + yolo.balanceOf(LaunchPlan.PROJECT_TREASURY), first - FIXED + later);
        assertEq(yolo.balanceOf(LaunchPlan.PROJECT_STABILIZER), 150_000_000e18);
        assertEq(yolo.balanceOf(g.dev), 77_777_777e18);
        assertEq(yolo.balanceOf(g.team), 50_000_000e18);
        assertEq(yolo.balanceOf(g.incentives) + yolo.balanceOf(LaunchPlan.PROJECT_INCENTIVES), 250_000_000e18);
    }

    /// Splitting one token starts no clock of another: a decoy split cannot start the $YOLO clocks early.
    function test_split_otherTokenStartsNoYoloClock() public {
        GenesisToken decoy = new GenesisToken();
        decoy.mint(address(sp), FIXED + 1);
        yolo.mint(g.dev, 1_000e18); // $YOLO already at a vesting before its split
        sp.split(address(decoy));
        ProjectVesting[4] memory vs = _vs();
        for (uint256 i; i < 4; ++i) {
            assertEq(vs[i].startOf(address(yolo)), 0);
        }
        skip(400 days);
        assertEq(ProjectVesting(g.dev).releasable(address(yolo)), 0, "no $YOLO clock from a decoy");
    }

    /// The splitter cannot bind the same vesting twice: passing one vesting for two roles fails in the constructor.
    function test_splitter_sameVestingTwiceRevertsInConstructor() public {
        DevVesting d = new DevVesting(LaunchPlan.PROJECT_DEV);
        vm.expectRevert(ProjectVesting.BindingClosed.selector);
        new YoloSplitter(address(d), address(d), makeAddr("t"), makeAddr("tr"), LaunchPlan.PROJECT_STABILIZER);
    }

    /// Each of the five constructor arguments refuses the zero address on its own.
    function test_splitter_eachZeroArgumentRefused() public {
        address[5] memory a = [makeAddr("a"), makeAddr("b"), makeAddr("c"), makeAddr("d"), makeAddr("e")];
        for (uint256 i; i < 5; ++i) {
            address[5] memory b = a;
            b[i] = address(0);
            vm.expectRevert(YoloSplitter.ZeroAddress.selector);
            new YoloSplitter(b[0], b[1], b[2], b[3], b[4]);
        }
    }

    // ---- vestings

    /// Only the splitter starts a clock: neither a beneficiary nor the gate writer nor anyone else can, even with
    /// $YOLO already at the vesting.
    function test_vesting_onlyStarterStartsAClock() public {
        ProjectVesting[4] memory vs = _vs();
        address[3] memory callers = [LaunchPlan.PROJECT_DEV, writer, makeAddr("x")];
        for (uint256 i; i < 4; ++i) {
            yolo.mint(address(vs[i]), 1e18);
            for (uint256 j; j < 3; ++j) {
                vm.prank(callers[j]);
                vs[i].release(address(yolo));
                assertEq(vs[i].startOf(address(yolo)), 0);
            }
        }
    }

    /// The starter's release with nothing held starts no clock (a dust-free clock cannot be started empty).
    function test_vesting_starterWithEmptyBalanceStartsNoClock() public {
        vm.prank(address(sp));
        ProjectVesting(g.dev).release(address(yolo));
        assertEq(ProjectVesting(g.dev).startOf(address(yolo)), 0);
    }

    /// bindStarter is closed after the deployment transaction, for everyone including the splitter.
    function test_vesting_bindClosedForEveryoneLater() public {
        ProjectVesting[4] memory vs = _vs();
        for (uint256 i; i < 4; ++i) {
            vm.prank(address(sp));
            vm.expectRevert(ProjectVesting.BindingClosed.selector);
            vs[i].bindStarter();
            vm.expectRevert(ProjectVesting.BindingClosed.selector);
            vs[i].bindStarter();
            assertEq(vs[i].starter(), address(sp));
        }
    }

    /// Release on a non-token reverts (no silent success that could mark anything).
    function test_vesting_releaseNonTokenReverts() public {
        vm.expectRevert();
        ProjectVesting(g.dev).release(address(0xBEEF));
    }

    /// The four schedules at an arbitrary time after a split of an arbitrary remainder: never more than arrived,
    /// at least the at-once part, linear in between, everything after the duration; repeated releases add up to the
    /// one-shot amount (no dust farmed by calling often).
    function testFuzz_vesting_schedulesAtAnyTime(uint256 remainder, uint256 t1, uint256 t2) public {
        remainder = bound(remainder, FIXED + 1, 800_000_000e18);
        t1 = bound(t1, 0, 800 days);
        t2 = bound(t2, t1, 800 days);
        yolo.mint(address(sp), remainder);
        sp.split(address(yolo));
        // the clock's start, read from the vesting (via-IR may re-read block.timestamp after a warp)
        uint256 t0 = ProjectVesting(g.dev).startOf(address(yolo));
        uint256[4] memory share = [uint256(250_000_000e18), 77_777_777e18, 50_000_000e18, remainder - FIXED];
        ProjectVesting[4] memory vs = _vs();
        vm.warp(t0 + t1);
        for (uint256 i; i < 4; ++i) {
            vs[i].release(address(yolo));
        }
        vm.warp(t0 + t2);
        for (uint256 i; i < 4; ++i) {
            vs[i].release(address(yolo));
            uint256 free = share[i] < vs[i].unlocked() ? share[i] : vs[i].unlocked();
            uint256 d = vs[i].duration();
            uint256 expected = t2 >= d ? share[i] : free + (share[i] - free) * t2 / d;
            assertEq(vs[i].released(address(yolo)), expected, "two releases != schedule");
            assertEq(yolo.balanceOf(address(vs[i])), share[i] - expected);
        }
    }

    // ---- gate

    function _one(address a, uint256 c) internal pure returns (address[] memory w, uint256[] memory n) {
        w = new address[](1);
        n = new uint256[](1);
        (w[0], n[0]) = (a, c);
    }

    /// The same wallet twice in one batch is refused and the whole batch is undone.
    function test_gate_duplicateInOneBatchRevertsWholeBatch() public {
        NftGate gate = NftGate(g.gate);
        address a = makeAddr("a");
        address b = makeAddr("b");
        address[] memory w = new address[](3);
        uint256[] memory n = new uint256[](3);
        (w[0], w[1], w[2]) = (a, b, a);
        (n[0], n[1], n[2]) = (1, 2, 3);
        vm.prank(writer);
        vm.expectRevert(abi.encodeWithSelector(NftGate.AlreadyRecorded.selector, a));
        gate.record(w, n);
        assertEq(gate.nftsOf(a), 0);
        assertEq(gate.nftsOf(b), 0);
        assertEq(gate.walletCount(), 0);
        assertEq(gate.snapshotHash(), bytes32(0));
    }

    /// An empty batch, a length mismatch and a zero entry at any index are refused.
    function test_gate_badBatchesRefused() public {
        NftGate gate = NftGate(g.gate);
        vm.startPrank(writer);
        vm.expectRevert(NftGate.BadBatch.selector);
        gate.record(new address[](0), new uint256[](0));
        vm.expectRevert(NftGate.BadBatch.selector);
        gate.record(new address[](1), new uint256[](2));
        address[] memory w = new address[](2);
        uint256[] memory n = new uint256[](2);
        (w[0], w[1]) = (makeAddr("a"), address(0));
        (n[0], n[1]) = (1, 1);
        vm.expectRevert(abi.encodeWithSelector(NftGate.ZeroEntry.selector, 1));
        gate.record(w, n);
        (w[1], n[1]) = (makeAddr("b"), 0);
        vm.expectRevert(abi.encodeWithSelector(NftGate.ZeroEntry.selector, 1));
        gate.record(w, n);
        vm.expectRevert(NftGate.EmptySnapshot.selector);
        gate.seal(1);
        vm.stopPrank();
    }

    /// Booking at the edge: exactly what is left books, one wei more books nothing and returns the same figures.
    function testFuzz_gate_consumeExactEdge(uint256 nftCount, uint256 first) public {
        nftCount = bound(nftCount, 1, 2_000);
        NftGate gate = NftGate(g.gate);
        address buyer = makeAddr("buyer");
        (address[] memory w, uint256[] memory n) = _one(buyer, nftCount);
        vm.startPrank(writer);
        gate.record(w, n);
        gate.seal(123);
        vm.stopPrank();
        uint256 allowance = nftCount * 500_000e18;
        first = bound(first, 0, allowance);
        GateCaller tk = new GateCaller();
        (uint256 al, uint256 before) = tk.consume(gate, buyer, first);
        assertEq(al, allowance);
        assertEq(before, 0);
        uint256 rest = allowance - first;
        (, before) = tk.consume(gate, buyer, rest + 1);
        assertEq(before, first);
        assertEq(gate.used(address(tk), buyer), first, "over the edge booked nothing");
        tk.consume(gate, buyer, rest);
        assertEq(gate.used(address(tk), buyer), allowance);
        assertEq(gate.left(address(tk), buyer), 0);
        (, before) = tk.consume(gate, buyer, 1);
        assertEq(before, allowance);
        assertEq(gate.used(address(tk), buyer), allowance);
        // another caller's books are untouched
        assertEq(gate.used(address(this), buyer), 0);
        assertEq(gate.left(address(this), buyer), allowance);
    }

    /// A wallet outside the snapshot has a zero allowance: any positive amount books nothing, zero books zero.
    function test_gate_outsiderBooksNothing() public {
        NftGate gate = NftGate(g.gate);
        (address[] memory w, uint256[] memory n) = _one(makeAddr("holder"), 1);
        vm.startPrank(writer);
        gate.record(w, n);
        gate.seal(1);
        vm.stopPrank();
        address out = makeAddr("outsider");
        (uint256 al, uint256 before) = gate.consume(out, 1);
        assertEq(al, 0);
        assertEq(before, 0);
        assertEq(gate.used(address(this), out), 0);
        gate.consume(out, 0);
        assertEq(gate.used(address(this), out), 0);
    }

    /// The writer's constructor check, and the gate never needs the NFT contract to exist.
    function test_gate_constructorRefusesZeroWriterOnly() public {
        vm.expectRevert(NftGate.NotWriter.selector);
        new NftGate(LaunchPlan.NFT, address(0));
        NftGate gate = new NftGate(address(0), writer);
        assertEq(gate.nft(), address(0));
    }
}
