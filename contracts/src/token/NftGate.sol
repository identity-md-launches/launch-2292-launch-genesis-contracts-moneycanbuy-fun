// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IDelegateRegistry} from "../interfaces/IDelegateRegistry.sol";

interface IERC721Owner {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @title NftGate
/// @notice Who may buy $YOLO in its first 30 minutes, and how much: identity.md NFT holders, 500,000 YOLO per
///         registered NFT. The holder (or a delegate.xyz v2 delegate of the holder, for cold wallets) registers NFTs
///         to the calling wallet, before the pool opens or during the window. An NFT is bound to that wallet for
///         good: moving it afterwards gives nobody a second allowance. A wallet's allowance is the sum over the NFTs
///         bound to it.
///         The token decides when the gate applies (it calls `consume` for a buy in its window); the gate has no
///         clock, no owner and nothing to change. It keeps the use per calling token, so a contract other than $YOLO
///         calling it only ever spends its own books: the gate needs no token address in advance.
///         It never calls back into the token and holds no funds.
contract NftGate {
    /// @notice YOLO a registered NFT lets its wallet buy in the window (0.05% of the supply)
    uint256 public constant ALLOWANCE_PER_NFT = 500_000e18;

    IERC721Owner public immutable nft;
    IDelegateRegistry public immutable delegateRegistry;

    /// @notice the wallet an NFT is registered to (zero: not registered)
    mapping(uint256 tokenId => address) public boundTo;
    /// @notice NFTs registered to a wallet
    mapping(address account => uint256) public nftsOf;
    /// @notice what a calling token has let a buyer take so far
    mapping(address token => mapping(address buyer => uint256)) public used;
    /// @notice NFTs registered in total
    uint256 public registeredCount;

    event Registered(address indexed account, uint256 indexed tokenId);

    error AlreadyRegistered(uint256 tokenId, address account);
    error NotOwnerOrDelegate(uint256 tokenId, address owner);
    error NoTokens();

    /// @param nft_ the identity.md NFT
    /// @param delegateRegistry_ delegate.xyz v2
    constructor(address nft_, address delegateRegistry_) {
        nft = IERC721Owner(nft_);
        delegateRegistry = IDelegateRegistry(delegateRegistry_);
    }

    /// @notice Register NFTs to the caller: each must be the caller's or delegated to the caller by its owner (the
    ///         whole wallet, this NFT contract or this token id). Each NFT once, for good.
    function register(uint256[] calldata tokenIds) external {
        uint256 n = tokenIds.length;
        if (n == 0) revert NoTokens();
        for (uint256 i; i < n; ++i) {
            uint256 id = tokenIds[i];
            address bound = boundTo[id];
            if (bound != address(0)) revert AlreadyRegistered(id, bound);
            address owner = nft.ownerOf(id);
            if (
                owner != msg.sender
                    && !delegateRegistry.checkDelegateForERC721(msg.sender, owner, address(nft), id, bytes32(0))
            ) revert NotOwnerOrDelegate(id, owner);
            boundTo[id] = msg.sender;
            emit Registered(msg.sender, id);
        }
        nftsOf[msg.sender] += n;
        registeredCount += n;
    }

    /// @notice A wallet's whole window allowance.
    function allowanceOf(address account) public view returns (uint256) {
        return nftsOf[account] * ALLOWANCE_PER_NFT;
    }

    /// @notice What `buyer` may still take from `token`.
    function left(address token, address buyer) external view returns (uint256) {
        return allowanceOf(buyer) - used[token][buyer];
    }

    /// @notice Called by a token for a buy in its window. Returns the buyer's allowance and what the calling token
    ///         had let him take before; books `amount` only if it fits. The token rejects the buy otherwise.
    function consume(address buyer, uint256 amount) external returns (uint256 allowance, uint256 usedBefore) {
        allowance = allowanceOf(buyer);
        usedBefore = used[msg.sender][buyer];
        if (amount <= allowance - usedBefore) used[msg.sender][buyer] = usedBefore + amount;
    }
}
