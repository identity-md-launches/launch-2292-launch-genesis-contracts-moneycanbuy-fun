// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import "./Base.t.sol";

/// @dev Random sequences of every user action over a few tasks. Every call is wrapped in try/catch.
contract Handler is CommonBase, StdCheats, StdUtils {
    ITaskVault internal vault;
    YoloSweetener internal sweetener;
    DareTrophy internal trophy;
    MockIntake internal intake;
    uint256 internal attesterKey;
    address[] internal people; // authors / contributors / doers / disputers
    uint256[5] internal voterKeys;
    address[5] internal voterAddrs;
    uint256[] public tasks;
    uint256[] public subs;
    mapping(bytes32 => uint256) internal _calls;

    function calls(bytes32 k) external view returns (uint256) {
        return _calls[k];
    }

    constructor(
        ITaskVault v,
        MockIntake i,
        uint256 attKey,
        address[] memory p,
        uint256[5] memory vk,
        address[5] memory va,
        YoloSweetener sw,
        DareTrophy tr
    ) {
        vault = v;
        sweetener = sw;
        trophy = tr;
        intake = i;
        attesterKey = attKey;
        people = p;
        voterKeys = vk;
        voterAddrs = va;
    }

    function taskCount() external view returns (uint256) {
        return tasks.length;
    }

    function _who(uint256 seed) internal view returns (address) {
        return people[seed % people.length];
    }

    function _task(uint256 seed) internal view returns (uint256) {
        return tasks.length == 0 ? 0 : tasks[seed % tasks.length];
    }

    function _sub(uint256 seed) internal view returns (uint256) {
        return subs.length == 0 ? 0 : subs[seed % subs.length];
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    // ------------------------------------------------------------------ actions

    function createTask(uint256 seed, uint256 amount) external {
        uint256 c = seed % 4;
        address cur = c == 0 ? ETH : c == 1 ? vault.usdc() : c == 2 ? vault.imd() : vault.yolo();
        if (c == 0) amount = bound(amount, 0.002 ether, 1 ether);
        else if (c == 1) amount = bound(amount, 5e6, 1_000e6);
        else if (c == 2) amount = bound(amount, 1e18, 100e18);
        else amount = bound(amount, 50_000e18, 10_000_000e18); // $5..$1,000 at $0.0001
        ImdPay memory none;
        vm.prank(_who(seed));
        try vault.createTask{value: 0.001 ether + (c == 0 ? amount : 0)}(
            cur, amount, 0, "Title", "c", 0, 0, "", 0.001 ether, none
        ) returns (
            uint256 id
        ) {
            tasks.push(id);
            _calls[keccak256("createTask")]++;
        } catch {}
    }

    function topUp(uint256 seed, uint256 amount) external {
        uint256 t = _task(seed);
        if (t == 0) return;
        address cur = vault.getTask(t).currency;
        amount = bound(
            amount, 1, cur == ETH ? 0.5 ether : cur == vault.usdc() ? 500e6 : cur == vault.imd() ? 50e18 : 5_000_000e18
        );
        ImdPay memory none;
        vm.prank(_who(seed >> 8));
        try vault.topUp{value: cur == ETH ? amount : 0}(t, amount, none) {
            _calls[keccak256("topUp")]++;
        } catch {}
    }

    function withdrawContribution(uint256 seed) external {
        uint256 t = _task(seed);
        address who = _who(seed >> 8);
        vm.prank(who);
        try vault.withdrawContribution(t) {
            _calls[keccak256("withdrawContribution")]++;
        } catch {
            // the active share of an open task needs an hour of notice first (swarm audit #8)
            vm.prank(who);
            try vault.announceWithdraw(t) {
                _calls[keccak256("announceWithdraw")]++;
            } catch {}
        }
    }

    function submit(uint256 seed, bool swapWithEth) external {
        uint256 t = _task(seed);
        if (t == 0) return;
        ImdPay memory pay;
        uint256 value;
        if (swapWithEth) {
            try vault.quoteSubmission(t) returns (uint256 bond, uint256 fee) {
                uint256 needed = bond + fee;
                value = needed * 1e18 / 312.5e18 + 1e15;
                pay = ImdPay({
                    tokenIn: ETH, amountIn: value, minImdOut: needed, deadline: uint64(_now() + 600), route: ""
                });
            } catch {
                return;
            }
        }
        vm.prank(_who(seed >> 8));
        try vault.submit{value: value}(
            t, "https://x.com/doer/status/1", Evidence(bytes32(0), false, ""), 0, type(uint256).max, pay
        ) returns (
            uint256 s
        ) {
            subs.push(s);
            _calls[keccak256("submit")]++;
        } catch {}
    }

    function dispute(uint256 seed, uint256 fee) external {
        uint256 s = _sub(seed);
        fee = bound(fee, 0.0003 ether, 0.01 ether);
        ImdPay memory none;
        vm.prank(_who(seed >> 8));
        try vault.dispute{value: fee}(s, "reason", fee, none) {
            _calls[keccak256("dispute")]++;
        } catch {}
    }

    function reply(uint256 seed) external {
        uint256 s = _sub(seed);
        if (s == 0) return;
        vm.prank(vault.getSubmission(s).doer);
        try vault.reply(s, "reply") {
            _calls[keccak256("reply")]++;
        } catch {}
    }

    function vote(uint256 seed, uint8 side, uint256 voterSeed, uint256 count, uint256 basefee) external {
        uint256 s = _sub(seed);
        if (s == 0) return;
        Submission memory sub = vault.getSubmission(s);
        if (sub.phase != Phase.Voting) return;
        uint256 vi = voterSeed % 5;
        uint256 from = vi == 0 ? 0 : vi == 1 ? 120 : vi == 2 ? 140 : vi == 3 ? 150 : 155;
        uint256 max = vi == 0 ? 120 : vi == 1 ? 20 : vi == 2 ? 10 : vi == 3 ? 5 : 2;
        count = bound(count, 1, max);
        uint256[] memory ids = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            ids[i] = from + i;
        }
        side = side % 2 == 0 ? 1 : 2;
        bytes32 structHash = keccak256(
            abi.encode(VoteLib.VOTE_TYPEHASH, s, side, keccak256(abi.encodePacked(ids)), sub.voteEnd, voterAddrs[vi])
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault.voteDomainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 ss) = vm.sign(voterKeys[vi], digest);
        Ballot[] memory bs = new Ballot[](1);
        bs[0] = Ballot({
            voter: voterAddrs[vi],
            side: side,
            payTo: voterAddrs[vi],
            tokenIds: ids,
            signature: abi.encodePacked(r, ss, v)
        });
        vm.fee(bound(basefee, 0, 100 gwei));
        vm.prank(_who(seed >> 16));
        try vault.submitVotes(s, bs) {
            _calls[keccak256("vote")]++;
        } catch {}
    }

    function appeal(uint256 seed) external {
        uint256 s = _sub(seed);
        ImdPay memory none;
        vm.prank(_who(seed >> 8));
        try vault.appeal(s, "appeal", type(uint256).max, none) {
            _calls[keccak256("appeal")]++;
        } catch {}
    }

    function appealReply(uint256 seed) external {
        uint256 s = _sub(seed);
        if (s == 0) return;
        vm.prank(vault.getSubmission(s).doer);
        try vault.appealReply(s, "r") {
            _calls[keccak256("appealReply")]++;
        } catch {}
    }

    function breakIntake(uint256 seed) external {
        intake.setBroken(seed % 7 == 0); // sometimes the Intake reverts on request()
        _calls[keccak256("breakIntake")]++;
    }

    function callSwarm(uint256 seed) external {
        uint256 s = _sub(seed);
        ImdPay memory none;
        vm.prank(_who(seed >> 8));
        try vault.callSwarm(s, (seed >> 4) % 2 == 0, "reason", type(uint256).max, none) {
            _calls[keccak256("callSwarm")]++;
        } catch {}
    }

    function answer(uint256 seed, uint8 mode) external {
        uint256 s = _sub(seed);
        if (s == 0) return;
        bytes32 rid = vault.getSubmission(s).request;
        if (rid == bytes32(0)) return;
        (,,, bool done) = intake.requests(rid);
        if (done) return;
        OracleAttestation.Attestation memory a;
        a.answerType = 0;
        a.answer = abi.encode(mode % 3 == 0);
        a.panelSize = 7;
        a.quorum = 5;
        a.agreed = 5;
        a.issuedAt = uint64(_now());
        bytes memory sig;
        if (mode % 3 != 2) {
            (uint8 v, bytes32 r, bytes32 ss) = vm.sign(attesterKey, vault.attestationDigest(a));
            sig = abi.encodePacked(r, ss, v);
        }
        try intake.complete(rid, mode % 3 == 2 ? 2 : 0, a, sig) {
            _calls[keccak256("answer")]++;
        } catch {}
    }

    /// @dev Moves the active submission of a random task one step down its path (deep phases otherwise rare).
    function progress(uint256 seed, uint8 choice) external {
        uint256 t = _task(seed);
        if (t == 0) return;
        vault.poke(t);
        uint256 s = vault.getTask(t).activeSub;
        if (s == 0) {
            if (vault.getTask(t).status == TaskStatus.Open) {
                this.submit(_indexOfTask(t) + tasks.length * (uint256(choice) + 1), choice % 5 == 0);
            }
            return;
        }
        Submission memory sub = vault.getSubmission(s);
        Phase ph = sub.phase;
        _calls[keccak256(abi.encode("phase", ph))]++;
        if (sub.asks > 1) _calls[keccak256("repeatedAsk")]++;
        uint256 i = _indexOf(s);
        uint256 other = i + subs.length * (uint256(choice) * 977 + 1); // same submission, another person
        if (ph == Phase.Review) {
            if (sub.check == CheckState.Requested) this.answer(i, choice);
            else if (choice % 4 != 0) this.dispute(other, 0.001 ether);
            else this.warp(1 days);
        } else if (ph == Phase.Voting) {
            if (choice % 3 == 0) this.warp(1 days);
            else this.vote(i, choice, choice, choice % 2 == 0 ? 120 : 15, 0);
        } else if (ph == Phase.Decided) {
            if (choice % 2 == 0) this.appeal(other);
            else this.warp(1 days);
        } else if (ph == Phase.NoDecision) {
            if (choice % 3 != 0) this.callSwarm(other);
            else this.warp(1 days);
        } else if (ph == Phase.Appealed) {
            if (choice % 2 == 0) this.appealReply(i);
            else this.warp(12 hours);
            this.poke(seed);
        } else if (ph == Phase.Asked) {
            if (choice % 4 == 3) this.warp(7 hours);
            else this.answer(i, choice);
        }
        _calls[keccak256("progress")]++;
    }

    // aliases: give the path-driving action more weight in the random selector choice
    function progressA(uint256 seed, uint8 choice) external {
        this.progress(seed, choice);
    }

    function progressB(uint256 seed, uint8 choice) external {
        this.progress(seed >> 3, choice);
    }

    function progressC(uint256 seed, uint8 choice) external {
        this.progress(seed >> 5, choice ^ 0x5a);
    }

    function progressD(uint256 seed, uint8 choice) external {
        this.progress(seed >> 7, choice ^ 0xa5);
    }

    function _indexOfTask(uint256 t) internal view returns (uint256) {
        for (uint256 i; i < tasks.length; ++i) {
            if (tasks[i] == t) return i;
        }
        return 0;
    }

    function _indexOf(uint256 s) internal view returns (uint256) {
        for (uint256 i; i < subs.length; ++i) {
            if (subs[i] == s) return i;
        }
        return 0;
    }

    function setIntakePrice(uint256 p) external {
        intake.setPrice(bound(p, 0.1e18, 1.2e18));
    }

    function warp(uint256 dt) external {
        vm.warp(_now() + bound(dt, 1 minutes, 1 days));
        _calls[keccak256("warp")]++;
    }

    function poke(uint256 seed) external {
        uint256 t = _task(seed);
        try vault.poke(t) {} catch {}
    }

    function emergencyExit(uint256 seed) external {
        uint256 t = _task(seed);
        try vault.emergencyExit(t) {
            _calls[keccak256("emergencyExit")]++;
        } catch {}
    }

    function claim(uint256 seed, uint8 kind) external {
        uint256 s = _sub(seed);
        address who = _who(seed >> 8);
        kind = kind % 5;
        vm.prank(who);
        if (kind == 0) {
            try vault.claimDisputer(s) {
                _calls[keccak256("claimDisputer")]++;
            } catch {}
        } else if (kind == 1) {
            try vault.claimVoterReward(s, voterAddrs[seed % 5]) {
                _calls[keccak256("claimVoter")]++;
            } catch {}
        } else if (kind == 2) {
            try vault.claimRelayerShortfall(s) {
                _calls[keccak256("claimShortfall")]++;
            } catch {}
        } else if (kind == 3) {
            try vault.claimVoidSubmission(s) {
                _calls[keccak256("claimVoid")]++;
            } catch {}
        } else {
            address[4] memory ts = [ETH, vault.usdc(), vault.imd(), vault.yolo()];
            try vault.withdraw(ts[seed % 4]) {
                _calls[keccak256("withdraw")]++;
            } catch {}
        }
    }

    // ------------------------------------------------------------------ $YOLO bonus (YoloSweetener)

    function sweeten(uint256 seed, uint256 amount) external {
        uint256 t = _task(seed);
        amount = bound(amount, 1, 50_000_000e18);
        vm.prank(_who(seed >> 8));
        try sweetener.sweeten(t, amount) {
            _calls[keccak256("sweeten")]++;
        } catch {}
    }

    /// @dev the hour of notice a withdrawal from an open task needs; `warp` lets it mature
    function announceBonusWithdraw(uint256 seed) external {
        uint256 t = _task(seed);
        vm.prank(_who(seed >> 8));
        try sweetener.announceWithdraw(t) {
            _calls[keccak256("announceBonusWithdraw")]++;
        } catch {}
    }

    function withdrawBonus(uint256 seed) external {
        uint256 t = _task(seed);
        vm.prank(_who(seed >> 8));
        try sweetener.withdraw(t) {
            _calls[keccak256("withdrawBonus")]++;
        } catch {}
    }

    function payoutBonus(uint256 seed) external {
        try sweetener.payout(_task(seed), _sub(seed >> 8)) {
            _calls[keccak256("payoutBonus")]++;
        } catch {}
    }

    /// @dev the doer of a random submission (or anybody) tries to mint its trophy; minted ids are kept for checks
    uint256[] public minted;

    function mintedCount() external view returns (uint256) {
        return minted.length;
    }

    function mintTrophy(uint256 seed, bool asDoer) external {
        uint256 s = _sub(seed);
        // as the doer: the first accepted submission from a random start (acceptances are rare in random runs)
        for (uint256 i; asDoer && i < subs.length; ++i) {
            uint256 c = subs[(seed + i) % subs.length];
            if (vault.getSubmission(c).outcome == Outcome.Accepted) {
                s = c;
                break;
            }
        }
        address who = asDoer && s != 0 ? vault.getSubmission(s).doer : _who(seed >> 8);
        vm.prank(who);
        try trophy.mint(s, "Trophy", type(uint256).max) {
            minted.push(s);
            _calls[keccak256("mintTrophy")]++;
        } catch {}
    }

    function sweep(uint256 seed) external {
        address[4] memory ts = [ETH, vault.usdc(), vault.imd(), vault.yolo()];
        try vault.sweepTreasury(ts[seed % 4]) {} catch {}
    }

    receive() external payable {}
}

contract InvariantTest is Base {
    Handler internal handler;

    function setUp() public override {
        super.setUp();
        allowEmergency = true;
        address[] memory people = new address[](9);
        people[0] = author;
        people[1] = alice;
        people[2] = bob;
        people[3] = doer;
        people[4] = doer2;
        people[5] = doer3;
        people[6] = dave;
        people[7] = erin;
        people[8] = relayer;
        handler = new Handler(vault, intake, attesterKey, people, voterKeys, voters, sweetener, trophy);
        vm.deal(address(handler), 1_000_000 ether); // msg.value of pranked calls is paid by the handler
        targetContract(address(handler));
    }

    /// @dev After every call: the vault can pay everything it owes, per currency.
    function invariant_BalanceCoversLiabilities() public view {
        _assertSolvent();
    }

    /// @dev After every call: the sweetener holds exactly the open bonuses, and each one is exactly what its
    ///      sweeteners may take back (until it is paid out to the doer).
    function invariant_SweetenerHoldsEveryBonus() public view {
        uint256 sum;
        for (uint256 i; i < handler.taskCount(); ++i) {
            uint256 t = handler.tasks(i);
            uint256 bonus = sweetener.bonusOf(t);
            sum += bonus;
            uint256 given;
            for (uint256 a; a < actors.length; ++a) {
                given += sweetener.givenBy(t, actors[a]);
            }
            if (vault.getTask(t).status == TaskStatus.Completed) {
                // givenBy stays once the doer is paid; after a capped payout it shares the returned rest
                uint256 base = sweetener.returnBase(t);
                if (base != 0) assertEq(given, base, "returned rest: base != what its sweeteners put in");
                continue;
            }
            assertEq(given, bonus, "bonus != what its sweeteners put in");
        }
        assertEq(yolo.balanceOf(address(sweetener)), sum, "sweetener balance != open bonuses");
    }

    /// @dev After every call: every trophy belongs to an accepted submission and was minted by its doer (it is still his:
    ///      nobody transfers in this run), the YOLO burned equals the sum of what the trophies cost, the trophy contract
    ///      keeps no YOLO.
    function invariant_TrophiesOnlyForAcceptedDoersAndEveryYoloBurned() public view {
        uint256 sum;
        for (uint256 i; i < handler.mintedCount(); ++i) {
            uint256 s = handler.minted(i);
            Submission memory sub = vault.getSubmission(s);
            assertEq(uint8(sub.outcome), uint8(Outcome.Accepted), "trophy of a submission that was not accepted");
            assertEq(trophy.ownerOf(s), sub.doer, "trophy not of the doer");
            sum += trophy.mintedOf(s).yoloBurned;
        }
        assertEq(trophy.totalBurned(), sum);
        assertEq(yolo.balanceOf(0x000000000000000000000000000000000000dEaD), sum, "burned != paid");
        assertEq(yolo.balanceOf(address(trophy)), 0);
    }

    /// @dev At the end of every run: play all timers, unwind what waits, claim everything; the vault must hold
    ///      exactly what it owes and owe only protocol buckets.
    function afterInvariant() public {
        string[22] memory names = [
            "createTask",
            "topUp",
            "submit",
            "dispute",
            "vote",
            "appeal",
            "breakIntake",
            "callSwarm",
            "answer",
            "emergencyExit",
            "claimDisputer",
            "claimVoter",
            "claimShortfall",
            "claimVoid",
            "withdrawContribution",
            "announceWithdraw",
            "progress",
            "sweeten",
            "announceBonusWithdraw",
            "withdrawBonus",
            "payoutBonus",
            "mintTrophy"
        ];
        for (uint256 i; i < names.length; ++i) {
            emit log_named_uint(names[i], handler.calls(keccak256(bytes(names[i]))));
        }
        emit log_named_uint("repeatedAsk", handler.calls(keccak256("repeatedAsk")));
        for (uint8 ph = uint8(Phase.Review); ph <= uint8(Phase.Asked); ++ph) {
            emit log_named_uint(
                string.concat("progress at phase ", vm.toString(ph)),
                handler.calls(keccak256(abi.encode("phase", Phase(ph))))
            );
        }
        for (uint256 i; i < handler.taskCount(); ++i) {
            trackedTasks.push(handler.tasks(i));
        }
        intake.setBroken(false);
        _claimEverythingAndCheck();
    }
}
