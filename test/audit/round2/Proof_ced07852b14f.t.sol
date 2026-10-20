// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {HiddenList} from "src/HiddenList.sol";

contract Nft { mapping(uint256 => address) public ownerOf; function set(uint256 id, address o) external { ownerOf[id] = o; } }

/// A 10-NFT cluster opens a round with 1 NFT, waits, and adds 9 in the round's last second: defenders who saw
/// 1 hide NFT for 24h are outvoted with no chance to answer, and the innocent item is hidden until the owner acts.
/// After the owner restores it (VISIBLE), the same cluster re-hides it in the next 24h: no cooldown applies.
contract HiddenListSnipeTest is Test {
    Nft nft = new Nft();
    HiddenList hl;
    address owner = address(0xA11CE);
    address[3] w = [address(0x1), address(0x2), address(0x3)];
    address keeper = address(0x4);
    address vault = address(0xBEEF);

    function setUp() public {
        hl = new HiddenList(owner, address(nft), address(0));
        for (uint256 i = 1; i <= 10; ++i) nft.set(i, w[i % 3]);
        nft.set(100, keeper); nft.set(101, keeper);
    }

    function _ids(uint256 a, uint256 b, uint256 m) internal pure returns (uint256[] memory r) {
        uint256 n; for (uint256 i = a; i <= b; ++i) if (i % 3 == m) ++n;
        r = new uint256[](n); n = 0; for (uint256 i = a; i <= b; ++i) if (i % 3 == m) r[n++] = i;
    }

    function _snipe() internal {
        vm.prank(w[1]); uint256[] memory one = new uint256[](1); one[0] = 1; hl.vote(vault, 1, 7, true, one);
        // keeper defends with 2 NFTs > 1 hide NFT
        uint256[] memory k = new uint256[](2); k[0] = 100; k[1] = 101;
        vm.prank(keeper); hl.vote(vault, 1, 7, false, k);
        (,,,, uint64 end) = hl.status(vault, 1, 7);
        vm.warp(end - 1);
        vm.prank(w[0]); hl.vote(vault, 1, 7, true, _ids(2, 10, 0));
        vm.prank(w[1]); hl.vote(vault, 1, 7, true, _ids(2, 10, 1));
        vm.prank(w[2]); hl.vote(vault, 1, 7, true, _ids(2, 10, 2));
        vm.warp(end);
    }

    function test_lastSecondSnipeHidesWithoutReply() public {
        _snipe();
        (uint8 st,,,,) = hl.status(vault, 1, 7);
        // expected (fixed, e.g. round extended on a late swing): still VISIBLE at `end`; actual: HIDDEN_BY_VOTE
        assertEq(st, 0, "hidden by a last-second swing nobody could answer");
    }
}
