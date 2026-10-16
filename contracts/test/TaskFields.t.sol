// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";
import {ParamsBounds} from "../src/VaultParams.sol";

/// @dev Title, condition, proof type and the proof format checked at submit; what reaches the swarm question.
contract TaskFieldsTest is Base {
    string internal constant COND = "Post a thread on X about IMD with the doer code in the last post";
    string internal constant TX = "0x5f3a9c0d2b7e41a8c6f09d3e7b25a1c4e8f60b9d2a7c3e15f4b8d06a9c2e7f13";

    function setUp() public override {
        super.setUp();
        _create(author, address(usdc), 50e6); // caches the parameter snapshot
    }

    function _task(string memory title, string memory cond, uint8 proofType) internal returns (uint256) {
        vm.prank(author);
        return vault.createTask{value: 0.001 ether}(
            address(usdc), 50e6, 0, title, cond, 1, proofType, "", 0.001 ether, _noSwap()
        );
    }

    function _expectCreateRevert(bytes memory err, string memory title, string memory cond, uint8 proofType) internal {
        vm.prank(author);
        vm.expectRevert(err);
        vault.createTask{value: 0.001 ether}(
            address(usdc), 50e6, 0, title, cond, 1, proofType, "", 0.001 ether, _noSwap()
        );
    }

    function _bytes(bytes1 ch, uint256 n) internal pure returns (string memory) {
        bytes memory b = new bytes(n);
        for (uint256 i; i < n; ++i) {
            b[i] = ch;
        }
        return string(b);
    }

    // ================================================================== title

    function test_Title_InEventOnly_Limits() public {
        uint256 next = vault.taskCount() + 1;
        vm.expectEmit(address(vault));
        emit TaskCreated(next, author, address(usdc), 50e6, 0, "Thread on X", COND, 1, PROOF_X_POST, "");
        _task("Thread on X", COND, PROOF_X_POST);

        _task("T", COND, 0); // 1 byte
        _task(_bytes("a", MAX_TITLE_BYTES), COND, 0); // 80 bytes
        // 40 Greek letters = 80 bytes of UTF-8
        _task(unicode"ΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩ", COND, 0);

        bytes memory bad = abi.encodeWithSelector(BadTitle.selector);
        _expectCreateRevert(bad, "", COND, 0);
        _expectCreateRevert(bad, _bytes("a", MAX_TITLE_BYTES + 1), COND, 0);
        _expectCreateRevert(
            bad, unicode"ΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩΩ", COND, 0
        ); // 82 bytes
        _expectCreateRevert(bad, 'say "hi"', COND, 0);
        _expectCreateRevert(bad, "back\\slash", COND, 0);
        _expectCreateRevert(bad, "line\nbreak", COND, 0);
        _expectCreateRevert(bad, "del\x7f", COND, 0);
        _expectCreateRevert(bad, string(bytes(hex"c0af")), COND, 0); // overlong
        _expectCreateRevert(bad, string(bytes(hex"d0")), COND, 0); // truncated
    }

    // ================================================================== condition

    function test_Condition_StoredAndLimited() public {
        uint256 t = _task("Title", COND, 0);
        assertEq(vault.getTask(t).condition, COND);
        _task("Title", _bytes("c", 256), 0);
        bytes memory bad = abi.encodeWithSelector(BadText.selector);
        _expectCreateRevert(bad, "Title", _bytes("c", 257), 0);
        _expectCreateRevert(bad, "Title", "", 0);
        _expectCreateRevert(bad, "Title", 'a "quoted" rule', 0);
    }

    // ================================================================== proof type

    function test_ProofType_StoredPackedFixed() public {
        for (uint8 k; k < PROOF_TYPE_COUNT; ++k) {
            Task memory task = vault.getTask(_task("Title", COND, k));
            assertEq(task.proofType, k);
            assertEq(task.category, 1); // packed next to it
            assertEq(task.currency, address(usdc));
            assertEq(uint8(task.status), uint8(TaskStatus.Open));
        }
        bytes memory bad = abi.encodeWithSelector(BadProofType.selector);
        _expectCreateRevert(bad, "Title", COND, PROOF_TYPE_COUNT);
        _expectCreateRevert(bad, "Title", COND, 255);
    }

    // ================================================================== proof formats at submit

    function _accepts(uint8 proofType, string[] memory proofs) internal {
        for (uint256 i; i < proofs.length; ++i) {
            uint256 t = _task("Title", COND, proofType);
            vm.prank(doer);
            vault.submit(t, proofs[i], _noEvidence(), 0, type(uint256).max, _noSwap());
            assertEq(_sub(vault.submissionCount()).proofUri, proofs[i]);
        }
    }

    function _rejects(uint8 proofType, string[] memory proofs) internal {
        uint256 t = _task("Title", COND, proofType);
        for (uint256 i; i < proofs.length; ++i) {
            vm.prank(doer);
            vm.expectRevert(abi.encodeWithSelector(BadProof.selector, proofType));
            vault.submit(t, proofs[i], _noEvidence(), 0, type(uint256).max, _noSwap());
        }
    }

    function test_Proof_XPost() public {
        string[] memory ok = new string[](7);
        ok[0] = "https://x.com/a/status/1";
        ok[1] = "https://twitter.com/A_b9/status/1234567890123456789"; // 19 digits
        ok[2] = "https://www.x.com/doer/status/12?s=20";
        ok[3] = "https://mobile.twitter.com/doer/status/1/photo/1";
        ok[4] = "https://x.com/abcdefghijklmno/status/7"; // 15-char handle
        ok[5] = "https://x.com/doer/status/1844000000000000000?t=AbC-d_e&s=19";
        ok[6] = "https://x.com/doer/status/1/";
        _accepts(PROOF_X_POST, ok);

        string[] memory bad = new string[](16);
        bad[0] = "http://x.com/u/status/1";
        bad[1] = "https://x.com/u/status/";
        bad[2] = "https://x.com/u/status/abc";
        bad[3] = "https://x.com//status/1";
        bad[4] = "https://x.com/abcdefghijklmnop/status/1"; // 16-char handle
        bad[5] = "https://x.com/u/status/12345678901234567890"; // 20 digits
        bad[6] = "https://x.com.evil.io/u/status/1";
        bad[7] = "https://evilx.com/u/status/1";
        bad[8] = "https://x.com/u/statuses/1";
        bad[9] = "https://x.com/u/status/1 and more";
        bad[10] = "https://x.com/u/status/1#frag";
        bad[11] = "https://x.com/u-dash/status/1";
        bad[12] = "https://www.youtube.com/watch?v=dQw4w9WgXcQ";
        bad[13] = "https://x.com/u/status/1?q=it's";
        bad[14] = "x.com/u/status/1";
        bad[15] = TX;
        _rejects(PROOF_X_POST, bad);
    }

    function test_Proof_Video() public {
        string[] memory ok = new string[](8);
        ok[0] = "https://www.youtube.com/watch?v=dQw4w9WgXcQ";
        ok[1] = "https://youtu.be/dQw4w9WgXcQ";
        ok[2] = "https://m.youtube.com/shorts/abc123";
        ok[3] = "https://kick.com/doerbuilds/videos/7c1e4b2a";
        ok[4] = "https://www.twitch.tv/videos/123456";
        ok[5] = "https://clips.twitch.tv/BraveClip-abc";
        ok[6] = "https://x.com/doer/status/1"; // a video posted on X
        ok[7] = "https://youtube.com/live/abc?si=x";
        _accepts(PROOF_VIDEO, ok);

        string[] memory bad = new string[](10);
        bad[0] = "https://youtube.com/";
        bad[1] = "https://youtube.com.evil.io/watch?v=x";
        bad[2] = "https://vimeo.com/1";
        bad[3] = "http://youtu.be/dQw4w9WgXcQ";
        bad[4] = "https://youtu.be";
        bad[5] = "https://notyoutube.com/watch";
        bad[6] = "https://www.youtube.com/watch?v=a'b";
        bad[7] = "https://www.youtube.com/watch?v=a b";
        bad[8] = "https://x.com/doer"; // X, but not a post
        bad[9] = TX;
        _rejects(PROOF_VIDEO, bad);
    }

    function test_Proof_OnchainTx() public {
        string[] memory ok = new string[](2);
        ok[0] = TX;
        ok[1] = "0xABCDEFabcdef0123456789ABCDEFabcdef0123456789ABCDEFabcdef01234567";
        _accepts(PROOF_ONCHAIN_TX, ok);

        string[] memory bad = new string[](7);
        bad[0] = "0x5f3a9c0d2b7e41a8c6f09d3e7b25a1c4e8f60b9d2a7c3e15f4b8d06a9c2e7f1"; // 63 hex
        bad[1] = "0x5f3a9c0d2b7e41a8c6f09d3e7b25a1c4e8f60b9d2a7c3e15f4b8d06a9c2e7f134"; // 65 hex
        bad[2] = "0X5f3a9c0d2b7e41a8c6f09d3e7b25a1c4e8f60b9d2a7c3e15f4b8d06a9c2e7f13";
        bad[3] = "0x5f3a9c0d2b7e41a8c6f09d3e7b25a1c4e8f60b9d2a7c3e15f4b8d06a9c2e7fg3";
        bad[4] = "https://etherscan.io/tx/0x5f3a9c0d2b7e41a8c6f09d3e7b25a1c4e8f60b9d2a7c3e15f4b8d06a9c2e7f13";
        bad[5] = "5f3a9c0d2b7e41a8c6f09d3e7b25a1c4e8f60b9d2a7c3e15f4b8d06a9c2e7f1300";
        bad[6] = "0x5f3a9c0d2b7e41a8c6f09d3e7b25a1c4e8f60b9d2a7c3e15f4b8d06a9c2e7f1 ";
        _rejects(PROOF_ONCHAIN_TX, bad);
    }

    function test_Proof_Link() public {
        string[] memory ok = new string[](4);
        ok[0] = "https://a";
        ok[1] = "https://github.com/example/site/pull/7";
        ok[2] = "https://example.com/a?b=c&d=%20#f";
        ok[3] = "https://x.com/doer/status/1";
        _accepts(PROOF_LINK, ok);

        string[] memory bad = new string[](8);
        bad[0] = "http://example.com";
        bad[1] = "https://";
        bad[2] = "ftp://example.com";
        bad[3] = "https://a b";
        bad[4] = "https://a'b";
        bad[5] = "https://a<b>";
        bad[6] = "ipfs://bafkreidivzimqfqtoqxkrpge6bjyhlvxqs3rhe73owtmdulaxr5do5in7u";
        bad[7] = TX;
        _rejects(PROOF_LINK, bad);
    }

    /// @dev Length and UTF-8 come first: an over-long proof is BadText whatever its form.
    function test_Proof_LengthStillFirst() public {
        uint256 t = _task("Title", COND, PROOF_LINK);
        vm.prank(doer);
        vm.expectRevert(BadText.selector);
        vault.submit(
            t, string(abi.encodePacked("https://", _bytes("a", 249))), _noEvidence(), 0, type(uint256).max, _noSwap()
        );
        vm.prank(doer);
        vault.submit(
            t, string(abi.encodePacked("https://", _bytes("a", 248))), _noEvidence(), 0, type(uint256).max, _noSwap()
        );
    }

    // ================================================================== swarm question

    function _question(bytes memory body) internal pure returns (bytes memory q) {
        bytes memory head = '{"v":1,"question":"';
        uint256 i = head.length;
        while (body[i] != '"') ++i;
        q = new bytes(i - head.length);
        for (uint256 k; k < q.length; ++k) {
            q[k] = body[head.length + k];
        }
    }

    function test_SwarmQuestion_ProofTypeIn_TitleOut() public {
        string[4] memory names = ["x_post", "video", "onchain_tx", "link"];
        string[4] memory proofs = ["https://x.com/doer/status/1", "https://youtu.be/dQw4w9WgXcQ", TX, "https://a.io/p"];
        for (uint8 k; k < PROOF_TYPE_COUNT; ++k) {
            uint256 t = _task("SECRET-TITLE-xyz", COND, k);
            vm.prank(doer);
            uint256 s = vault.submit(t, proofs[k], _noEvidence(), 0, type(uint256).max, _noSwap());
            _dispute(dave, s);
            _warp(24 hours);
            vault.poke(t);
            bytes memory q = _question(_previewBody(s));
            assertTrue(
                _has(q, bytes.concat(" | PROOF: ", bytes(proofs[k]), " | PROOF TYPE: ", bytes(names[k]), " | DOER: "))
            );
            assertTrue(_has(q, bytes.concat("TASK: ", bytes(COND), " | PROOF: ")));
            assertFalse(_has(_previewBody(s), "SECRET-TITLE"));
        }
    }

    /// @dev The question carries the doer code exactly as a front-end shows it: IMD-<task>-<doer address, lowercase>.
    function test_SwarmQuestion_DoerCode() public {
        address d = 0xabCDeF0123456789AbcdEf0123456789aBCDEF01; // checksummed (mixed case), lowercase in the code
        vm.deal(d, 1 ether);
        imd.mint(d, 100e18);
        vm.prank(d);
        imd.approve(address(vault), type(uint256).max);
        uint256 t = _task("Title", COND, PROOF_X_POST);
        vm.prank(d);
        uint256 s = vault.submit(t, "https://x.com/doer/status/1", _noEvidence(), 0, type(uint256).max, _noSwap());
        _dispute(dave, s);
        _warp(24 hours);
        vault.poke(t);
        bytes memory q = _question(_previewBody(s));
        string memory code = string.concat("IMD-", vm.toString(t), "-0xabcdef0123456789abcdef0123456789abcdef01");
        assertTrue(
            _has(
                q,
                bytes(
                    string.concat(
                        " | DOER: 0xabcdef0123456789abcdef0123456789abcdef01 | DOER CODE: ", code, " | CASE: "
                    )
                )
            )
        );
        assertTrue(
            _has(
                q,
                "must contain the whole DOER CODE (a part of it does not count); for PROOF TYPE onchain_tx the transaction must be sent from DOER"
            )
        );
    }

    function _previewBody(uint256 s) internal view returns (bytes memory body) {
        (body,) = vault.previewSwarmBody(s, 2);
    }

    /// @dev The longest question the parameter bounds allow stays within the Intake limit of 2000.
    function test_SwarmQuestion_WorstCaseFitsIntakeLimit() public {
        string memory cond = _bytes("c", 256);
        string memory proof = string(abi.encodePacked("0x", _bytes("a", 64)));
        uint256 t = _task("Title", cond, PROOF_ONCHAIN_TX);
        vm.prank(doer);
        uint256 s = vault.submit(t, proof, _noEvidence(), 0, type(uint256).max, _noSwap());
        _dispute(dave, s);
        _warp(24 hours);
        vault.poke(t);
        bytes memory q = _question(_previewBody(s));
        uint256 prefix = vault.paramsOf(1).questionPrefix.length;
        uint256 fixedPart = q.length - prefix - bytes(cond).length - bytes(proof).length;
        // ids here are short: the worst case lengthens the task id (it is in the question twice: DOER CODE and CASE)
        // and the submission id to 20 digits (uint64), the nonce to 10 (asks + 1, uint32)
        uint256 worstFixed = fixedPart + 2 * (20 - bytes(vm.toString(t)).length) + (20 - bytes(vm.toString(s)).length)
            + (10 - bytes(vm.toString(uint256(_sub(s).asks) + 1)).length);
        assertEq(worstFixed, ParamsBounds.QUESTION_FIXED);
        assertEq(uint256(1_766 + ParamsBounds.QUESTION_FIXED), uint256(2_000));

        Params memory p = defaultParams();
        p.maxTextBytes = 256;
        p.questionPrefix = bytes(_bytes("q", 1_766 - 512));
        vm.prank(owner);
        registry.proposeParams(p); // at the bound: accepted
        p.questionPrefix = bytes(_bytes("q", 1_766 - 511));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ParamsBounds.ParamOutOfBounds.selector, "questionPrefix"));
        registry.proposeParams(p);
    }

    // ================================================================== gas

    function test_GasFields() public {
        uint256 g = gasleft();
        uint256 t = _task("Stream 30 min on Kick", COND, PROOF_VIDEO);
        emit log_named_uint("createTask (title 21 B, condition 64 B)", g - gasleft());
        g = gasleft();
        vm.prank(doer);
        vault.submit(t, "https://kick.com/doerbuilds/videos/7c1e4b2a", _noEvidence(), 0, type(uint256).max, _noSwap());
        emit log_named_uint("submit (video link)", g - gasleft());
        uint256 t2 = _task("Mint", COND, PROOF_ONCHAIN_TX);
        g = gasleft();
        vm.prank(doer2);
        vault.submit(t2, string(TX), _noEvidence(), 0, type(uint256).max, _noSwap());
        emit log_named_uint("submit (tx hash)", g - gasleft());
    }

    function _has(bytes memory hay, bytes memory needle) internal pure returns (bool) {
        if (needle.length > hay.length) return false;
        for (uint256 i; i <= hay.length - needle.length; ++i) {
            bool ok = true;
            for (uint256 j; j < needle.length; ++j) {
                if (hay[i + j] != needle[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
}
