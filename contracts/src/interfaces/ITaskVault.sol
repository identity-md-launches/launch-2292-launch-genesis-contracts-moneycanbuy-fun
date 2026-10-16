// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Params} from "../VaultParams.sol";
import {OracleAttestation} from "../OracleAttestation.sol";
import {Ballot} from "../libraries/VoteLib.sol";
import "../VaultTypes.sol";

/// @notice The whole user interface of TaskVault: what the site, any indexer and the tests call. Functions the vault
///         does not implement itself are forwarded to its desks (TaskVault.fallback); events come from the vault
///         (tasks, money, swarm requests and answers) and from the desks (submissions, disputes, votes, appeals,
///         settlements), see VaultTypes.sol.
interface ITaskVault {
    // ---- tasks (the vault itself)

    /// @notice Create a task. msg.value covers `authorFee` (non-refundable, to the treasury) + the reward for ETH
    ///         tasks + ETH swapped in mode A (IMD tasks). Excess ETH is refunded.
    ///         `title` (1..MAX_TITLE_BYTES, only in TaskCreated, never sent to the swarm); `condition` (what to do and
    ///         how to prove it: stored, the swarm's TASK); `category` (< CATEGORY_COUNT) and `proofType`
    ///         (< PROOF_TYPE_COUNT: what every proofUri must be) are stored; `cover` (empty, `ipfs://…` or `https://…`,
    ///         at most MAX_COVER_BYTES) is only emitted in TaskCreated. None of them can change later.
    function createTask(
        address currency,
        uint256 amount,
        uint64 deadline,
        string calldata title,
        string calldata condition,
        uint8 category,
        uint8 proofType,
        string calldata cover,
        uint256 authorFee,
        ImdPay calldata payIn
    ) external payable returns (uint256);
    /// @notice Add to a task's reward (same currency). During an active submission it waits for the next round.
    function topUp(uint256 taskId, uint256 amount, ImdPay calldata payIn) external payable;
    /// @notice Announce taking back your active share of an open task: allowed from 1 h after this for 1 day.
    function announceWithdraw(uint256 taskId) external;
    /// @notice Take back your share when allowed (no active submission and a due notice, pending top-ups, expiry,
    ///         unwind).
    function withdrawContribution(uint256 taskId) external;
    /// @notice When the announced withdrawal of `who`'s active share may happen (0 = none; valid for 1 day).
    function withdrawNoticeAt(uint256 taskId, address who) external view returns (uint64);
    /// @notice Play the expired timers of a task (anyone; every task call does this first).
    function poke(uint256 taskId) external;
    /// @notice Unwind a task whose active step is stuck `emergencyDelay` after its timer expired.
    function emergencyExit(uint256 taskId) external;
    function taskCount() external view returns (uint256);
    function getTask(uint256 taskId) external view returns (Task memory);
    function getContribution(uint256 taskId, address who) external view returns (Contribution memory);

    // ---- submissions (CaseDesk)

    /// @notice Bond and mandatory check fee (large tasks, not refunded) a new submission to `taskId` would need now.
    function quoteSubmission(uint256 taskId) external view returns (uint256 bond, uint256 checkFee);

    /// @notice Submit a proof with an IMD bond (and the mandatory-check prepayment for large tasks). `proofUri` is one
    ///         link in the form the task's proof type requires (`BadProof` otherwise, TextLib.checkProof).
    ///         `evidence`: optional screenshot (IPFS digest) and note, sent to the swarm with the proof (Evidence).
    ///         Reverts if the reward is now below `minReward` or bond + check fee above `maxImdIn`.
    function submit(
        uint256 taskId,
        string calldata proofUri,
        Evidence calldata evidence,
        uint256 minReward,
        uint256 maxImdIn,
        ImdPay calldata payIn
    ) external payable returns (uint256);
    function claimVoidSubmission(uint256 subId) external;
    /// @notice The doer's single reply to the disputes.
    function reply(uint256 subId, string calldata text) external;
    function submissionCount() external view returns (uint256);
    function getSubmission(uint256 subId) external view returns (Submission memory);
    function stepDeadline(uint256 subId) external view returns (uint256);
    /// @notice The JSON body the vault would send now for `kind` (1 check, 2 escalation, 3 appeal).
    function previewSwarmBody(uint256 subId, uint8 kind) external view returns (bytes memory body, bytes32 qh);

    // ---- disputes, votes, appeals, claims (DisputeDesk)

    /// @notice Dispute the active submission: IMD bond + ETH gas fee (`disputeFee`, msg.value) + reason.
    function dispute(uint256 subId, string calldata reason, uint256 disputeFee, ImdPay calldata payIn) external payable;
    /// @notice Relay a batch of signed NFT votes; the relayer is reimbursed from the dispute pot (pull).
    function submitVotes(uint256 subId, Ballot[] calldata ballots) external;
    /// @notice Appeal an NFT decision (dispute bond + the live swarm fee, paid now; at most `maxImdIn` IMD).
    function appeal(uint256 subId, string calldata reason, uint256 maxImdIn, ImdPay calldata payIn) external payable;
    /// @notice The appellant's opponent replies once.
    function appealReply(uint256 subId, string calldata text) external;
    /// @notice NFT undecided: call the swarm paying the live fee + a dispute bond now, standing for (`sidesDoer`)
    ///         or against the acceptance, with his own `reason` for the swarm; at most `maxImdIn` IMD.
    function callSwarm(uint256 subId, bool sidesDoer, string calldata reason, uint256 maxImdIn, ImdPay calldata payIn)
        external
        payable;
    function claimDisputer(uint256 subId) external;
    function claimVoterReward(uint256 subId, address payTo) external;
    function claimRelayerShortfall(uint256 subId) external;
    function getDispute(uint256 subId) external view returns (Dispute memory);
    function getDisputer(uint256 subId, address who) external view returns (DisputerInfo memory);
    function getAppeal(uint256 subId) external view returns (Appeal memory);
    function getSettlement(uint256 subId) external view returns (Settlement memory);
    function votesOf(uint256 subId, address payTo) external view returns (uint256 accept, uint256 reject);
    function voterClaimed(uint256 subId, address payTo) external view returns (bool);
    function tokensVoted(uint256 subId, uint256[] calldata tokenIds) external view returns (bool[] memory voted);
    function tokenVoted(uint256 subId, uint256 tokenId) external view returns (bool);
    function relayerShortfall(uint256 subId, address relayer) external view returns (uint256);
    function voteDomainSeparator() external view returns (bytes32);
    /// @notice Dispute bond of `subId`. Appealing or calling the swarm costs the same bond plus `quoteSwarmFee`.
    function quoteDisputeBond(uint256 subId) external view returns (uint256);
    /// @notice Live swarm fee (IMD) for questions about `subId`; 0 = the Intake does not sell the action now.
    function quoteSwarmFee(uint256 subId) external view returns (uint256);

    // ---- parameters (ParamsRegistry)

    /// @notice The parameter snapshot of `version` (forwarded to the registry).
    function paramsOf(uint32 version) external view returns (Params memory);

    // ---- the vault itself: money, swarm answers

    /// @notice Intake callback (selector 0x510379c7). Records only; never reverts on foreign or duplicate input.
    ///         The only way a swarm answer reaches the vault (no public fallback, audit B-01).
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
