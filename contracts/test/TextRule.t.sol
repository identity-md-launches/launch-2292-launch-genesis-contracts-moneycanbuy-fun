// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TextLib} from "../src/helpers/TextRules.sol";

/// @dev Calls TextLib.validText on calldata, the way the vault does.
contract TextRuleProbe {
    function check(string calldata t, uint256 maxLen) external pure returns (bool) {
        return TextLib.validText(t, maxLen);
    }
}

/// @dev The word-at-a-time validText (32 ASCII bytes per step) against the plain byte-by-byte rule it replaced:
///      same answer on any input, so the swarm JSON can never get a quote, backslash, control byte or bad UTF-8.
contract TextRuleTest is Test {
    TextRuleProbe internal probe = new TextRuleProbe();

    /// @dev The rule byte by byte: 1..maxLen bytes of well-formed UTF-8, no quote, backslash, control or DEL.
    function _reference(bytes memory b, uint256 maxLen) internal pure returns (bool) {
        uint256 len = b.length;
        if (len == 0 || len > maxLen) return false;
        uint256 i;
        while (i < len) {
            uint8 c = uint8(b[i]);
            if (c < 0x80) {
                if (c < 0x20 || c == 0x22 || c == 0x5c || c == 0x7f) return false;
                ++i;
                continue;
            }
            uint256 n;
            uint8 lo = 0x80;
            uint8 hi = 0xbf;
            if (c >= 0xc2 && c <= 0xdf) {
                n = 1;
            } else if (c >= 0xe0 && c <= 0xef) {
                n = 2;
                if (c == 0xe0) lo = 0xa0;
                if (c == 0xed) hi = 0x9f;
            } else if (c >= 0xf0 && c <= 0xf4) {
                n = 3;
                if (c == 0xf0) lo = 0x90;
                if (c == 0xf4) hi = 0x8f;
            } else {
                return false;
            }
            if (i + n >= len) return false;
            uint8 c1 = uint8(b[i + 1]);
            if (c1 < lo || c1 > hi) return false;
            for (uint256 k = 2; k <= n; ++k) {
                uint8 ck = uint8(b[i + k]);
                if (ck < 0x80 || ck > 0xbf) return false;
            }
            i += n + 1;
        }
        return true;
    }

    function _same(bytes memory b) internal view {
        assertEq(probe.check(string(b), 512), _reference(b, 512), string(abi.encodePacked("input 0x", vm.toString(b))));
    }

    /// @dev Random bytes: mostly rejected, exercises every early exit.
    function testFuzz_RandomBytes(bytes memory b) public view {
        vm.assume(b.length <= 600);
        _same(b);
    }

    /// @dev Long printable ASCII with one byte replaced anywhere (any value): the 32-byte steps and the tail.
    function testFuzz_AsciiWithOneByte(uint16 len, uint16 at, uint8 value, uint256 seed) public view {
        len = uint16(bound(len, 1, 520));
        bytes memory b = new bytes(len);
        for (uint256 i; i < len; ++i) {
            b[i] = bytes1(uint8(0x20 + uint256(keccak256(abi.encode(seed, i))) % 95)); // 0x20..0x7e
        }
        for (uint256 i; i < len; ++i) {
            if (b[i] == '"' || b[i] == "\\") b[i] = "a";
        }
        _same(b); // all printable: accepted unless longer than 512
        b[bound(at, 0, len - 1)] = bytes1(value);
        _same(b);
    }

    /// @dev Text mixing ASCII runs and multi-byte characters, sometimes cut in the middle of one.
    function testFuzz_MixedUtf8(uint256 seed, uint16 cut) public view {
        bytes memory b;
        for (uint256 i; i < 24; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 kind = r % 5;
            if (kind == 0) b = bytes.concat(b, "the quick brown fox jumps over the lazy dog");
            else if (kind == 1) b = bytes.concat(b, unicode"Ωμέγα");
            else if (kind == 2) b = bytes.concat(b, unicode"👀");
            else if (kind == 3) b = bytes.concat(b, unicode"€");
            else b = bytes.concat(b, bytes1(uint8(r >> 8)));
        }
        _same(b);
        uint256 n = bound(cut, 1, b.length);
        bytes memory head = new bytes(n);
        for (uint256 i; i < n; ++i) {
            head[i] = b[i];
        }
        _same(head);
    }

    function test_Examples() public view {
        _same(bytes(_repeat("a", 32)));
        _same(bytes(_repeat("a", 512)));
        _same(bytes(_repeat("a", 513)));
        _same(bytes.concat(bytes(_repeat("a", 31)), '"'));
        _same(bytes.concat(bytes(_repeat("a", 32)), "\\"));
        _same(bytes.concat(bytes(_repeat("a", 40)), hex"7f"));
        _same(bytes.concat(bytes(_repeat("a", 63)), hex"1f"));
        _same(bytes.concat(bytes(_repeat("a", 30)), hex"e0a080")); // overlong
        _same(bytes.concat(bytes(_repeat("a", 30)), hex"eda080")); // surrogate
        _same(bytes.concat(bytes(_repeat("a", 30)), unicode"Ωμέγα"));
        _same("");
        assertTrue(probe.check(_repeat("a", 64), 512));
        assertFalse(probe.check(string(bytes.concat(bytes(_repeat("a", 64)), '"')), 512));
    }

    function _repeat(bytes1 ch, uint256 n) internal pure returns (string memory) {
        bytes memory b = new bytes(n);
        for (uint256 i; i < n; ++i) {
            b[i] = ch;
        }
        return string(b);
    }
}
