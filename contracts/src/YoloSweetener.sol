// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ParamsRegistry} from "./ParamsRegistry.sol";
import {ParamsCore} from "./VaultParams.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {SubmitTerms, SubCore, ICaseDesk} from "./desks/DeskApi.sol";
import {TaskStatus, Outcome, Submission, SwarmRequest, SWARM_DELIVERY_GRACE} from "./VaultTypes.sol";

/// @dev The vault views the sweetener reads.
interface ISweetenedVault {
    function submitTerms(uint256 taskId, address doer) external view returns (SubmitTerms memory);
    function caseDesk() external view returns (address);
    function registry() external view returns (address);
    function yolo() external view returns (IERC20);
    function requests(bytes32 requestId) external view returns (SwarmRequest memory);
}

/// @dev The CaseDesk view the sweetener reads for the swarm request of a submission.
interface ISweetenedCaseDesk {
    function getSubmission(uint256 subId) external view returns (Submission memory);
}

/// @title YoloSweetener: a $YOLO bonus on top of any task, whatever the currency of its reward
/// @notice Anyone may add YOLO to an open task. The bonus sits here, apart from the vault's pots, and follows the task:
///         - a submission is accepted (task `Completed`): anyone calls `payout`. A bonus worth more than the large
///           threshold of the task's parameters (`largeRewardUsd`, by that version's oracle) is paid in
///           full only to a submission the swarm confirmed (its latest swarm request answered "yes"); otherwise the
///           doer gets the bonus up to that threshold and the rest goes back to the sweeteners pro rata to what each
///           put in (`withdraw`). Without a YOLO price the payout waits (`PayoutDeferred`, nothing moves) and pays
///           in full once `NO_PRICE_WAIT` (7 days) has passed since the first such call with still no price. The doer pays the protocol fee of the task's parameters (`feeBps`, 10%) on what he
///           gets, the fee goes to the treasury, both in YOLO;
///         - the task expires or is unwound: each sweetener takes back his own (`withdraw`);
///         - while the task is open and no submission is active, a sweetener may also take his back after one hour of
///           public notice (`announceWithdraw`; the notice then holds for a day), so a
///           doer sees the bonus leaving before he submits; while one is active (under review, disputed, asked)
///           nothing leaves, like a contributor's active share in the vault. A live notice cannot be renewed and
///           `announceWithdraw` reverts while a submission is active, so a doer always sees a real gap before a
///           fresh notice starts (audit round 2, finding 16).
///         Reads the vault's task status, its busy flag, the accepted submission and its swarm answer; changes nothing
///         in the vault. No owner, no admin. The fee goes to the treasury of the current parameters, as
///         `TaskVault.sweepTreasury`. The whole fee goes to the treasury; the NFT
///         voters' share applies to the reward only.
contract YoloSweetener {
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;
    /// @notice A withdrawal from an open task waits this long after `announceWithdraw` ...
    uint256 public constant NOTICE = 1 hours;
    /// @notice ... and the notice holds this long after that; past that, or once used, `announceWithdraw` must be
    ///         called again (it reverts while the earlier notice is still live, audit round 2, finding 16).
    uint256 public constant NOTICE_VALID = 1 days;
    /// @notice A payout that needs a YOLO price waits while there is none; after this long from the first such
    ///         call, still without a price, it pays the doer in full (swarm audit #6).
    uint256 public constant NO_PRICE_WAIT = 7 days;

    ISweetenedVault public immutable vault;
    ICaseDesk public immutable caseDesk; // the vault's, read at deployment like the registry and $YOLO
    ParamsRegistry public immutable registry;
    IERC20 public immutable yolo;

    /// @notice YOLO held for a task: the bonus until it is paid out, then what goes back to the sweeteners (0 if all
    ///         of it went to the doer).
    mapping(uint256 => uint256) public bonusOf;
    /// @notice What `who` put on a task and has not taken back.
    mapping(uint256 => mapping(address => uint256)) public givenBy;
    /// @notice After a capped payout: the sum of `givenBy` still to share the returned rest (0 = nothing returns).
    mapping(uint256 => uint256) public returnBase;
    /// @notice When the withdrawal `who` announced on an open task may happen (0 = no notice).
    mapping(uint256 => mapping(address => uint64)) public leavingAt;
    /// @notice When `payout` of a task first found no YOLO price while it needed one (0 = never).
    mapping(uint256 => uint64) public noPriceSince;

    event Sweetened(uint256 indexed taskId, address indexed from, uint256 amount, uint256 bonus);
    event BonusWithdrawn(uint256 indexed taskId, address indexed to, uint256 amount, uint256 bonus);
    event BonusPaid(uint256 indexed taskId, uint256 indexed subId, address indexed doer, uint256 toDoer, uint256 fee);
    /// @notice The swarm did not confirm the accepted submission: `returned` of the bonus (above `cap`) goes back.
    event BonusCapped(uint256 indexed taskId, uint256 cap, uint256 returned);
    event WithdrawAnnounced(uint256 indexed taskId, address indexed from, uint256 amount, uint64 leavingAt);
    /// @notice `payout` needed a YOLO price and there was none: nothing moved. From `fullFrom` a payout still without
    ///         a price pays the doer in full.
    event PayoutDeferred(uint256 indexed taskId, uint256 indexed subId, uint64 fullFrom);

    error ZeroAddress();
    error ZeroAmount();
    error TaskNotOpen();
    error BonusLocked();
    error NotAccepted();
    error NothingToPay();
    error NoNotice();
    error NoticeNotDue(uint64 leavingAt);
    /// @notice `announceWithdraw` while a submission is active (audit round 2, finding 16).
    error SubmissionActive();
    /// @notice `announceWithdraw` while a notice already given is still live (audit round 2, finding 16).
    error NoticeLive(uint64 validUntil);

    constructor(address vault_) {
        if (vault_ == address(0)) revert ZeroAddress();
        ISweetenedVault v = ISweetenedVault(vault_);
        vault = v;
        caseDesk = ICaseDesk(v.caseDesk());
        registry = ParamsRegistry(v.registry());
        yolo = v.yolo();
    }

    /// @notice Add `amount` YOLO (pulled with transferFrom) to the bonus of an open task.
    function sweeten(uint256 taskId, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (vault.submitTerms(taskId, address(0)).status != TaskStatus.Open) revert TaskNotOpen();
        uint256 bonus = bonusOf[taskId] + amount;
        bonusOf[taskId] = bonus;
        givenBy[taskId][msg.sender] += amount;
        yolo.safeTransferFrom(msg.sender, address(this), amount);
        emit Sweetened(taskId, msg.sender, amount, bonus);
    }

    /// @notice Announce taking back all you put on an open task: `withdraw` works from `NOTICE` after this call for
    ///         `NOTICE_VALID`. Reverts while a submission is active, or while an earlier notice is still live: a
    ///         standing notice cannot be renewed into an always-due one (audit round 2, finding 16).
    function announceWithdraw(uint256 taskId) external {
        uint256 given = givenBy[taskId][msg.sender];
        if (given == 0) revert ZeroAmount();
        if (vault.submitTerms(taskId, address(0)).busy) revert SubmissionActive();
        uint64 existing = leavingAt[taskId][msg.sender];
        if (existing != 0 && block.timestamp <= existing + NOTICE_VALID) revert NoticeLive(existing);
        uint64 at = uint64(block.timestamp + NOTICE);
        leavingAt[taskId][msg.sender] = at;
        emit WithdrawAnnounced(taskId, msg.sender, given, at);
    }

    /// @notice The live notice of `who` on a task (zeros if none or expired): what he has on it, from when he may
    ///         withdraw it and until when the notice holds.
    function pendingWithdraw(uint256 taskId, address who)
        external
        view
        returns (uint256 amount, uint64 from, uint64 until)
    {
        from = leavingAt[taskId][who];
        if (from == 0 || block.timestamp > uint256(from) + NOTICE_VALID) return (0, 0, 0);
        return (givenBy[taskId][who], from, uint64(from + NOTICE_VALID));
    }

    /// @notice Take back all you put on a task: after it expired or was unwound; while it is open with no active
    ///         submission, once your notice is due (none needed past the deadline, when nobody can submit); or your
    ///         share of the rest a capped `payout` returned. Never the part paid to the doer of an accepted submission.
    function withdraw(uint256 taskId) external {
        SubmitTerms memory t = vault.submitTerms(taskId, address(0));
        uint256 given = givenBy[taskId][msg.sender];
        uint256 left = bonusOf[taskId];
        uint256 amount = given;
        if (t.status == TaskStatus.Completed) {
            uint256 base = returnBase[taskId];
            if (base == 0) revert BonusLocked(); // not paid out yet, or all of it was the doer's
            if (given == 0) revert ZeroAmount();
            amount = Math.mulDiv(left, given, base); // the last one (given == base) takes all that is left
            returnBase[taskId] = base - given;
        } else if (t.status == TaskStatus.Open) {
            if (t.busy) revert BonusLocked();
            if (given == 0) revert ZeroAmount();
            if (t.deadline == 0 || block.timestamp < t.deadline) _useNotice(taskId);
        } else if (t.status == TaskStatus.Expired || t.status == TaskStatus.Unwound) {
            if (given == 0) revert ZeroAmount();
        } else {
            revert BonusLocked();
        }
        givenBy[taskId][msg.sender] = 0;
        if (leavingAt[taskId][msg.sender] != 0) delete leavingAt[taskId][msg.sender];
        uint256 bonus = left - amount;
        bonusOf[taskId] = bonus;
        if (amount != 0) yolo.safeTransfer(msg.sender, amount);
        emit BonusWithdrawn(taskId, msg.sender, amount, bonus);
    }

    /// @notice Pay the bonus of a completed task to the doer of its accepted submission `subId` (anyone may call):
    ///         all of it if the swarm confirmed that submission, otherwise up to the large threshold, the rest back to
    ///         the sweeteners. Without a YOLO price (needed only for that cap) nothing moves (`PayoutDeferred`) until
    ///         there is one, or until NO_PRICE_WAIT after the first such call: then all of it.
    function payout(uint256 taskId, uint256 subId) external {
        SubmitTerms memory t = vault.submitTerms(taskId, address(0));
        if (t.status != TaskStatus.Completed) revert NotAccepted();
        SubCore memory s = caseDesk.subCore(subId);
        if (s.taskId != taskId || s.outcome != Outcome.Accepted) revert NotAccepted();
        uint256 bonus = bonusOf[taskId];
        if (bonus == 0 || returnBase[taskId] != 0) revert NothingToPay();
        ParamsCore memory p = registry.core(t.version);
        uint256 pay = bonus;
        if (!_swarmConfirmed(subId, p.swarmTimeout)) {
            (bool priced, uint256 cap) = _cap(p.priceOracle, p.largeRewardUsd);
            if (!priced) {
                // no price, no cap: the bonus waits for one instead of going back (swarm audit #6); anyone can
                // make a price by sampling the pool, so only an outage of a week pays it in full
                uint64 since = noPriceSince[taskId];
                if (since == 0) noPriceSince[taskId] = since = uint64(block.timestamp);
                if (block.timestamp < uint256(since) + NO_PRICE_WAIT) {
                    emit PayoutDeferred(taskId, subId, uint64(since + NO_PRICE_WAIT));
                    return;
                }
            } else if (cap < bonus) {
                pay = cap;
                returnBase[taskId] = bonus; // = the sum of givenBy on the task
                emit BonusCapped(taskId, cap, bonus - cap);
            }
        }
        bonusOf[taskId] = bonus - pay;
        uint256 fee = pay * p.feeBps / BPS;
        address treasury = registry.core(registry.currentVersion()).treasury;
        if (pay != fee) yolo.safeTransfer(s.doer, pay - fee);
        if (fee != 0) yolo.safeTransfer(treasury, fee);
        emit BonusPaid(taskId, subId, s.doer, pay - fee, fee);
    }

    /// @dev The YOLO worth `largeUsd` by `oracle` (18-decimal USD per whole token); `priced` false without a reliable
    ///      price or if any oracle call fails.
    function _cap(address oracle, uint256 largeUsd) private view returns (bool priced, uint256 cap) {
        try IPriceOracle(oracle).hasPrice(address(yolo)) returns (bool ok) {
            if (!ok) return (false, 0);
        } catch {
            return (false, 0);
        }
        try IPriceOracle(oracle).usdValue(address(yolo), 1e18) returns (uint256 usd) {
            if (usd == 0) return (false, 0);
            return (true, Math.mulDiv(largeUsd, 1e18, usd));
        } catch {
            return (false, 0);
        }
    }

    /// @dev The latest swarm request of the submission is answered "yes", by an answer the CaseDesk counts (signed
    ///      within the swarm timeout, delivered within SWARM_DELIVERY_GRACE after it).
    function _swarmConfirmed(uint256 subId, uint256 swarmTimeout) private view returns (bool) {
        bytes32 rid = ISweetenedCaseDesk(address(caseDesk)).getSubmission(subId).request;
        if (rid == bytes32(0)) return false;
        SwarmRequest memory r = vault.requests(rid);
        uint256 deadline = uint256(r.askedAt) + swarmTimeout;
        return r.answered && r.answer && r.subId == subId && r.answerTime <= deadline
            && r.recordedAt <= deadline + SWARM_DELIVERY_GRACE;
    }

    function _useNotice(uint256 taskId) private view {
        uint256 at = leavingAt[taskId][msg.sender];
        if (at == 0 || block.timestamp > at + NOTICE_VALID) revert NoNotice();
        if (block.timestamp < at) revert NoticeNotDue(uint64(at));
    }
}
