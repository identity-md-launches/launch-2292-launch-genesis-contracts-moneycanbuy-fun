// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TextLib} from "../../src/helpers/TextRules.sol";
import "../../src/VaultTypes.sol";

contract ProofHarness {
    function check(string calldata proof, uint8 t) external pure {
        TextLib.checkProof(proof, t);
    }
}

/// @dev Which real-world link forms the proof check accepts and which it rejects.
contract ReviewProofFormat is Test {
    ProofHarness h = new ProofHarness();

    function _ok(string memory s, uint8 t) internal view {
        h.check(s, t);
    }

    function _bad(string memory s, uint8 t) internal {
        vm.expectRevert(abi.encodeWithSelector(BadProof.selector, t));
        h.check(s, t);
    }

    function test_XPostForms() public {
        _ok("https://x.com/doer_1/status/1844000000000000000", PROOF_X_POST);
        _ok("https://twitter.com/Doer/status/1844000000000000000?s=20", PROOF_X_POST);
        _ok("https://mobile.twitter.com/doer/status/1/photo/1", PROOF_X_POST);
        // rejected, although these are links to the post:
        _bad("https://x.com/i/web/status/1844000000000000000", PROOF_X_POST); // "share" from some clients
        _bad("https://X.com/doer/status/1844000000000000000", PROOF_X_POST); // host case
        _bad("x.com/doer/status/1844000000000000000", PROOF_X_POST); // no scheme
        _bad("https://x.com/doer/status/1844000000000000000#m", PROOF_X_POST); // fragment
    }

    function test_VideoAndTx() public {
        _ok("https://youtu.be/dQw4w9WgXcQ", PROOF_VIDEO);
        _ok("https://www.youtube.com/shorts/abc", PROOF_VIDEO);
        _ok("https://kick.com/video/123e4567-e89b-12d3-a456-426614174000", PROOF_VIDEO);
        _bad("https://music.youtube.com/watch?v=x", PROOF_VIDEO);
        _ok("0x1111111111111111111111111111111111111111111111111111111111111111", PROOF_ONCHAIN_TX);
        _bad(
            "https://etherscan.io/tx/0x1111111111111111111111111111111111111111111111111111111111111111",
            PROOF_ONCHAIN_TX
        );
    }
}
