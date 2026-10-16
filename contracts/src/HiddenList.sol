// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IDelegateRegistry} from "./interfaces/IDelegateRegistry.sol";

/// @title HiddenList
/// @notice The site's hide list, standalone: no core contract reads it and it reads no core contract. It holds no
///         money (no `payable`, no `receive`, no token call) and cannot freeze or redirect any task, bond or reward;
///         it only tells the site what not to render. Key of an item: `(vault, kind, id)`, kind 1 = task, 2 = proof
///         (ids are per vault, so the vault is part of the key). Owner is the project treasury wallet, fixed at
///         deployment, no transfer, no other role: `setState` is its only action, instant, no timelock, both ways
///         (hide or unhide). identity.md NFT holders (or their delegate.xyz v2 delegate) may also vote an item
///         hidden: the first `hide` vote of a round opens a 24h window; the round passes at >= 10 hide NFTs, more
///         hide than keep NFTs, and >= 3 distinct hide *owners* (`ownerOf` at vote time, not the caller, so
///         delegating one holder's NFTs to extra hot wallets does not manufacture distinct wallets, audit round 2
///         finding 13a; `status`'s `hideWallets` still counts distinct callers, unchanged, for display). A round
///         that ended *contested* (it drew at least one keep vote) may be retried only 7 days after it ended; an
///         uncontested round (nobody defended the item) may be retried at once, so one NFT cannot keep an item
///         un-hideable by opening a lone round every 8 days (audit round 2 finding 13b). A hide vote inside the
///         round's last hour that would make the round pass extends `roundEnd` by one hour, so a late swing cannot
///         close before the keep side can answer (finding 13c). `KEPT` blocks rounds entirely. The owner's
///         `setState` always closes whatever round is open and clears its tally; restoring `VISIBLE` over a round
///         that had already started also opens the same 7-day cooldown before a new hide round, so the item the
///         owner just restored cannot be re-hidden the same day by the cluster the owner just overruled
///         (finding 13c). The owner's word is final until a fresh round passes.
contract HiddenList {
    uint8 public constant KIND_TASK = 1;
    uint8 public constant KIND_PROOF = 2;

    uint8 public constant VISIBLE = 0;
    uint8 public constant HIDDEN = 1;
    uint8 public constant KEPT = 2;
    /// @notice Never stored: `status` derives it from a closed round that passed. Owner states (VISIBLE/HIDDEN/KEPT)
    ///         always win over it, since the owner's `setState` clears the round tally.
    uint8 public constant HIDDEN_BY_VOTE = 3;

    uint64 public constant ROUND = 24 hours;
    uint64 public constant COOLDOWN = 7 days;
    uint32 public constant QUORUM_NFTS = 10;
    uint16 public constant MIN_WALLETS = 3;

    address public immutable owner;
    address public immutable nft;
    address public immutable delegateRegistry;

    /// @dev One slot. `round` is internal bookkeeping (scopes the per-round bitmap and wallet-side mappings below);
    ///      `status` does not return it. `roundEnd` is reused for cooldown once the round it names has closed: it is
    ///      only overwritten when a new round actually opens, never reset to 0 by a vote.
    struct ItemState {
        uint8 state;
        uint32 round;
        uint32 hideNfts;
        uint32 keepNfts;
        /// @notice Distinct callers who cast a hide vote this round (`status`'s public count; unchanged meaning).
        uint16 hideWallets;
        uint64 roundEnd;
        /// @dev Forces the 7-day cooldown on the next hide vote regardless of `keepNfts`, set only when the owner's
        ///      `setState(VISIBLE)` closes a round that had started; cleared once a new round actually opens.
        bool ownerCooldown;
        /// @dev Distinct NFT *owners* (via `ownerOf`, not the caller) behind this round's hide votes: the real gate
        ///      `_won` checks against `MIN_WALLETS`, so delegating one holder's NFTs to extra hot wallets raises
        ///      `hideWallets` but not this. Not returned by `status`.
        uint16 hideOwners;
    }

    struct Item {
        address vault;
        uint8 kind;
        uint256 id;
    }

    mapping(bytes32 => ItemState) private _items;
    /// @dev roundKey = keccak256(key, round) => tokenId word (id >> 8) => bitmap; a tokenId counts once per round.
    mapping(bytes32 => mapping(uint256 => uint256)) private _usedTokens;
    /// @dev roundKey => wallet => 0 (none) / 1 (hide) / 2 (keep); one side per wallet per round, like VoteLib.
    mapping(bytes32 => mapping(address => uint8)) private _walletSide;
    /// @dev roundKey => NFT owner (not caller) already counted toward `hideWallets` this round.
    mapping(bytes32 => mapping(address => bool)) private _hideOwnerSeen;

    event StateSet(address indexed vault, uint8 indexed kind, uint256 indexed id, uint8 state);
    event HideVote(
        address indexed vault, uint8 indexed kind, uint256 indexed id, address voter, bool hide, uint256 counted, uint64 roundEnd
    );

    error NotOwner();
    error ZeroAddress();
    error BadState();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param owner_ the project treasury wallet; fixed for good, no transfer function exists
    /// @param nft_ identity.md ERC-721
    /// @param delegateRegistry_ delegate.xyz v2; address(0) disables delegated votes
    constructor(address owner_, address nft_, address delegateRegistry_) {
        if (owner_ == address(0) || nft_ == address(0)) revert ZeroAddress();
        owner = owner_;
        nft = nft_;
        delegateRegistry = delegateRegistry_;
    }

    // ------------------------------------------------------------------ owner

    /// @notice Sets the state of a batch of items at once. Instant, no timelock. Always closes whatever vote round
    ///         is open on each item and clears its tally, so the owner's word stands until a fresh round passes.
    ///         Restoring `VISIBLE` over an item that had a round running or closed starts the same 7-day cooldown a
    ///         contested vote would (finding 13c): the cluster the owner just overruled cannot reopen it that day.
    function setState(Item[] calldata items, uint8 state) external onlyOwner {
        if (state > KEPT) revert BadState();
        uint256 n = items.length;
        for (uint256 i; i < n; ++i) {
            Item calldata it = items[i];
            bytes32 k = _key(it.vault, it.kind, it.id);
            ItemState storage s = _items[k];
            bool hadRound = s.roundEnd != 0;
            s.state = state;
            s.round += 1;
            s.hideNfts = 0;
            s.keepNfts = 0;
            s.hideWallets = 0;
            s.hideOwners = 0;
            bool restoring = state == VISIBLE && hadRound;
            s.roundEnd = restoring ? uint64(block.timestamp) : 0;
            s.ownerCooldown = restoring;
            emit StateSet(it.vault, it.kind, it.id, state);
        }
    }

    // ------------------------------------------------------------------ votes

    /// @notice An NFT holder (or its delegate.xyz delegate) votes to hide or keep an item. The first `hide` vote on
    ///         a `VISIBLE` item with no round running opens a 24h round, unless the previous round already passed
    ///         (only the owner can change that now) or it ended less than 7 days ago. Bad tokenIds (not owned or
    ///         delegated to the caller, already used this round) are skipped, never revert; a wallet keeps one side
    ///         per round. A round is opened only once the call is known to count at least one NFT, so an empty or
    ///         all-bad `tokenIds` array cannot burn a round or start a cooldown.
    function vote(address vault, uint8 kind, uint256 id, bool hide, uint256[] calldata tokenIds) external {
        ItemState storage s = _items[_key(vault, kind, id)];
        if (s.state != VISIBLE) return;

        bool activeRound = s.roundEnd != 0 && block.timestamp < s.roundEnd;
        uint32 round = s.round;
        if (!activeRound) {
            if (!hide) return; // nothing open to defend
            if (s.roundEnd != 0) {
                if (_won(s)) return; // a passed round stands until the owner changes it
                // cooldown only after a round that was actually contested (drew a keep vote) or that the owner just
                // overruled back to VISIBLE; an uncontested round (nobody defended, nobody watching) may be retried
                // at once, so one lone NFT cannot keep an item un-hideable by reopening an empty round every 8 days
                // (audit round 2, finding 13b)
                if ((s.keepNfts > 0 || s.ownerCooldown) && block.timestamp < s.roundEnd + COOLDOWN) return;
            }
            round += 1; // the round this vote would open, used only to scope its bitmap below; not stored yet
        }
        bytes32 rk = keccak256(abi.encode(vault, kind, id, round));

        uint256 counted = _applyVote(s, rk, round, hide, activeRound, tokenIds);
        if (counted != 0) emit HideVote(vault, kind, id, msg.sender, hide, counted, s.roundEnd);
    }

    /// @dev One wallet, one side per round; counts qualifying `tokenIds` (and distinct hide owners, finding 13a);
    ///      opens the round's storage (committing `round`) on a first qualifying vote, never on an empty or all-bad
    ///      `tokenIds`; extends a near-end round that just passed by hide (finding 13c). Returns 0 (no state change)
    ///      if nothing in `tokenIds` qualified.
    function _applyVote(
        ItemState storage s,
        bytes32 rk,
        uint32 round,
        bool hide,
        bool activeRound,
        uint256[] calldata tokenIds
    ) private returns (uint256 counted) {
        uint8 side = hide ? 1 : 2;
        uint8 seen = _walletSide[rk][msg.sender];
        if (seen != 0 && seen != side) return 0; // one wallet, one side per round

        uint256 newHideOwners;
        (counted, newHideOwners) = _countTokens(rk, hide, tokenIds);
        if (counted == 0) return 0;

        if (!activeRound) {
            s.round = round;
            s.hideNfts = 0;
            s.keepNfts = 0;
            s.hideWallets = 0;
            s.hideOwners = 0;
            s.roundEnd = uint64(block.timestamp + ROUND);
            s.ownerCooldown = false;
        }
        if (seen == 0) {
            _walletSide[rk][msg.sender] = side;
            if (hide) ++s.hideWallets;
        }
        if (hide) {
            s.hideNfts += uint32(counted);
            s.hideOwners += uint16(newHideOwners);
        } else {
            s.keepNfts += uint32(counted);
        }

        // a hide vote inside the round's last hour that makes the round pass gets a 1h reply window instead of
        // closing the round before the keep side can answer (audit round 2, finding 13c)
        if (hide && activeRound && block.timestamp + 1 hours >= s.roundEnd && _won(s)) {
            uint64 extended = uint64(block.timestamp + 1 hours);
            if (extended > s.roundEnd) s.roundEnd = extended;
        }
    }

    // ------------------------------------------------------------------ view

    /// @notice `state` is the owner's state if one was set; otherwise `HIDDEN_BY_VOTE` once a round has closed
    ///         (`block.timestamp >= roundEnd`) and passed, else `VISIBLE`. No settle transaction: this is computed
    ///         fresh on every read.
    function status(address vault, uint8 kind, uint256 id)
        external
        view
        returns (uint8 state, uint32 hideNfts, uint32 keepNfts, uint16 hideWallets, uint64 roundEnd)
    {
        ItemState storage s = _items[_key(vault, kind, id)];
        state = s.state;
        if (state == VISIBLE && s.roundEnd != 0 && block.timestamp >= s.roundEnd && _won(s)) {
            state = HIDDEN_BY_VOTE;
        }
        hideNfts = s.hideNfts;
        keepNfts = s.keepNfts;
        hideWallets = s.hideWallets;
        roundEnd = s.roundEnd;
    }

    // ------------------------------------------------------------------ internal

    function _key(address vault, uint8 kind, uint256 id) private pure returns (bytes32) {
        return keccak256(abi.encode(vault, kind, id));
    }

    /// @dev The >= 3 distinct hide wallets bar is checked against `hideOwners` (real NFT owners), not the public
    ///      `hideWallets` (distinct callers): a holder delegating to extra hot wallets raises the latter but not the
    ///      former, so it cannot pass the round alone (finding 13a).
    function _won(ItemState storage s) private view returns (bool) {
        return s.hideNfts >= QUORUM_NFTS && s.hideNfts > s.keepNfts && s.hideOwners >= MIN_WALLETS;
    }

    /// @dev Marks each of `tokenIds` used this round (`rk`) that `msg.sender` may vote with and was not already
    ///      used; `counted` is how many qualified, `newHideOwners` how many of those (for a hide vote) belong to an
    ///      NFT owner not yet counted toward `hideOwners` this round (finding 13a).
    function _countTokens(bytes32 rk, bool hide, uint256[] calldata tokenIds)
        private
        returns (uint256 counted, uint256 newHideOwners)
    {
        uint256 len = tokenIds.length;
        for (uint256 i; i < len; ++i) {
            uint256 id_ = tokenIds[i];
            uint256 word = id_ >> 8;
            uint256 bit = 1 << (id_ & 0xff);
            uint256 bits = _usedTokens[rk][word];
            if (bits & bit != 0) continue;
            address holder = _mayVote(id_, msg.sender);
            if (holder == address(0)) continue;
            _usedTokens[rk][word] = bits | bit;
            ++counted;
            if (hide && !_hideOwnerSeen[rk][holder]) {
                _hideOwnerSeen[rk][holder] = true;
                ++newHideOwners;
            }
        }
    }

    /// @dev `voter` owns `id` now, or is a delegate.xyz delegate of its current owner; returns the real owner (never
    ///      `voter` unless he is the owner), so `hideWallets` counts owners, not the caller. Never reverts.
    function _mayVote(uint256 id, address voter) private view returns (address holder) {
        try IERC721(nft).ownerOf(id) returns (address o) {
            holder = o;
        } catch {
            return address(0);
        }
        if (holder == address(0)) return address(0);
        if (holder == voter) return holder;
        if (delegateRegistry == address(0)) return address(0);
        try IDelegateRegistry(delegateRegistry).checkDelegateForERC721(voter, holder, nft, id, bytes32(0)) returns (
            bool ok
        ) {
            return ok ? holder : address(0);
        } catch {
            return address(0);
        }
    }
}
