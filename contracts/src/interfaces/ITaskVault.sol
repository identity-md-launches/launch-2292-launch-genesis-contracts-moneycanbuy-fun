// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Params} from "../VaultParams.sol";
import {OracleAttestation} from "../OracleAttestation.sol";
import "../VaultTypes.sol";

/// @notice The whole user interface of TaskVault: what the site, off-chain readers and the tests call. Functions the vault
///         does not implement itself are forwarded to its desks (TaskVault.fallback); events come from the vault
///         (tasks, money, swarm requests and answers) and from the desks (submissions, disputes, votes, appeals,
///         settlements), see VaultTypes.sol.
interface ITaskVault {
    // ---- tasks (the vault itself)

    /// @notice Create a task. No creation fee. msg.value covers the reward for ETH tasks + ETH
    ///         swapped in mode A (IMD tasks). Excess ETH is refunded. `deadline` is required; the
    ///         reward is worth at least the currency's own minimum, no upper limit.
    ///         `title` (1..MAX_TITLE_BYTES, only in TaskCreated, never sent to the swarm); `rules` (TaskRules: TASK,
    ///         PROOF and NO texts, each 1..maxTextBytes, stored, each one swarm definition); `category` (< CATEGORY_COUNT) and `proofType`
    ///         (< PROOF_TYPE_COUNT: what every proofUri must be) are stored; `cover` (empty, `ipfs://…` or `https://…`,
    ///         at most MAX_COVER_BYTES) is only emitted in TaskCreated. None of them can change later.
    function createTask(
        address currency,
        uint256 amount,
        uint64 deadline,
        string calldata title,
        TaskRules calldata rules,
        uint8 category,
        uint8 proofType,
        string calldata cover,
        ImdPay calldata payIn
    ) external payable returns (uint256);
    /// @notice Add to a task's reward (same currency). It joins the reward at once, also during a check.
    function topUp(uint256 taskId, uint256 amount, ImdPay calldata payIn) external payable;
    /// @notice Take back your share once the reward is unlocked: after expiry or a cancellation. Nothing after an
    ///         acceptance (the whole reward went to the doer), never while the task is open.
    function withdrawContribution(uint256 taskId) external;
    /// @notice The BuybackBurner that receives the burn shares in ETH, USDC and IMD.
    function burner() external view returns (address);
    /// @notice The YoloSweetener whose $YOLO add-on counts with the reward (0 until bound).
    function sweetener() external view returns (address);
    /// @notice Bind the YoloSweetener of this vault once (the registry owner).
    function bindSweetener(address s) external;
    /// @notice Play the expired timers of a task (anyone; every task call does this first).
    function poke(uint256 taskId) external;
    /// @notice The dev wallet (owner of the task's DevPrices) cancels an open task: Unwound,
    ///         everyone takes back what they put in with their own claim; the dev wallet gets nothing.
    function cancelTask(uint256 taskId) external;
    function taskCount() external view returns (uint256);
    function getTask(uint256 taskId) external view returns (Task memory);
    function potOf(uint256 taskId) external view returns (uint256);
    function getContribution(uint256 taskId, address who) external view returns (Contribution memory);

    // ---- submissions (CaseDesk)

    /// @notice The bond a new submission to `taskId` would need now: 0.5 IMD fixed + 3% R (R = the author's own
    ///         share of the pot in the task currency; a $YOLO add-on is not part of it), no oracle.
    function quoteSubmission(uint256 taskId) external view returns (Bond memory bond);

    /// @notice Submit a proof with a bond (0.5 IMD + 3% R, see `quoteSubmission`). `proofUri` is one link in the
    ///         form the task's proof type requires (`BadProof` otherwise, TextLib.checkProof).
    ///         `evidence`: optional screenshot link (allowlisted host) and note, sent to the swarm with the proof (Evidence).
    ///         Reverts if the reward is now below `minReward` or the bond's `rew` part above `maxBondRew`.
    function submit(
        uint256 taskId,
        string calldata proofUri,
        Evidence calldata evidence,
        uint256 minReward,
        uint256 maxBondRew,
        ImdPay calldata payIn
    ) external payable returns (uint256);
    function claimVoidSubmission(uint256 subId) external;
    function submissionCount() external view returns (uint256);
    function getSubmission(uint256 subId) external view returns (Submission memory);
    function stepDeadline(uint256 subId) external view returns (uint256);
    /// @notice The JSON body the vault would send now for `kind` (2 escalation, 3 appeal). `rt`: resupplied task
    ///         rules + dispute reason/proof link, checked against the stored hashes.
    function previewSwarmBody(uint256 subId, uint8 kind, RuleTexts calldata rt)
        external
        view
        returns (bytes memory body, bytes32 qh);

    // ---- disputes, votes, appeals, claims (DisputeDesk)

    /// @notice Dispute the active submission: IMD bond + reason + the disputer's own proof link, optional:
    ///         empty allowed. No ETH fee (nobody is reimbursed for gas). Only
    ///         keccak256(abi.encode(reason, disputerProofUri)) is stored; both texts stay in this call's calldata
    ///         and the Disputed event.
    function dispute(uint256 subId, string calldata reason, string calldata disputerProofUri, ImdPay calldata payIn)
        external
        payable;
    /// @notice Cast an NFT vote (side 1 accept, 2 reject) with NFT ids the sender owns now or holds a delegate.xyz
    ///         delegation for; each id votes once per dispute, the vote counts the ids; more transactions for the same
    ///         side add NFTs, the side cannot change. The reward of the vote
    ///         goes to `payTo`.
    function vote(uint256 subId, uint8 side, address payTo, uint256[] calldata tokenIds) external;
    /// @notice Appeal an NFT decision (dispute bond + the live swarm fee, paid now; at most `maxImdIn` IMD). No
    ///         `reason`: a button, not a text field. The ask is
    ///         lazy: call `askAppealSwarm` separately to resupply the text
    ///         and ask the swarm.
    function appeal(uint256 subId, uint256 maxImdIn, ImdPay calldata payIn) external payable;
    /// @notice Lazy ask for an appeal filed by `appeal` above: anyone may call this once the
    ///         submission sits in Phase.Appealed, resupplying the task rules + the filed dispute's reason/proof
    ///         link; checked against the stored hashes, `RulesMismatch` otherwise.
    function askAppealSwarm(uint256 subId, RuleTexts calldata rt) external;
    /// @notice NFT undecided: call the swarm paying the live fee + a dispute bond now, standing for (`sidesDoer`)
    ///         or against the acceptance; at most `maxImdIn` IMD. No `reason` (same button-not-text rule
    ///         as `appeal`). `rt`: the task rules + the filed dispute's reason/proof link, resupplied in this same
    ///         call to rebuild the swarm question, checked against the stored hashes.
    function callSwarm(uint256 subId, bool sidesDoer, uint256 maxImdIn, ImdPay calldata payIn, RuleTexts calldata rt)
        external
        payable;
    function claimDisputer(uint256 subId) external;
    function claimVoterReward(uint256 subId, address payTo) external;
    /// @notice claimVoterReward on many submissions in one transaction (with the $YOLO bonus shares).
    function claimVoterRewards(uint256[] calldata subIds, address payTo) external;
    function getDispute(uint256 subId) external view returns (Dispute memory);
    function getDisputer(uint256 subId, address who) external view returns (DisputerInfo memory);
    function getAppeal(uint256 subId) external view returns (Appeal memory);
    function getSettlement(uint256 subId) external view returns (Settlement memory);
    /// @notice IMD each side's own dispute bond already paid to the swarm for its calls: the doer's and the
    ///         disputer's bond give back that much less, and a side's next call is paid in full from the wallet.
    function sideSpent(uint256 subId) external view returns (SideSpent memory);
    function votesOf(uint256 subId, address payTo) external view returns (uint256 accept, uint256 reject);
    function voterClaimed(uint256 subId, address payTo) external view returns (bool);
    function hasVoted(uint256 subId, address voter) external view returns (bool);
    /// @notice The side `voter` voted on a submission: 0 none, 1 accept, 2 reject.
    function sideOf(uint256 subId, address voter) external view returns (uint8);
    /// @notice Whether NFT `tokenId` already voted on a submission (each id once per dispute).
    function tokenVoted(uint256 subId, uint256 tokenId) external view returns (bool);
    /// @notice VotePower: who may vote with an NFT now (owner or delegate.xyz delegate).
    function votePower() external view returns (address);
    /// @notice Dispute bond of `subId`. A stranger appealing or calling the swarm posts this bond plus `quoteSwarmFee`
    ///         (on an IMD task its `rew` part is IMD too). The doer and the disputer post no second bond: a side's
    ///         first call is paid out of its own bond, a repeat call takes the whole fee from the wallet (`sideSpent`).
    function quoteDisputeBond(uint256 subId) external view returns (Bond memory);
    /// @notice Live swarm fee (IMD) for questions about `subId`; 0 = the Intake does not sell the action now.
    function quoteSwarmFee(uint256 subId) external view returns (uint256);

    // ---- parameters (ParamsRegistry)

    /// @notice The parameter snapshot of `version` (forwarded to the registry).
    function paramsOf(uint32 version) external view returns (Params memory);

    // ---- the vault itself: money, swarm answers

    /// @notice Intake callback (selector 0x510379c7). Records only; never reverts on foreign or duplicate input.
    ///         The only way a swarm answer reaches the vault (no public fallback).
    function onOracleResult(bytes32 requestId, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external;
    function withdraw(address token) external;
    function withdrawTo(address token, address to) external;
    function sweepTreasury(address token) external;
    function imd() external view returns (address);
    function usdc() external view returns (address);
    function yolo() external view returns (address);
    function registry() external view returns (address);
    function textRules() external view returns (address);
    function attestationChecker() external view returns (address);
    function caseDesk() external view returns (address);
    function disputeDesk() external view returns (address);
    function liabilities(address token) external view returns (uint256);
    function credits(address token, address account) external view returns (uint256);
    function treasuryPot(address token) external view returns (uint256);
    function requests(bytes32 requestId) external view returns (SwarmRequest memory);
    function attestationDigest(OracleAttestation.Attestation calldata a) external view returns (bytes32);
}
