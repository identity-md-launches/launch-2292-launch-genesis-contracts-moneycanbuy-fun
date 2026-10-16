// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {HiddenList} from "src/HiddenList.sol";
import {IDelegateRegistry} from "src/interfaces/IDelegateRegistry.sol";

contract SybilNft is ERC721("identity.md", "IMDID") {
    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

/// @dev delegate.xyz v2 subset: wallet-level delegation (`delegateAll`), as the real registry offers.
contract SybilDelegates is IDelegateRegistry {
    mapping(address => mapping(address => bool)) public delegated;

    function delegateAll(address to, bool on) external {
        delegated[msg.sender][to] = on;
    }

    function checkDelegateForERC721(address to, address from, address, uint256, bytes32) external view returns (bool) {
        return delegated[from][to];
    }
}

/// @notice HiddenList's "3 distinct hide wallets" rule counts msg.sender, not the NFT holder. One holder of 10 NFTs
///         delegates (delegate.xyz, free, no transfer) to two hot wallets and votes from three addresses: the round
///         passes with a single real holder behind it. Fails on this code (status == HIDDEN_BY_VOTE); passes once
///         distinct wallets are counted per NFT holder (ownerOf) instead of per caller.
contract HiddenListDelegateSybilTest is Test {
    HiddenList list;
    SybilNft nft;
    SybilDelegates delegates;

    address constant OWNER = address(0x7EA5);
    address constant VAULT = address(0xBA07);
    address holder = address(0xA11CE);
    address hot1 = address(0xD001);
    address hot2 = address(0xD002);

    function setUp() public {
        vm.warp(1_800_000_000);
        nft = new SybilNft();
        delegates = new SybilDelegates();
        list = new HiddenList(OWNER, address(nft), address(delegates));
        for (uint256 i = 1; i <= 10; ++i) {
            nft.mint(holder, i);
        }
        vm.startPrank(holder);
        delegates.delegateAll(hot1, true);
        delegates.delegateAll(hot2, true);
        vm.stopPrank();
    }

    function _ids(uint256 from, uint256 n) internal pure returns (uint256[] memory a) {
        a = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            a[i] = from + i;
        }
    }

    function test_oneHolderThreeAddressesPassesTheThreeWalletRule() public {
        vm.prank(holder);
        list.vote(VAULT, 1, 1, true, _ids(1, 8));
        vm.prank(hot1);
        list.vote(VAULT, 1, 1, true, _ids(9, 1));
        vm.prank(hot2);
        list.vote(VAULT, 1, 1, true, _ids(10, 1));
        (, uint32 hideNfts,, uint16 hideWallets,) = list.status(VAULT, 1, 1);
        assertEq(hideNfts, 10, "all ten NFTs of one holder counted");
        assertEq(hideWallets, 3, "three 'wallets' from one holder");

        vm.warp(block.timestamp + 24 hours);
        (uint8 state,,,,) = list.status(VAULT, 1, 1);
        // the documented rule ">= 3 distinct hide wallets" is meant to need three holders; one holder passes it
        assertEq(state, list.VISIBLE(), "a single NFT holder must not hide an item alone");
    }
}
