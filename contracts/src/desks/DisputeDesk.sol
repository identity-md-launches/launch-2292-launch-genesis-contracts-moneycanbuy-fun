// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ParamsCore} from "../VaultParams.sol";
import {Ballot, VoteBook, VoteLib, IBallotChecker} from "../libraries/VoteLib.sol";
import {Desk} from "./Desk.sol";
import {SubCore, Facts, Tally, AppealCore, ICaseDesk, IVault} from "./DeskApi.sol";
import "../VaultTypes.sol";

/// @title DisputeDesk
/// @notice Disputes, the NFT vote batches with relayer reimbursement, appeals and calls of the swarm, the money split
///         of a final submission and its lazy per-claimant payouts. The phases these actions move are kept by the
///         CaseDesk; the money is held by the vault.
contract DisputeDesk is Desk {
    /// @inheritdoc Desk
    function isCaseDesk() public pure override returns (bool) {
        return false;
    }

    /// @notice The most of a loser penalty that relayer shortfall may take (20%): winners and correct votes always
    ///         share the rest (swarm audit #3). Shortfall above it is not paid.
    uint256 public constant MAX_SHORTFALL_BPS = 2_000;

    bytes32 private constant VOTE_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    mapping(uint256 => Dispute) internal _disputes;
    mapping(uint256 => mapping(address => DisputerInfo)) internal _disputerInfo;
    mapping(uint256 => Appeal) internal _appeals;
    mapping(uint256 => Settlement) internal _settlements;
    mapping(uint256 => VoteBook) internal _votes;
    mapping(uint256 => mapping(address => uint256)) public relayerShortfall; // subId => relayer => IMD

    IBallotChecker internal immutable ballotChecker;

    constructor(address registry_, address imd_, address usdc_, address textRules_, address ballotChecker_)
        Desk(registry_, imd_, usdc_, textRules_)
    {
        ballotChecker = IBallotChecker(ballotChecker_);
    }

    // ================================================================== disputes and votes (through the vault)

    /// @notice Dispute the active submission inside its window (any number of disputers; not its doer, who therefore
    ///         can never answer an appeal as a disputer).
    ///         Bond max(minBond, bondBase + 1% R) in IMD plus an ETH gas fee within [min, max] that funds the
    ///         relaying of NFT votes. The first dispute starts the NFT vote and the doer's reply window.
    function dispute(uint256 subId, string calldata reason, uint256 disputeFee, ImdPay calldata payIn) external routed {
        address sender = _sender();
        SubCore memory s = ICaseDesk(caseDesk).advanced(subId);
        Phase ph = s.phase;
        if (ph != Phase.Review && ph != Phase.Voting) revert WrongPhase();
        if (sender == s.doer) revert DoerCannotDispute(); // audit C-01
        if (s.windowEnd == 0 || block.timestamp >= s.windowEnd) revert WindowClosed();
        ParamsCore memory p = _params(s.version);
        _checkText(reason, p);
        if (disputeFee < p.minDisputeFee || disputeFee > p.maxDisputeFee) revert FeeOutOfRange();
        DisputerInfo storage info = _disputerInfo[subId][sender];
        if (info.bond != 0) revert AlreadyDisputed();
        Dispute storage d = _disputes[subId];

        uint256 bond = _bondFor(s.rewardImd, p.disputeBondBps, p);
        bool contributor = _bank().isContributor(s.taskId, sender);
        info.bond = bond;
        info.fee = disputeFee;
        info.contributor = contributor;
        info.reason = reason;
        d.disputers.push(sender);
        d.bondTotal += bond;
        if (contributor) d.contributorBondTotal += bond;
        d.feeTotal += disputeFee;
        d.ethPot += disputeFee;

        if (ph == Phase.Review) ICaseDesk(caseDesk).startVote(subId, p.voteWindow, p.replyWindow);
        IVault bank = _bank();
        uint256 value = _value();
        uint256 ethNeeded = disputeFee + bank.collectImd(sender, value, bond, p.swapAdapter, payIn);
        bank.bookEth(disputeFee, false);
        bank.settleValue(sender, value, ethNeeded);
        emit Disputed(subId, sender, bond, disputeFee, reason);
    }

    /// @notice Relay a batch of signed NFT votes (anyone), until the vote end. Counting only: the NFT decides at
    ///         the vote end (CaseDesk.step), never on a partial count (audit C-02). The relayer is
    ///         reimbursed basefee x measured gas x (1 + markup), capped per newly counted vote, first from the dispute pot;
    ///         the rest is recorded in IMD and paid from the loser penalty if the case ends with a winner, all relayers
    ///         of a case together at most MAX_SHORTFALL_BPS (20%) of that penalty, pro rata.
    function submitVotes(uint256 subId, Ballot[] calldata ballots) external routed {
        // measured here: the vault's forwarding, its calldata and the 21k base are covered by relayBaseGas + 16 gas
        // per calldata byte, counted over the canonical ABI encoding only
        uint256 gasStart = gasleft();
        SubCore memory s = ICaseDesk(caseDesk).advanced(subId);
        if (s.phase != Phase.Voting || block.timestamp >= s.voteEnd) revert WrongPhase();
        ParamsCore memory p = _params(s.version);
        Dispute storage d = _disputes[subId];

        VoteLib.Result memory r = VoteLib.castBallots(
            _votes[subId],
            ballots,
            VoteLib.Context({
                subId: subId,
                voteEnd: s.voteEnd,
                domainSeparator: voteDomainSeparator(),
                nft: p.nft,
                delegateRegistry: p.delegateRegistry
            }),
            ballotChecker
        );
        d.votesAccept += uint32(r.accept);
        d.votesReject += uint32(r.reject);
        d.walletsAccept += uint32(r.acceptWallets);
        d.walletsReject += uint32(r.rejectWallets);

        uint256 counted = r.accept + r.reject;
        uint256 paid;
        if (counted != 0) {
            paid = _reimburseRelayer(subId, s.imdPerEth, p, counted, gasStart, _chargedCalldata(ballots));
        }
        emit VotesSubmitted(subId, _sender(), r.accept, r.reject, paid);
    }

    // ================================================================== appeals and calls of the swarm

    /// @notice Appeal an NFT decision within the appeal window (24h from the decision, or from the last silence
    ///         of the swarm). Anyone may appeal (the doer only a rejection of his submission); the appellant takes the
    ///         side opposite to the decision and pays a
    ///         dispute bond plus the live swarm fee now. The question is asked lazily (any call on the task, e.g.
    ///         poke) after the opponent replied or the reply window ended.
    ///         `maxImdIn` caps bond + fee: the Intake owner can change the price without delay.
    function appeal(uint256 subId, string calldata reason, uint256 maxImdIn, ImdPay calldata payIn) external routed {
        address sender = _sender();
        SubCore memory s = ICaseDesk(caseDesk).advanced(subId);
        if (s.phase != Phase.Decided) revert WrongPhase();
        // the doer may appeal a rejection, never his own acceptance (swarm audit #4, as DoerCannotDispute)
        if (sender == s.doer && s.nftDecision != Verdict.Reject) revert DoerCannotDispute();
        ParamsCore memory p = _params(s.version);
        _checkText(reason, p);
        uint256 fee = _swarmPrice(p);
        if (fee == 0) revert ActionNotSold();
        Appeal storage a = _appeals[subId];
        uint256 bond = _bondFor(s.rewardImd, p.disputeBondBps, p);
        if (bond + fee > maxImdIn) revert CostAboveMax();
        a.appellant = sender;
        a.sidesDoer = s.nftDecision == Verdict.Reject;
        a.contributor = _bank().isContributor(s.taskId, sender);
        a.replyEnd = uint64(block.timestamp) + p.appealReplyWindow;
        a.bond = bond;
        a.funds = fee;
        a.reason = reason;
        ICaseDesk(caseDesk).markAppealed(subId);
        IVault bank = _bank();
        uint256 value = _value();
        bank.settleValue(sender, value, bank.collectImd(sender, value, bond + fee, p.swapAdapter, payIn));
        emit Appealed(subId, sender, bond, fee, reason);
    }

    /// @notice The NFT did not decide (NoDecision window): anyone may call the swarm, paying the live fee plus a
    ///         dispute bond, and picks a side (the doer only his own). The swarm is asked at once with the disputes and the doer's reply.
    ///         Win: the loser reimburses the fee and the caller shares the loser bond as a winner. Silence: the fee
    ///         is lost, the bond is credited back and a new window starts. Nobody calls: accepted (tie rule).
    function callSwarm(uint256 subId, bool sidesDoer, string calldata reason, uint256 maxImdIn, ImdPay calldata payIn)
        external
        routed
    {
        address sender = _sender();
        SubCore memory s = ICaseDesk(caseDesk).advanced(subId);
        if (s.phase != Phase.NoDecision) revert WrongPhase();
        if (sender == s.doer && !sidesDoer) revert DoerCannotDispute(); // swarm audit #4
        ParamsCore memory p = _params(s.version);
        _checkText(reason, p);
        uint256 price = _swarmPrice(p);
        if (price == 0) revert ActionNotSold();
        uint256 bond = _bondFor(s.rewardImd, p.disputeBondBps, p);
        if (bond + price > maxImdIn) revert CostAboveMax();
        IVault bank = _bank();
        uint256 value = _value();
        uint256 ethNeeded = bank.collectImd(sender, value, bond + price, p.swapAdapter, payIn);
        Appeal storage a = _appeals[subId];
        a.appellant = sender;
        a.sidesDoer = sidesDoer;
        a.contributor = _bank().isContributor(s.taskId, sender);
        a.bond = bond;
        a.reason = reason; // goes into the question as "appeal"
        (bool ok, uint256 spent) = ICaseDesk(caseDesk).askEscalation(subId, price);
        if (!ok) revert SwarmUnavailable();
        a.spent = spent;
        a.funds = price - spent;
        emit SwarmCalled(subId, sender, sidesDoer, bond, price);
        bank.settleValue(sender, value, ethNeeded);
    }

    /// @notice The appellant's opponent replies once: the doer, or any disputer if the appeal sides with the doer.
    function appealReply(uint256 subId, string calldata text) external routed {
        address sender = _sender();
        SubCore memory s = ICaseDesk(caseDesk).subCore(subId);
        Appeal storage a = _appeals[subId];
        if (s.phase != Phase.Appealed || block.timestamp >= a.replyEnd) revert WindowClosed();
        if (a.replied) revert AlreadyReplied();
        bool opponent = a.sidesDoer ? _disputerInfo[subId][sender].bond != 0 : sender == s.doer;
        if (!opponent) revert NotOpponent();
        _checkText(text, _params(s.version));
        a.replied = true;
        a.reply = text;
        emit AppealReplied(subId, sender, text);
    }

    // ================================================================== claims (through the vault)

    /// @notice Disputer: own bond back if the disputers won or on an emergency exit, a share of the won bonds
    ///         (non-contributors only, pro rata to bonds), and the pro-rata leftover of the dispute ETH pot
    ///         (pro rata to fees, in every outcome).
    function claimDisputer(uint256 subId) external routed {
        address sender = _sender();
        SubCore memory s = ICaseDesk(caseDesk).advanced(subId); // play due timers first: no separate poke needed
        if (s.phase != Phase.Final) revert NotFinal();
        DisputerInfo storage info = _disputerInfo[subId][sender];
        if (info.bond == 0 || info.claimed) revert NothingToClaim();
        info.claimed = true;
        Settlement storage st = _settlements[subId];
        IVault bank = _bank();
        uint256 imdAmount = st.neutral || st.disputersWon ? info.bond : 0;
        if (st.disputersWon && !info.contributor && st.disputerRewardBonds != 0) {
            uint256 share = st.disputerReward * info.bond / st.disputerRewardBonds;
            st.disputerReward -= share;
            st.disputerRewardBonds -= info.bond;
            // became a contributor after disputing: the share goes to the treasury
            if (_bank().isContributor(s.taskId, sender)) bank.addTreasury(address(imd), share);
            else imdAmount += share;
        }
        uint256 ethAmount;
        if (st.ethFeesLeft != 0) {
            ethAmount = st.ethLeft * info.fee / st.ethFeesLeft;
            st.ethLeft -= ethAmount;
            st.ethFeesLeft -= info.fee;
        }
        emit DisputerClaimed(subId, sender, imdAmount, ethAmount);
        bank.pay(address(imd), sender, imdAmount);
        bank.pay(ETH, sender, ethAmount);
    }

    /// @notice NFT voter reward for `payTo` (anyone may trigger; money goes to payTo). Only when the NFT decided
    ///         and the final outcome agrees: a share of the loser bonds (IMD) and of the fee (reward currency),
    ///         pro rata to the votes on the final side.
    function claimVoterReward(uint256 subId, address payTo) external routed {
        SubCore memory s = ICaseDesk(caseDesk).advanced(subId); // play due timers first: no separate poke needed
        if (s.phase != Phase.Final) revert NotFinal();
        Settlement storage st = _settlements[subId];
        VoteBook storage vb = _votes[subId];
        uint256 n = s.outcome == Outcome.Accepted ? vb.acceptVotesOf[payTo] : vb.rejectVotesOf[payTo];
        uint256 left = st.voterVotesLeft;
        if (n == 0 || left == 0 || vb.claimed[payTo] != 0) revert NothingToClaim();
        vb.claimed[payTo] = 1;
        uint256 imdShare = st.voterImd * n / left;
        uint256 feeShare = st.voterFee * n / left;
        st.voterImd -= imdShare;
        st.voterFee -= feeShare;
        st.voterVotesLeft = left - n;
        emit VoterRewardClaimed(subId, payTo, n, imdShare, feeShare);
        IVault bank = _bank();
        bank.pay(address(imd), payTo, imdShare);
        bank.pay(s.currency, payTo, feeShare);
    }

    /// @notice Relayer: IMD for gas the dispute pot could not cover, from the loser penalty (not on emergency exit).
    function claimRelayerShortfall(uint256 subId) external routed {
        address sender = _sender();
        SubCore memory s = ICaseDesk(caseDesk).advanced(subId); // play due timers first: no separate poke needed
        if (s.phase != Phase.Final) revert NotFinal();
        Settlement storage st = _settlements[subId];
        if (st.neutral) revert NothingToClaim();
        uint256 mine = relayerShortfall[subId][sender];
        if (mine == 0) revert NothingToClaim();
        relayerShortfall[subId][sender] = 0;
        uint256 amount = st.shortfallPay * mine / st.shortfallLeft;
        st.shortfallPay -= amount;
        st.shortfallLeft -= mine;
        emit RelayerShortfallClaimed(subId, sender, amount);
        _bank().pay(address(imd), sender, amount);
    }

    // ================================================================== for the case desk and the question builder

    function tally(uint256 subId) external view returns (Tally memory) {
        return _tally(_disputes[subId]);
    }

    function appealCore(uint256 subId) external view returns (AppealCore memory c) {
        Appeal storage a = _appeals[subId];
        c.appellant = a.appellant;
        c.sidesDoer = a.sidesDoer;
        c.replied = a.replied;
        c.replyEnd = a.replyEnd;
        c.funds = a.funds;
    }

    /// @notice The first `maxClaims` dispute reasons in filing order and the current caller's texts (read by the
    ///         SwarmQuestionBuilder).
    function questionPart(uint256 subId, uint256 maxClaims)
        external
        view
        returns (string[] memory claims, string memory appealReason, string memory appealReply_)
    {
        address[] storage list = _disputes[subId].disputers;
        uint256 n = list.length < maxClaims ? list.length : maxClaims;
        claims = new string[](n);
        for (uint256 i; i < n; ++i) {
            claims[i] = _disputerInfo[subId][list[i]].reason;
        }
        Appeal storage a = _appeals[subId];
        return (claims, a.reason, a.reply);
    }

    /// @notice The appeal question was asked: its price leaves the prepaid fee.
    function appealAsked(uint256 subId, uint256 spent) external only(caseDesk) {
        Appeal storage a = _appeals[subId];
        a.funds -= spent;
        a.spent = spent;
    }

    /// @notice The caller's question was void or the swarm stayed silent: his bond and unspent fee are his again.
    function dropCaller(uint256 subId) external only(caseDesk) {
        Appeal storage a = _appeals[subId];
        _bank().credit(address(imd), a.appellant, a.bond + a.funds);
        delete _appeals[subId];
    }

    /// @notice The money of a final submission: the dispute pot leftover goes back to the disputers in every outcome;
    ///         an emergency exit returns every bond; otherwise the reward is paid (accepted) and the loser bonds are
    ///         split (`_settleDecided`). Credits only; never transfers.
    function settle(uint256 subId, Outcome o, bool tie, Facts calldata f) external only(caseDesk) {
        Settlement storage st = _settlements[subId];
        Dispute storage d = _disputes[subId];
        st.ethLeft = d.ethPot;
        st.ethFeesLeft = d.feeTotal;
        d.ethPot = 0;

        if (o == Outcome.Unwound) {
            st.neutral = true;
            _settleNeutral(subId, f);
        } else {
            ParamsCore memory p = _params(f.version);
            bool doerWins = o == Outcome.Accepted;
            // the NFT decided and the final outcome agrees with it
            bool nftRight = f.nftDecision != Verdict.None && (f.nftDecision == Verdict.Accept) == doerWins;
            if (nftRight) st.voterVotesLeft = doerWins ? d.votesAccept : d.votesReject;
            if (doerWins) _payReward(subId, f, nftRight, p);
            _settleDecided(subId, f, doerWins, nftRight, tie, p);
        }
    }

    // ================================================================== views

    function getDispute(uint256 subId) external view returns (Dispute memory) {
        return _disputes[subId];
    }

    function getDisputer(uint256 subId, address who) external view returns (DisputerInfo memory) {
        return _disputerInfo[subId][who];
    }

    function getAppeal(uint256 subId) external view returns (Appeal memory) {
        return _appeals[subId];
    }

    function getSettlement(uint256 subId) external view returns (Settlement memory) {
        return _settlements[subId];
    }

    function votesOf(uint256 subId, address payTo) external view returns (uint256 accept, uint256 reject) {
        return (_votes[subId].acceptVotesOf[payTo], _votes[subId].rejectVotesOf[payTo]);
    }

    function voterClaimed(uint256 subId, address payTo) external view returns (bool) {
        return _votes[subId].claimed[payTo] != 0;
    }

    /// @notice For each tokenId, whether it already voted on a submission.
    function tokensVoted(uint256 subId, uint256[] calldata tokenIds) external view returns (bool[] memory voted) {
        voted = new bool[](tokenIds.length);
        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 id = tokenIds[i];
            voted[i] = _votes[subId].usedTokens[id >> 8] & (1 << (id & 0xff)) != 0;
        }
    }

    /// @notice Whether an NFT already voted on a submission.
    function tokenVoted(uint256 subId, uint256 tokenId) external view returns (bool) {
        return _votes[subId].usedTokens[tokenId >> 8] & (1 << (tokenId & 0xff)) != 0;
    }

    /// @notice EIP-712 domain of NFT votes: ("IMD TaskVault", "1", chainid, vault).
    function voteDomainSeparator() public view returns (bytes32) {
        return
            keccak256(
                abi.encode(VOTE_DOMAIN_TYPEHASH, keccak256("IMD TaskVault"), keccak256("1"), block.chainid, vault)
            );
    }

    /// @notice Dispute bond of `subId`. Appealing or calling the swarm costs the same bond plus `quoteSwarmFee`.
    function quoteDisputeBond(uint256 subId) external view returns (uint256) {
        SubCore memory s = ICaseDesk(caseDesk).subCore(subId);
        ParamsCore memory p = _params(s.version);
        return _bondFor(s.rewardImd, p.disputeBondBps, p);
    }

    /// @notice Live swarm fee (IMD) for questions about `subId`; 0 = the Intake does not sell the action now.
    function quoteSwarmFee(uint256 subId) external view returns (uint256) {
        return _swarmPrice(_params(ICaseDesk(caseDesk).subCore(subId).version));
    }

    // ================================================================== internal

    /// @dev Calldata bytes the relayer is paid for: the length of the canonical ABI encoding of
    ///      `submitVotes(uint256, Ballot[])`, never more than what was actually sent. A relayer who appends a tail
    ///      (zero bytes cost it 4 or the EIP-7623 floor, reimbursement was 16) is not paid for it.
    function _chargedCalldata(Ballot[] calldata ballots) private pure returns (uint256) {
        // selector + subId + offset of the array + its length + one offset per ballot
        uint256 canonical = 4 + 32 + 32 + 32 + ballots.length * 32;
        for (uint256 i; i < ballots.length; ++i) {
            // five head slots (voter, side, payTo, two offsets), then both dynamic arrays with their length slot
            canonical += 160 + 32 + ballots[i].tokenIds.length * 32 + 32 + ((ballots[i].signature.length + 31) / 32) * 32;
        }
        uint256 sent = msg.data.length - SUFFIX;
        return canonical < sent ? canonical : sent;
    }

    function _tally(Dispute storage d) private view returns (Tally memory) {
        return Tally(d.votesAccept, d.votesReject, d.walletsAccept, d.walletsReject);
    }

    function _reimburseRelayer(
        uint256 subId,
        uint256 imdPerEth,
        ParamsCore memory p,
        uint256 counted,
        uint256 gasStart,
        uint256 calldataBytes
    ) private returns (uint256 fromPot) {
        Dispute storage d = _disputes[subId];
        uint256 gasUsed = gasStart - gasleft() + p.relayBaseGas + calldataBytes * 16;
        uint256 cap = uint256(p.relayBaseGas) + counted * p.maxRelayGasPerVote;
        if (gasUsed > cap) gasUsed = cap;
        uint256 cost = gasUsed * block.basefee * (BPS + p.relayMarkupBps) / BPS;
        fromPot = cost < d.ethPot ? cost : d.ethPot;
        address relayer = _sender();
        if (fromPot != 0) {
            d.ethPot -= fromPot;
            _bank().credit(ETH, relayer, fromPot);
        }
        uint256 shortWei = cost - fromPot;
        if (shortWei != 0) {
            uint256 shortImd = shortWei * imdPerEth / 1e18;
            relayerShortfall[subId][relayer] += shortImd;
            d.shortfallTotal += shortImd;
        }
    }

    /// @dev Emergency exit: every bond and unused prepayment back (disputers claim theirs with claimDisputer).
    ///      Swarm fees already paid stay paid; relayer shortfall is unpaid (no loser).
    function _settleNeutral(uint256 subId, Facts calldata f) private {
        IVault bank = _bank();
        bank.credit(address(imd), f.doer, f.bond + f.checkFunds);
        Appeal storage a = _appeals[subId];
        if (a.appellant != address(0)) {
            bank.credit(address(imd), a.appellant, a.bond + a.funds);
            a.funds = 0;
        }
    }

    /// @dev Accepted or Rejected. The losing side's bonds (disputers, or the doer; plus a losing swarm caller) are
    ///      the penalty: first a winning swarm caller gets his fee back, then the relayer shortfall (at most
    ///      MAX_SHORTFALL_BPS of what is left), then
    ///      - NFT tie and nobody called the swarm: tieDoerBps to the doer, the rest to the treasury;
    ///      - NFT decided right: winnerBondBps to the winning side pro rata to bonds, the rest to the correct votes;
    ///      - NFT wrong or undecided: everything to the winning side.
    ///      A winner who contributed to the task gets only his own bond back; his share goes to the correct
    ///      votes (NFT right) or to the treasury. Rejected by the mandatory check (no winner): to the treasury.
    function _settleDecided(
        uint256 subId,
        Facts calldata f,
        bool doerWins,
        bool nftRight,
        bool tie,
        ParamsCore memory p
    ) private {
        Dispute storage d = _disputes[subId];
        Appeal storage a = _appeals[subId];
        Settlement storage st = _settlements[subId];
        IVault bank = _bank();
        address imd_ = address(imd);
        st.disputersWon = !doerWins;

        // a caller still recorded here got a swarm answer (silence clears him)
        bool hasCaller = a.appellant != address(0);
        bool callerWins = hasCaller && a.sidesDoer == doerWins;
        uint256 callerLost = hasCaller && !callerWins ? a.bond : 0;

        uint256 penalty; // IMD of the losing side
        uint256 winnerBonds;
        if (doerWins) {
            penalty = d.bondTotal + callerLost;
            winnerBonds = f.bond + (callerWins ? a.bond : 0);
        } else {
            penalty = f.bond + callerLost;
            winnerBonds = d.bondTotal + (callerWins ? a.bond : 0);
        }
        uint256 total = penalty;

        // 0. the loser pays the winning caller's swarm fee
        uint256 feeBack;
        if (callerWins) {
            feeBack = a.spent < penalty ? a.spent : penalty;
            penalty -= feeBack;
        }

        // 1. relayer shortfall, at most MAX_SHORTFALL_BPS of the penalty: the rest goes to the winners and the
        //    correct votes whatever the relayers metered (swarm audit #3)
        uint256 shortCap = penalty * MAX_SHORTFALL_BPS / BPS;
        uint256 shortPay = d.shortfallTotal < shortCap ? d.shortfallTotal : shortCap;
        st.shortfallPay = shortPay;
        st.shortfallLeft = d.shortfallTotal;
        penalty -= shortPay;

        // 2. split
        uint256 toVoters;
        uint256 toTreasury;
        uint256 redirect; // contributor-winner shares
        if (tie) {
            uint256 toDoer = penalty * p.tieDoerBps / BPS;
            if (f.doerIsContributor || _isContributor(f.taskId, f.doer)) redirect = toDoer;
            else bank.credit(imd_, f.doer, toDoer);
            toTreasury = penalty - toDoer;
        } else {
            if (nftRight) toVoters = penalty - penalty * p.winnerBondBps / BPS;
            uint256 winnerShare = penalty - toVoters;
            if (winnerBonds == 0) toTreasury = winnerShare; // rejected by the mandatory check
            else if (winnerShare != 0) redirect = _payWinners(subId, f, doerWins, callerWins, winnerShare, winnerBonds);
        }
        if (nftRight) toVoters += redirect;
        else toTreasury += redirect;
        st.voterImd = toVoters;
        bank.addTreasury(imd_, toTreasury);
        emit SubmissionSettled(subId, nftRight, total, penalty - toVoters - toTreasury, toVoters, toTreasury);

        // 3. direct credits: the doer's bond if he won (and any unused check prepayment), the caller
        bank.credit(imd_, f.doer, (doerWins ? f.bond : 0) + f.checkFunds);
        if (hasCaller) {
            uint256 back = a.funds + (callerWins ? a.bond + feeBack : 0);
            a.funds = 0;
            bank.credit(imd_, a.appellant, back);
        }
    }

    /// @dev Accepted: R - fee to the doer, in the reward currency. The fee goes to the treasury, except that after
    ///      a dispute the NFT decided right, nftFeeBps of R go to the correct votes. (The vault takes R out of
    ///      the task's pot when it closes the submission.)
    function _payReward(uint256 subId, Facts calldata f, bool nftRight, ParamsCore memory p) private {
        uint256 r = f.reward;
        uint256 fee = r * p.feeBps / BPS;
        uint256 toVoters = nftRight ? r * p.nftFeeBps / BPS : 0;
        _settlements[subId].voterFee = toVoters;
        IVault bank = _bank();
        bank.addTreasury(f.currency, fee - toVoters);
        bank.credit(f.currency, f.doer, r - fee);
    }

    /// @dev Splits the winners' share pro rata to bonds. The doer and the caller are credited directly;
    ///      disputers claim lazily from a bucket. Returns the part of contributors (redirected by the caller).
    function _payWinners(
        uint256 subId,
        Facts calldata f,
        bool doerWins,
        bool callerWins,
        uint256 winnerShare,
        uint256 winnerBonds
    ) private returns (uint256 redirect) {
        Dispute storage d = _disputes[subId];
        Appeal storage a = _appeals[subId];
        Settlement storage st = _settlements[subId];
        address imd_ = address(imd);
        uint256 appPart = callerWins ? winnerShare * a.bond / winnerBonds : 0;
        if (appPart != 0) {
            if (a.contributor || _isContributor(f.taskId, a.appellant)) redirect += appPart;
            else _bank().credit(imd_, a.appellant, appPart);
        }
        uint256 rest = winnerShare - appPart;
        if (doerWins) {
            if (f.doerIsContributor || _isContributor(f.taskId, f.doer)) redirect += rest;
            else _bank().credit(imd_, f.doer, rest);
        } else if (rest != 0) {
            uint256 toContributors = rest * d.contributorBondTotal / d.bondTotal;
            redirect += toContributors;
            st.disputerReward = rest - toContributors;
            st.disputerRewardBonds = d.bondTotal - d.contributorBondTotal;
        }
    }

    /// @dev Contributor status is re-checked at settlement: topping up after submitting / appealing does not
    ///      escape the "a contributor who wins gets only his own bond" rule.
    function _isContributor(uint256 taskId, address who) private view returns (bool) {
        return _bank().isContributor(taskId, who);
    }
}
