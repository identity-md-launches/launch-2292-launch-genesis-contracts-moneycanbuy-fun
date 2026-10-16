// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Shared types, events and errors of TaskVault and its desks (src/desks). TaskVault is the one public address:
///      it holds the money, the tasks and the swarm requests and forwards the other calls to the desk that owns the
///      state (CaseDesk: submissions, DisputeDesk: disputes, appeals, votes and settlements).

address constant ETH = address(0);
uint256 constant BPS = 10_000;
uint8 constant SWARM_KIND_CHECK = 1; // mandatory check of a large submission
uint8 constant SWARM_KIND_ESCALATION = 2; // NFT vote without decision, somebody paid to call the swarm
uint8 constant SWARM_KIND_APPEAL = 3; // appeal of an NFT decision
/// @dev Task categories: 0 social, 1 stream, 2 irl, 3 onchain, 4 dev, 5 art, 6 other (the site's labels and fallback
///      covers). Set once at creation.
uint8 constant CATEGORY_COUNT = 7;
/// @dev Longest cover link: `ipfs://<CIDv1>` is 66 bytes, the rest is room for a path or an https fallback.
uint256 constant MAX_COVER_BYTES = 160;
/// @dev Task title: shown on the site, never sent to the swarm (the condition says what to do and how to prove it).
uint256 constant MAX_TITLE_BYTES = 80;
/// @dev Proof types: what a submission's proofUri must be (TextLib.checkProof). Set once at creation.
uint8 constant PROOF_X_POST = 0; // https://x.com/<user>/status/<id> (or twitter.com)
uint8 constant PROOF_VIDEO = 1; // https link on youtube.com, youtu.be, kick.com, twitch.tv, or an X post
uint8 constant PROOF_ONCHAIN_TX = 2; // 0x + 64 hex: an Ethereum mainnet transaction hash
uint8 constant PROOF_LINK = 3; // any https link
uint8 constant PROOF_TYPE_COUNT = 4;
/// @dev Doer's note on a submission: same text rule as the condition (TextLib.validText), short. Stored because the
///      swarm question is built on chain in whatever transaction asks it; 200 bytes = at most 8 storage slots.
uint256 constant MAX_NOTE_BYTES = 200;
/// @dev onOracleResult(bytes32,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,
///      uint16,uint16,uint16,uint64,uint64),bytes) - matches the IMD docs and a delivered mainnet callback.
bytes4 constant CALLBACK_SELECTOR = 0x510379c7;
/// @dev A swarm answer signed within the swarm timeout counts if it reaches the vault at most this long after the
///      timeout; silence is declared only after it, so the outcome never depends on who pokes when (swarm audit
///      #7).
uint256 constant SWARM_DELIVERY_GRACE = 1 hours;
/// @dev A contributor's active share leaves an open task only after this public notice (`announceWithdraw`) ...
uint256 constant WITHDRAW_NOTICE = 1 hours;
/// @dev ... and the notice holds this long after that (then it must be renewed), as YoloSweetener's.
uint256 constant WITHDRAW_NOTICE_VALID = 1 days;

// ====================================================================== enums

enum TaskStatus {
    None,
    Open,
    Completed, // a submission was accepted
    Expired, // deadline passed with no submission in flight: everyone takes back his share
    Unwound // emergency exit: everyone takes back what he put in
}

enum Phase {
    None,
    Queued, // waiting behind the active submission
    Review, // active; dispute window (large tasks: after the mandatory swarm check answered "yes" or was silent)
    Voting, // at least one dispute: NFT vote running
    NoDecision, // NFT did not decide: optimistic window, anyone may call the swarm paying fee + bond
    Decided, // NFT decision stands: appeal window, anyone may appeal paying fee + bond
    Appealed, // appeal filed (fee prepaid): opponent reply window, then the question is asked lazily
    Asked, // the swarm was asked for a caller (appellant or NoDecision caller); answer or silence pending
    Final, // settled, see Outcome
    Void // queued submission of a task that was completed / unwound: bond refunded
}

enum Outcome {
    None,
    Accepted,
    Rejected,
    Unwound // emergency exit: everyone takes back what he put in
}

enum Verdict {
    None,
    Accept,
    Reject
}

enum CheckState {
    None, // not a large task (or the check was silent: treated as no check)
    Requested,
    Passed
}

enum SwarmStatus {
    Pending,
    Answered,
    Silent
}

// ====================================================================== structs

/// @notice How the payer provides IMD. `amountIn == 0`: mode B, IMD is pulled with transferFrom.
///         Otherwise mode A: `amountIn` of `tokenIn` (ETH or USDC) is swapped through the swap adapter with the
///         user's `minImdOut` and `deadline`; surplus IMD is returned in the same transaction.
/// @notice What a doer may attach to his proof link, both optional, both shown to the swarm and to NFT voters as his
///         argument (the proof link itself decides). `screenshot` is the sha2-256 digest of the IPFS block of a picture,
///         0 = none: CIDv1 `ipfs://b…` with codec raw (`screenshotRaw`, a file of one 256 KiB chunk) or dag-pb (the
///         UnixFS root of a chunked file), byte for byte what `ipfs add --cid-version=1` gives.
///         A digest instead of a 66-byte link: one storage slot instead of four, and it can only name an IPFS file.
///         `note`: 0..MAX_NOTE_BYTES bytes, the condition's text rule.
struct Evidence {
    bytes32 screenshot;
    bool screenshotRaw;
    string note;
}

struct ImdPay {
    address tokenIn;
    uint256 amountIn;
    uint256 minImdOut;
    uint64 deadline;
    bytes route;
}

struct Task {
    address author;
    uint64 deadline; // 0 = no deadline
    uint32 paramsVersion;
    TaskStatus status;
    address currency; // ETH, USDC, IMD or $YOLO
    uint64 busyEpoch; // +1 each time a busy period ends without acceptance (pending top-ups join the pot)
    uint8 category; // see CATEGORY_COUNT; packed into the slot written at creation anyway (no extra SSTORE)
    uint8 proofType; // see PROOF_TYPE_COUNT; same slot
    uint64 activeSub;
    uint64 queueHead;
    uint64 queueTail;
    uint32 rejectedCount;
    uint256 pot; // reward in play = sum of active shares; constant while any submission is active
    uint256 pending; // top-ups made while a submission was active
    string condition; // what to do and how to prove it: stored, sent to the swarm as TASK
}

struct Contribution {
    uint128 active;
    uint128 pending;
    uint64 pendingEpoch; // busyEpoch at the time of the pending top-up
    bool ever; // ever contributed to this task: as a winner he gets only his own bond back
}

struct Submission {
    uint64 taskId;
    address doer;
    Phase phase;
    Outcome outcome;
    CheckState check;
    Verdict nftDecision;
    bool large;
    bool doerIsContributor;
    bool screenshotRaw; // packed into a slot written at submission anyway
    uint32 asks; // swarm questions asked for this submission (question nonce)
    uint64 activatedAt;
    uint64 windowEnd; // end of the dispute window (0 while a mandatory check is pending)
    uint64 voteEnd;
    uint64 replyEnd;
    uint64 decidedAt; // time of the NFT decision
    uint64 callFrom; // start of the current window to call the swarm (NoDecision / Decided)
    uint256 reward; // R, fixed at submission
    uint256 rewardImd; // R in IMD at submission (bond base; IMD tasks: = R)
    uint256 imdPerEth; // IMD per 1e18 wei at submission (relayer shortfall conversion)
    uint256 bond; // doer bond, IMD, all of it penalty
    uint256 checkFunds; // prepaid mandatory-check fee not spent yet (back to the doer if never spent)
    bytes32 request; // current swarm request (Intake id)
    string proofUri;
    string doerReply;
    bytes32 screenshot; // Evidence.screenshot, 0 = none
    string doerNote; // Evidence.note, empty = none
}

struct Dispute {
    uint256 bondTotal;
    uint256 contributorBondTotal; // bonds of disputers who contributed to the task
    uint256 feeTotal; // ETH gas fees paid by disputers
    uint256 ethPot; // ETH left in the dispute pot (fees minus relayer reimbursements)
    uint256 shortfallTotal; // IMD owed to relayers from the loser penalty
    uint32 votesAccept;
    uint32 votesReject;
    uint32 walletsAccept;
    uint32 walletsReject;
    address[] disputers;
}

struct DisputerInfo {
    uint256 bond;
    uint256 fee;
    bool contributor;
    bool claimed;
    string reason;
}

/// @notice The current swarm caller of a submission: an appellant against the NFT decision, or whoever called the
///         swarm when the NFT did not decide (he picks a side). He pays the swarm fee and a dispute bond. At most one
///         at a time; cleared when the swarm stays silent (his bond is credited back, his fee is lost).
struct Appeal {
    address appellant;
    bool sidesDoer; // true: stands for acceptance (appeals a "reject" decision)
    bool contributor;
    bool replied;
    uint64 replyEnd; // 0 for a NoDecision call (asked at once)
    uint256 bond;
    uint256 funds; // prepaid swarm fee not spent yet
    uint256 spent; // paid to the Intake for his question (reimbursed from the loser if he wins)
    string reason;
    string reply;
}

/// @notice Buckets of a final submission paid out by lazy per-claimant claims. Every bucket is split
///         remaining/remaining, so the last claimant takes the exact rest and no dust is left.
struct Settlement {
    bool neutral; // emergency exit: every bond back, no penalty, no voter reward, relayer shortfall unpaid
    bool disputersWon; // the disputers are on the winning side (Rejected)
    uint256 disputerReward; // IMD for winning non-contributor disputers, pro rata to bonds
    uint256 disputerRewardBonds; // their bonds not yet claimed
    uint256 ethLeft; // dispute pot leftover for disputers, pro rata to fees
    uint256 ethFeesLeft;
    uint256 voterImd; // IMD (loser bond share) for NFT votes on the final side, when the NFT decided right
    uint256 voterFee; // reward currency (fee share) for the same votes
    uint256 voterVotesLeft; // correct votes not yet claimed
    uint256 shortfallPay; // IMD for relayers
    uint256 shortfallLeft;
}

struct SwarmRequest {
    uint64 subId;
    uint64 askedAt;
    uint64 answerTime; // signed issuedAt clamped to [askedAt, recordedAt]: decides "in time"
    uint64 recordedAt; // when the answer reached the vault: windows that follow an answer start here
    uint8 kind; // SwarmQuestion.KIND_*
    bool answered;
    bool answer;
    bytes32 questionHash; // keccak256(question) - assumed formula; informational (SwarmAsked), checks nothing
}

// ====================================================================== events

/// @dev `title` and `cover` (empty = category cover) live only in this event: nothing on chain reads them, and a log
///      costs ~8 gas per byte instead of ~22k per 32-byte storage slot. Nothing here can change after creation.
event TaskCreated(
    uint256 indexed taskId,
    address indexed author,
    address currency,
    uint256 amount,
    uint64 deadline,
    string title,
    string condition,
    uint8 category,
    uint8 proofType,
    string cover
);
event ToppedUp(uint256 indexed taskId, address indexed contributor, uint256 amount, bool pending);
event ContributionWithdrawn(uint256 indexed taskId, address indexed contributor, uint256 amount);
/// @dev `contributor` may take his active share `amount` of an open task from `leavingAt` (TaskVault.announceWithdraw).
event WithdrawAnnounced(uint256 indexed taskId, address indexed contributor, uint256 amount, uint64 leavingAt);
event TaskStatusChanged(uint256 indexed taskId, TaskStatus status);
event Submitted(
    uint256 indexed subId, uint256 indexed taskId, address indexed doer, uint256 reward, uint256 bond, bool queued
);
/// @dev Emitted right after `Submitted` when the doer attached a screenshot or a note (Evidence).
event EvidenceAttached(uint256 indexed subId, bytes32 screenshot, bool screenshotRaw, string note);
event Activated(uint256 indexed subId, uint64 windowEnd, bool checkRequired);
event CheckPassed(uint256 indexed subId, uint64 windowEnd); // also after a silent check (window from silence)
event Disputed(uint256 indexed subId, address indexed disputer, uint256 bond, uint256 fee, string reason);
event DoerReplied(uint256 indexed subId, string reply);
event VotesSubmitted(uint256 indexed subId, address indexed relayer, uint256 accept, uint256 reject, uint256 paidWei);
event NftDecided(uint256 indexed subId, Verdict decision, bool instant);
event NoNftDecision(uint256 indexed subId);
event Appealed(uint256 indexed subId, address indexed appellant, uint256 bond, uint256 prepaid, string reason);
event AppealReplied(uint256 indexed subId, address indexed by, string reply);
event SwarmAsked(uint256 indexed subId, bytes32 indexed requestId, uint8 kind, uint256 paid, bytes32 questionHash);
event SwarmCalled(uint256 indexed subId, address indexed caller, bool sidesDoer, uint256 bond, uint256 fee);
event SwarmSilent(uint256 indexed subId, bytes32 indexed requestId, uint64 windowFrom);
event AppealVoided(uint256 indexed subId, uint256 price);
event SwarmAnswered(bytes32 indexed requestId, uint256 indexed subId, bool answer, uint64 answerTime, bool viaCallback);
event AttestationIgnored(bytes32 indexed requestId, uint8 reason);
event SubmissionFinal(uint256 indexed subId, uint256 indexed taskId, Outcome outcome);
event DisputerClaimed(uint256 indexed subId, address indexed disputer, uint256 imd, uint256 eth);
event VoterRewardClaimed(uint256 indexed subId, address indexed payTo, uint256 votes, uint256 imd, uint256 fee);
event RelayerShortfallClaimed(uint256 indexed subId, address indexed relayer, uint256 imd);
event VoidSubmissionClaimed(uint256 indexed subId, address indexed doer, uint256 imd);
event Credited(address indexed token, address indexed account, uint256 amount);
event Paid(address indexed token, address indexed account, uint256 amount);
event TreasurySwept(address indexed token, address indexed treasury, uint256 amount);
event SubmissionSettled(
    uint256 indexed subId, bool nftRight, uint256 penalty, uint256 toWinners, uint256 toVoters, uint256 toTreasury
);
event ParamsCached(uint32 indexed version);

// ====================================================================== errors

error Paused();
error BadCurrency();
error BadAmount();
error BadDeadline();
error BadText();
error BadTitle();
error BadCategory();
error BadProofType();
error BadCover();
/// @dev proofUri does not have the form its task's proof type requires (TextLib.checkProof).
error BadProof(uint8 proofType);
/// @dev Evidence: a note breaking the text rule or longer than MAX_NOTE_BYTES, or a codec flag without a screenshot.
error BadEvidence();
error RewardTooSmall();
error FeeTooLow();
error FeeOutOfRange();
error NotEnoughEth();
error TaskNotOpen();
error DeadlinePassed();
error WrongPhase();
error WindowClosed();
error AlreadyDisputed();
/// @dev The doer of a submission cannot dispute it (audit C-01).
error DoerCannotDispute();
error RewardChanged();
error CostAboveMax();
error ImdShort();
error NotDoer();
error NotOpponent();
error AlreadyReplied();
error SwarmUnavailable();
error ActionNotSold();
error UnknownRequest();
error NothingToClaim();
error NotFinal();
error NotStuck();
error NoNotice();
error NoticeNotDue(uint64 leavingAt);
/// @notice `announceWithdraw` while a submission is active: wait for it to clear (audit round 2, finding 16).
error SubmissionActive();
/// @notice `announceWithdraw` while a notice already given is still live: wait for it to lapse, or withdraw once it
///         is due, instead of renewing it (audit round 2, finding 16).
error NoticeLive(uint64 validUntil);
error InsufficientGas();
error SwapDisabled();
error SwapExpired();
error SwapShort();
error OnlySelf();
error TransferFailed();
/// @dev A desk function called by someone other than the vault or the desk it serves.
error NotAuthorized();
/// @dev The vault has no route for this selector.
error UnknownFunction();
/// @dev A desk can be wired only once, by the vault, in the transaction that deployed it.
error WiringClosed();
error WrongWiring();
