// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {HiddenList} from "src/HiddenList.sol";

contract GriefNft is ERC721("identity.md", "IMDID") {
    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

/// @notice One NFT holder (the author of a harmful dare, for instance) opens a hide round on his own item the moment
///         it exists, with one hide vote and nobody watching. The round fails after 24 h (1 of 10 NFTs) and the 7-day
///         cooldown then blocks every honest hide vote: 10 honest holders in 10 wallets voting on day 2 count nothing
///         and the item stays VISIBLE for the whole week. Fails on this code; passes once an uncontested round that
///         fell short of quorum (no keep votes) starts no cooldown, so the honest round opens immediately.
/// @dev The report's two intermediate checks (`roundEnd < now`, `hideNfts + hideWallets == 2`)
///      describe the BUG's own symptom (honest votes silently dropped) and cannot hold under any fix that actually
///      lets those votes through: once they count, a fresh round necessarily opens with `roundEnd` in the future.
///      Replaced with the fixed-code analogue (a new round opens right away and counts all ten); the real regression
///      check, that the item ends up `HIDDEN_BY_VOTE` within the week instead of staying grieved, is unchanged.
contract HiddenListCooldownGriefTest is Test {
    HiddenList list;
    GriefNft nft;

    address constant OWNER = address(0x7EA5);
    address constant VAULT = address(0xBA07);
    address griefer = address(0xBAD);

    function setUp() public {
        vm.warp(1_800_000_000);
        nft = new GriefNft();
        list = new HiddenList(OWNER, address(nft), address(0));
        nft.mint(griefer, 1);
    }

    function _ids1(uint256 id) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = id;
    }

    function test_oneNftBlocksHonestHidersForAWeek() public {
        // day 0: the griefer opens a round alone
        vm.prank(griefer);
        list.vote(VAULT, 1, 1, true, _ids1(1));

        // day 2: ten honest holders, ten wallets, try to hide the item
        vm.warp(block.timestamp + 2 days);
        for (uint256 i; i < 10; ++i) {
            address w = address(uint160(0x1000 + i));
            nft.mint(w, 100 + i);
            vm.prank(w);
            list.vote(VAULT, 1, 1, true, _ids1(100 + i));
        }
        (uint8 s, uint32 hideNfts,, uint16 hideWallets, uint64 roundEnd) = list.status(VAULT, 1, 1);
        assertGt(roundEnd, block.timestamp, "a fresh round opened: cooldown did not block the honest vote");
        assertEq(hideNfts, 10, "all ten honest NFTs counted (not dropped by cooldown)");
        assertEq(hideWallets, 10, "all ten honest wallets counted");

        // day 3: the fresh round has closed and quorum passed
        vm.warp(roundEnd);
        (s,,,,) = list.status(VAULT, 1, 1);
        assertEq(s, list.HIDDEN_BY_VOTE(), "ten honest holders could not hide the item within the week");
    }
}
