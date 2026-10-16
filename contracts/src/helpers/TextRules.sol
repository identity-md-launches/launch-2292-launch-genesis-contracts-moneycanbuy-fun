// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../VaultTypes.sol";

/// @title TextLib
/// @notice The text rules of every user string the vault stores or sends to the swarm (pure, inlined into TextRules).
library TextLib {
    /// @dev Every user string is embedded verbatim into the swarm JSON body: 1..maxLen bytes of well-formed UTF-8 (no
    ///      overlong forms, no surrogates), no quote, backslash, control character or DEL. Malformed text could make the
    ///      Intake refuse the body, and a refusal counts as silence. Used for the condition, proofs, reasons, replies,
    ///      the title and the doer note.
    ///      Reads calldata directly and does no overflow checks: every index is below `len`, which calldata bounds.
    function validText(string calldata str, uint256 maxLen) internal pure returns (bool) {
        uint256 len = bytes(str).length;
        if (len == 0 || len > maxLen) return false;
        uint256 at;
        assembly ("memory-safe") {
            at := str.offset
        }
        unchecked {
            uint256 i;
            while (i < len) {
                if (i + 32 <= len) {
                    uint256 w;
                    assembly ("memory-safe") {
                        w := calldataload(add(at, i))
                    }
                    if (w & HIGH_BITS == 0) {
                        // 32 ASCII bytes at once
                        if (_hasBadAscii(w)) return false;
                        i += 32;
                        continue;
                    }
                }
                uint256 c = _byteAt(at, i);
                if (c < 0x80) {
                    if (c < 0x20 || c == 0x22 || c == 0x5c || c == 0x7f) return false;
                    ++i;
                    continue;
                }
                uint256 n; // continuation bytes
                uint256 lo = 0x80;
                uint256 hi = 0xbf; // allowed range of the first continuation byte
                if (c >= 0xc2 && c <= 0xdf) {
                    n = 1;
                } else if (c >= 0xe0 && c <= 0xef) {
                    n = 2;
                    if (c == 0xe0) lo = 0xa0; // overlong
                    if (c == 0xed) hi = 0x9f; // surrogates
                } else if (c >= 0xf0 && c <= 0xf4) {
                    n = 3;
                    if (c == 0xf0) lo = 0x90; // overlong
                    if (c == 0xf4) hi = 0x8f; // above U+10FFFF
                } else {
                    return false;
                }
                if (i + n >= len) return false;
                uint256 c1 = _byteAt(at, i + 1);
                if (c1 < lo || c1 > hi) return false;
                for (uint256 k = 2; k <= n; ++k) {
                    uint256 ck = _byteAt(at, i + k);
                    if (ck < 0x80 || ck > 0xbf) return false;
                }
                i += n + 1;
            }
        }
        return true;
    }

    uint256 private constant ONES = 0x0101010101010101010101010101010101010101010101010101010101010101;
    uint256 private constant HIGH_BITS = ONES * 0x80;

    /// @dev Whether a word of 32 ASCII bytes holds a control character, quote, backslash or DEL. Exact (Bit Twiddling
    ///      Hacks "hasless" and "haszero", valid for bytes below 0x80): `(x - ONES * n) & ~x & HIGH_BITS` is nonzero
    ///      iff some byte of x is below n.
    function _hasBadAscii(uint256 w) private pure returns (bool) {
        unchecked {
            uint256 x22 = w ^ (ONES * 0x22);
            uint256 x5c = w ^ (ONES * 0x5c);
            uint256 x7f = w ^ (ONES * 0x7f);
            uint256 found =
                ((w - ONES * 0x20) & ~w) | ((x22 - ONES) & ~x22) | ((x5c - ONES) & ~x5c) | ((x7f - ONES) & ~x7f);
            return found & HIGH_BITS != 0;
        }
    }

    function _byteAt(uint256 at, uint256 i) private pure returns (uint256 c) {
        assembly ("memory-safe") {
            c := byte(0, calldataload(add(at, i)))
        }
    }

    /// @dev Cover link: empty (category cover) or `ipfs://…` / `https://…` with something after the scheme, at most
    ///      MAX_COVER_BYTES of link characters (`_linkTail`; it ends up in an `<img src>`, the site still treats it
    ///      as untrusted).
    function checkCover(string calldata cover) internal pure {
        bytes calldata b = bytes(cover);
        uint256 len = b.length;
        if (len == 0) return;
        if (len > MAX_COVER_BYTES) revert BadCover();
        uint256 scheme;
        if (_startsWith(b, 0, "ipfs://")) scheme = 7;
        else if (_startsWith(b, 0, "https://")) scheme = 8;
        else revert BadCover();
        if (len == scheme || !_linkTail(b, scheme)) revert BadCover();
    }

    /// @dev A submission's proofUri in the form its task's proof type requires (the length and UTF-8 rule is
    ///      `checkText`, checked before):
    ///      x_post      https://[www.|mobile.](x.com|twitter.com)/<user 1-15 [A-Za-z0-9_]>/status/<1-19 digits>
    ///                  [then ? or / and link characters]
    ///      video       https://[www.|m.](youtube.com|youtu.be|kick.com|twitch.tv|clips.twitch.tv)/<path>, or an
    ///                  x_post link (a video posted on X)
    ///      onchain_tx  0x + 64 hex digits (a transaction hash on Ethereum mainnet)
    ///      link        https://<link characters>
    function checkProof(string calldata proof, uint8 proofType) internal pure {
        bytes calldata b = bytes(proof);
        bool ok;
        if (proofType == PROOF_X_POST) ok = _isXPost(b);
        else if (proofType == PROOF_VIDEO) ok = _isVideo(b) || _isXPost(b);
        else if (proofType == PROOF_ONCHAIN_TX) ok = _isTxHash(b);
        else ok = b.length > 8 && _startsWith(b, 0, "https://") && _linkTail(b, 8);
        if (!ok) revert BadProof(proofType);
    }

    /// @dev Link characters from `from` to the end: printable ASCII without space, quotes, backslash or angle
    ///      brackets (the swarm JSON, an href and an <img src> stay well-formed).
    function _linkTail(bytes calldata b, uint256 from) private pure returns (bool) {
        for (uint256 i = from; i < b.length; ++i) {
            uint8 c = uint8(b[i]);
            if (c <= 0x20 || c >= 0x7f || c == 0x22 || c == 0x27 || c == 0x3c || c == 0x3e || c == 0x5c) return false;
        }
        return true;
    }

    function _startsWith(bytes calldata b, uint256 at, bytes memory prefix) private pure returns (bool) {
        if (b.length < at + prefix.length) return false;
        for (uint256 i; i < prefix.length; ++i) {
            if (b[at + i] != prefix[i]) return false;
        }
        return true;
    }

    /// @dev `https://` + host + `/`: index right after the slash, 0 when the host is not in the list.
    ///      The host may start with `www.` (and `m.` / `mobile.` where those exist).
    function _afterHost(bytes calldata b, bytes[] memory hosts) private pure returns (uint256) {
        if (!_startsWith(b, 0, "https://")) return 0;
        uint256 at = 8;
        if (_startsWith(b, at, "www.")) at += 4;
        else if (_startsWith(b, at, "mobile.")) at += 7;
        else if (_startsWith(b, at, "m.")) at += 2;
        for (uint256 h; h < hosts.length; ++h) {
            if (_startsWith(b, at, hosts[h]) && _startsWith(b, at + hosts[h].length, "/")) {
                return at + hosts[h].length + 1;
            }
        }
        return 0;
    }

    function _isXPost(bytes calldata b) private pure returns (bool) {
        bytes[] memory hosts = new bytes[](2);
        hosts[0] = "x.com";
        hosts[1] = "twitter.com";
        uint256 i = _afterHost(b, hosts);
        if (i == 0) return false;
        uint256 start = i;
        while (i < b.length && i - start < 16 && _isHandleChar(uint8(b[i]))) ++i;
        if (i == start || i - start > 15 || !_startsWith(b, i, "/status/")) return false;
        i += 8;
        start = i;
        while (i < b.length && uint8(b[i]) >= 0x30 && uint8(b[i]) <= 0x39) ++i;
        if (i == start || i - start > 19) return false;
        if (i == b.length) return true;
        return (b[i] == "?" || b[i] == "/") && _linkTail(b, i);
    }

    function _isVideo(bytes calldata b) private pure returns (bool) {
        bytes[] memory hosts = new bytes[](5);
        hosts[0] = "youtube.com";
        hosts[1] = "youtu.be";
        hosts[2] = "kick.com";
        hosts[3] = "twitch.tv";
        hosts[4] = "clips.twitch.tv";
        uint256 i = _afterHost(b, hosts);
        return i != 0 && i < b.length && _linkTail(b, i);
    }

    function _isTxHash(bytes calldata b) private pure returns (bool) {
        if (b.length != 66 || b[0] != "0" || b[1] != "x") return false;
        for (uint256 i = 2; i < 66; ++i) {
            uint8 c = uint8(b[i]);
            if (!((c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x66) || (c >= 0x41 && c <= 0x46))) return false;
        }
        return true;
    }

    function _isHandleChar(uint8 c) private pure returns (bool) {
        return (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == 0x5f;
    }
}

/// @title TextRules
/// @notice Stateless helper: the desks check user strings here (STATICCALL) instead of carrying the code themselves
///         (code size limit). Reverts carry the vault's own errors (BadCover, BadProof).
contract TextRules {
    function validText(string calldata str, uint256 maxLen) external pure returns (bool) {
        return TextLib.validText(str, maxLen);
    }

    function checkCover(string calldata cover) external pure {
        TextLib.checkCover(cover);
    }

    function checkProof(string calldata proof, uint8 proofType) external pure {
        TextLib.checkProof(proof, proofType);
    }
}
