// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";

/// @dev "Sweeten with $YOLO": a YOLO bonus on top of any task. Paid to the accepted doer minus the protocol fee,
///      returned to each sweetener when the task ends without acceptance, locked while a submission is active.
contract SweetenerTest is Base {
    uint8 internal constant REJECT = 2;
    uint256 internal t;

    function setUp() public override {
        super.setUp();
        t = _create(author, ETH, 0.01 ether); // a reward in ETH: the bonus does not care about the currency
    }

    function test_AcceptedDoerGetsTheBonusMinusFee() public {
        _sweeten(alice, t, 1_000_000e18);
        _sweeten(bob, t, 500_000e18);
        assertEq(sweetener.bonusOf(t), 1_500_000e18);
        assertEq(yolo.balanceOf(address(sweetener)), 1_500_000e18);

        uint256 s = _submit(doer, t);
        vm.warp(_sub(s).windowEnd + 1);
        vault.poke(t);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Completed));

        uint256 doerBefore = yolo.balanceOf(doer);
        vm.prank(erin); // anyone may trigger the payout
        sweetener.payout(t, s);
        assertEq(yolo.balanceOf(doer) - doerBefore, 1_350_000e18, "90% to the doer");
        assertEq(yolo.balanceOf(treasury), 150_000e18, "10% fee to the treasury, in YOLO");
        assertEq(sweetener.bonusOf(t), 0);
        assertEq(yolo.balanceOf(address(sweetener)), 0);

        vm.expectRevert(YoloSweetener.NothingToPay.selector);
        sweetener.payout(t, s);
        vm.prank(alice);
        vm.expectRevert(YoloSweetener.BonusLocked.selector);
        sweetener.withdraw(t);
        vm.prank(alice);
        vm.expectRevert(YoloSweetener.TaskNotOpen.selector);
        sweetener.sweeten(t, 1);
        _claimEverythingAndCheck();
    }

    function test_LockedWhileASubmissionIsActive_FreeAfterRejection() public {
        _sweeten(alice, t, 2_000_000e18);
        uint256 s = _submit(doer, t);
        vm.prank(alice);
        vm.expectRevert(YoloSweetener.BonusLocked.selector);
        sweetener.withdraw(t);

        // a late bonus during review joins the same bonus and is locked as well
        _sweeten(bob, t, 1e18);
        vm.prank(bob);
        vm.expectRevert(YoloSweetener.BonusLocked.selector);
        sweetener.withdraw(t);

        _dispute(dave, s);
        _vote(s, 0, REJECT, 0, 120);
        _warp(24 hours);
        vault.poke(t);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Open));

        vm.expectRevert(YoloSweetener.NotAccepted.selector);
        sweetener.payout(t, s);
        uint256 before = yolo.balanceOf(alice);
        vm.prank(alice); // open again: an hour of public notice first
        sweetener.announceWithdraw(t);
        _warp(sweetener.NOTICE());
        vm.prank(alice);
        sweetener.withdraw(t);
        assertEq(yolo.balanceOf(alice) - before, 2_000_000e18, "all of it back");
        assertEq(sweetener.bonusOf(t), 1e18, "bob's part stays");
        vm.prank(alice);
        vm.expectRevert(YoloSweetener.ZeroAmount.selector);
        sweetener.withdraw(t);
        _claimEverythingAndCheck();
    }

    function test_ExpiredTaskReturnsTheBonus() public {
        uint256 d = _createWithDeadline(author, address(usdc), 10e6, uint64(_now() + 1 days));
        _sweeten(alice, d, 300e18);
        _warp(1 days + 1);
        vault.poke(d);
        assertEq(uint8(vault.getTask(d).status), uint8(TaskStatus.Expired));
        vm.prank(alice);
        sweetener.withdraw(d);
        assertEq(sweetener.bonusOf(d), 0);
        _claimEverythingAndCheck();
    }

    function test_UnwoundTaskReturnsTheBonus() public {
        allowEmergency = true;
        _sweeten(alice, t, 7e18);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        vm.mockCallRevert(address(vault), abi.encodeWithSelector(TaskVault.advanceFromSelf.selector, t), "");
        _warp(LONG);
        vault.emergencyExit(t);
        vm.clearMockedCalls();
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Unwound));
        vm.prank(alice);
        sweetener.withdraw(t);
        assertEq(sweetener.bonusOf(t), 0);
        _claimEverythingAndCheck();
    }

    function test_PayoutOnlyForTheAcceptedSubmissionOfThatTask() public {
        uint256 other = _create(author, address(imd), 10e18);
        _sweeten(alice, t, 100e18);
        uint256 sOther = _submit(doer2, other);
        uint256 s = _submit(doer, t);
        vm.warp(_sub(s).windowEnd + 1);
        vault.poke(t);
        vault.poke(other);
        assertEq(uint8(_sub(sOther).outcome), uint8(Outcome.Accepted));
        vm.expectRevert(YoloSweetener.NotAccepted.selector);
        sweetener.payout(t, sOther); // accepted, but on another task
        vm.expectRevert(YoloSweetener.NothingToPay.selector);
        sweetener.payout(other, sOther); // nobody sweetened that one
        sweetener.payout(t, s);
        assertEq(yolo.balanceOf(treasury), 10e18);
        _claimEverythingAndCheck();
    }

    function test_RefusedInputs() public {
        vm.prank(alice);
        vm.expectRevert(YoloSweetener.ZeroAmount.selector);
        sweetener.sweeten(t, 0);
        vm.prank(alice);
        vm.expectRevert(YoloSweetener.TaskNotOpen.selector);
        sweetener.sweeten(999, 1e18); // no such task
        vm.expectRevert(YoloSweetener.NotAccepted.selector);
        sweetener.payout(t, 1); // the task is still open
        vm.expectRevert(YoloSweetener.ZeroAddress.selector);
        new YoloSweetener(address(0));
    }

    /// @dev Open, no active submission: a sweetener may change his mind, like a contributor with an idle share,
    ///      after an hour of public notice.
    function test_WithdrawWhileIdle(uint256 amount) public {
        amount = bound(amount, 1, yolo.balanceOf(bob));
        _sweeten(bob, t, amount);
        uint256 before = yolo.balanceOf(bob);
        vm.prank(bob);
        sweetener.announceWithdraw(t);
        _warp(sweetener.NOTICE());
        vm.prank(bob);
        sweetener.withdraw(t);
        assertEq(yolo.balanceOf(bob) - before, amount);
        assertEq(yolo.balanceOf(address(sweetener)), 0);
    }

    function _sweeten(address who, uint256 taskId, uint256 amount) internal {
        vm.prank(who);
        sweetener.sweeten(taskId, amount);
    }
}
