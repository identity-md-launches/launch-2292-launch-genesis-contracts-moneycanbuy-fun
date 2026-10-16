// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IDelegateRegistry} from "../interfaces/IDelegateRegistry.sol";

interface IBallotChecker {
    function check(Ballot[] calldata ballots, VoteLib.Context calldata ctx)
        external
        view
        returns (bool[] memory sigOk, bool[][] memory mayVote);
}

/// @notice One signed NFT vote: a holder (or a delegate.xyz hot wallet) votes with several tokenIds at once.
/// @param voter   the signer (EOA or ERC-1271 wallet); must own every counted tokenId or be its delegate
/// @param side    1 = the doer is right (accept), 2 = the disputers are right (reject)
/// @param payTo   receiver of the vote rewards (penalty share and NFT pool share)
struct Ballot {
    address voter;
    uint8 side;
    address payTo;
    uint256[] tokenIds;
    bytes signature;
}

/// @notice Per-submission vote storage.
struct VoteBook {
    mapping(uint256 => uint256) usedTokens; // tokenId >> 8 => bitmap; a tokenId counts once per submission
    mapping(address => uint8) walletSides; // voter => the side it voted (1 accept, 2 reject): one side per wallet
    mapping(address => uint256) acceptVotesOf; // payTo => counted NFTs on side 1
    mapping(address => uint256) rejectVotesOf; // payTo => counted NFTs on side 2
    mapping(address => uint8) claimed; // payTo => 1 when the voter reward was claimed
}

/// @title VoteLib
/// @notice Verifies batches of EIP-712 NFT votes. Ownership (`ownerOf`) or delegation is checked at the moment
///         the batch is submitted; a bitmap per submission makes every tokenId count at most once, so replaying a
///         signature, re-voting after selling the NFT, or voting twice with the same NFT adds nothing. A wallet votes
///         one side per submission: a ballot of a voter who already voted the other side is skipped (reason 4).
///         Invalid entries are skipped, never reverted, so one bad ballot cannot block a batch.
///         Internal: runs inside DisputeDesk, which owns the vote books.
library VoteLib {
    bytes32 internal constant VOTE_TYPEHASH =
        keccak256("Vote(uint256 subId,uint8 side,uint256[] tokenIds,uint64 voteEnd,address payTo)");

    uint8 internal constant SIDE_ACCEPT = 1;
    uint8 internal constant SIDE_REJECT = 2;

    struct Context {
        uint256 subId;
        uint64 voteEnd;
        bytes32 domainSeparator;
        address nft;
        address delegateRegistry;
    }

    struct Result {
        uint256 accept; // newly counted NFTs for side 1
        uint256 reject; // newly counted NFTs for side 2
        uint256 acceptWallets; // new distinct voters on side 1
        uint256 rejectWallets; // new distinct voters on side 2
    }

    event VoteCounted(uint256 indexed subId, address indexed voter, address indexed payTo, uint8 side, uint256 counted);
    event BallotSkipped(uint256 indexed subId, address indexed voter, uint8 reason);

    /// @dev Signatures and ownership are checked by the stateless BallotChecker (one STATICCALL per batch); the vote
    ///      book is updated here, inside the DisputeDesk.
    function castBallots(VoteBook storage book, Ballot[] calldata ballots, Context memory ctx, IBallotChecker checker)
        internal
        returns (Result memory r)
    {
        (bool[] memory sigOk, bool[][] memory mayVote) = checker.check(ballots, ctx);
        for (uint256 i; i < ballots.length; ++i) {
            Ballot calldata b = ballots[i];
            if (!wellFormed(b)) {
                emit BallotSkipped(ctx.subId, b.voter, 1);
                continue;
            }
            if (!sigOk[i]) {
                emit BallotSkipped(ctx.subId, b.voter, 2);
                continue;
            }
            uint8 sideBit = b.side; // 1 or 2 doubles as the bit
            uint8 seen = book.walletSides[b.voter];
            if (seen != 0 && seen != sideBit) {
                // this wallet already voted the other side of this submission: one wallet, one side (swarm audit
                // #5); its NFTs stay unused here
                emit BallotSkipped(ctx.subId, b.voter, 4);
                continue;
            }
            uint256 counted;
            for (uint256 j; j < b.tokenIds.length; ++j) {
                uint256 id = b.tokenIds[j];
                uint256 word = id >> 8;
                uint256 bit = 1 << (id & 0xff);
                uint256 bits = book.usedTokens[word];
                if (bits & bit != 0) continue; // this NFT already voted on this submission
                if (!mayVote[i][j]) continue;
                book.usedTokens[word] = bits | bit;
                ++counted;
            }
            if (counted == 0) {
                emit BallotSkipped(ctx.subId, b.voter, 3);
                continue;
            }
            if (seen == 0) {
                book.walletSides[b.voter] = sideBit;
                if (b.side == SIDE_ACCEPT) ++r.acceptWallets;
                else ++r.rejectWallets;
            }
            if (b.side == SIDE_ACCEPT) {
                book.acceptVotesOf[b.payTo] += counted;
                r.accept += counted;
            } else {
                book.rejectVotesOf[b.payTo] += counted;
                r.reject += counted;
            }
            emit VoteCounted(ctx.subId, b.voter, b.payTo, b.side, counted);
        }
    }

    function wellFormed(Ballot calldata b) internal pure returns (bool) {
        return (b.side == SIDE_ACCEPT || b.side == SIDE_REJECT) && b.payTo != address(0) && b.tokenIds.length != 0;
    }

    function hashVote(Context memory ctx, Ballot calldata b) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(VOTE_TYPEHASH, ctx.subId, b.side, keccak256(abi.encodePacked(b.tokenIds)), ctx.voteEnd, b.payTo)
        );
    }
}

/// @title BallotChecker
/// @notice Stateless helper of the DisputeDesk: for every ballot of a batch, whether its EIP-712 signature is valid
///         and, per tokenId, whether the voter owns it now or is a delegate.xyz delegate of its owner. Never reverts
///         on a bad ballot. Malformed ballots (VoteLib.wellFormed) and ballots with a bad signature get no
///         ownership checks.
contract BallotChecker {
    function check(Ballot[] calldata ballots, VoteLib.Context calldata ctx)
        external
        view
        returns (bool[] memory sigOk, bool[][] memory mayVote)
    {
        sigOk = new bool[](ballots.length);
        mayVote = new bool[][](ballots.length);
        for (uint256 i; i < ballots.length; ++i) {
            Ballot calldata b = ballots[i];
            if (!VoteLib.wellFormed(b)) continue;
            bytes32 digest = MessageHashUtils.toTypedDataHash(ctx.domainSeparator, VoteLib.hashVote(ctx, b));
            if (!_validSignature(b.voter, digest, b.signature)) continue;
            sigOk[i] = true;
            bool[] memory may = new bool[](b.tokenIds.length);
            for (uint256 j; j < b.tokenIds.length; ++j) {
                may[j] = _mayVote(ctx, b.voter, b.tokenIds[j]);
            }
            mayVote[i] = may;
        }
    }

    /// @dev Gas an ERC-1271 wallet may use to check one ballot. Without a cap, a wallet that burns the gas it gets
    ///      (63/64 of what is left, twice) reverts the whole batch out of gas (audit C, C-03); with it, such a ballot
    ///      is skipped like any bad one. Far above what a real wallet (multisig, passkey verifier) needs.
    uint256 private constant ERC1271_GAS = 500_000;

    /// @dev A plain key signature first (also for EOAs with an EIP-7702 delegation, which have code), then
    ///      ERC-1271 for contract wallets. OZ 5.1 SignatureChecker tries only ERC-1271 once the address has code.
    ///      The ERC-1271 call gets at most ERC1271_GAS and at most 32 bytes of its return data are copied.
    function _validSignature(address voter, bytes32 digest, bytes calldata signature) private view returns (bool) {
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err == ECDSA.RecoverError.NoError && signer == voter) return true;
        if (voter.code.length == 0) return false;
        bytes memory data = abi.encodeCall(IERC1271.isValidSignature, (digest, signature));
        bytes32 magic = bytes32(IERC1271.isValidSignature.selector);
        bool ok;
        assembly ("memory-safe") {
            let success := staticcall(ERC1271_GAS, voter, add(data, 0x20), mload(data), 0x00, 0x20)
            ok := and(success, and(gt(returndatasize(), 0x1f), eq(mload(0x00), magic)))
        }
        return ok;
    }

    /// @dev `voter` owns `id` now, or is a delegate.xyz delegate of the current owner. Never reverts.
    function _mayVote(VoteLib.Context calldata ctx, address voter, uint256 id) private view returns (bool) {
        address owner;
        try IERC721(ctx.nft).ownerOf(id) returns (address o) {
            owner = o;
        } catch {
            return false;
        }
        if (owner == address(0)) return false;
        if (owner == voter) return true;
        if (ctx.delegateRegistry == address(0)) return false;
        try IDelegateRegistry(ctx.delegateRegistry)
            .checkDelegateForERC721(voter, owner, ctx.nft, id, bytes32(0)) returns (
            bool ok
        ) {
            return ok;
        } catch {
            return false;
        }
    }
}
