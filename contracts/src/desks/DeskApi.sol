// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../VaultTypes.sol";

/// @dev The internal API between TaskVault and its desks. Nothing here is callable by users: every function checks
///      that its caller is the vault or the one desk it serves (see each desk). Users reach the desks only through
///      the vault, which appends the original sender and msg.value to the forwarded calldata.

/// @notice What a task tells the case desk at submission time (TaskVault.submitTerms).
struct SubmitTerms {
    TaskStatus status;
    uint64 deadline;
    uint32 version; // parameter version of the task
    address currency;
    uint8 proofType;
    uint32 rejectedCount;
    bool busy; // a submission is active: a new one is queued
    uint256 ahead; // the active submission (0 or 1) plus the queue in front of a new submission
    uint256 pot;
    bool doerEver; // the doer ever contributed to this task
}

/// @notice The fixed fields of a submission the other desks read (CaseDesk.subCore).
struct SubCore {
    uint64 taskId;
    address doer;
    Phase phase;
    Outcome outcome;
    Verdict nftDecision;
    uint64 windowEnd;
    uint64 voteEnd;
    uint32 version; // parameter version of its task
    address currency; // reward currency of its task
    uint256 rewardImd;
    uint256 imdPerEth;
}

/// @notice A submission at settlement (CaseDesk -> DisputeDesk.settle).
struct Facts {
    uint64 taskId;
    uint32 version;
    address currency;
    address doer;
    bool doerIsContributor;
    Verdict nftDecision;
    uint256 reward;
    uint256 bond;
    uint256 checkFunds; // unused mandatory-check prepayment, credited back to the doer
}

/// @notice NFT vote totals of a submission.
struct Tally {
    uint256 accept;
    uint256 reject;
    uint256 walletsAccept;
    uint256 walletsReject;
}

/// @notice The fixed fields of the current swarm caller of a submission (an `Appeal` without its texts).
struct AppealCore {
    address appellant;
    bool sidesDoer;
    bool replied;
    uint64 replyEnd;
    uint256 funds;
}

/// @notice A swarm question the vault pays for (IVault.ask): the Intake, its action and price, and the panel the
///         answer must come from (the parameters of the submission's task).
struct AskTerms {
    uint64 subId;
    uint8 kind;
    uint16 minPanelSize;
    uint16 minQuorum;
    address intake;
    bytes32 action;
    bytes32 questionHash;
    uint256 price;
}

/// @notice The vault as the desks see it: the bank (every amount moves here) and the tasks.
interface IVault {
    function collectImd(address from, uint256 msgValue, uint256 needed, address adapter, ImdPay calldata payIn)
        external
        returns (uint256 ethNeeded);
    function bookEth(uint256 amount, bool toTreasury) external;
    function settleValue(address payer, uint256 msgValue, uint256 ethNeeded) external;
    function credit(address token, address account, uint256 amount) external;
    function pay(address token, address to, uint256 amount) external;
    function addTreasury(address token, uint256 amount) external;
    function ask(AskTerms calldata t, bytes calldata body) external returns (bool ok, uint256 spent, bytes32 requestId);
    function requests(bytes32 requestId) external view returns (SwarmRequest memory);

    function advance(uint256 taskId) external;
    function isContributor(uint256 taskId, address who) external view returns (bool);
    function submitTerms(uint256 taskId, address doer) external view returns (SubmitTerms memory);
    function place(uint256 taskId, uint256 subId, bool queued) external;
    function closeSubmission(uint256 taskId, Outcome o, uint256 reward) external returns (uint256 next);
    function statusOf(uint256 taskId) external view returns (TaskStatus);
}

interface ICaseDesk {
    function step(uint256 subId) external returns (bool moved);
    function finalize(uint256 subId, Outcome o) external;
    function stepDeadline(uint256 subId) external view returns (uint256);
    function subCore(uint256 subId) external view returns (SubCore memory);
    function advanced(uint256 subId) external returns (SubCore memory);
    function startVote(uint256 subId, uint32 voteWindow, uint32 replyWindow) external;
    function markAppealed(uint256 subId) external;
    function askEscalation(uint256 subId, uint256 price) external returns (bool ok, uint256 spent);
}

interface IDisputeDesk {
    function tally(uint256 subId) external view returns (Tally memory);
    function appealCore(uint256 subId) external view returns (AppealCore memory);
    function appealAsked(uint256 subId, uint256 spent) external;
    function dropCaller(uint256 subId) external;
    function settle(uint256 subId, Outcome o, bool tie, Facts calldata f) external;
}
