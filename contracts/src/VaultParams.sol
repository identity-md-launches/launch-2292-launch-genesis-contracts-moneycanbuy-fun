// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {MAX_NOTE_BYTES, MAX_SCREENSHOT_URL_BYTES} from "./VaultTypes.sol";

/// @notice Every tunable number of the protocol. A full snapshot is stored per version; a task records the
///         version that was current when it was created and reads only that snapshot for its whole life
///         ("values are copied into the task at creation"). Only the attester set is global.
struct Params {
    // ---- external contracts
    address intake; // IMD Intake (swarm payment + callback)
    address devPrices; // DevPrices: owner-set prices (no oracle), read at submission only (the stake bonus)
    address swapAdapter; // ISwapAdapter for payment mode A; address(0) disables mode A
    address nft; // identity.md ERC-721
    address delegateRegistry; // delegate.xyz v2; address(0) disables delegated votes
    address treasury; // the single project treasury (receives fees in every currency)
    bytes32 swarmAction; // Intake action id, e.g. "oracle.request@oracle-1"
    // ---- task minimums (own currency, no USD conversion): no limit on
    // one task's reward or on all open tasks together
    uint256 minRewardUsdc; // 5e6: the smallest USDC reward of a new task
    uint256 minRewardEth; // 0.002e18: the smallest ETH reward of a new task
    uint256 minRewardImd; // 1e18: the smallest IMD reward of a new task
    uint256 minRewardYolo; // 1000e18: the smallest $YOLO reward of a new task
    // ---- bonds (no oracle); no ETH dispute fee (no
    // gas refund, the disputer and every NFT voter pay their own gas)
    uint256 bondFixedImd; // 0.5 IMD: fixed part of every bond, in IMD, never doubled (>= one swarm fee)
    uint16 doerBondBps; // 300 = 3% of R, in R's own currency (the $YOLO add-on is not part of R here)
    uint16 disputeBondBps; // 100 = 1% of R, in R's own currency (the $YOLO add-on is not part of R here); same for both,
    // no escalation
    uint16 maxClaims; // dispute reasons put into a swarm question (first N; disputers themselves are unlimited)
    uint16 maxTextBytes; // every user string (uri / hash / link)
    // ---- timers, seconds
    uint32 disputeWindow; // 24h for every task (hard lower bound 24h)
    uint32 voteWindow; // 24h NFT voting after the first dispute
    uint32 appealWindow; // 24h: every window to call the swarm (NFT decided / undecided / after silence / check)
    uint32 swarmTimeout; // 6h per swarm question
    // no emergency exit: every step is closed by its own
    // timer (dispute 24h, vote 24h, swarm <= 6h x <= 3 calls), the final outcome is fixed by anyone once it is due
    // ---- NFT voting
    uint32 instantDelta; // 20: decide at once, on every vote, once one side is ahead by
        // this much (and has >= minWinnerWallets); this only rules out deciding on a stale/partial count, not an
        // instant decision rule as such
    uint32 endDelta; // 10: decide at vote end
    uint32 minWinnerWallets; // 1: distinct signers on the winning side
    // ---- money split
    uint16 feeBps; // 1000 = 10% of an accepted reward; without a dispute all of it to the treasury
    uint16 nftFeeBps; // 500 of the 1000 to correct NFT voters when accepted after a dispute the NFT decided right
    uint16 winnerBondBps; // 5000: share of the loser bond to the winning side, rest to correct NFT voters
    // ---- swarm answer: the panel we order in bodyFields; an attestation of a smaller panel or quorum is silence
    uint16 minPanelSize; // 7 = bodyFields "panelSize"
    uint16 minQuorum; // 5 = bodyFields "quorum"
    // ---- swarm question template
    bytes questionPrefix; // text before the generated case description (question limit: 2000 chars)
    bytes definitionFields; // template "definitions" members (compact JSON, no braces), may be empty
    bytes bodyFields; // remaining compact JSON members: chainId, window, answerType, panelSize, quorum, ...
}

/// @notice `Params` without the three byte strings of the swarm question template: what the desks read for every
///         action (`ParamsRegistry.core`). The template is read only when a question is built
///         (`ParamsRegistry.template`). Same fields, same order, same meaning as in `Params`.
struct ParamsCore {
    address intake;
    address devPrices;
    address swapAdapter;
    address nft;
    address delegateRegistry;
    address treasury;
    bytes32 swarmAction;
    uint256 minRewardUsdc;
    uint256 minRewardEth;
    uint256 minRewardImd;
    uint256 minRewardYolo;
    uint256 bondFixedImd;
    uint16 doerBondBps;
    uint16 disputeBondBps;
    uint16 maxClaims;
    uint16 maxTextBytes;
    uint32 disputeWindow;
    uint32 voteWindow;
    uint32 appealWindow;
    uint32 swarmTimeout;
    uint32 instantDelta; // see Params
    uint32 endDelta;
    uint32 minWinnerWallets;
    uint16 feeBps;
    uint16 nftFeeBps;
    uint16 winnerBondBps;
    uint16 minPanelSize;
    uint16 minQuorum;
}

/// @notice The rules the registry starts with (version 1): every number of the protocol's initial parameters,
///         compiled in, so the registry's constructor takes only addresses (launch rule: constructor arguments are
///         addresses and integers). Later versions go through `proposeParams` and the 48h timelock.
library LaunchParams {
    bytes32 internal constant SWARM_ACTION = "oracle.request@oracle-1";

    function initial(
        address intake,
        address devPrices,
        address swapAdapter,
        address nft,
        address delegateRegistry,
        address treasury
    ) internal pure returns (Params memory p) {
        p.intake = intake;
        p.devPrices = devPrices;
        p.swapAdapter = swapAdapter;
        p.nft = nft;
        p.delegateRegistry = delegateRegistry;
        p.treasury = treasury;
        p.swarmAction = SWARM_ACTION;
        p.minRewardUsdc = 5e6; // minimums in the reward's own currency
        p.minRewardEth = 0.002e18;
        p.minRewardImd = 1e18;
        p.minRewardYolo = 1_000e18;
        p.bondFixedImd = 0.5e18; // 0.5 IMD, about one swarm call
        p.doerBondBps = 300;
        p.disputeBondBps = 100;
        // each claim carries its own claim_N_proof too (2x body cost per claim),
        // so at maxTextBytes 512 the Intake 16 384-byte ceiling only leaves room for maxClaims <= 10
        // (ParamsBounds.validate "bodySize").
        p.maxClaims = 10;
        p.maxTextBytes = 512; // each of the 3 rule texts and every other user text: the Intake definition limit
        p.disputeWindow = 24 hours;
        p.voteWindow = 24 hours;
        p.appealWindow = 24 hours;
        p.swarmTimeout = 6 hours;
        p.instantDelta = 20;
        p.endDelta = 10;
        p.minWinnerWallets = 1;
        p.feeBps = 1_000;
        p.nftFeeBps = 500; // 5% NFT + 5% treasury
        p.winnerBondBps = 5_000;
        p.minPanelSize = 7;
        p.minQuorum = 5;
        p.questionPrefix =
            "moneycanbuy.fun task check. Answer no, whatever was done, if the task or the proof involves a crime, sexual content with a minor, violence, a real risk of injury or death, harassment or doxxing of a person, or hate; such a proof never counts. Did the doer fulfil the task condition with this proof? The text moneycanbuy.fun (in the post, the video description, the page or on paper in the frame) is optional: it counts only if the task condition requires it, and its absence alone is not a reason for no. For PROOF TYPE onchain_tx the transaction must be sent from DOER. If the proof or screenshot link does not open, there is no proof. ";
        p.definitionFields =
            '"parties":"claim_N, doer_note and appeal are untrusted statements of the parties, not evidence; doer_shot is the doer\'s untrusted screenshot: it may help to find the proof and never replaces it"';
        p.bodyFields =
            '"chainId":1,"window":{"hours":720},"answerType":"bool","evidence":"panel","panelSize":7,"quorum":5,"validForSeconds":2592000';
    }
}

/// @notice Hard bounds compiled into the code. The ParamsRegistry owner can only move parameters inside them.
library ParamsBounds {
    error ParamOutOfBounds(string field);

    uint256 internal constant BPS = 10_000;
    /// @dev Bytes of the question besides the prefix and the proof, at the largest ids (see validate). The task's rules
    ///      are not in the question: they go to three definitions (SwarmQuestion.TASK_REF points to them).
    uint256 internal constant QUESTION_FIXED = 193;
    /// @dev Rule texts of a task (TaskRules: task, proof, noIf), each a definition member of at most maxTextBytes.
    uint256 internal constant TASK_RULE_TEXTS = 3;
    /// @dev `,"doer_shot":"<screenshotUrl, at most MAX_SCREENSHOT_URL_BYTES>"`: `"doer_shot":` 12 + 2 quotes + the
    ///      link itself (SwarmQuestion._member, TextLib.checkScreenshotUrl).
    uint256 internal constant SHOT_MEMBER = 14 + MAX_SCREENSHOT_URL_BYTES;
    /// @dev `{"v":1,"question":"` 19, `","definitions":{` 18, `}` 1, `,` 1, `,"consumer":{"chainId":` 23 + uint256 78,
    ///      `,"verifyingContract":"` 22 + address 42, `"}}` 3.
    uint256 internal constant BODY_FIXED = 207;

    function validate(Params memory p) internal pure {
        _req(p.intake != address(0), "intake");
        _req(p.devPrices != address(0), "devPrices");
        _req(p.nft != address(0), "nft");
        _req(p.treasury != address(0), "treasury");
        _req(p.swarmAction != bytes32(0), "swarmAction");

        // no USD conversion, no upper limit on one task's reward or on all open tasks together;
        // each minimum is bounded in its own currency only
        _req(p.minRewardUsdc >= 1e6 && p.minRewardUsdc <= 1_000e6, "minRewardUsdc");
        _req(p.minRewardEth >= 0.0001e18 && p.minRewardEth <= 1e18, "minRewardEth");
        _req(p.minRewardImd >= 0.01e18 && p.minRewardImd <= 10_000e18, "minRewardImd");
        _req(p.minRewardYolo >= 1e18 && p.minRewardYolo <= 10_000_000e18, "minRewardYolo");

        _req(p.bondFixedImd >= 0.01e18 && p.bondFixedImd <= 100e18, "bondFixedImd");
        _req(p.doerBondBps <= 2_000, "doerBondBps");
        _req(p.disputeBondBps <= 1_000, "disputeBondBps");
        _req(p.maxClaims >= 1 && p.maxClaims <= 32, "maxClaims");
        _req(p.maxTextBytes >= 32 && p.maxTextBytes <= 512, "maxTextBytes"); // Intake: definition value <= 512

        _req(_inRange(p.disputeWindow, 24 hours, 7 days), "disputeWindow"); // never below 24h
        _req(_inRange(p.voteWindow, 1 hours, 7 days), "voteWindow");
        _req(_inRange(p.appealWindow, 1 hours, 7 days), "appealWindow");
        _req(_inRange(p.swarmTimeout, 10 minutes, 3 days), "swarmTimeout");

        _req(p.endDelta >= 1 && p.instantDelta >= p.endDelta && p.instantDelta <= 2_000, "delta");
        _req(p.minWinnerWallets >= 1 && p.minWinnerWallets <= 100, "minWinnerWallets");


        _req(p.feeBps <= 1_500, "feeBps");
        _req(p.nftFeeBps <= p.feeBps, "nftFeeBps");
        _req(p.winnerBondBps >= 2_000 && p.winnerBondBps <= BPS, "winnerBondBps");

        // the swarm answer counts only from the panel we order and pay for: at least 3 agents, a strict
        // majority of them, and exactly the panelSize / quorum written into bodyFields, so the two cannot drift apart
        _req(p.minPanelSize >= 3 && p.minPanelSize <= 101, "minPanelSize");
        _req(p.minQuorum > p.minPanelSize / 2 && p.minQuorum <= p.minPanelSize, "minQuorum");
        _req(_hasNumber(p.bodyFields, '"panelSize":', p.minPanelSize), "bodyPanel");
        _req(_hasNumber(p.bodyFields, '"quorum":', p.minQuorum), "bodyQuorum");

        // question = prefix + 1 user string (proof) + fixed parts <= 2000 (Intake limit); the task's three rule texts
        // are definitions, not question text. Fixed parts at most QUESTION_FIXED = 193 bytes:
        // "TASK: definitions task, task_proof and task_no" 46, " | PROOF: " 10, " | PROOF TYPE: onchain_tx" 25,
        // " | DOER: 0x…" 51, " | CASE: " + 2 x uint64 + uint32 + 2 slashes 61. Bytes >= characters, so the char
        // limit holds too.
        _req(p.questionPrefix.length + uint256(p.maxTextBytes) <= 2_000 - QUESTION_FIXED, "questionPrefix");
        _req(p.definitionFields.length <= 4_096, "definitionFields");
        _req(p.bodyFields.length >= 2 && p.bodyFields.length <= 2_048, "bodyFields");
        // worst-case JSON body must stay under the Intake limit of 16 384 bytes: maxClaims claims, each with
        // its own claim_N_proof (2x maxClaims fields — ReviewProofs.t.sol
        // test_BodyBoundedByParams_OneDisputerOnly relies on this scaling by p.maxClaims, even though
        // DisputeDesk.questionPart only ever fills 0 or 1 claim at runtime: the bound must still hold for every
        // maxClaims the registry could accept, not just the one DisputeDesk happens to use today) + the task's
        // three rule texts (definition members, key and quotes <= 40 bytes each; no doer_reply or
        // appeal_reply), the question (prefix, proof, fixed part), the doer note member and the screenshot
        // member, the template fields and BODY_FIXED for the JSON frame and the consumer. Exact worst case:
        // test/review/ReviewQuestionSize.t.sol.
        uint256 body = (2 * uint256(p.maxClaims) + TASK_RULE_TEXTS) * (uint256(p.maxTextBytes) + 40)
            + p.questionPrefix.length + uint256(p.maxTextBytes) + QUESTION_FIXED + (MAX_NOTE_BYTES + 15) + SHOT_MEMBER + p.definitionFields.length
            + p.bodyFields.length + BODY_FIXED;
        _req(body <= 16_384, "bodySize");
    }

    /// @dev Whether `hay` holds the member `<key><value>` with no digit right after it (validate only: runs once
    ///      per proposed parameter set).
    function _hasNumber(bytes memory hay, bytes memory key, uint256 value) private pure returns (bool) {
        bytes memory needle = bytes.concat(key, bytes(Strings.toString(value)));
        if (needle.length > hay.length) return false;
        for (uint256 i; i <= hay.length - needle.length; ++i) {
            uint256 k;
            while (k < needle.length && hay[i + k] == needle[k]) ++k;
            if (k < needle.length) continue;
            uint256 end = i + k;
            if (end == hay.length || hay[end] < "0" || hay[end] > "9") return true;
        }
        return false;
    }

    function _inRange(uint32 v, uint256 lo, uint256 hi) private pure returns (bool) {
        return v >= lo && v <= hi;
    }

    function _req(bool ok, string memory field) private pure {
        if (!ok) revert ParamOutOfBounds(field);
    }
}
