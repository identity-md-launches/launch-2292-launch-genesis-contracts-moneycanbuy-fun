// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Base} from "../Base.t.sol";
import {TaskVault} from "../../src/TaskVault.sol";
import {ParamsRegistry} from "../../src/ParamsRegistry.sol";
import {Params, ParamsBounds} from "../../src/VaultParams.sol";
import "../../src/VaultTypes.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev R1-R5: front-running guards (minReward, maxImdIn), text validation and the question size bound.
contract ReviewProofs is Base {
    uint8 constant ACCEPT = 1;
    uint8 constant REJECT = 2;

    // R1. The author swaps the reward before a submission (withdrawContribution + topUp to the minimum): a submission
    //     with minReward reverts, the doer loses nothing.
    function test_R1_FrontrunReward_SubmitRevertsWithMinReward() public {
        uint256 t = _create(author, address(usdc), 1_000e6);
        _announceWithdraw(author, t); // an hour of public notice first (swarm audit #8)
        vm.prank(author);
        vault.withdrawContribution(t);
        _topUp(author, t, 5e6);
        uint256 before = imd.balanceOf(doer);
        vm.prank(doer);
        vm.expectRevert(RewardChanged.selector);
        vault.submit(t, "https://x.com/doer/status/1", _noEvidence(), 1_000e6, type(uint256).max, _noSwap());
        assertEq(imd.balanceOf(doer), before);
    }

    // R2. The bond doubled because of a submission inserted before the doer: with maxImdIn = quote the submission reverts.
    function test_R2_BondDoubled_SubmitRevertsWithMaxImdIn() public {
        uint256 t = _create(author, address(usdc), 100e6);
        (uint256 quoted,) = vault.quoteSubmission(t);
        _submit(doer2, t);
        vm.prank(doer);
        vm.expectRevert(CostAboveMax.selector);
        vault.submit(t, "https://x.com/doer/status/1", _noEvidence(), 100e6, quoted, _noSwap());
        vm.prank(doer);
        vault.submit(t, "https://x.com/doer/status/1", _noEvidence(), 100e6, quoted * 2, _noSwap()); // agrees to the new price
    }

    // R3. The swarm price rose 0.5 → 200 IMD: an appeal with maxImdIn at the old quote reverts.
    function test_R3_AppealPriceJump_RevertsWithMaxImdIn() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        _vote(s, 0, REJECT, 0, 100);
        _endVote(s); // the NFT decides at the vote end
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
        uint256 quoted = vault.quoteDisputeBond(s) + vault.quoteSwarmFee(s);
        intake.setPrice(200e18);
        vm.prank(doer);
        vm.expectRevert(CostAboveMax.selector);
        vault.appeal(s, "ipfs://appeal", quoted, _noSwap());
    }

    // R4. Invalid UTF-8 is rejected; non-Latin letters (valid UTF-8, here Greek) are accepted.
    function test_R4_InvalidUtf8Rejected_NonLatinAccepted() public {
        uint256 t = _create(author, address(usdc), 1_000e6);
        bytes[5] memory bad = [
            bytes(hex"68747470733a2f2f78fffe"), // 0xFF
            bytes(hex"c0af"), // overlong '/'
            bytes(hex"eda080"), // surrogate
            bytes(hex"d0"), // truncated
            bytes(hex"e282")
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(doer);
            vm.expectRevert(BadText.selector);
            vault.submit(t, string(bad[i]), _noEvidence(), 0, type(uint256).max, _noSwap());
        }
        // (the proof is a link of the task's type, checked before UTF-8; non-Latin text is checked on a dispute reason)
        uint256 s = _submit(doer, _create(author, address(usdc), 100e6)); // small: dispute window right away
        vm.prank(dave);
        vault.dispute{value: 0.001 ether}(
            s, unicode"Θέμα χάθηκε, κωδ Z7 μη ορατό", 0.001 ether, _noSwap()
        );
        (bytes memory body,) = vault.previewSwarmBody(s, 1);
        assertGt(body.length, 0);
    }

    // R5. Parameter bounds never let a question body exceed the Intake limit; the number of disputers is unbounded,
    //     the first maxClaims reasons go into the question, the body stays within bounds.
    function test_R5_BodyBoundedByParams_DisputersUnlimited() public {
        Params memory p = defaultParams();
        p.maxClaims = 32;
        p.maxTextBytes = 512;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ParamsBounds.ParamOutOfBounds.selector, "bodySize"));
        registry.proposeParams(p);
        p.maxClaims = 33;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ParamsBounds.ParamOutOfBounds.selector, "maxClaims"));
        registry.proposeParams(p);

        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        bytes memory reason = new bytes(256);
        for (uint256 i; i < 256; ++i) {
            reason[i] = "a";
        }
        for (uint256 i; i < 40; ++i) {
            address d = address(uint160(0xD15000 + i));
            vm.deal(d, 1 ether);
            imd.mint(d, 10e18);
            vm.startPrank(d);
            imd.approve(address(vault), type(uint256).max);
            vault.dispute{value: 0.001 ether}(s, string(reason), 0.001 ether, _noSwap());
            vm.stopPrank();
        }
        assertEq(vault.getDispute(s).disputers.length, 40);
        _warp(24 hours);
        _callSwarm(erin, s); // works: 16 claims + the caller's own reason
        assertLe(intake.lastBodyLength(), 16_384);
        assertEq(uint8(_phase(s)), uint8(Phase.Asked));
    }

    // W1 (front-end). The task deadline does not block a dispute, votes and an appeal on an already active submission: the
    //     contract accepts them, so a front-end must not hide these buttons after the deadline.
    function test_W1_DisputeVoteAppealAfterTaskDeadline() public {
        uint256 t = _createWithDeadline(author, address(usdc), 100e6, uint64(_now() + 1 days));
        uint256 s = _submit(doer, t);
        _warp(23 hours);
        _dispute(dave, s);
        _warp(2 hours); // task deadline passed
        assertGt(_now(), vault.getTask(t).deadline);
        _vote(s, 0, REJECT, 0, 100); // votes are accepted
        _endVote(s); // decision at the end of voting
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
        _appeal(doer, s); // so is an appeal
        assertEq(uint8(_phase(s)), uint8(Phase.Appealed));
    }

    // R7. An NFT holder with an EIP-7702 delegation (code 0xef0100||impl at the address) signs a vote with his own key:
    //     fixed, a plain key signature is checked first, then ERC-1271.
    function test_R7_Eip7702Voter_EcdsaSignatureCounted() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        address impl = address(new MockERC20("x", "x", 18)); // any contract without isValidSignature
        vm.etch(voters[1], abi.encodePacked(hex"ef0100", impl));
        _vote(s, 1, REJECT, 120, 20); // signed with the owner's key, the NFT is his
        assertEq(vault.getDispute(s).votesReject, 20, "owner key signature counted");
    }
}
