// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";

/// @dev $YOLO, the fourth reward currency: paid and refunded in YOLO, Bonds in IMD sized by the oracle's YOLO price;
///      without a reliable price (too few pool samples, or the oracle failing) the task is large: mandatory check and
///      Bonds as at the large threshold.
contract YoloTest is Base {
    // $0.0001 per YOLO (Base), IMD $8: 2M YOLO = $200 = 25 IMD
    uint256 constant R = 2_000_000e18;

    function test_YoloTaskAcceptedPaysInYolo() public {
        uint256 authorBefore = yolo.balanceOf(author);
        uint256 t = _create(author, address(yolo), R);
        assertEq(yolo.balanceOf(author), authorBefore - R);
        uint256 s = _submit(doer, t);
        Submission memory sub = _sub(s);
        assertFalse(sub.large);
        assertEq(sub.rewardImd, 25e18, "R in IMD from the oracle");
        assertEq(sub.bond, 0.5e18 + 25e18 * 300 / 10_000, "0.5 + 3% R in IMD");
        vm.warp(sub.windowEnd + 1);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(vault.credits(address(yolo), doer) + _paidDirect(doer), R * 90 / 100, "R - 10% in YOLO");
        assertEq(vault.treasuryPot(address(yolo)), R / 10, "the fee in the reward currency");
        trackedTasks.push(t);
        _claimEverythingAndCheck();
    }

    function test_YoloAboveThresholdNeedsTheSwarm() public {
        uint256 t = _create(author, address(yolo), 3_000_000e18); // $300
        uint256 s = _submit(doer, t);
        assertTrue(_sub(s).large);
        assertEq(uint8(_sub(s).check), uint8(CheckState.Requested));
    }

    function test_YoloBelowUsdMinimumRefused() public {
        uint256 value = 0.001 ether;
        vm.prank(author);
        vm.expectRevert(RewardTooSmall.selector);
        vault.createTask{value: value}(address(yolo), 49_000e18, 0, "Title", "c", 0, 0, "", value, _noSwap()); // $4.9
    }

    /// Without a reliable price a $YOLO task is large, whatever its size:
    /// mandatory swarm check and Bonds as at the large threshold (40 IMD), so a missing or crashed price can only make
    /// a submission dearer.
    function test_UnpricedYolo_IsLargeWithTheThresholdBond() public {
        oracle.set(address(yolo), 0, 18); // too few pool samples: no price
        assertFalse(oracle.hasPrice(address(yolo)));
        // no USD minimum without a price (the author fee is the spam guard)
        uint256 small = _create(author, address(yolo), 1e18);
        uint256 huge = _create(alice, address(yolo), 900_000_000e18);
        uint256 s1 = _submit(doer, small);
        uint256 s2 = _submit(doer2, huge);
        for (uint256 i; i < 2; ++i) {
            Submission memory sub = _sub(i == 0 ? s1 : s2);
            assertTrue(sub.large, "the mandatory check, whatever the size");
            assertEq(sub.rewardImd, 40e18, "valued at the large threshold");
            assertEq(sub.bond, 1.7e18, "0.5 + 3% of 40 IMD");
            assertEq(uint8(sub.check), uint8(CheckState.Requested));
        }
        trackedTasks.push(small);
        trackedTasks.push(huge);
        _finishAll();
        _claimEverythingAndCheck();
    }

    /// The same when the oracle itself fails (unreadable IMD TWAP, stale feed): a $YOLO submission still goes in, as
    /// a large one, instead of reverting; the relayer shortfall rate is then simply 0.
    function test_YoloWithBrokenOracle_IsLarge() public {
        uint256 t = _create(author, address(yolo), 100_000e18); // $10
        oracle.setBroken(true);
        uint256 s = _submit(doer, t);
        Submission memory sub = _sub(s);
        assertTrue(sub.large);
        assertEq(sub.rewardImd, 40e18);
        assertEq(sub.imdPerEth, 0);
        assertEq(uint8(sub.check), uint8(CheckState.Requested));
        (uint256 bond, uint256 fee) = vault.quoteSubmission(t);
        assertGt(fee, 0, "the quote asks for the check fee too");
        assertEq(bond, 1.7e18 * 2, "doubled for the submission ahead");
        oracle.setBroken(false);
    }

    function test_PriceComesBackForTheNextSubmission() public {
        oracle.set(address(yolo), 0, 18);
        uint256 t = _create(author, address(yolo), 3_000_000e18);
        oracle.set(address(yolo), 0.0001e18, 18);
        uint256 s = _submit(doer, t);
        assertTrue(_sub(s).large, "priced at submission, not at creation");
    }

    function test_YoloTopUpAndContributionBack() public {
        uint256 t = _create(author, address(yolo), R);
        _topUp(alice, t, R);
        assertEq(vault.getTask(t).pot, 2 * R);
        uint256 before = yolo.balanceOf(alice);
        _announceWithdraw(alice, t);
        vm.prank(alice);
        vault.withdrawContribution(t);
        assertEq(yolo.balanceOf(alice) - before, R);
    }

    function test_OtherTokensStillRefused() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        vm.prank(author);
        vm.expectRevert(BadCurrency.selector);
        vault.createTask{value: 0.001 ether}(address(other), 1e18, 0, "Title", "c", 0, 0, "", 0.001 ether, _noSwap());
    }

    // ------------------------------------------------------------------ helpers

    function _paidDirect(address who) internal view returns (uint256) {
        return yolo.balanceOf(who) - 1_000_000_000e18;
    }

    function _finishAll() internal {
        for (uint256 i; i < 40; ++i) {
            _warp(13 hours);
            for (uint256 k; k < trackedTasks.length; ++k) {
                try vault.poke(trackedTasks[k]) {} catch {}
            }
        }
    }
}
