// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Shared types, events and errors of TaskVault and its desks (src/desks). TaskVault is the one public address:
///      it holds the money, the tasks and the swarm requests and forwards the other calls to the desk that owns the
///      state (CaseDesk: submissions, DisputeDesk: disputes, appeals, votes and settlements).

address constant ETH = address(0);
uint256 constant BPS = 10_000;
// kind 1 is reserved
uint8 constant SWARM_KIND_ESCALATION = 2; // NFT vote without decision, somebody paid to call the swarm
uint8 constant SWARM_KIND_APPEAL = 3; // appeal of an NFT decision
/// @dev Task categories: 0 trash, 1 crazy, 2 action, 3 sport, 4 food, 5 prank, 6 shill, 7 onchain, 8 other (the site's
///      labels and fallback covers). Set once at creation.
uint8 constant CATEGORY_COUNT = 9;
/// @dev Longest cover link: `ipfs://<CIDv1>` is 66 bytes, the rest is room for a path or an https fallback.
uint256 constant MAX_COVER_BYTES = 160;
/// @dev Task title: shown on the site, never sent to the swarm (the rules say what to do and how to prove it).
///      Same limit as DareTrophy.MAX_TITLE_BYTES (the doer resupplies the title at mint): a task created past 64
///      bytes could never mint a trophy (contract = 64, as on the site).
uint256 constant MAX_TITLE_BYTES = 64;
/// @dev Proof types: what a submission's proofUri must be (TextLib.checkProof). Set once at creation.
uint8 constant PROOF_X_POST = 0; // https://x.com/<user>/status/<id> (or twitter.com)
uint8 constant PROOF_VIDEO = 1; // https link on youtube.com or youtu.be, or an X post
uint8 constant PROOF_ONCHAIN_TX = 2; // 0x + 64 hex: an Ethereum mainnet transaction hash
uint8 constant PROOF_LINK = 3; // https link on a host of the allowlist (TextLib.checkHost)
uint8 constant PROOF_TYPE_COUNT = 4;
/// @dev Doer's note on a submission: optional, same text rule as the task rules (TextLib.validText: printable
///      ASCII only), same ceiling as maxTextBytes (ParamsBounds.validate, 32..512).
uint256 constant MAX_NOTE_BYTES = 512;
/// @dev Evidence.screenshotUrl: `https://` link on a host of the allowlist (TextLib.checkHost),
///      bounded so one screenshot link cannot blow up the swarm question (TextLib.checkScreenshotUrl).
uint256 constant MAX_SCREENSHOT_URL_BYTES = 300;
/// @dev Longest proof or screenshot link the host allowlist accepts (TextLib.checkHost).
uint256 constant MAX_LINK_BYTES = 512;
/// @dev onOracleResult(bytes32,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,
///      uint16,uint16,uint16,uint64,uint64),bytes) - matches the IMD docs and a delivered mainnet callback.
bytes4 constant CALLBACK_SELECTOR = 0x510379c7;
/// @dev A swarm answer signed within the swarm timeout counts if it reaches the vault at most this long after the
///      timeout; silence is declared only after it, so the outcome never depends on who pokes when.
uint256 constant SWARM_DELIVERY_GRACE = 1 hours;
/// @dev At most this many swarm questions per submission (appeals and calls after silence together, and appeals void
///      because the Intake failed or its price rose). After the last one stays silent or is void the
///      submission ends as if nobody had called the swarm.
uint256 constant MAX_SWARM_CALLS = 3;
/// @dev The doer stake bonus: 4% of the reward x min(1, lock power / reward in
///      $YOLO), from any power, no threshold.
uint256 constant MAX_STAKE_BONUS_BPS = 400;

// ====================================================================== enums

enum TaskStatus {
    None,
    Open,
    Completed, // a submission was accepted (Task.activeSub keeps its id)
    Expired, // deadline passed with no submission in flight: everyone takes back their share
    Unwound // cancelled by the dev wallet (TaskVault.cancelTask): everyone takes back what they put in
}

enum Phase {
    None,
    Queued, // waiting behind the active submission
    Review, // active; dispute window
    Voting, // at least one dispute: NFT vote running
    NoDecision, // NFT did not decide: optimistic window, anyone may call the swarm paying fee + bond
    Decided, // NFT decision stands: appeal window, anyone may appeal paying fee + bond
    Appealed, // appeal filed (fee prepaid): the question is due at once, asked lazily (askAppealSwarm)
    Asked, // the swarm was asked for a caller (appellant or NoDecision caller); answer or silence pending
    Final, // settled, see Outcome
    Void // queued submission of a task that was completed / unwound: bond refunded
}

enum Outcome {
    None,
    Accepted,
    Rejected,
    Unwound // cancelled by the dev wallet (TaskVault.cancelTask): everyone takes back what they put in
}

enum Verdict {
    None,
    Accept,
    Reject
}

enum SwarmStatus {
    Pending,
    Answered,
    Silent
}

// ====================================================================== structs

/// @notice A bond or penalty split by currency: `imd` is the fixed IMD part
///         (a `ParamsCore.bondFixedImd` parameter, never doubled; a side's own swarm call draws only from it, so it
///         is kept at least one swarm fee), `rew` is doerBondBps/disputeBondBps percent of the author's own reward
///         in the task's currency. Top-ups of other contributors and the $YOLO add-on are not part of any bond.
///         No oracle, no USD
///         conversion: every part is paid and penalized in its own currency.
struct Bond {
    uint256 imd;
    uint256 rew;
}

/// @notice How the payer provides IMD. `amountIn == 0`: mode B, IMD is pulled with transferFrom.
///         Otherwise mode A: `amountIn` of `tokenIn` (ETH or USDC) is swapped through the swap adapter with the
///         user's `minImdOut` and `deadline`; surplus IMD is returned in the same transaction.
/// @notice What a doer may attach to their proof link, both shown to the swarm and to NFT voters as their
///         argument (the proof link itself decides). `screenshotUrl`: an `https://` link to the picture or clip on
///         a host of the allowlist (TextLib.checkHost: x.com, twitter.com, pbs.twimg.com, youtube.com, youtu.be,
///         tiktok.com, instagram.com, drive.google.com, lh3.googleusercontent.com, photos.google.com, imgur.com,
///         i.imgur.com, t.me, ibb.co, i.ibb.co, reddit.com, i.redd.it, dropbox.com, arweave.net, etherscan.io,
///         sepolia.etherscan.io, github.com, kick.com, twitch.tv, clips.twitch.tv); required for x_post and video
///         (EvidenceRequired), optional otherwise. Empty = none;
///         otherwise no spaces, at most MAX_SCREENSHOT_URL_BYTES (TextLib.checkScreenshotUrl).
///         `note`: 0..MAX_NOTE_BYTES bytes, the text rule of the task rules.
struct Evidence {
    string screenshotUrl;
    string note;
}

struct ImdPay {
    address tokenIn;
    uint256 amountIn;
    uint256 minImdOut;
    uint64 deadline;
    bytes route;
}

/// @notice The rules of a task: three texts, each 1..maxTextBytes bytes (TextLib.validText), each sent to the swarm as
///         its own definition (Intake: definition values <= 512), so a task may carry up to 3 x maxTextBytes of rules.
///         `task` (definition "task"): TASK, what to do, every step and every text needed (SPEECH and the like).
///         `proof` (definition "task_proof"): WINDOW, WHO, PROOF, SOURCE: when, who hands in, what the proof shows,
///         where it lives, where the DOER CODE is. `noIf` (definition "task_no"): "NO if: ...", when the answer is no.
///         Stored at creation, never change.
struct TaskRules {
    string task;
    string proof;
    string noIf;
}

/// @dev Whoever asks the swarm (DisputeDesk.callSwarm, CaseDesk.askAppealSwarm)
///      resupplies in calldata everything the question needs that storage holds only as a hash - the task's
///      three rule texts (Task.rulesHash) and the filed disputer's reason + proof link (DisputerInfo.reasonHash).
///      Checked against both hashes, then handed to SwarmQuestion.build(); never written to storage.
struct RuleTexts {
    string task;
    string taskProof;
    string taskNo;
    string disputeReason;
    string disputerProofUri;
}

struct Task {
    address author;
    uint64 deadline; // always set, never changes (no task without a deadline)
    uint32 paramsVersion;
    TaskStatus status;
    address currency; // ETH, USDC, IMD or $YOLO
    uint64 busyEpoch; // reserved, always 0
    uint8 category; // see CATEGORY_COUNT; packed into the slot written at creation anyway (no extra SSTORE)
    uint8 proofType; // see PROOF_TYPE_COUNT; same slot
    uint64 activeSub; // the submission under judging; on a Completed task: the accepted one
    uint32 queueHead;
    uint32 queueTail;
    uint32 rejectedCount;
    uint64 createdAt; // YOLO Predict weighs positions over [createdAt, deadline]
    uint256 pot; // reward in play = sum of active shares; a top-up joins it at once, also during a check
    uint256 pending; // reserved, always 0
    // keccak256(abi.encode(task, proof, noIf)) instead of the 3 strings (up to 1 536 B
    // = ~48 slots) - the texts live only in createTask's calldata and the TaskCreated event; whoever later needs
    // them to build the swarm question (DisputeDesk.callSwarm, CaseDesk.askAppealSwarm) resupplies them in that
    // same call and the hash is checked against this, else RulesMismatch.
    bytes32 rulesHash;
}

struct Contribution {
    uint128 active;
    uint128 pending; // reserved, always 0
    uint64 pendingEpoch; // reserved, always 0
    bool ever; // ever contributed to this task: as a winner they get only their own bond back
}

struct Submission {
    uint64 taskId;
    address doer;
    Phase phase;
    Outcome outcome;
    Verdict nftDecision;
    uint32 asks; // swarm questions asked or void for this submission (question nonce; at most MAX_SWARM_CALLS)
    uint16 stakeBps; // the doer stake bonus fixed at submission, 0..400 bps of R
    uint64 submittedAt; // the lock behind stakeBps must still run at the payout (YoloLockHub.stakePower)
    uint64 activatedAt;
    uint64 windowEnd; // end of the dispute window
    uint64 voteEnd;
    uint64 decidedAt; // time of the NFT decision
    uint64 callFrom; // start of the current window to call the swarm (NoDecision / Decided)
    uint64 appealedAt; // when markAppealed ran; stepDeadline of Phase.Appealed
        // (the question is due at once)
    // R and the author's part of it share one slot (both < 2^128: every share of a pot is a uint128)
    uint128 reward; // R, fixed at submission (task currency): what the doer is paid
    uint128 base; // the author's own share of R at submission: the base of every bond's "rew" part
    uint256 addon; // $YOLO add-on, fixed at submission (its voter pool on acceptance; not part of any bond)
    Bond bond; // doer bond: imd fixed + rew% of the author's base (reward currency), never doubled
    bytes32 request; // current swarm request (Intake id)
    string proofUri;
    string screenshotUrl; // Evidence.screenshotUrl, empty = none
    string doerNote; // Evidence.note, empty = none: their "why honest" text, written at submission
        // (no separate "doer answers the dispute" step)
}

struct Dispute {
    Bond bondTotal;
    // uint32: votes are bounded today by the IMD identity NFT's MAX_SUPPLY (2,000 NFTs, 1 NFT = 1 vote, each id once
    // per dispute), far under uint16's 65,535 — but that bound lives in the NFT contract, not here, and SafeCast reverts
    // rather than wraps, so an NFT collection or delegation scheme that crosses 65,535 would permanently
    // stick every vote on a dispute with uint16; uint32 costs one storage slot and leaves headroom many orders
    // above the NFT supply.
    uint32 votesAccept;
    uint32 votesReject;
    uint32 walletsAccept;
    uint32 walletsReject;
    address disputer; // one dispute, one disputer: address(0) = nobody yet
    uint32 openBlock; // the block of the dispute (no snapshot: an NFT votes with its holder at the vote)
}

struct DisputerInfo {
    Bond bond;
    bool claimed;
    // keccak256(abi.encode(reason, proofUri)) instead of the raw reason string;
    // proofUri is the link to the disputer's own proof that the submission fails the rule, same text
    // rule and byte cap as reason. Both texts live in dispute()'s calldata and the Disputed event; whoever later
    // calls the swarm (DisputeDesk.callSwarm, CaseDesk.askAppealSwarm) resupplies them, checked against this hash.
    bytes32 reasonHash;
}

/// @notice The current swarm caller of a submission: an appellant against the NFT decision, or whoever called the
///         swarm when the NFT did not decide (they pick a side). They pay the swarm fee and a dispute bond. At most one
///         at a time; cleared when the swarm stays silent (their bond is credited back, their fee is lost).
struct Appeal {
    address appellant;
    bool sidesDoer; // true: stands for acceptance (appeals a "reject" decision)
    Bond bond;
    uint256 funds; // prepaid swarm fee not spent yet
    uint256 spent; // paid to the Intake for his question (reimbursed from the loser if he wins)
    // no reason text: an appeal/call of the swarm is a button,
    // not a text field. The panel still sees the original dispute reason (DisputerInfo), not a second one.
    // a side of the dispute (the doer, or the disputer against the doer) calling the swarm for itself: no second
    // bond (`bond` stays 0), the fee comes out of its dispute bond first;
    // the part of the prepaid fee its bond covers, `funds` is what it paid on top
    uint256 fromBond;
}

/// @notice IMD the sides' own dispute bonds paid to the swarm for their calls: taken off what
///         the side gets back or loses at settlement.
struct SideSpent {
    uint128 doer;
    uint128 disputer;
}

/// @notice Buckets of a final submission paid out by lazy per-claimant claims. Every bucket is split
///         remaining/remaining, so the last claimant takes the exact rest and no dust is left.
struct Settlement {
    bool neutral; // cancelled by the dev wallet: every bond back, no penalty, no voter reward
    bool disputersWon; // the disputers are on the winning side (Rejected)
    uint256 stakeBps; // accepted with the doer stake bonus: its share of R in bps (0..400), YoloSweetener pays the same share
    Bond disputerReward; // for winning disputers (any of them: author/contributor included),
    // pro rata to bonds, per currency
    Bond disputerRewardBonds; // their bonds not yet claimed, per currency
    Bond voterBond; // loser bond share for NFT votes on the final side, when the NFT decided right
    uint256 voterFee; // reward currency (10% reward fee share) for the same votes
    uint256 voterVotesLeft; // correct votes not yet claimed
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
    TaskRules rules,
    uint8 category,
    uint8 proofType,
    string cover
);
/// @dev `duringCheck`: made while a submission was being checked; it joined the reward in play all the same.
event ToppedUp(uint256 indexed taskId, address indexed contributor, uint256 amount, bool duringCheck);
event ContributionWithdrawn(uint256 indexed taskId, address indexed contributor, uint256 amount);
event TaskStatusChanged(uint256 indexed taskId, TaskStatus status);
/// @notice The dev wallet cancelled an open task: status Unwound, everyone takes back their own.
event TaskCancelled(uint256 indexed taskId, address indexed by);
event SweetenerBound(address indexed sweetener);
/// @dev `proofUri`: always set, not indexed so Etherscan decodes it from this log —
///      the one event every submission emits, so this is where the site/a reader finds the proof link without
///      depending on the optional `EvidenceAttached`.
event Submitted(
    uint256 indexed subId,
    uint256 indexed taskId,
    address indexed doer,
    uint256 reward,
    uint256 bondImd,
    uint256 bondRew,
    bool queued,
    string proofUri
);
/// @dev Emitted right after `Submitted` when the doer attached a screenshot link or a note (Evidence).
event EvidenceAttached(uint256 indexed subId, string screenshotUrl, string note);
event Activated(uint256 indexed subId, uint64 windowEnd);
/// @dev `disputerProofUri`: the disputer's own proof that the submission
///      fails the rule; empty when the disputer gave no link (optional). Both strings are not indexed so Etherscan decodes them on a verified contract, straight
///      from this log, with no site and no indexer.
event Disputed(
    uint256 indexed subId,
    address indexed disputer,
    uint256 bondImd,
    uint256 bondRew,
    string reason,
    string disputerProofUri
);
event DoerReplied(uint256 indexed subId, string reply);
event NftDecided(uint256 indexed subId, Verdict decision, bool instant);
event NoNftDecision(uint256 indexed subId);
/// @dev No `reason`: appeal is a button.
event Appealed(
    uint256 indexed subId, address indexed appellant, uint256 bondImd, uint256 bondRew, uint256 prepaid
);
event AppealReplied(uint256 indexed subId, address indexed by, string reply);
event SwarmAsked(uint256 indexed subId, bytes32 indexed requestId, uint8 kind, uint256 paid, bytes32 questionHash);
event SwarmCalled(
    uint256 indexed subId,
    address indexed caller,
    bool sidesDoer,
    uint256 bondImd,
    uint256 bondRew,
    uint256 fee
);
event SwarmSilent(uint256 indexed subId, bytes32 indexed requestId, uint64 windowFrom);
event AppealVoided(uint256 indexed subId, uint256 price);
event SwarmAnswered(bytes32 indexed requestId, uint256 indexed subId, bool answer, uint64 answerTime, bool viaCallback);
event AttestationIgnored(bytes32 indexed requestId, uint8 reason);
event SubmissionFinal(uint256 indexed subId, uint256 indexed taskId, Outcome outcome);
event DisputerClaimed(uint256 indexed subId, address indexed disputer, uint256 imd, uint256 rew);
event VoterRewardClaimed(uint256 indexed subId, address indexed payTo, uint256 votes, uint256 imd, uint256 rew, uint256 fee);
event VoidSubmissionClaimed(uint256 indexed subId, address indexed doer, uint256 imd, uint256 rew);
event Credited(address indexed token, address indexed account, uint256 amount);
event Paid(address indexed token, address indexed account, uint256 amount);
event TreasurySwept(address indexed token, address indexed treasury, uint256 amount);
/// @dev `amount` of `token` left for burning: $YOLO straight to 0x…dEaD, any other token to the BuybackBurner.
event Burned(address indexed token, uint256 amount);

event SubmissionSettled(
    uint256 indexed subId,
    bool nftRight,
    uint256 penaltyImd,
    uint256 toVotersImd,
    uint256 toTreasuryImd,
    uint256 penaltyRew,
    uint256 toVotersRew,
    uint256 toTreasuryRew
);
event ParamsCached(uint32 indexed version);

// ====================================================================== errors

error Paused();
error BadCurrency();
error BadAmount();
error BadDeadline();
error BadText();
/// @dev A text resupplied to build the swarm question does not hash to what was stored at creation/dispute:
///      wrong text, wrong order, or tampered calldata.
error RulesMismatch();
error BadTitle();
error BadCategory();
error BadProofType();
error BadCover();
/// @dev proofUri does not have the form its task's proof type requires (TextLib.checkProof).
error BadProof(uint8 proofType);
/// @dev Evidence: a note breaking the text rule or longer than MAX_NOTE_BYTES, or a screenshotUrl that is not a
///      bare `https://` link within MAX_SCREENSHOT_URL_BYTES (TextLib.checkScreenshotUrl).
error BadEvidence();
/// @dev A screenshot link (or video link, same Evidence.screenshotUrl) is mandatory for the
///      proof types the swarm cannot open itself (x_post, x_reply — both PROOF_X_POST — and video).
error EvidenceRequired();
/// @dev A proof link or screenshot link that is not `https://` on a host of the allowlist, or longer than
///      MAX_LINK_BYTES (TextLib.checkHost).
error HostNotAllowed();
error RewardTooSmall();
error NotEnoughEth();
error TaskNotOpen();
error DeadlinePassed();
error WrongPhase();
error WindowClosed();
error AlreadyDisputed();
/// @dev The doer of a submission cannot dispute it.
error DoerCannotDispute();
/// @dev The sender neither owns `tokenId` nor is a delegate.xyz delegate of its owner.
error NotTokenHolder(uint256 tokenId);
/// @dev `tokenId` already voted in this dispute, or appears twice in the list.
error TokenVoted(uint256 tokenId);
/// @dev A vote with no NFT ids.
error NoTokens();
/// @dev A vote with a side other than 1/2 or no payTo.
error BadVote();
/// @dev The wallet already voted the other side on this submission: the side cannot change.
error AlreadyVoted();
error RewardChanged();
error CostAboveMax();
error ImdShort();
error NotOpponent();
error AlreadyReplied();
error SwarmUnavailable();
error ActionNotSold();
error UnknownRequest();
error NothingToClaim();
error NotFinal();
error InsufficientGas();
error SwapDisabled();
error SwapExpired();
error SwapShort();
error TransferFailed();
/// @dev withdraw/withdrawTo to the zero address: a plain ETH `call` to address(0) would otherwise
///      succeed and burn the money with no way back.
error WithdrawToZero();
/// @dev A desk function called by someone other than the vault or the desk it serves.
error NotAuthorized();
/// @dev The vault has no route for this selector.
error UnknownFunction();
/// @dev A desk can be wired only once, by the vault, in the transaction that deployed it.
error WiringClosed();
error WrongWiring();
