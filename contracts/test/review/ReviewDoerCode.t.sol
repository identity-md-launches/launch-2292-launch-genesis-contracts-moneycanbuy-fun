// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../Base.t.sol";

/// @dev The proof is bound to the doer via `DOER CODE` = `IMD-<task>-<doer's full address, 0x + 40 hex
///      lowercase>` (a short prefix of the address could be matched with a vanity tool in seconds, so a thief
///      could submit someone else's post first with the same code). Tests: the code carries the whole
///      address, addresses sharing 6 (or even 39) hex get different codes, the swarm question for the thief's
///      submission carries their own code, which is not even a substring in the honest post.
contract ReviewDoerCode is Base {
    // Two different addresses with the same first 6 hex ("abcdef"): a 6-hex code would collide.
    address internal honest = 0xabCDEf1111111111111111111111111111111111;
    address internal thief = 0xaBcdef2222222222222222222222222222222222;
    // Matches the honest address in everything but the last hex: not findable in practice, and it still fails.
    address internal twin = 0xAbCDEf1111111111111111111111111111111112;

    string internal constant COND = "Post a thread on X about IMD with the doer code in the last post";
    string internal constant PROOF = "https://x.com/honestdoer/status/1934567890123456789";

    function setUp() public override {
        super.setUp();
        _fund(honest);
        _fund(thief);
        _fund(twin);
    }

    function _task() internal returns (uint256) {
        vm.prank(author);
        return vault.createTask{value: 0.001 ether}(
            address(usdc), 50e6, uint64(_now() + TTL), "Thread about IMD", rulesOf(COND), 1, PROOF_X_POST, "", _noSwap()
        );
    }

    string internal constant _SCREENSHOT = "https://i.imgur.com/screenshot.png";

    function _submitAs(address who, uint256 t) internal returns (uint256) {
        vm.prank(who);
        // this task is PROOF_X_POST, a screenshot is mandatory.
        return vault.submit(t, PROOF, Evidence(_SCREENSHOT, ""), 0, type(uint256).max, _noSwap());
    }

    /// @dev Code = the task number and the doer's whole address lowercase, with 0x.
    function test_DoerCodeIsTheWholeAddress() public {
        uint256 t = _task();
        uint256 s = _submitAs(honest, t);
        assertEq(
            string(_codeOf(s)), string.concat("IMD-", vm.toString(t), "-0xabcdef1111111111111111111111111111111111")
        );
    }

    /// @dev Sharing the first 6 hex (or even 39 of 40) gives no shared code.
    function test_DoerCodeDiffersForAddressesSharingSixHex() public {
        bytes memory codeHonest = _codeOf(_submitAs(honest, _task()));
        bytes memory codeThief = _codeOf(_submitAs(thief, _task()));
        bytes memory codeTwin = _codeOf(_submitAs(twin, _task()));
        emit log_named_string("code of the honest doer", string(codeHonest));
        emit log_named_string("code of the thief", string(codeThief));
        assertEq(string(_tail(codeHonest)), "-0xabcdef1111111111111111111111111111111111");
        assertEq(string(_tail(codeThief)), "-0xabcdef2222222222222222222222222222222222");
        assertEq(string(_tail(codeTwin)), "-0xabcdef1111111111111111111111111111111112");
    }

    /// @dev The thief (first 6 hex match, the address does not) submits the same link first: the swarm question
    ///      carries their own code, while the honest doer's post carries the honest code, where the thief's code
    ///      is not even a substring. By the rule in the prompt ("the whole DOER CODE, a part does not count") the
    ///      panel answers "no".
    function test_ThiefQuestionCarriesThiefCode() public {
        uint256 t = _task();
        uint256 stolen = _submitAs(thief, t);
        uint256 mine = _submitAs(honest, t);
        assertEq(uint8(vault.getSubmission(stolen).phase), uint8(Phase.Review));
        assertEq(uint8(vault.getSubmission(mine).phase), uint8(Phase.Queued));

        _dispute(honest, stolen);
        _warp(24 hours);
        vault.poke(t);
        bytes memory q = _question(stolen);
        bytes memory thiefCode =
            bytes(string.concat("IMD-", vm.toString(t), "-0xabcdef2222222222222222222222222222222222"));
        bytes memory honestPost = bytes(
            string.concat(
                "Thread about IMD 1/3 ... IMD-", vm.toString(t), "-0xabcdef1111111111111111111111111111111111"
            )
        );

        assertTrue(_has(q, bytes(PROOF)));
        assertTrue(_has(q, bytes.concat("DOER CODE: ", thiefCode, " ")));
        assertFalse(_has(q, "0xabcdef1111111111111111111111111111111111"));
        assertFalse(_has(honestPost, thiefCode));
        assertTrue(_has(q, bytes("must contain the whole DOER CODE (a part of it does not count)")));
        emit log_named_string("question (thief's submission)", string(q));
    }

    // ================================================================== helpers

    /// @dev Every task here is `_task()` = `rulesOf(COND)`; the dispute reason/proof only matter once a dispute
    ///      was actually filed (the hash check is skipped with none), so passing DISPUTE_REASON/DISPUTER_PROOF
    ///      unconditionally is safe for both the undisputed and the disputed call sites below.
    function _question(uint256 subId) internal view returns (bytes memory q) {
        (bytes memory body,) =
            vault.previewSwarmBody(subId, 2, RuleTexts(COND, TEST_RULE_PROOF, TEST_RULE_NO, DISPUTE_REASON, DISPUTER_PROOF));
        bytes memory head = '{"v":1,"question":"';
        uint256 i = head.length;
        while (body[i] != '"') ++i;
        q = new bytes(i - head.length);
        for (uint256 k; k < q.length; ++k) {
            q[k] = body[head.length + k];
        }
    }

    /// @dev `IMD-<task>-0x<40 hex>` from the submission's swarm question.
    function _codeOf(uint256 subId) internal view returns (bytes memory) {
        bytes memory q = _question(subId);
        bytes memory mark = "DOER CODE: ";
        uint256 at = _indexOf(q, mark) + mark.length;
        uint256 end = at;
        while (end < q.length && q[end] != " ") ++end;
        bytes memory out = new bytes(end - at);
        for (uint256 k; k < out.length; ++k) {
            out[k] = q[at + k];
        }
        return out;
    }

    /// @dev Tail of the code: `-0x<40 hex>` (the part that depends on the address).
    function _tail(bytes memory code) internal pure returns (bytes memory out) {
        out = new bytes(43);
        for (uint256 k; k < 43; ++k) {
            out[k] = code[code.length - 43 + k];
        }
    }

    function _indexOf(bytes memory hay, bytes memory needle) internal pure returns (uint256) {
        for (uint256 i; i <= hay.length - needle.length; ++i) {
            bool ok = true;
            for (uint256 j; j < needle.length; ++j) {
                if (hay[i + j] != needle[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return i;
        }
        revert("not found");
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
