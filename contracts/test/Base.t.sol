// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TaskVault} from "../src/TaskVault.sol";
import {YoloSweetener} from "../src/YoloSweetener.sol";
import {DareTrophy} from "../src/DareTrophy.sol";
import {TrophyCatalog} from "../src/TrophyCatalog.sol";
import {YoloLockHub} from "../src/YoloLockHub.sol";
import {BuybackBurner} from "../src/BuybackBurner.sol";
import {ITaskVault} from "../src/interfaces/ITaskVault.sol";
import {ParamsRegistry} from "../src/ParamsRegistry.sol";
import {CaseDesk} from "../src/desks/CaseDesk.sol";
import {DisputeDesk} from "../src/desks/DisputeDesk.sol";
import {TextRules} from "../src/helpers/TextRules.sol";
import {SwarmQuestionBuilder} from "../src/helpers/SwarmQuestion.sol";
import {AttestationChecker} from "../src/helpers/AttestationChecker.sol";
import {Params} from "../src/VaultParams.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {VoteLib} from "../src/libraries/VoteLib.sol";
import {VotePower} from "../src/VotePower.sol";
import "../src/VaultTypes.sol";
import {rulesOf, rulesForehead, rulesSupermarket, TEST_RULE_PROOF, TEST_RULE_NO} from "./mocks/TaskRulesFixture.sol";

/// @dev A vote as the tests build it: the sender votes with NFT ids they hold; `_submitVotes` sends every NFT
///      the voter holds in setUp, `tokenIds` only for a wallet with none there. `signature` is not read.
struct Ballot {
    address voter;
    uint8 side;
    address payTo;
    uint256[] tokenIds;
    bytes signature;
}

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockNFT} from "./mocks/MockNFT.sol";
import {MockIntake} from "./mocks/MockIntake.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";
import {MockSwapAdapter} from "./mocks/MockSwapAdapter.sol";
import {MockDelegateRegistry} from "./mocks/MockDelegateRegistry.sol";

/// @dev The vault has no public attestation fallback. Declared here only to show that its selector is
///      unknown: the vault answers it with UnknownFunction.
interface IAttestationFallback {
    function submitAttestation(bytes32 requestId, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
        returns (bool);
}

/// @dev Shared deployment and helpers. Prices: ETH $2500, IMD $8, USDC $1.
abstract contract Base is Test {
    bytes32 internal constant ACTION = "oracle.request@oracle-1";
    uint256 internal constant PRICE = 0.5e18; // Intake price in IMD
    uint256 internal constant LONG = 60 days; // longer than every timer
    /// @dev Every task has a deadline; `_create` gives this one unless a test sets its own.
    uint256 internal constant TTL = 365 days;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

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
    TrophyCatalog internal catalog; // trophy designs, owned by the registry owner
    YoloLockHub internal hub; // the doer stake: a $YOLO lock, bonus up to 4%
    BuybackBurner internal burner; // takes the burn shares: $YOLO burns, ETH / USDC / IMD forwarded to the buyback wallet
    VotePower internal votePower; // who may vote with an NFT
    /// @dev The NFT ids each test wallet got in setUp / `_holder` (what its votes send).
    mapping(address => uint256[]) internal held;
    uint256 internal nextNftId = 1_000_000; // fresh ids for `_holder`

    address internal multisig = makeAddr("multisig");
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
    /// @dev the dev wallet: owner of the DevPrices (here its test double MockPriceOracle), the only one who may cancel a task
    address internal devWallet = makeAddr("devWallet");
    /// @dev the buyback wallet: BuybackBurner.forward sends ETH, USDC, IMD here
    address internal buybackWallet = makeAddr("buybackWallet");

    uint256 internal attesterKey = 0xA77E57;
    address internal attester;

    // NFT voters: keys and token ranges
    uint256[5] internal voterKeys = [uint256(0xB0B1), 0xB0B2, 0xB0B3, 0xB0B4, 0xB0B5];
    address[5] internal voters;
    // voter0: ids 0..119 (120), voter1: 120..139 (20), voter2: 140..149 (10), voter3: 150..154 (5), voter4: 155..156

    address[] internal actors;
    uint256[] internal trackedTasks;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        imd = new MockERC20("IMD", "IMD", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        yolo = new MockERC20("YOLO", "YOLO", 18);
        nft = new MockNFT();
        intake = new MockIntake(swarmPayee, ACTION, address(imd), PRICE);
        oracle = new MockPriceOracle(address(imd));
        oracle.setOwner(devWallet);
        oracle.set(ETH, 2500e18, 18);
        oracle.set(address(imd), 8e18, 18);
        oracle.set(address(usdc), 1e18, 6);
        oracle.set(address(yolo), 0.0001e18, 18); // test YOLO price (18 decimals)
        oracle.setYolo(address(yolo), 0); // the stake bonus: rewards in $YOLO at its set price unless a test lowers it
        adapter = new MockSwapAdapter();
        adapter.setRate(ETH, 312.5e18); // IMD per ETH
        adapter.setRate(address(usdc), 0.125e30); // 1 USDC (1e6 units) -> 0.125 IMD: 1e6 * 1.25e29 / 1e18 = 1.25e17
        delegates = new MockDelegateRegistry();
        attester = vm.addr(attesterKey);

        registry = new ParamsRegistry(
            multisig,
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
        // no registration: a vote sends the ids
        for (uint256 i; i < 5; ++i) {
            (uint256 from, uint256 count) = _rangeOf(i);
            held[voters[i]] = _ids(from, count);
        }
        // the ladders of `_vote` for a part of a voter's NFTs: wallets of 1, 2, 4, ... fresh NFTs per voter 0, 1, 2
        for (uint256 i; i < 3; ++i) {
            for (uint256 k; (1 << k) < _rangeCount(i); ++k) {
                address w = _rung(i, k);
                uint256[] memory ids = _ids(2_000_000 + i * 1_000 + (1 << k), 1 << k);
                for (uint256 j; j < ids.length; ++j) {
                    nft.mint(w, ids[j]);
                }
                held[w] = ids;
            }
        }
        vm.roll(vm.getBlockNumber() + 1);

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
        hub = new YoloLockHub(address(yolo));
        burner = new BuybackBurner(address(yolo), address(imd), address(usdc), address(oracle), buybackWallet);
        caseDesk = new CaseDesk(
            r, address(imd), address(usdc), address(text), address(new SwarmQuestionBuilder()), address(yolo), address(hub)
        );
        votePower = new VotePower(address(nft), address(delegates));
        disputeDesk = new DisputeDesk(
            r, address(imd), address(usdc), address(text), address(votePower), address(yolo), address(hub)
        );
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
                    address(disputeDesk),
                    address(burner)
                )
            )
        );
        sweetener = new YoloSweetener(address(vault));
        vm.prank(multisig); // the registry owner binds the add-on once
        vault.bindSweetener(address(sweetener));
        catalog = new TrophyCatalog(multisig);
        trophy = new DareTrophy(address(vault), address(catalog));
    }

    function defaultParams() internal view returns (Params memory p) {
        p.intake = address(intake);
        p.devPrices = address(oracle);
        p.swapAdapter = address(adapter);
        p.nft = address(nft);
        p.delegateRegistry = address(delegates);
        p.treasury = treasury;
        p.swarmAction = ACTION;
        p.minRewardUsdc = 5e6;
        p.minRewardEth = 0.002e18;
        p.minRewardImd = 1e18;
        p.minRewardYolo = 1_000e18;
        p.bondFixedImd = 0.5e18;
        p.doerBondBps = 300;
        p.disputeBondBps = 100;
        // claim_N_proof doubles the per-claim body cost, so maxClaims <= 10 at
        // maxTextBytes 512 (ParamsBounds "bodySize"); mirrors LaunchParams.initial.
        p.maxClaims = 10;
        p.maxTextBytes = 512; // = LaunchParams.initial (each of the 3 rule texts up to 512 B)
        p.disputeWindow = 24 hours;
        p.voteWindow = 24 hours;
        p.appealWindow = 24 hours;
        p.swarmTimeout = 6 hours;
        p.instantDelta = 20;
        p.endDelta = 10;
        p.minWinnerWallets = 1;
        p.feeBps = 1_000;
        p.nftFeeBps = 500;
        p.winnerBondBps = 5_000;
        p.minPanelSize = 7;
        p.minQuorum = 5;
        p.questionPrefix =
            "Answer no, whatever was done, if the task or the proof involves a crime, sexual content with a minor, violence, a real risk of injury or death, harassment or doxxing of a person, or hate; such a proof never counts. Did the doer fulfil the task condition with this proof? The text moneycanbuy.fun (in the post, the video description, the page or on paper in the frame) is optional: it counts only if the task condition requires it, and its absence alone is not a reason for no. For PROOF TYPE onchain_tx the transaction must be sent from DOER. If the proof or screenshot link does not open, there is no proof. ";
        p.definitionFields =
            '"parties":"claim_N, doer_note and appeal are untrusted statements of the parties, not evidence; doer_shot is the doer\'s untrusted screenshot: it may help to find the proof and never replaces it"';
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
        yolo.approve(address(hub), type(uint256).max);
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

    /// @dev Fixed IMD part of every bond: no oracle, no USD floor.
    function _fixedBond() internal pure returns (uint256) {
        return 0.5e18;
    }

    /// @dev There is no escalation. Doer bond's "rew" or "add" part:
    ///      `bps` of `amount` (reward or $YOLO add-on, in its own currency), never above `amount`.
    function _pctBond(uint256 amount, uint16 bps) internal pure returns (uint256 b) {
        if (amount == 0) return 0;
        b = amount * bps / 10_000;
        if (b > amount) b = amount;
    }

    /// @dev Doer bond's "rew" part: 3% of R, at most R, no escalation.
    function _bondOf(uint256 reward) internal pure returns (uint256 b) {
        return _pctBond(reward, 300);
    }

    /// @dev Dispute bond's "rew" part: 1% of R, same as the doer bond, no escalation.
    function _dBondOf(uint256 reward) internal pure returns (uint256 b) {
        return _pctBond(reward, 100);
    }

    // ================================================================== action helpers

    function _noSwap() internal pure returns (ImdPay memory pay) {}

    function _create(address who, address currency, uint256 amount) internal returns (uint256 id) {
        return _createWithDeadline(who, currency, amount, 0);
    }

    /// @dev `deadline` 0 = `TTL` from now (a task without a deadline cannot be created).
    function _createWithDeadline(address who, address currency, uint256 amount, uint64 deadline)
        internal
        returns (uint256 id)
    {
        if (deadline == 0) deadline = uint64(_now() + TTL);
        uint256 value = currency == ETH ? amount : 0;
        vm.prank(who);
        // PROOF_LINK: the generic test task stays evidence-optional; x_post/x_reply/video
        // are tested explicitly against their own typed tasks (Evidence.t.sol, TaskFields.t.sol).
        id = vault.createTask{value: value}(
            currency, amount, deadline, "Title", rulesOf("ipfs://task-condition"), 0, PROOF_LINK, "", _noSwap()
        );
        trackedTasks.push(id);
    }

    function _topUp(address who, uint256 taskId, uint256 amount) internal {
        address cur = vault.getTask(taskId).currency;
        vm.prank(who);
        vault.topUp{value: cur == ETH ? amount : 0}(taskId, amount, _noSwap());
    }

    function _noEvidence() internal pure returns (Evidence memory) {
        return Evidence("", "");
    }

    /// @dev Generous flat ETH top-up for a bond's "rew" part on an ETH-reward task (ETH only comes
    ///      from msg.value, never transferFrom); the excess is always refunded by `settleValue`.
    uint256 internal constant ETH_BOND_HEADROOM = 1 ether;

    function _submit(address who, uint256 taskId) internal returns (uint256 subId) {
        vm.prank(who);
        subId = vault.submit{value: ETH_BOND_HEADROOM}(
            taskId, "https://x.com/doer/status/1", _noEvidence(), 0, type(uint256).max, _noSwap()
        );
    }

    /// @dev The task's rule texts and the disputer's reason/proof link are not kept in storage, only their
    ///      hashes. Every task `_create`/`_createWithDeadline` makes carries this
    ///      fixed `rulesOf("ipfs://task-condition")` (test/mocks/TaskRulesFixture.sol), and `_dispute` always files
    ///      this fixed reason/proof - so these two constants are the right resupply for every `_callSwarm`/
    ///      `_askAppealSwarm` in a test built on the generic helpers. A test that creates its own task/dispute text
    ///      directly (not through these helpers) must resupply its own text instead.
    string internal constant DISPUTE_REASON = "ipfs://reason";
    string internal constant DISPUTER_PROOF = "ipfs://reason-proof";

    function _genericRuleTexts() internal pure returns (RuleTexts memory rt) {
        TaskRules memory r = rulesOf("ipfs://task-condition");
        rt.task = r.task;
        rt.taskProof = r.proof;
        rt.taskNo = r.noIf;
        rt.disputeReason = DISPUTE_REASON;
        rt.disputerProofUri = DISPUTER_PROOF;
    }

    function _dispute(address who, uint256 subId) internal {
        vm.prank(who);
        vault.dispute{value: ETH_BOND_HEADROOM}(subId, DISPUTE_REASON, DISPUTER_PROOF, _noSwap());
    }

    function _appeal(address who, uint256 subId) internal {
        vm.prank(who);
        vault.appeal{value: ETH_BOND_HEADROOM}(subId, type(uint256).max, _noSwap());
    }

    /// @dev The appeal's ask is a separate step - `_appeal` above only files it; this
    ///      resupplies the generic rule texts and actually asks the swarm (anyone may call it, no `vm.prank` needed).
    function _askAppealSwarm(uint256 subId) internal {
        vault.askAppealSwarm(subId, _genericRuleTexts());
    }

    /// @dev NFT undecided: calls the swarm paying the live fee + a dispute bond, against the acceptance.
    function _callSwarm(address who, uint256 subId) internal {
        _callSwarm(who, subId, false);
    }

    function _callSwarm(address who, uint256 subId, bool sidesDoer) internal {
        vm.prank(who);
        vault.callSwarm{value: ETH_BOND_HEADROOM}(subId, sidesDoer, type(uint256).max, _noSwap(), _genericRuleTexts());
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

    /// @dev `subId`, `voteEnd` are unused: votes carry no signature.
    function _ballotByKey(uint256 subId, uint256 key, uint8 side, uint256[] memory ids, address payTo, uint64 voteEnd)
        internal
        pure
        returns (Ballot memory b)
    {
        subId;
        voteEnd;
        b = Ballot({voter: vm.addr(key), side: side, payTo: payTo, tokenIds: ids, signature: ""});
    }

    /// @dev Sends each ballot as one `vault.vote` from the current caller (a `vm.prank` before this call applies to
    ///      the first ballot only; every call site sends one). The vote sends every NFT the voter holds (setUp).
    function _submitVotes(uint256 subId, Ballot[] memory bs) internal {
        for (uint256 i; i < bs.length; ++i) {
            uint256[] memory ids = held[bs[i].voter].length != 0 ? held[bs[i].voter] : bs[i].tokenIds;
            vault.vote(subId, bs[i].side, bs[i].payTo, ids);
        }
    }

    /// @dev The NFT ids of voter `i` (setUp): 0..119, 120..139, 140..149, 150..154, 155..156.
    function _rangeOf(uint256 i) internal pure returns (uint256 from, uint256 count) {
        if (i == 0) return (0, 120);
        if (i == 1) return (120, 20);
        if (i == 2) return (140, 10);
        if (i == 3) return (150, 5);
        return (155, 2);
    }

    function _rangeCount(uint256 i) internal pure returns (uint256 count) {
        (, count) = _rangeOf(i);
    }

    /// @dev Rung `k` of voter `i`'s ladder: a wallet of 2^k NFTs of its own (setUp), voting for voter `i`.
    function _rung(uint256 i, uint256 k) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("rung", i, k)))));
    }

    /// @dev Voter `voterIdx` votes `count` NFTs with the reward to themself. Their whole wallet (`from`..`from+count-1`
    ///      = all their NFTs): one vote. A part of it (this helper always sends a wallet's whole NFT list):
    ///      the rungs of their ladder that add up to `count` vote, largest first, each for them, until the
    ///      count is reached or the vote is decided (an instant decision closes it, as a single vote would).
    ///      A part can be voted once per dispute per voter.
    function _vote(uint256 subId, uint256 voterIdx, uint8 side, uint256 from, uint256 count) internal {
        (uint256 f, uint256 c) = _rangeOf(voterIdx);
        if (f == from && c == count) {
            vm.prank(voters[voterIdx]); // only the holder sends their own vote
            vault.vote(subId, side, voters[voterIdx], held[voters[voterIdx]]);
            return;
        }
        require(voterIdx < 3 && from >= f && from + count <= f + c && count != 0, "no ladder for this vote");
        bool first = true;
        for (uint256 k = 8; k > 0; --k) {
            uint256 bit = 1 << (k - 1);
            if (count & bit == 0) continue;
            if (!first && _phase(subId) != Phase.Voting) return;
            first = false;
            address rung = _rung(voterIdx, k - 1);
            vm.prank(rung);
            vault.vote(subId, side, voters[voterIdx], held[rung]);
        }
    }

    /// @dev A new wallet holding `count` fresh NFTs (its votes send them); the next block starts.
    function _holder(string memory name, uint256 count) internal returns (address w) {
        w = makeAddr(name);
        uint256[] memory ids = _ids(nextNftId, count);
        for (uint256 i; i < count; ++i) {
            nft.mint(w, ids[i]);
        }
        nextNftId += count;
        held[w] = ids;
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// @dev `w` votes for themself with all their NFTs.
    function _voteAs(uint256 subId, address w, uint8 side) internal {
        vm.prank(w);
        vault.vote(subId, side, w, held[w]);
    }

    /// @dev The NFT decides at the vote end, unless an instant decision (instantDelta) already fired earlier:
    ///      warp to the vote end (if not there yet) and play the timer, but skip poke if already Decided.
    function _endVote(uint256 subId) internal {
        if (_phase(subId) == Phase.Decided) return;
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

    /// @dev There is no public fallback: the call reverts UnknownFunction for any input.
    function _expectNoFallback(bytes32 rid, OracleAttestation.Attestation memory a, bytes memory sig) internal {
        vm.expectRevert(UnknownFunction.selector);
        IAttestationFallback(address(vault)).submitAttestation(rid, a, sig);
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
        // every step is closed by its own timer (no stuck-state fallback)
        for (uint256 round; round < 12; ++round) {
            _warp(LONG);
            bool busy;
            for (uint256 i; i < trackedTasks.length; ++i) {
                Task memory tkBefore = vault.getTask(trackedTasks[i]);
                // The appeal's ask is a separate step and needs a resupplied RuleTexts
                // `poke` cannot carry - a submission left in Phase.Appealed by a test that never asks itself
                // would otherwise sit here forever. Try the generic fixture's texts (every `_create`/`_dispute`/
                // `_appeal` helper in this file uses them); a custom-text test that reaches this path unresolved
                // stays busy, same as any other genuinely stuck case.
                if (tkBefore.activeSub != 0 && uint8(_phase(tkBefore.activeSub)) == uint8(Phase.Appealed)) {
                    try vault.askAppealSwarm(tkBefore.activeSub, _genericRuleTexts()) {} catch {}
                }
                vault.poke(trackedTasks[i]);
                Task memory tk = vault.getTask(trackedTasks[i]);
                if (tk.status == TaskStatus.Open && tk.activeSub != 0) busy = true;
            }
            if (!busy) break;
        }
        // rewards are locked until the deadline: let every task reach it and expire if nobody did it
        uint256 last;
        for (uint256 i; i < trackedTasks.length; ++i) {
            uint256 dl = vault.getTask(trackedTasks[i]).deadline;
            if (dl > last) last = dl;
        }
        if (_now() < last) vm.warp(last);
        for (uint256 i; i < trackedTasks.length; ++i) {
            vault.poke(trackedTasks[i]);
        }
        uint256 subs = vault.submissionCount();
        for (uint256 s = 1; s <= subs; ++s) {
            try vault.claimVoidSubmission(s) {} catch {}
            for (uint256 a; a < actors.length; ++a) {
                vm.prank(actors[a]);
                try vault.claimDisputer(s) {} catch {}
                try vault.claimVoterReward(s, actors[a]) {} catch {}
            }
        }
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

    /// @dev Every $YOLO bonus ends with its task: paid out on an accepted submission (doer, NFT votes, burn), or back
    ///      to whoever put it in after expiry or unwind. After all tasks are final the sweetener holds nothing.
    function _settleSweetener(uint256) internal {
        for (uint256 t; t < trackedTasks.length; ++t) {
            uint256 id = trackedTasks[t];
            if (vault.getTask(id).status == TaskStatus.Completed) {
                try sweetener.payout(id) {} catch {}
                for (uint256 a; a < actors.length; ++a) {
                    try sweetener.claimVoter(id, actors[a]) {} catch {}
                }
                assertEq(sweetener.voterPool(id), 0, "voter bonus left in the sweetener");
            } else {
                for (uint256 a; a < actors.length; ++a) {
                    vm.prank(actors[a]);
                    try sweetener.withdraw(id) {} catch {}
                }
            }
            assertEq(sweetener.bonusOf(id), 0, "bonus of a task not paid or returned");
        }
        assertEq(yolo.balanceOf(address(sweetener)), 0, "YOLO stuck in the sweetener");
    }
}
