// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ParamsCore} from "../VaultParams.sol";
import {IIntake} from "../interfaces/IIntake.sol";
import {SwarmQuestionBuilder} from "../helpers/SwarmQuestion.sol";
import {Desk} from "./Desk.sol";
import {SubmitTerms, SubCore, Facts, Tally, AppealCore, AskTerms, IVault, IDisputeDesk} from "./DeskApi.sol";
import "../VaultTypes.sol";

/// @title CaseDesk
/// @notice Submissions and the lazy state machine of a task's active submission: activation (and the mandatory
///         swarm check of a large submission), the dispute window, the NFT decision, the windows to call the swarm,
///         prepaid questions, the final outcome. Timers move only forward and only here. Questions that are already
///         paid for (the mandatory check of a queued submission, an appeal after the reply window) are asked here
///         too, so no step waits for a keeper; a failing Intake never blocks the machine (the question counts as
///         silence / the appeal is void). The money of a final submission is split by the DisputeDesk (`settle`).
contract CaseDesk is Desk {
    /// @inheritdoc Desk
    function isCaseDesk() public pure override returns (bool) {
        return true;
    }

    /// @dev What a submission inherits from its task, fixed at submission: one slot instead of a call per step.
    struct Terms {
        uint32 version;
        address currency;
    }

    SwarmQuestionBuilder internal immutable questionBuilder;

    uint256 public submissionCount;
    mapping(uint256 => Submission) internal _subs;
    mapping(uint256 => Terms) internal _terms;

    constructor(address registry_, address imd_, address usdc_, address textRules_, address questionBuilder_)
        Desk(registry_, imd_, usdc_, textRules_)
    {
        questionBuilder = SwarmQuestionBuilder(questionBuilder_);
    }

    // ================================================================== user actions (through the vault)

    /// @notice Submit a proof (irrevocable). Bond = max(minBond, bondBase + 3% R in IMD) x 2^(rejected + ahead).
    ///         For R >= the large threshold the doer also prepays the live swarm price for the mandatory check (his
    ///         own cost, never refunded once asked), asked when the submission becomes active.
    ///         `minReward` and `maxImdIn` protect the doer from changes between his quote and the transaction (the
    ///         contributors withdrawing, a submission queued ahead doubling the bond, the task turning large).
    ///         `proofUri` is one link in the form the task's proof type requires (`BadProof` otherwise).
    ///         `evidence`: optional screenshot (IPFS digest) and note, sent to the swarm with the proof; stored before
    ///         activation, because a large submission's check question is asked there.
    function submit(
        uint256 taskId,
        string calldata proofUri,
        Evidence calldata evidence,
        uint256 minReward,
        uint256 maxImdIn,
        ImdPay calldata payIn
    ) external routed returns (uint256 subId) {
        address sender = _sender();
        IVault tasks = _bank();
        tasks.advance(taskId);
        SubmitTerms memory t = tasks.submitTerms(taskId, sender);
        if (t.status != TaskStatus.Open) revert TaskNotOpen();
        if (t.deadline != 0 && block.timestamp >= t.deadline) revert DeadlinePassed();
        if (t.pot == 0) revert RewardTooSmall();
        if (t.pot < minReward) revert RewardChanged();
        ParamsCore memory p = _params(t.version);
        _checkText(proofUri, p);
        textRules.checkProof(proofUri, t.proofType);
        bool hasNote = bytes(evidence.note).length != 0;
        if (hasNote && !textRules.validText(evidence.note, MAX_NOTE_BYTES)) revert BadEvidence();
        if (evidence.screenshotRaw && evidence.screenshot == 0) revert BadEvidence();

        subId = ++submissionCount;
        Submission storage s = _subs[subId];
        s.taskId = uint64(taskId);
        s.doer = sender;
        s.proofUri = proofUri;
        s.doerIsContributor = t.doerEver;
        s.reward = t.pot;
        (s.rewardImd, s.imdPerEth, s.large) = _priceReward(t.currency, t.pot, p);
        s.bond = _doerBond(t.rejectedCount, t.ahead, p, s.rewardImd);
        if (s.large) {
            s.checkFunds = _swarmPrice(p);
            if (s.checkFunds == 0) revert ActionNotSold(); // a large task cannot be checked now
        }
        _terms[subId] = Terms(t.version, t.currency);

        if (s.bond + s.checkFunds > maxImdIn) revert CostAboveMax();
        uint256 value = _value();
        uint256 ethNeeded = _bank().collectImd(sender, value, s.bond + s.checkFunds, p.swapAdapter, payIn);

        bool queued = t.busy;
        emit Submitted(subId, taskId, sender, s.reward, s.bond, queued);
        if (evidence.screenshot != 0 || hasNote) {
            if (evidence.screenshot != 0) {
                s.screenshot = evidence.screenshot;
                s.screenshotRaw = evidence.screenshotRaw;
            }
            if (hasNote) s.doerNote = evidence.note;
            emit EvidenceAttached(subId, evidence.screenshot, evidence.screenshotRaw, evidence.note);
        }
        tasks.place(taskId, subId, queued);
        if (queued) s.phase = Phase.Queued;
        else _activate(subId); // a large submission's check is asked here
        _bank().settleValue(sender, value, ethNeeded); // excess ETH back last (checks, effects, interactions)
    }

    /// @notice Bond (and check prepayment) of a queued submission whose task was completed or unwound.
    function claimVoidSubmission(uint256 subId) external routed {
        Submission storage s = _subs[subId];
        IVault tasks = _bank();
        tasks.advance(s.taskId);
        TaskStatus ts = tasks.statusOf(s.taskId);
        if (s.phase != Phase.Queued || (ts != TaskStatus.Completed && ts != TaskStatus.Unwound)) {
            revert NothingToClaim();
        }
        s.phase = Phase.Void;
        uint256 amount = s.bond + s.checkFunds;
        s.checkFunds = 0;
        emit VoidSubmissionClaimed(subId, s.doer, amount);
        _bank().pay(address(imd), s.doer, amount);
    }

    /// @notice The doer answers the disputes once, within the reply window.
    function reply(uint256 subId, string calldata text) external routed {
        Submission storage s = _subs[subId];
        if (_sender() != s.doer) revert NotDoer();
        if (s.replyEnd == 0 || block.timestamp >= s.replyEnd || s.phase == Phase.Final) revert WindowClosed();
        if (bytes(s.doerReply).length != 0) revert AlreadyReplied();
        _checkText(text, _params(_terms[subId].version));
        s.doerReply = text;
        emit DoerReplied(subId, text);
    }

    // ================================================================== the machine (TaskVault.advance)

    /// @notice One transition of the active submission. False if nothing can move now.
    function step(uint256 subId) external only(vault) returns (bool) {
        Submission storage s = _subs[subId];
        ParamsCore memory p = _params(_terms[subId].version);
        Phase ph = s.phase;

        if (ph == Phase.Review) {
            if (s.check == CheckState.Requested) {
                (SwarmStatus st, bool answer, uint64 at) = _swarmStatus(s.request, p);
                if (st == SwarmStatus.Pending) return false;
                if (st == SwarmStatus.Answered && !answer) {
                    _finalize(subId, Outcome.Rejected, false); // the mandatory check said "no"
                    return true;
                }
                // "yes", or silence: the dispute window runs from the answer / from the moment of silence
                s.check = st == SwarmStatus.Answered ? CheckState.Passed : CheckState.None;
                if (st == SwarmStatus.Silent) emit SwarmSilent(subId, s.request, at);
                s.windowEnd = at + p.disputeWindow;
                emit CheckPassed(subId, s.windowEnd);
                return true;
            }
            if (block.timestamp < s.windowEnd) return false;
            _finalize(subId, Outcome.Accepted, false); // nobody disputed
            return true;
        }
        if (ph == Phase.Voting) {
            if (block.timestamp < s.voteEnd) return false;
            if (!_tryDecide(subId, IDisputeDesk(disputeDesk).tally(subId), s.voteEnd, p)) {
                s.phase = Phase.NoDecision; // optimistic window: anyone may call the swarm, paying
                s.callFrom = s.voteEnd;
                emit NoNftDecision(subId);
            }
            return true;
        }
        if (ph == Phase.NoDecision || ph == Phase.Decided) {
            if (block.timestamp < uint256(s.callFrom) + p.appealWindow) return false;
            if (ph == Phase.NoDecision) {
                _finalize(subId, Outcome.Accepted, true); // nobody called the swarm: accepted (tie rule)
            } else {
                _finalize(subId, s.nftDecision == Verdict.Accept ? Outcome.Accepted : Outcome.Rejected, false);
            }
            return true;
        }
        if (ph == Phase.Appealed) {
            AppealCore memory a = IDisputeDesk(disputeDesk).appealCore(subId);
            if (!a.replied && block.timestamp < a.replyEnd) return false;
            _askAppeal(subId, a.funds, p);
            return true;
        }
        if (ph == Phase.Asked) {
            (SwarmStatus st, bool answer, uint64 at) = _swarmStatus(s.request, p);
            if (st == SwarmStatus.Pending) return false;
            if (st == SwarmStatus.Answered) {
                _finalize(subId, answer ? Outcome.Accepted : Outcome.Rejected, false); // the swarm is final
            } else {
                // silent: the caller's fee is lost, the rest of his deposit is his (pull); the state before the
                // call stands again and a new window to call the swarm starts at the moment of silence
                IDisputeDesk(disputeDesk).dropCaller(subId);
                s.phase = s.nftDecision == Verdict.None ? Phase.NoDecision : Phase.Decided;
                s.callFrom = at;
                emit SwarmSilent(subId, s.request, at);
            }
            return true;
        }
        return false; // Queued / Final / Void are inert
    }

    /// @notice Emergency exit of the active submission (the vault checked that it is stuck).
    function finalize(uint256 subId, Outcome o) external only(vault) {
        _finalize(subId, o, false);
    }

    // ================================================================== for the dispute desk

    /// @notice Plays the task's timers first, then returns the submission as it stands.
    function advanced(uint256 subId) external only(disputeDesk) returns (SubCore memory) {
        _bank().advance(_subs[subId].taskId);
        return _core(subId);
    }

    /// @notice The first dispute starts the NFT vote and the doer's reply window.
    function startVote(uint256 subId, uint32 voteWindow, uint32 replyWindow) external only(disputeDesk) {
        Submission storage s = _subs[subId];
        if (s.phase != Phase.Review) return;
        s.phase = Phase.Voting;
        s.voteEnd = uint64(block.timestamp) + voteWindow;
        s.replyEnd = uint64(block.timestamp) + replyWindow;
    }

    function markAppealed(uint256 subId) external only(disputeDesk) {
        _subs[subId].phase = Phase.Appealed;
    }

    /// @notice The swarm is called while the NFT did not decide: asked at once, paid from the caller's deposit.
    function askEscalation(uint256 subId, uint256 price) external only(disputeDesk) returns (bool ok, uint256 spent) {
        (ok, spent) = _ask(subId, SWARM_KIND_ESCALATION, price, _params(_terms[subId].version));
        if (ok) _subs[subId].phase = Phase.Asked;
    }

    // ================================================================== views

    function getSubmission(uint256 subId) external view returns (Submission memory) {
        return _subs[subId];
    }

    function subCore(uint256 subId) external view returns (SubCore memory) {
        return _core(subId);
    }

    /// @notice Bond and mandatory check fee (large tasks, not refunded) a new submission to `taskId` would need now.
    function quoteSubmission(uint256 taskId) external view returns (uint256 bond, uint256 checkFee) {
        SubmitTerms memory t = _bank().submitTerms(taskId, address(0));
        ParamsCore memory p = _params(t.version);
        (uint256 rewardImd,, bool large) = _priceReward(t.currency, t.pot, p);
        bond = _doerBond(t.rejectedCount, t.ahead, p, rewardImd);
        if (large) checkFee = _swarmPrice(p);
    }

    /// @notice When the current step of an active submission times out (the emergency clock starts there).
    function stepDeadline(uint256 subId) external view returns (uint256) {
        Submission storage s = _subs[subId];
        ParamsCore memory p = _params(_terms[subId].version);
        Phase ph = s.phase;
        if (ph == Phase.Review) {
            if (s.check == CheckState.Requested) {
                return uint256(_bank().requests(s.request).askedAt) + p.swarmTimeout + SWARM_DELIVERY_GRACE;
            }
            return s.windowEnd;
        }
        if (ph == Phase.Voting) return s.voteEnd;
        if (ph == Phase.NoDecision || ph == Phase.Decided) return uint256(s.callFrom) + p.appealWindow;
        if (ph == Phase.Appealed) return IDisputeDesk(disputeDesk).appealCore(subId).replyEnd;
        if (ph == Phase.Asked) return uint256(_bank().requests(s.request).askedAt) + p.swarmTimeout + SWARM_DELIVERY_GRACE;
        return type(uint128).max; // not an active step
    }

    /// @notice The JSON body the vault would send now for `kind` (1 check, 2 escalation, 3 appeal).
    function previewSwarmBody(uint256 subId, uint8 kind) external view returns (bytes memory body, bytes32 qh) {
        return questionBuilder.buildFor(vault, subId, kind, _params(_terms[subId].version).maxClaims);
    }

    // ================================================================== internal: activation and decisions

    /// @dev Opens the dispute window of the task's new active submission (the vault already made it active). A large
    ///      submission is first checked by the swarm (its prepaid fee); if it cannot be asked now (price above the
    ///      prepayment, action not sold, Intake failing) the check counts as silent: the window opens now and the
    ///      prepayment goes back to the doer.
    function _activate(uint256 subId) private {
        Submission storage s = _subs[subId];
        ParamsCore memory p = _params(_terms[subId].version);
        s.phase = Phase.Review;
        s.activatedAt = uint64(block.timestamp);
        if (s.large) {
            uint256 price = _swarmPrice(p);
            if (price != 0 && price <= s.checkFunds) {
                (bool ok, uint256 spent) = _ask(subId, SWARM_KIND_CHECK, price, p);
                if (ok) {
                    s.check = CheckState.Requested;
                    _bank().credit(address(imd), s.doer, s.checkFunds - spent);
                    s.checkFunds = 0;
                    emit Activated(subId, 0, true);
                    return;
                }
            }
            _bank().credit(address(imd), s.doer, s.checkFunds);
            s.checkFunds = 0;
        }
        s.windowEnd = uint64(block.timestamp) + p.disputeWindow;
        emit Activated(subId, s.windowEnd, false);
    }

    /// @dev NFT decision rule, played only at vote end (step, Voting): |accept - reject| >= endDelta and the winning
    ///      side has >= minWinnerWallets distinct signers. No instant decision on a partial count (see
    ///      audit C-02): `instantDelta` is unused and NftDecided.instant is always false.
    function _tryDecide(uint256 subId, Tally memory v, uint64 at, ParamsCore memory p) private returns (bool) {
        if (v.accept == v.reject) return false;
        bool acceptWins = v.accept > v.reject;
        uint256 diff = acceptWins ? v.accept - v.reject : v.reject - v.accept;
        uint256 wallets = acceptWins ? v.walletsAccept : v.walletsReject;
        if (diff < p.endDelta || wallets < p.minWinnerWallets) return false;
        Submission storage s = _subs[subId];
        s.nftDecision = acceptWins ? Verdict.Accept : Verdict.Reject;
        s.decidedAt = at;
        s.callFrom = at; // appeal window
        s.phase = Phase.Decided;
        emit NftDecided(subId, s.nftDecision, false);
        return true;
    }

    /// @dev The appeal question is asked once the opponent replied or the reply window ended. If the live price is
    ///      now above the prepaid fee, 0, or the Intake fails, the appeal is void: bond and fee are the appellant's
    ///      again (credit), the NFT decision stands and a new appeal window starts now.
    function _askAppeal(uint256 subId, uint256 funds, ParamsCore memory p) private {
        Submission storage s = _subs[subId];
        IDisputeDesk disputes = IDisputeDesk(disputeDesk);
        uint256 price = _swarmPrice(p);
        if (price != 0 && price <= funds) {
            (bool ok, uint256 spent) = _ask(subId, SWARM_KIND_APPEAL, price, p);
            if (ok) {
                s.phase = Phase.Asked;
                disputes.appealAsked(subId, spent);
                return;
            }
        }
        disputes.dropCaller(subId);
        s.phase = Phase.Decided;
        s.callFrom = uint64(block.timestamp);
        emit AppealVoided(subId, price);
    }

    /// @dev Status of a swarm question. An answer counts if its signed time is within the timeout and it reached
    ///      the vault within SWARM_DELIVERY_GRACE after the timeout; `at` of an answer is the moment it reached the
    ///      vault (a window that follows it is never shortened). Silence: no such answer by the end of the grace
    ///      (moment of silence = ask time + timeout + grace), or no answer recorded and the Intake already reports
    ///      the request completed (status 1 / 2; moment of silence = now). Nothing is settled as silent while an
    ///      answer signed in time can still count, so the outcome is the same whenever anyone pokes (swarm audit #7).
    function _swarmStatus(bytes32 rid, ParamsCore memory p)
        private
        view
        returns (SwarmStatus status, bool answer, uint64 at)
    {
        SwarmRequest memory r = _bank().requests(rid);
        uint256 deadline = uint256(r.askedAt) + p.swarmTimeout;
        uint256 lastDelivery = deadline + SWARM_DELIVERY_GRACE;
        if (r.answered && r.answerTime <= deadline && r.recordedAt <= lastDelivery) {
            return (SwarmStatus.Answered, r.answer, r.recordedAt);
        }
        if (block.timestamp >= lastDelivery) return (SwarmStatus.Silent, false, uint64(lastDelivery));
        if (r.answered) return (SwarmStatus.Pending, false, 0); // signed too late: silence at the end of the grace
        try IIntake(p.intake).requests(rid) returns (address, address, bytes4, bool completed) {
            if (completed) return (SwarmStatus.Silent, false, uint64(block.timestamp));
        } catch {}
        return (SwarmStatus.Pending, false, 0);
    }

    // ================================================================== internal: settlement

    /// @dev Closes a submission with `o`: the DisputeDesk splits the money, the vault moves the task on (next
    ///      queued submission, merge of pending top-ups, completion or unwind). Credits only; never transfers.
    /// @param tie accepted because the NFT did not decide and nobody called the swarm
    function _finalize(uint256 subId, Outcome o, bool tie) private {
        Submission storage s = _subs[subId];
        Terms memory tm = _terms[subId];
        uint256 taskId = s.taskId;
        s.phase = Phase.Final;
        s.outcome = o;
        Facts memory f = Facts({
            taskId: s.taskId,
            version: tm.version,
            currency: tm.currency,
            doer: s.doer,
            doerIsContributor: s.doerIsContributor,
            nftDecision: s.nftDecision,
            reward: s.reward,
            bond: s.bond,
            checkFunds: s.checkFunds
        });
        s.checkFunds = 0; // credited back to the doer by the settlement
        IDisputeDesk(disputeDesk).settle(subId, o, tie, f);
        emit SubmissionFinal(subId, taskId, o);
        uint256 next = _bank().closeSubmission(taskId, o, s.reward);
        if (next != 0) _activate(next);
    }

    // ================================================================== internal: swarm questions

    /// @dev Builds the question from stored data and has the vault pay the Intake `price` IMD (already held in one
    ///      of the submission's buckets). Never reverts on an Intake failure: ok = false and nothing is spent.
    function _ask(uint256 subId, uint8 kind, uint256 price, ParamsCore memory p)
        private
        returns (bool ok, uint256 spent)
    {
        (bytes memory body, bytes32 qh) = questionBuilder.buildFor(vault, subId, kind, p.maxClaims);
        bytes32 rid;
        (ok, spent, rid) = _bank()
            .ask(AskTerms(uint64(subId), kind, p.minPanelSize, p.minQuorum, p.intake, p.swarmAction, qh, price), body);
        if (!ok) return (false, 0);
        Submission storage s = _subs[subId];
        ++s.asks;
        s.request = rid;
    }

    function _core(uint256 subId) private view returns (SubCore memory c) {
        Submission storage s = _subs[subId];
        Terms memory tm = _terms[subId];
        c.taskId = s.taskId;
        c.doer = s.doer;
        c.phase = s.phase;
        c.outcome = s.outcome;
        c.nftDecision = s.nftDecision;
        c.windowEnd = s.windowEnd;
        c.voteEnd = s.voteEnd;
        c.version = tm.version;
        c.currency = tm.currency;
        c.rewardImd = s.rewardImd;
        c.imdPerEth = s.imdPerEth;
    }
}
