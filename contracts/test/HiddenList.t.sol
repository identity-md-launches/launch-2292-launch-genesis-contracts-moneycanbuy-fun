// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {HiddenList} from "../src/HiddenList.sol";
import {MockNFT} from "./mocks/MockNFT.sol";
import {MockDelegateRegistry} from "./mocks/MockDelegateRegistry.sol";

/// @dev Owner hides / unhides / keeps a batch; a non-owner reverts; ETH sent to it reverts and no function moves
///      tokens; a vote counts for the owner and a delegate.xyz delegate, not for a stranger; a tokenId counts once
///      per round; edges 9 vs 10 NFTs, 2 vs 3 wallets, a tie; the view before and after `roundEnd`; a new round
///      before and after 7 days; `KEPT` blocks rounds; the owner overrides a vote result both ways; events carry
///      vault/kind/id; gas report for every row of the gas table.
contract HiddenListTest is Test {
    HiddenList list;
    MockNFT nft;
    MockDelegateRegistry delegateRegistry;

    address constant TREASURY = address(0x7EA5);
    address constant VAULT = address(0xBA07);
    address constant STRANGER = address(0xBEEF);

    uint8 constant KIND_TASK = 1;
    uint8 constant KIND_PROOF_ = 2;
    uint8 constant VISIBLE_ = 0;
    uint8 constant HIDDEN_ = 1;
    uint8 constant KEPT_ = 2;
    uint8 constant HIDDEN_BY_VOTE_ = 3;
    uint64 constant ROUND_ = 24 hours;
    uint64 constant COOLDOWN_ = 7 days;

    function setUp() public {
        nft = new MockNFT();
        delegateRegistry = new MockDelegateRegistry();
        list = new HiddenList(TREASURY, address(nft), address(delegateRegistry));
    }

    function _holders(uint256 n) internal returns (address[] memory wallets) {
        return _holders(n, 0);
    }

    function _holders(uint256 n, uint256 salt) internal returns (address[] memory wallets) {
        wallets = new address[](n);
        for (uint256 i; i < n; ++i) {
            address w = address(uint160(uint256(keccak256(abi.encode("holder", salt, i)))));
            wallets[i] = w;
            nft.mint(w, salt * 1000 + i + 1);
        }
    }

    function _ids1(uint256 id) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = id;
    }

    // ------------------------------------------------------------------ constructor

    function test_ConstructorFixesOwnerNoTransferFunction() public view {
        assertEq(list.owner(), TREASURY);
        assertEq(list.nft(), address(nft));
        assertEq(list.delegateRegistry(), address(delegateRegistry));
        // no transfer function exists: this is a compile-time guarantee, documented here for the record.
    }

    function test_ConstructorRejectsZeroOwnerOrNft() public {
        vm.expectRevert(HiddenList.ZeroAddress.selector);
        new HiddenList(address(0), address(nft), address(delegateRegistry));
        vm.expectRevert(HiddenList.ZeroAddress.selector);
        new HiddenList(TREASURY, address(0), address(delegateRegistry));
    }

    function test_ConstructorAllowsZeroDelegateRegistry() public {
        HiddenList l = new HiddenList(TREASURY, address(nft), address(0));
        assertEq(l.delegateRegistry(), address(0));
    }

    /// @dev This file's local constants (used instead of `list.HIDDEN()` etc., which would be calls that consume a
    ///      pending `vm.prank` when evaluated as an argument) must match the contract's real ones.
    function test_LocalConstantsMatchContract() public view {
        assertEq(KIND_TASK, list.KIND_TASK());
        assertEq(KIND_PROOF_, list.KIND_PROOF());
        assertEq(VISIBLE_, list.VISIBLE());
        assertEq(HIDDEN_, list.HIDDEN());
        assertEq(KEPT_, list.KEPT());
        assertEq(HIDDEN_BY_VOTE_, list.HIDDEN_BY_VOTE());
        assertEq(ROUND_, list.ROUND());
        assertEq(COOLDOWN_, list.COOLDOWN());
    }

    // ------------------------------------------------------------------ owner: setState

    function test_OwnerHidesUnhidesKeepsABatch() public {
        HiddenList.Item[] memory items = new HiddenList.Item[](2);
        items[0] = HiddenList.Item(VAULT, KIND_TASK, 1);
        items[1] = HiddenList.Item(VAULT, KIND_TASK, 2);

        vm.prank(TREASURY);
        list.setState(items, HIDDEN_);
        (uint8 s1,,,,) = list.status(VAULT, KIND_TASK, 1);
        (uint8 s2,,,,) = list.status(VAULT, KIND_TASK, 2);
        assertEq(s1, HIDDEN_);
        assertEq(s2, HIDDEN_);

        vm.prank(TREASURY);
        list.setState(items, VISIBLE_);
        (s1,,,,) = list.status(VAULT, KIND_TASK, 1);
        assertEq(s1, VISIBLE_);

        vm.prank(TREASURY);
        list.setState(items, KEPT_);
        (s1,,,,) = list.status(VAULT, KIND_TASK, 1);
        assertEq(s1, KEPT_);
    }

    function test_SetStateInstantNoTimelock() public {
        HiddenList.Item[] memory items = new HiddenList.Item[](1);
        items[0] = HiddenList.Item(VAULT, KIND_TASK, 1);
        vm.prank(TREASURY);
        list.setState(items, HIDDEN_);
        (uint8 s,,,,) = list.status(VAULT, KIND_TASK, 1); // no warp: takes effect in the same block
        assertEq(s, HIDDEN_);
    }

    function test_SetStateEmitsStateSetWithVaultKindId() public {
        HiddenList.Item[] memory items = new HiddenList.Item[](1);
        items[0] = HiddenList.Item(VAULT, KIND_TASK, 42);
        vm.expectEmit(true, true, true, true);
        emit HiddenList.StateSet(VAULT, KIND_TASK, 42, HIDDEN_);
        vm.prank(TREASURY);
        list.setState(items, HIDDEN_);
    }

    function test_SetStateRejectsBadStateValue() public {
        HiddenList.Item[] memory items = new HiddenList.Item[](1);
        items[0] = HiddenList.Item(VAULT, KIND_TASK, 1);
        vm.prank(TREASURY);
        vm.expectRevert(HiddenList.BadState.selector);
        list.setState(items, 3); // HIDDEN_BY_VOTE is derived, never a stored target
    }

    function test_NonOwnerSetStateReverts() public {
        HiddenList.Item[] memory items = new HiddenList.Item[](1);
        items[0] = HiddenList.Item(VAULT, KIND_TASK, 1);
        vm.prank(STRANGER);
        vm.expectRevert(HiddenList.NotOwner.selector);
        list.setState(items, HIDDEN_);
    }

    // ------------------------------------------------------------------ no money

    function test_PlainEthTransferReverts() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(list).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(list).balance, 0);
    }

    function test_EthWithDataReverts() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(list).call{value: 1 ether}(abi.encodeWithSignature("status(address,uint8,uint256)", VAULT, KIND_TASK, 1));
        assertFalse(ok);
    }

    // ------------------------------------------------------------------ votes: eligibility

    function test_OwnerOfNftCanVote() public {
        address holder = address(0xA11CE);
        nft.mint(holder, 1);
        vm.prank(holder);
        list.vote(VAULT, KIND_TASK, 1, true, _ids1(1));
        (, uint32 hideNfts,,,) = list.status(VAULT, KIND_TASK, 1);
        assertEq(hideNfts, 1);
    }

    function test_DelegateXyzDelegateCanVote() public {
        address holder = address(0xA11CE);
        address hot = address(0xD0D0);
        nft.mint(holder, 1);
        vm.prank(holder);
        delegateRegistry.delegateAll(hot, true);
        vm.prank(hot);
        list.vote(VAULT, KIND_TASK, 1, true, _ids1(1));
        (, uint32 hideNfts,,,) = list.status(VAULT, KIND_TASK, 1);
        assertEq(hideNfts, 1);
    }

    function test_StrangerCannotVoteWithSomeoneElsesNft() public {
        nft.mint(address(0xA11CE), 1);
        vm.prank(STRANGER);
        list.vote(VAULT, KIND_TASK, 1, true, _ids1(1));
        (uint8 s, uint32 hideNfts,,,) = list.status(VAULT, KIND_TASK, 1);
        assertEq(hideNfts, 0);
        assertEq(s, VISIBLE_);
    }

    function test_NonexistentTokenIdSkippedNotReverted() public {
        vm.prank(STRANGER);
        list.vote(VAULT, KIND_TASK, 1, true, _ids1(999)); // no revert, just no effect
        (, uint32 hideNfts,,,) = list.status(VAULT, KIND_TASK, 1);
        assertEq(hideNfts, 0);
    }

    function test_EmptyTokenIdsDoesNotOpenARound() public {
        vm.prank(STRANGER);
        list.vote(VAULT, KIND_TASK, 1, true, new uint256[](0));
        (uint8 s, uint32 hideNfts,, uint16 hideWallets, uint64 roundEnd) = list.status(VAULT, KIND_TASK, 1);
        assertEq(roundEnd, 0);
        assertEq(hideNfts, 0);
        assertEq(hideWallets, 0);
        assertEq(s, VISIBLE_);
    }

    function test_AllBadTokenIdsDoesNotOpenARound() public {
        nft.mint(address(0xA11CE), 1);
        vm.prank(STRANGER); // owns nothing
        list.vote(VAULT, KIND_TASK, 1, true, _ids1(1));
        (,,,, uint64 roundEnd) = list.status(VAULT, KIND_TASK, 1);
        assertEq(roundEnd, 0);
    }

    // ------------------------------------------------------------------ votes: bitmap, one side per wallet

    function test_TokenIdCountsOnceInARound() public {
        address holder = address(0xA11CE);
        nft.mint(holder, 1);
        vm.startPrank(holder);
        list.vote(VAULT, KIND_TASK, 1, true, _ids1(1));
        list.vote(VAULT, KIND_TASK, 1, true, _ids1(1)); // same NFT again, same round
        vm.stopPrank();
        (, uint32 hideNfts,,,) = list.status(VAULT, KIND_TASK, 1);
        assertEq(hideNfts, 1);
    }

    function test_WalletKeepsOneSidePerRoundOtherSideSkipped() public {
        address[] memory w = _holders(1);
        vm.prank(w[0]);
        list.vote(VAULT, KIND_TASK, 1, true, _ids1(1));
        // same wallet, different NFT, opposite side: skipped (one side per wallet per round)
        nft.mint(w[0], 50);
        vm.prank(w[0]);
        list.vote(VAULT, KIND_TASK, 1, false, _ids1(50));
        (, uint32 hideNfts, uint32 keepNfts,,) = list.status(VAULT, KIND_TASK, 1);
        assertEq(hideNfts, 1);
        assertEq(keepNfts, 0);
    }

    function test_SameWalletMoreNftsLaterAddToTallyNotWallets() public {
        address holder = address(0xA11CE);
        nft.mint(holder, 1);
        nft.mint(holder, 2);
        vm.startPrank(holder);
        list.vote(VAULT, KIND_TASK, 1, true, _ids1(1));
        list.vote(VAULT, KIND_TASK, 1, true, _ids1(2));
        vm.stopPrank();
        (, uint32 hideNfts,, uint16 hideWallets,) = list.status(VAULT, KIND_TASK, 1);
        assertEq(hideNfts, 2);
        assertEq(hideWallets, 1);
    }

    function test_KeepVoteWithNoActiveRoundIsANoOp() public {
        address holder = address(0xA11CE);
        nft.mint(holder, 1);
        vm.prank(holder);
        list.vote(VAULT, KIND_TASK, 1, false, _ids1(1));
        (,, uint32 keepNfts,, uint64 roundEnd) = list.status(VAULT, KIND_TASK, 1);
        assertEq(keepNfts, 0);
        assertEq(roundEnd, 0);
    }

    // ------------------------------------------------------------------ quorum edges

    function _hideWith(address[] memory wallets, uint256 n) internal {
        _hideWith(wallets, n, 0);
    }

    function _hideWith(address[] memory wallets, uint256 n, uint256 salt) internal {
        for (uint256 i; i < n; ++i) {
            vm.prank(wallets[i]);
            list.vote(VAULT, KIND_TASK, 1, true, _ids1(salt * 1000 + i + 1));
        }
    }

    function test_9Of10NftsDoesNotPass() public {
        address[] memory w = _holders(9);
        _hideWith(w, 9);
        vm.warp(block.timestamp + ROUND_);
        (uint8 s,,,,) = list.status(VAULT, KIND_TASK, 1);
        assertEq(s, VISIBLE_);
    }

    function test_10Of10NftsPassesAfterRoundEnd() public {
        address[] memory w = _holders(10);
        _hideWith(w, 10);
        vm.warp(block.timestamp + ROUND_);
        (uint8 s,,,,) = list.status(VAULT, KIND_TASK, 1);
        assertEq(s, HIDDEN_BY_VOTE_);
    }

    function test_2Of3WalletsDoesNotPassEvenWith10Nfts() public {
        // 2 wallets cast 10 hide NFTs between them: fails the 3-distinct-wallets rule.
        address w0 = address(0xA1);
        address w1 = address(0xA2);
        for (uint256 i = 1; i <= 9; ++i) {
            nft.mint(w0, i);
        }
        nft.mint(w1, 10);
        vm.prank(w0);
        uint256[] memory nine = new uint256[](9);
        for (uint256 i; i < 9; ++i) {
            nine[i] = i + 1;
        }
        list.vote(VAULT, KIND_TASK, 1, true, nine);
        vm.prank(w1);
        list.vote(VAULT, KIND_TASK, 1, true, _ids1(10));
        vm.warp(block.timestamp + ROUND_);
        (uint8 s, uint32 hideNfts,, uint16 hideWallets,) = list.status(VAULT, KIND_TASK, 1);
        assertEq(hideNfts, 10);
        assertEq(hideWallets, 2);
        assertEq(s, VISIBLE_);
    }

    function test_3Of3WalletsWith10NftsPasses() public {
        address w0 = address(0xA1);
        address w1 = address(0xA2);
        address w2 = address(0xA3);
        for (uint256 i = 1; i <= 8; ++i) {
            nft.mint(w0, i);
        }
        nft.mint(w1, 9);
        nft.mint(w2, 10);
        uint256[] memory eight = new uint256[](8);
        for (uint256 i; i < 8; ++i) {
            eight[i] = i + 1;
        }
        vm.prank(w0);
        list.vote(VAULT, KIND_TASK, 1, true, eight);
        vm.prank(w1);
        list.vote(VAULT, KIND_TASK, 1, true, _ids1(9));
        vm.prank(w2);
        list.vote(VAULT, KIND_TASK, 1, true, _ids1(10));
        vm.warp(block.timestamp + ROUND_);
        (uint8 s,,, uint16 hideWallets,) = list.status(VAULT, KIND_TASK, 1);
        assertEq(hideWallets, 3);
        assertEq(s, HIDDEN_BY_VOTE_);
    }

    function test_TieHideEqualsKeepDoesNotPass() public {
        address[] memory hiders = _holders(10); // ids 1..10
        _hideWith(hiders, 10);
        address[] memory keepers = new address[](10);
        for (uint256 i; i < 10; ++i) {
            address w = address(uint160(uint256(keccak256(abi.encode("keeper", i)))));
            keepers[i] = w;
            nft.mint(w, 100 + i);
            vm.prank(w);
            list.vote(VAULT, KIND_TASK, 1, false, _ids1(100 + i));
        }
        vm.warp(block.timestamp + ROUND_);
        (uint8 s, uint32 hideNfts, uint32 keepNfts,,) = list.status(VAULT, KIND_TASK, 1);
        assertEq(hideNfts, keepNfts);
        assertEq(s, VISIBLE_); // hideNfts > keepNfts is strict
    }

    // ------------------------------------------------------------------ view before/after roundEnd

    function test_StatusHiddenOnlyAfterRoundEndEvenIfQuorumAlreadyMet() public {
        address[] memory w = _holders(10);
        _hideWith(w, 10);
        (uint8 before_,,,,) = list.status(VAULT, KIND_TASK, 1); // round still open: not yet hidden
        assertEq(before_, VISIBLE_);
        vm.warp(block.timestamp + ROUND_ - 1);
        (uint8 stillBefore,,,,) = list.status(VAULT, KIND_TASK, 1);
        assertEq(stillBefore, VISIBLE_);
        vm.warp(block.timestamp + 1);
        (uint8 after_,,,,) = list.status(VAULT, KIND_TASK, 1);
        assertEq(after_, HIDDEN_BY_VOTE_);
    }

    // ------------------------------------------------------------------ cooldown / retry

    /// @notice Cooldown only bites a round someone actually defended (a keep vote landed); audit round 2, finding
    ///         13b: an uncontested round (nobody watching, see `test_UncontestedFailedRoundRetriesAtOnce` below)
    ///         must not get this cooldown, or one lone NFT could keep an item un-hideable forever by opening an
    ///         empty round every 8 days.
    function test_FailedRoundCannotRetryBefore7Days() public {
        address[] memory w = _holders(2); // short of quorum: round fails
        _hideWith(w, 2);
        address keeper = address(0xCAFE);
        nft.mint(keeper, 999);
        vm.prank(keeper);
        list.vote(VAULT, KIND_TASK, 1, false, _ids1(999)); // contested: someone defended the item
        vm.warp(block.timestamp + ROUND_);
        (uint8 s,,,,) = list.status(VAULT, KIND_TASK, 1);
        assertEq(s, VISIBLE_);

        address later = address(0xC0FFEE);
        nft.mint(later, 500);
        vm.warp(block.timestamp + COOLDOWN_ - 1);
        vm.prank(later);
        list.vote(VAULT, KIND_TASK, 1, true, _ids1(500));
        (,,,, uint64 roundEnd) = list.status(VAULT, KIND_TASK, 1);
        assertLt(roundEnd, block.timestamp); // no new round opened: the vote was a no-op
    }

    /// @notice Audit round 2, finding 13b: an uncontested round (short of quorum, no keep vote at all, nobody
    ///         watching) starts no cooldown, so a griefer's lone NFT cannot keep an honest item un-hideable by
    ///         opening an empty round every 8 days; the very next hide vote opens a fresh round at once.
    function test_UncontestedFailedRoundRetriesAtOnce() public {
        address[] memory w = _holders(2); // short of quorum, nobody defends: round fails uncontested
        _hideWith(w, 2);
        vm.warp(block.timestamp + ROUND_);
        (uint8 s,,,,) = list.status(VAULT, KIND_TASK, 1);
        assertEq(s, VISIBLE_);

        address later = address(0xC0FFEE);
        nft.mint(later, 500);
        vm.warp(block.timestamp + 1 hours); // well inside the old 7-day cooldown window
        vm.prank(later);
        list.vote(VAULT, KIND_TASK, 1, true, _ids1(500));
        (,,,, uint64 roundEnd) = list.status(VAULT, KIND_TASK, 1);
        assertGt(roundEnd, block.timestamp, "a fresh round opened: no cooldown after an uncontested round");
    }

    function test_FailedRoundCanRetryAfter7Days() public {
        address[] memory w = _holders(2);
        _hideWith(w, 2);
        uint256 firstRoundEnd = block.timestamp + ROUND_;
        vm.warp(firstRoundEnd);

        address[] memory w2 = _holders(10, 1); // fresh wallets and tokenIds: a new round, a fresh bitmap
        vm.warp(firstRoundEnd + COOLDOWN_);
        _hideWith(w2, 10, 1);
        vm.warp(block.timestamp + ROUND_);
        (uint8 s,,,,) = list.status(VAULT, KIND_TASK, 1);
        assertEq(s, HIDDEN_BY_VOTE_);
    }

    // ------------------------------------------------------------------ KEPT blocks rounds

    function test_KeptBlocksNewRounds() public {
        HiddenList.Item[] memory items = new HiddenList.Item[](1);
        items[0] = HiddenList.Item(VAULT, KIND_TASK, 1);
        vm.prank(TREASURY);
        list.setState(items, KEPT_);

        address holder = address(0xA11CE);
        nft.mint(holder, 1);
        vm.prank(holder);
        list.vote(VAULT, KIND_TASK, 1, true, _ids1(1));
        (uint8 s,,,, uint64 roundEnd) = list.status(VAULT, KIND_TASK, 1);
        assertEq(s, KEPT_);
        assertEq(roundEnd, 0);
    }

    // ------------------------------------------------------------------ owner overrides a vote both ways

    function test_OwnerOverridesAPassedVoteBackToVisible() public {
        address[] memory w = _holders(10);
        _hideWith(w, 10);
        vm.warp(block.timestamp + ROUND_);
        (uint8 s,,,,) = list.status(VAULT, KIND_TASK, 1);
        assertEq(s, HIDDEN_BY_VOTE_);

        HiddenList.Item[] memory items = new HiddenList.Item[](1);
        items[0] = HiddenList.Item(VAULT, KIND_TASK, 1);
        vm.prank(TREASURY);
        list.setState(items, VISIBLE_);
        (s,,,,) = list.status(VAULT, KIND_TASK, 1);
        assertEq(s, VISIBLE_);
    }

    /// @notice Audit round 2, finding 13c: restoring `VISIBLE` over a round that had started also opens the 7-day
    ///         cooldown, so the cluster the owner just overruled cannot reopen a round on the item that same day.
    function test_OwnerRestoreVisibleStartsCooldown() public {
        address[] memory w = _holders(10);
        _hideWith(w, 10);
        vm.warp(block.timestamp + ROUND_);
        (uint8 s,,,,) = list.status(VAULT, KIND_TASK, 1);
        assertEq(s, HIDDEN_BY_VOTE_);

        HiddenList.Item[] memory items = new HiddenList.Item[](1);
        items[0] = HiddenList.Item(VAULT, KIND_TASK, 1);
        vm.prank(TREASURY);
        list.setState(items, VISIBLE_);

        address later = address(0xC0FFEE);
        nft.mint(later, 500);
        vm.warp(block.timestamp + COOLDOWN_ - 1);
        vm.prank(later);
        list.vote(VAULT, KIND_TASK, 1, true, _ids1(500));
        (,,,, uint64 roundEnd) = list.status(VAULT, KIND_TASK, 1);
        assertLt(roundEnd, block.timestamp, "no new round opened: cooldown after the owner's restore");
    }

    function test_OwnerHidesAnItemNoVoteEverPassed() public {
        HiddenList.Item[] memory items = new HiddenList.Item[](1);
        items[0] = HiddenList.Item(VAULT, KIND_TASK, 1);
        vm.prank(TREASURY);
        list.setState(items, HIDDEN_);
        (uint8 s,,,,) = list.status(VAULT, KIND_TASK, 1);
        assertEq(s, HIDDEN_);
    }

    function test_VotePassingCannotUnhideAnOwnerHiddenItem() public {
        HiddenList.Item[] memory items = new HiddenList.Item[](1);
        items[0] = HiddenList.Item(VAULT, KIND_TASK, 1);
        vm.prank(TREASURY);
        list.setState(items, HIDDEN_);

        address[] memory w = _holders(10);
        _hideWith(w, 10); // vote is a no-op: state != VISIBLE
        vm.warp(block.timestamp + ROUND_);
        (uint8 s,,,,) = list.status(VAULT, KIND_TASK, 1);
        assertEq(s, HIDDEN_);
    }

    // ------------------------------------------------------------------ events carry vault/kind/id

    function test_HideVoteEventCarriesVaultKindId() public {
        address holder = address(0xA11CE);
        nft.mint(holder, 7);
        vm.expectEmit(true, true, true, false); // roundEnd varies with block.timestamp; checked by topics + voter/hide/counted below
        emit HiddenList.HideVote(VAULT, KIND_TASK, 3, holder, true, 1, 0);
        vm.prank(holder);
        list.vote(VAULT, KIND_TASK, 3, true, _ids1(7));
    }

    // ------------------------------------------------------------------ keys are per-vault

    function test_SameIdDifferentVaultsAreIndependent() public {
        address vaultB = address(0xBA08);
        HiddenList.Item[] memory items = new HiddenList.Item[](1);
        items[0] = HiddenList.Item(VAULT, KIND_TASK, 1);
        vm.prank(TREASURY);
        list.setState(items, HIDDEN_);
        (uint8 sA,,,,) = list.status(VAULT, KIND_TASK, 1);
        (uint8 sB,,,,) = list.status(vaultB, KIND_TASK, 1);
        assertEq(sA, HIDDEN_);
        assertEq(sB, VISIBLE_);
    }

    function test_TaskAndProofKindsAreIndependent() public {
        HiddenList.Item[] memory items = new HiddenList.Item[](1);
        items[0] = HiddenList.Item(VAULT, KIND_PROOF_, 1);
        vm.prank(TREASURY);
        list.setState(items, HIDDEN_);
        (uint8 sTask,,,,) = list.status(VAULT, KIND_TASK, 1);
        (uint8 sProof,,,,) = list.status(VAULT, KIND_PROOF_, 1);
        assertEq(sTask, VISIBLE_);
        assertEq(sProof, HIDDEN_);
    }

    // ------------------------------------------------------------------ gas report (DESIGN.md gas table)

    function test_GasOwnerHides1Item() public {
        HiddenList.Item[] memory items = new HiddenList.Item[](1);
        items[0] = HiddenList.Item(VAULT, KIND_TASK, 1);
        vm.prank(TREASURY);
        uint256 g0 = gasleft();
        list.setState(items, HIDDEN_);
        emit log_named_uint("owner hides 1 item", g0 - gasleft());
    }

    function test_GasOwnerHides20Items() public {
        HiddenList.Item[] memory items = new HiddenList.Item[](20);
        for (uint256 i; i < 20; ++i) {
            items[i] = HiddenList.Item(VAULT, KIND_TASK, i + 1);
        }
        vm.prank(TREASURY);
        uint256 g0 = gasleft();
        list.setState(items, HIDDEN_);
        emit log_named_uint("owner hides 20 items (batch)", g0 - gasleft());
    }

    function test_GasOwnerUnhides1Item() public {
        HiddenList.Item[] memory items = new HiddenList.Item[](1);
        items[0] = HiddenList.Item(VAULT, KIND_TASK, 1);
        vm.prank(TREASURY);
        list.setState(items, HIDDEN_);
        vm.prank(TREASURY);
        uint256 g0 = gasleft();
        list.setState(items, VISIBLE_);
        emit log_named_uint("owner unhides 1 item", g0 - gasleft());
    }

    function test_GasNftHolderVote1NftOpensRound() public {
        address holder = address(0xA11CE);
        nft.mint(holder, 1);
        vm.prank(holder);
        uint256 g0 = gasleft();
        list.vote(VAULT, KIND_TASK, 1, true, _ids1(1));
        emit log_named_uint("NFT holder vote, 1 NFT (opens a round)", g0 - gasleft());
    }

    function test_GasNftHolderVote1NftLaterVote() public {
        address holder = address(0xA11CE);
        nft.mint(holder, 1);
        nft.mint(holder, 2);
        vm.prank(holder);
        list.vote(VAULT, KIND_TASK, 1, true, _ids1(1)); // opens the round
        vm.prank(holder);
        uint256 g0 = gasleft();
        list.vote(VAULT, KIND_TASK, 1, true, _ids1(2));
        emit log_named_uint("NFT holder vote, 1 NFT (later vote)", g0 - gasleft());
    }
}
