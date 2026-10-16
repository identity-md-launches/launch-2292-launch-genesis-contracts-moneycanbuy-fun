// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TaskVault} from "../src/TaskVault.sol";
import {YoloSweetener} from "../src/YoloSweetener.sol";
import {DareTrophy} from "../src/DareTrophy.sol";
import {ITaskVault} from "../src/interfaces/ITaskVault.sol";
import {ParamsRegistry} from "../src/ParamsRegistry.sol";
import {CaseDesk} from "../src/desks/CaseDesk.sol";
import {DisputeDesk} from "../src/desks/DisputeDesk.sol";
import {TextRules} from "../src/helpers/TextRules.sol";
import {SwarmQuestionBuilder} from "../src/helpers/SwarmQuestion.sol";
import {AttestationChecker} from "../src/helpers/AttestationChecker.sol";
import {Params} from "../src/VaultParams.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {Ballot, VoteLib, BallotChecker} from "../src/libraries/VoteLib.sol";
import "../src/VaultTypes.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockNFT} from "./mocks/MockNFT.sol";
import {MockIntake} from "./mocks/MockIntake.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";
import {MockSwapAdapter} from "./mocks/MockSwapAdapter.sol";
import {MockDelegateRegistry} from "./mocks/MockDelegateRegistry.sol";

/// @dev The removed public attestation fallback (audit B-01). Kept here only to show that its selector is
///      gone: the vault answers it with UnknownFunction.
interface IRemovedFallback {
    function submitAttestation(bytes32 requestId, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
        returns (bool);
}

/// @dev Shared deployment and helpers. Prices: ETH $2500, IMD $8, USDC $1.
abstract contract Base is Test {
    bytes32 internal constant ACTION = "oracle.request@oracle-1";
    uint256 internal constant PRICE = 0.5e18; // Intake price in IMD
    uint256 internal constant LONG = 60 days; // longer than every timer incl. the emergency delay

    MockERC20 internal imd;
    MockERC20 internal usdc;
    MockERC20 internal yolo;
    MockNFT internal nft;
    MockIntake internal intake;
    MockPriceOracle internal oracle;
    MockSwapAdapter internal adapter;
    MockDelegateRegistry internal delegates;
    ParamsRegistry internal registry;
    ITaskVault internal vault; // the one public address (TaskVault); its desks below hold the judging state
    CaseDesk internal caseDesk;
    DisputeDesk internal disputeDesk;
    YoloSweetener internal sweetener; // the $YOLO bonus module next to the vault
    DareTrophy internal trophy; // NFT trophies of accepted submissions, paid in burned $YOLO

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal swarmPayee = makeAddr("swarmPayee");
    address internal author = makeAddr("author");
    address internal alice = makeAddr("alice"); // contributor
    address internal bob = makeAddr("bob"); // contributor
    address internal doer = makeAddr("doer");
    address internal doer2 = makeAddr("doer2");
    address internal doer3 = makeAddr("doer3");
    address internal dave = makeAddr("dave"); // disputer
    address internal erin = makeAddr("erin"); // disputer
    address internal relayer = makeAddr("relayer");

    uint256 internal attesterKey = 0xA77E57;
    address internal attester;

    // NFT voters: keys and token ranges
    uint256[5] internal voterKeys = [uint256(0xB0B1), 0xB0B2, 0xB0B3, 0xB0B4, 0xB0B5];
    address[5] internal voters;
    // voter0: ids 0..119 (120), voter1: 120..139 (20), voter2: 140..149 (10), voter3: 150..154 (5), voter4: 155..156

    address[] internal actors;
    /// @dev Only emergency tests and the invariant run may need the emergency exit; elsewhere it means a stuck machine.
    bool internal allowEmergency;
    uint256[] internal trackedTasks;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        imd = new MockERC20("IMD", "IMD", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        yolo = new MockERC20("YOLO", "YOLO", 18);
        nft = new MockNFT();
        intake = new MockIntake(swarmPayee, ACTION, address(imd), PRICE);
        oracle = new MockPriceOracle(address(imd));
        oracle.set(ETH, 2500e18, 18);
        oracle.set(address(imd), 8e18, 18);
        oracle.set(address(usdc), 1e18, 6);
        oracle.set(address(yolo), 0.0001e18, 18); // $0.0001 per YOLO
        adapter = new MockSwapAdapter();
        adapter.setRate(ETH, 312.5e18); // IMD per ETH
        adapter.setRate(address(usdc), 0.125e30); // 1 USDC (1e6 units) -> 0.125 IMD: 1e6 * 1.25e29 / 1e18 = 1.25e17
        delegates = new MockDelegateRegistry();
        attester = vm.addr(attesterKey);

        registry = new ParamsRegistry(
            owner,
            address(intake),
            address(oracle),
            address(adapter),
            address(nft),
            address(delegates),
            treasury,
            attester
        );
        _deployVault();

        for (uint256 i; i < 5; ++i) {
            voters[i] = vm.addr(voterKeys[i]);
        }
        for (uint256 id; id < 157; ++id) {
            address to =
                id < 120 ? voters[0] : id < 140 ? voters[1] : id < 150 ? voters[2] : id < 155 ? voters[3] : voters[4];
            nft.mint(to, id);
        }

        address[12] memory people =
            [author, alice, bob, doer, doer2, doer3, dave, erin, relayer, voters[0], voters[1], voters[2]];
        for (uint256 i; i < people.length; ++i) {
            _fund(people[i]);
            actors.push(people[i]);
        }
        actors.push(voters[3]);
        actors.push(voters[4]);
        actors.push(treasury);
    }

    /// @dev The launch order: stateless helpers, the two desks, the vault last (it wires the desks; all of this
    ///      must happen in one transaction, as in the launch: setUp is one).
    function _deployVault() internal {
        TextRules text = new TextRules();
        address r = address(registry);
        caseDesk = new CaseDesk(r, address(imd), address(usdc), address(text), address(new SwarmQuestionBuilder()));
        disputeDesk = new DisputeDesk(r, address(imd), address(usdc), address(text), address(new BallotChecker()));
        vault = ITaskVault(
            address(
                new TaskVault(
                    r,
                    address(imd),
                    address(usdc),
                    address(yolo),
                    address(new AttestationChecker(r)),
                    address(text),
                    address(caseDesk),
                    address(disputeDesk)
                )
            )
        );
        sweetener = new YoloSweetener(address(vault));
        trophy = new DareTrophy(address(vault), 1.5e18, 10_000e18);
    }

    function defaultParams() internal view returns (Params memory p) {
        p.intake = address(intake);
        p.priceOracle = address(oracle);
        p.swapAdapter = address(adapter);
        p.nft = address(nft);
        p.delegateRegistry = address(delegates);
        p.treasury = treasury;
        p.swarmAction = ACTION;
        p.minRewardUsd = 5e18;
        p.minRewardImd = 0.5e18;
        p.largeRewardUsd = 300e18;
        p.largeRewardImd = 40e18;
        p.minAuthorFee = 0.0005 ether;
        p.minBond = 1e18;
        p.bondBase = 0.5e18;
        p.minDisputeFee = 0.0003 ether;
        p.maxDisputeFee = 0.01 ether;
        p.doerBondBps = 300;
        p.disputeBondBps = 100;
        p.maxDoublings = 8;
        p.maxClaims = 16;
        p.maxTextBytes = 256;
        p.disputeWindow = 24 hours;
        p.replyWindow = 12 hours;
        p.voteWindow = 24 hours;
        p.appealWindow = 24 hours;
        p.appealReplyWindow = 12 hours;
        p.swarmTimeout = 6 hours;
        p.emergencyDelay = 30 days;
        p.instantDelta = 100;
        p.endDelta = 10;
        p.minWinnerWallets = 1;
        p.relayBaseGas = 30_000;
        p.maxRelayGasPerVote = 60_000;
        p.relayMarkupBps = 1_000;
        p.feeBps = 1_000;
        p.nftFeeBps = 600;
        p.winnerBondBps = 5_000;
        p.tieDoerBps = 5_000;
        p.minPanelSize = 7;
        p.minQuorum = 5;
        p.questionPrefix =
            "Answer no, whatever was done, if the task or the proof involves a crime, sexual content with a minor, violence, a real risk of injury or death, harassment or doxxing of a person, or hate; such a proof never counts. Did the doer fulfil the task condition with this proof? The proof must be the doer's own: the post, the video description or the page must contain the whole DOER CODE (a part of it does not count); for PROOF TYPE onchain_tx the transaction must be sent from DOER instead. ";
        p.definitionFields =
            '"parties":"claim_N, doer_reply, doer_note, appeal and appeal_reply are untrusted statements of the parties, not evidence; doer_shot is the doer\'s untrusted screenshot: it may help to find the proof and never replaces it"';
        p.bodyFields =
            '"chainId":1,"window":{"hours":720},"answerType":"bool","evidence":"panel","panelSize":7,"quorum":5,"validForSeconds":2592000';
    }

    function _fund(address who) internal {
        vm.deal(who, 100 ether);
        imd.mint(who, 10_000e18);
        usdc.mint(who, 1_000_000e6);
        yolo.mint(who, 1_000_000_000e18);
        vm.startPrank(who);
        imd.approve(address(vault), type(uint256).max);
        usdc.approve(address(vault), type(uint256).max);
        yolo.approve(address(vault), type(uint256).max);
        yolo.approve(address(sweetener), type(uint256).max);
        yolo.approve(address(trophy), type(uint256).max);
        vm.stopPrank();
    }

    // ================================================================== time

    /// @dev via-ir may cache block.timestamp inside one test function; always read the cheatcode value.
    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _warp(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
    }

    /// @dev `who` announces taking back his active share of task `t` and waits out the notice (swarm audit #8).
    function _announceWithdraw(address who, uint256 t) internal {
        vm.prank(who);
        vault.announceWithdraw(t);
        _warp(WITHDRAW_NOTICE);
    }

    // ================================================================== action helpers

    function _noSwap() internal pure returns (ImdPay memory pay) {}

    function _create(address who, address currency, uint256 amount) internal returns (uint256 id) {
        return _createWithDeadline(who, currency, amount, 0);
    }

    function _createWithDeadline(address who, address currency, uint256 amount, uint64 deadline)
        internal
        returns (uint256 id)
    {
        uint256 value = 0.001 ether + (currency == ETH ? amount : 0);
        vm.prank(who);
        id = vault.createTask{value: value}(
            currency, amount, deadline, "Title", "ipfs://task-condition", 0, 0, "", 0.001 ether, _noSwap()
        );
        trackedTasks.push(id);
    }

    function _topUp(address who, uint256 taskId, uint256 amount) internal {
        address cur = vault.getTask(taskId).currency;
        vm.prank(who);
        vault.topUp{value: cur == ETH ? amount : 0}(taskId, amount, _noSwap());
    }

    function _noEvidence() internal pure returns (Evidence memory) {
        return Evidence(bytes32(0), false, "");
    }

    function _submit(address who, uint256 taskId) internal returns (uint256 subId) {
        vm.prank(who);
        subId = vault.submit(taskId, "https://x.com/doer/status/1", _noEvidence(), 0, type(uint256).max, _noSwap());
    }

    function _dispute(address who, uint256 subId) internal {
        vm.prank(who);
        vault.dispute{value: 0.001 ether}(subId, "ipfs://reason", 0.001 ether, _noSwap());
    }

    function _appeal(address who, uint256 subId) internal {
        vm.prank(who);
        vault.appeal(subId, "ipfs://appeal", type(uint256).max, _noSwap());
    }

    /// @dev NFT undecided: calls the swarm paying the live fee + a dispute bond, against the acceptance.
    function _callSwarm(address who, uint256 subId) internal {
        _callSwarm(who, subId, false);
    }

    function _callSwarm(address who, uint256 subId, bool sidesDoer) internal {
        vm.prank(who);
        vault.callSwarm(subId, sidesDoer, "ipfs://caller-reason", type(uint256).max, _noSwap());
    }

    function _sub(uint256 subId) internal view returns (Submission memory) {
        return vault.getSubmission(subId);
    }

    function _phase(uint256 subId) internal view returns (Phase) {
        return vault.getSubmission(subId).phase;
    }

    // ================================================================== votes

    function _ids(uint256 from, uint256 count) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            ids[i] = from + i;
        }
    }

    function _ballot(uint256 subId, uint256 voterIdx, uint8 side, uint256[] memory ids, address payTo)
        internal
        view
        returns (Ballot memory b)
    {
        return _ballotByKey(subId, voterKeys[voterIdx], side, ids, payTo, _sub(subId).voteEnd);
    }

    function _ballotByKey(uint256 subId, uint256 key, uint8 side, uint256[] memory ids, address payTo, uint64 voteEnd)
        internal
        view
        returns (Ballot memory b)
    {
        bytes32 structHash =
            keccak256(abi.encode(VoteLib.VOTE_TYPEHASH, subId, side, keccak256(abi.encodePacked(ids)), voteEnd, payTo));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault.voteDomainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        b = Ballot({voter: vm.addr(key), side: side, payTo: payTo, tokenIds: ids, signature: abi.encodePacked(r, s, v)});
    }

    function _vote(uint256 subId, uint256 voterIdx, uint8 side, uint256 from, uint256 count) internal {
        Ballot[] memory bs = new Ballot[](1);
        bs[0] = _ballot(subId, voterIdx, side, _ids(from, count), voters[voterIdx]);
        vm.prank(relayer);
        vault.submitVotes(subId, bs);
    }

    /// @dev The NFT decides only at the vote end (audit C-02): warp to it (if not there yet) and play the timer.
    function _endVote(uint256 subId) internal {
        Submission memory sub = _sub(subId);
        if (_now() < sub.voteEnd) vm.warp(sub.voteEnd);
        vault.poke(sub.taskId);
    }

    // ================================================================== swarm

    function _attestation(bool answer) internal view returns (OracleAttestation.Attestation memory a) {
        a.requestId = bytes32(bytes16(keccak256("uuid")));
        a.chainId = 1;
        a.questionHash = keccak256("unknown formula");
        a.answerType = 0;
        a.answer = abi.encode(answer);
        a.panelSize = 7;
        a.quorum = 5;
        a.agreed = 6;
        a.issuedAt = uint64(_now());
        a.expiresAt = uint64(_now() + 1 days);
    }

    function _sign(OracleAttestation.Attestation memory a, uint256 key) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, vault.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    /// @dev The swarm answers the current request of `subId` through the Intake callback.
    function _answer(uint256 subId, bool answer) internal {
        bytes32 rid = _sub(subId).request;
        OracleAttestation.Attestation memory a = _attestation(answer);
        intake.complete(rid, 0, a, _sign(a, attesterKey));
        assertTrue(intake.lastDelivered(), "callback not delivered");
    }

    /// @dev The removed public fallback (audit B-01) reverts UnknownFunction for any input.
    function _expectNoFallback(bytes32 rid, OracleAttestation.Attestation memory a, bytes memory sig) internal {
        vm.expectRevert(UnknownFunction.selector);
        IRemovedFallback(address(vault)).submitAttestation(rid, a, sig);
    }

    /// @dev The swarm does not answer (status 2, no callback).
    function _silent(uint256 subId) internal {
        OracleAttestation.Attestation memory a;
        intake.complete(_sub(subId).request, 2, a, "");
    }

    // ================================================================== accounting checks

    function _balance(address token) internal view returns (uint256) {
        return token == ETH ? address(vault).balance : IERC20(token).balanceOf(address(vault));
    }

    function _tokens() internal view returns (address[4] memory) {
        return [ETH, address(usdc), address(imd), address(yolo)];
    }

    function _assertSolvent() internal view {
        address[4] memory ts = _tokens();
        for (uint256 i; i < 4; ++i) {
            assertGe(_balance(ts[i]), vault.liabilities(ts[i]), "balance < liabilities");
        }
    }

    /// @dev Claims everything for every actor and checks that only protocol-owned buckets remain and that the
    ///      vault holds exactly what it owes (nothing stuck, nothing missing, nothing created).
    function _claimEverythingAndCheck() internal {
        // let every timer run out (queued submissions get activated and judged by timers one per round);
        // a case whose machine cannot move (should not happen) is unwound by the emergency exit
        for (uint256 round; round < 12; ++round) {
            _warp(LONG);
            bool busy;
            for (uint256 i; i < trackedTasks.length; ++i) {
                vault.poke(trackedTasks[i]);
                try vault.emergencyExit(trackedTasks[i]) {
                    assertTrue(allowEmergency, "emergency exit was needed: the state machine got stuck");
                } catch {}
                Task memory tk = vault.getTask(trackedTasks[i]);
                if (tk.status == TaskStatus.Open && tk.activeSub != 0) busy = true;
            }
            if (!busy) break;
        }
        uint256 subs = vault.submissionCount();
        for (uint256 s = 1; s <= subs; ++s) {
            try vault.claimVoidSubmission(s) {} catch {}
            for (uint256 a; a < actors.length; ++a) {
                vm.prank(actors[a]);
                try vault.claimDisputer(s) {} catch {}
                vm.prank(actors[a]);
                try vault.claimRelayerShortfall(s) {} catch {}
                try vault.claimVoterReward(s, actors[a]) {} catch {}
            }
        }
        // an active share leaves an open task after an hour of notice (swarm audit #8)
        for (uint256 t; t < trackedTasks.length; ++t) {
            for (uint256 a; a < actors.length; ++a) {
                vm.prank(actors[a]);
                try vault.announceWithdraw(trackedTasks[t]) {} catch {}
            }
        }
        _warp(WITHDRAW_NOTICE);
        for (uint256 t; t < trackedTasks.length; ++t) {
            for (uint256 a; a < actors.length; ++a) {
                vm.prank(actors[a]);
                try vault.withdrawContribution(trackedTasks[t]) {} catch {}
            }
        }
        address[4] memory ts = _tokens();
        for (uint256 i; i < 4; ++i) {
            try vault.sweepTreasury(ts[i]) {} catch {} // reverts before the first task (no params cached)
            for (uint256 a; a < actors.length; ++a) {
                vm.prank(actors[a]);
                try vault.withdraw(ts[i]) {} catch {}
            }
        }
        _settleSweetener(subs);
        for (uint256 i; i < 4; ++i) {
            address tk = ts[i];
            assertEq(vault.treasuryPot(tk), 0, "treasury not swept");
            assertEq(vault.liabilities(tk), 0, "user money left in the vault");
            assertEq(_balance(tk), vault.liabilities(tk), "balance != liabilities");
        }
    }

    /// @dev Every $YOLO bonus ends with its task: paid to the accepted doer (all of it, or up to the large threshold
    ///      with the rest back to the sweeteners), or back to whoever put it in (an open task after the hour of notice).
    ///      After all tasks are final the sweetener holds nothing, and what it held always equals the sum of open
    ///      bonuses.
    function _settleSweetener(uint256 subs) internal {
        bool deferred;
        for (uint256 t; t < trackedTasks.length; ++t) {
            uint256 id = trackedTasks[t];
            if (vault.getTask(id).status != TaskStatus.Completed) continue;
            for (uint256 s = 1; s <= subs; ++s) {
                try sweetener.payout(id, s) {} catch {}
            }
            if (sweetener.noPriceSince(id) != 0 && sweetener.bonusOf(id) != 0) deferred = true;
        }
        if (deferred) {
            // a payout deferred for want of a YOLO price pays in full after NO_PRICE_WAIT (swarm audit #6)
            _warp(sweetener.NO_PRICE_WAIT());
            for (uint256 t; t < trackedTasks.length; ++t) {
                uint256 id = trackedTasks[t];
                if (vault.getTask(id).status != TaskStatus.Completed) continue;
                for (uint256 s = 1; s <= subs; ++s) {
                    try sweetener.payout(id, s) {} catch {}
                }
            }
        }
        for (uint256 t; t < trackedTasks.length; ++t) {
            uint256 id = trackedTasks[t];
            if (vault.getTask(id).status == TaskStatus.Completed) continue;
            for (uint256 a; a < actors.length; ++a) {
                vm.prank(actors[a]);
                try sweetener.announceWithdraw(id) {} catch {}
            }
        }
        _warp(sweetener.NOTICE());
        for (uint256 t; t < trackedTasks.length; ++t) {
            uint256 id = trackedTasks[t];
            for (uint256 a; a < actors.length; ++a) {
                vm.prank(actors[a]);
                try sweetener.withdraw(id) {} catch {}
            }
            assertEq(sweetener.bonusOf(id), 0, "bonus of a task not paid or returned");
        }
        assertEq(yolo.balanceOf(address(sweetener)), 0, "YOLO stuck in the sweetener");
    }
}
