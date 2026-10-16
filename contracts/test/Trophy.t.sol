// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev DareTrophy: the doer of an accepted submission mints its NFT trophy once, burning its price in YOLO; the
///      metadata (JSON + SVG badge) are built on chain.
contract TrophyTest is Base {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function test_DoerMintsOnceBurningYolo() public {
        (uint256 t, uint256 s) = _accepted(address(usdc), 12_345_678, 3); // 12.345678 USDC, category irl
        assertEq(trophy.price(), 15_000e18, "$1.50 at $0.0001 per YOLO");
        uint256 before = yolo.balanceOf(doer);
        _mint(doer, s, "Scream at the Charging Bull");
        assertEq(trophy.ownerOf(s), doer);
        assertEq(before - yolo.balanceOf(doer), 15_000e18);
        assertEq(yolo.balanceOf(DEAD), 15_000e18, "burned to the dead address");
        assertEq(yolo.balanceOf(address(trophy)), 0, "the trophy keeps no YOLO");
        assertEq(trophy.totalBurned(), 15_000e18);
        assertEq(trophy.mintedOf(s).taskId, t);

        vm.prank(doer);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidSender.selector, address(0)));
        trophy.mint(s, "Again", type(uint256).max);
    }

    function test_OnlyTheDoerOfAnAcceptedSubmission() public {
        uint256 t = _create(author, address(imd), 10e18);
        uint256 s = _submit(doer, t);
        vm.prank(doer);
        vm.expectRevert(DareTrophy.NotAccepted.selector);
        trophy.mint(s, "Too early", type(uint256).max); // still in review
        vm.warp(_sub(s).windowEnd + 1);
        vault.poke(t);
        vm.prank(doer2);
        vm.expectRevert(DareTrophy.NotTheDoer.selector);
        trophy.mint(s, "Not mine", type(uint256).max);
        vm.prank(doer);
        vm.expectRevert(DareTrophy.NotTheDoer.selector);
        trophy.mint(999, "No such submission", type(uint256).max);

        // a rejected submission has no trophy
        uint256 t2 = _create(author, address(imd), 10e18);
        uint256 s2 = _submit(doer2, t2);
        _dispute(dave, s2);
        _vote(s2, 0, 2, 0, 120);
        _warp(48 hours);
        vault.poke(t2);
        assertEq(uint8(_sub(s2).outcome), uint8(Outcome.Rejected));
        vm.prank(doer2);
        vm.expectRevert(DareTrophy.NotAccepted.selector);
        trophy.mint(s2, "Rejected", type(uint256).max);
        _claimEverythingAndCheck();
    }

    function test_TitleAndPriceGuards() public {
        (, uint256 s) = _accepted(address(imd), 10e18, 0);
        string[3] memory bad = ["", 'say "hi"', "0123456789012345678901234567890123456789012345678901234567890123x"];
        for (uint256 i; i < 3; ++i) {
            vm.prank(doer);
            vm.expectRevert(DareTrophy.BadTitle.selector);
            trophy.mint(s, bad[i], type(uint256).max);
        }
        vm.prank(doer);
        vm.expectRevert(abi.encodeWithSelector(DareTrophy.PriceAboveMax.selector, 15_000e18));
        trophy.mint(s, "Fine title", 14_999e18);
    }

    function test_FixedPriceWithoutYoloPriceOrOracle() public {
        oracle.set(address(yolo), 0, 18); // too few samples
        assertEq(trophy.price(), 10_000e18);
        oracle.set(address(yolo), 0.0001e18, 18);
        oracle.setBroken(true);
        assertEq(trophy.price(), 10_000e18, "a failing oracle never blocks a trophy");
        oracle.setBroken(false);
        oracle.set(address(yolo), 0.01e18, 18); // the oracle's cap
        assertEq(trophy.price(), 150e18);
    }

    function test_MetadataOnChain() public {
        (uint256 t, uint256 s) = _accepted(address(usdc), 12_345_678, 2);
        _mint(doer, s, "Scream at the Charging Bull");
        string memory uri = trophy.tokenURI(s);
        string memory prefix = "data:application/json;base64,";
        assertTrue(_startsWith(uri, prefix));
        string memory json = string(_b64decode(_slice(bytes(uri), bytes(prefix).length)));
        assertEq(vm.parseJsonString(json, ".name"), string.concat("Dare #", vm.toString(t), " trophy"));
        assertEq(vm.parseJsonString(json, ".description"), "Scream at the Charging Bull (accepted on moneycanbuy.fun)");
        assertEq(vm.parseJsonUint(json, ".attributes[0].value"), t);
        assertEq(vm.parseJsonUint(json, ".attributes[1].value"), s);
        assertEq(vm.parseJsonString(json, ".attributes[2].value"), "IRL");
        assertEq(vm.parseJsonString(json, ".attributes[3].value"), "12.3456 USDC");
        assertEq(vm.parseJsonString(json, ".attributes[4].value"), "https://x.com/doer/status/1");
        assertEq(vm.parseJsonUint(json, ".attributes[5].value"), _now());
        string memory img = vm.parseJsonString(json, ".image");
        string memory svg = string(_b64decode(_slice(bytes(img), 26))); // "data:image/svg+xml;base64,"
        assertEq(svg, trophy.badge(2));
        assertTrue(_startsWith(svg, "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'"));

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 999));
        trophy.tokenURI(999);
    }

    function test_RewardFormatting() public {
        (, uint256 s1) = _accepted(ETH, 0.01 ether, 1);
        _mint(doer, s1, "ETH task");
        assertTrue(_contains(_json(s1), '"Reward","value":"0.01 ETH"'));
        (, uint256 s2) = _accepted(address(yolo), 2_000_000e18, 6);
        _mint(doer, s2, "YOLO task");
        assertTrue(_contains(_json(s2), '"Reward","value":"2000000 YOLO"'));
    }

    /// @dev Every category has its own badge, every badge is a valid 24x24 SVG with at least one pixel of its icon.
    function test_BadgesPerCategory() public view {
        for (uint8 c; c < 8; ++c) {
            string memory svg = trophy.badge(c);
            assertTrue(_startsWith(svg, "<svg"));
            assertTrue(_contains(svg, "fill='#fff'/>"));
            if (c > 0 && c < 7) assertNotEq(keccak256(bytes(svg)), keccak256(bytes(trophy.badge(c - 1))));
        }
        assertEq(trophy.badge(7), trophy.badge(6), "an unknown category draws as other");
    }

    // ------------------------------------------------------------------ helpers

    function _accepted(address currency, uint256 amount, uint8 category) internal returns (uint256 t, uint256 s) {
        uint256 value = 0.001 ether + (currency == ETH ? amount : 0);
        vm.prank(author);
        t = vault.createTask{value: value}(currency, amount, 0, "Title", "ipfs://task-condition", category, 0, "", 0.001 ether, _noSwap());
        trackedTasks.push(t);
        s = _submit(doer, t); // every amount here is below the large threshold: no swarm check
        vm.warp(_sub(s).windowEnd + 1);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
    }

    function _mint(address who, uint256 s, string memory title) internal {
        vm.prank(who);
        trophy.mint(s, title, type(uint256).max);
    }

    function _json(uint256 s) internal view returns (string memory) {
        return string(_b64decode(_slice(bytes(trophy.tokenURI(s)), 29)));
    }

    function _startsWith(string memory a, string memory p) internal pure returns (bool) {
        bytes memory x = bytes(a);
        bytes memory y = bytes(p);
        if (x.length < y.length) return false;
        for (uint256 i; i < y.length; ++i) {
            if (x[i] != y[i]) return false;
        }
        return true;
    }

    function _contains(string memory a, string memory n) internal pure returns (bool) {
        bytes memory x = bytes(a);
        bytes memory y = bytes(n);
        for (uint256 i; i + y.length <= x.length; ++i) {
            bool ok = true;
            for (uint256 j; j < y.length && ok; ++j) {
                ok = x[i + j] == y[j];
            }
            if (ok) return true;
        }
        return false;
    }

    function _slice(bytes memory b, uint256 from) internal pure returns (bytes memory out) {
        out = new bytes(b.length - from);
        for (uint256 i; i < out.length; ++i) {
            out[i] = b[from + i];
        }
    }

    function _b64decode(bytes memory d) internal pure returns (bytes memory out) {
        bytes memory table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        uint8[128] memory rev;
        for (uint8 i; i < 64; ++i) {
            rev[uint8(table[i])] = i;
        }
        uint256 pad = d.length > 0 && d[d.length - 1] == "=" ? (d.length > 1 && d[d.length - 2] == "=" ? 2 : 1) : 0;
        out = new bytes(d.length / 4 * 3 - pad);
        uint256 k;
        for (uint256 i; i < d.length; i += 4) {
            uint256 n = (uint256(rev[uint8(d[i])]) << 18) | (uint256(rev[uint8(d[i + 1])]) << 12)
                | (uint256(d[i + 2] == "=" ? 0 : rev[uint8(d[i + 2])]) << 6) | uint256(d[i + 3] == "=" ? 0 : rev[uint8(d[i + 3])]);
            if (k < out.length) out[k++] = bytes1(uint8(n >> 16));
            if (k < out.length) out[k++] = bytes1(uint8(n >> 8));
            if (k < out.length) out[k++] = bytes1(uint8(n));
        }
    }
}
