// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";

/// @dev Emergency exit: a step left open 30 days after its timer unwinds the task; everyone takes back what he
///      put in (minus what already went to the swarm or relayers).
contract EmergencyTest is Base {
    uint256 internal t;
    uint256 internal s;
    uint256 internal s2;

    function setUp() public override {
        super.setUp();
        allowEmergency = true;
        t = _create(author, address(usdc), 100e6);
        _topUp(alice, t, 50e6);
        s = _submit(doer, t);
        s2 = _submit(doer2, t); // queued
        _topUp(bob, t, 20e6); // pending
        _dispute(dave, s);
    }

    /// @dev The appeal question can never be asked (Intake reverts) and the machine itself keeps failing (a
    ///      broken dependency): after 30 days past the step timer anyone unwinds the task.
    function test_Unwind_WhenAdvanceKeepsFailing() public {
        _vote(s, 1, 1, 120, 20);
        _warp(24 hours);
        vault.poke(t);
        _appeal(erin, s);
        vm.mockCallRevert(address(vault), abi.encodeWithSelector(TaskVault.advanceFromSelf.selector, t), "");
        _warp(12 hours + 30 days - 1);
        vm.expectRevert(NotStuck.selector);
        vault.emergencyExit(t);
        _warp(1);
        vault.emergencyExit(t);
        vm.clearMockedCalls();
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Unwound));
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Unwound));

        // everyone gets exactly what he put in (the author fee is a non-refundable fee, already in treasury)
        _expectBack(author, address(usdc), 100e6);
        _expectBack(alice, address(usdc), 50e6);
        _expectBack(bob, address(usdc), 20e6);
        assertEq(vault.credits(address(imd), doer), _sub(s).bond); // 1.0625 IMD (R = 150 USDC)
        assertEq(vault.credits(address(imd), erin), 1e18 + PRICE); // bond + untouched fee
        vault.claimVoidSubmission(s2);
        assertEq(imd.balanceOf(doer2), 10_000e18);
        uint256 before = dave.balance;
        vm.prank(dave);
        vault.claimDisputer(s);
        assertEq(imd.balanceOf(dave), 10_000e18);
        assertEq(dave.balance - before, 0.001 ether);
        _claimEverythingAndCheck();
    }

    function test_AppealAskedLazily_NoUnwindNeeded() public {
        _vote(s, 1, 1, 120, 20);
        _warp(24 hours);
        vault.poke(t);
        _appeal(erin, s);
        _warp(12 hours + 31 days); // nobody poked: the question is asked by the self-advance, no exit
        vm.expectRevert(NotStuck.selector);
        vault.emergencyExit(t);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.Asked));
        _answer(s, true);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        _claimEverythingAndCheck();
    }

    function test_NoDecision_ResolvesItself_NoUnwind() public {
        _warp(24 hours); // vote over, no votes -> NoDecision, nobody calls the swarm
        _warp(31 days);
        vm.expectRevert(NotStuck.selector); // the self-advance accepts the submission first
        vault.emergencyExit(t);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertFalse(vault.getSettlement(s).neutral);
        _claimEverythingAndCheck();
    }

    function test_SwarmNeverAnswers_NoUnwind() public {
        _warp(24 hours);
        _callSwarm(erin, s);
        // the swarm never answers and nobody pokes for a long time: silence, then the undecided window ends
        _warp(40 days);
        vm.expectRevert(NotStuck.selector);
        vault.emergencyExit(t);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(vault.credits(address(imd), erin), 1e18); // her bond back, the fee went to the swarm
        vault.claimVoidSubmission(s2);
        _claimEverythingAndCheck();
    }

    function test_NoUnwind_WhenTheStateMachineCanResolve() public {
        _vote(s, 1, 1, 120, 20);
        _warp(24 hours + 24 hours + 31 days); // decided, appeal window over long ago
        vm.expectRevert(NotStuck.selector); // the self-advance accepts the submission first
        vault.emergencyExit(t);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        _claimEverythingAndCheck();
    }

    function test_EmergencyNeedsGas() public {
        vm.expectRevert(InsufficientGas.selector);
        vault.emergencyExit{gas: 2_000_000}(t);
    }

    function _expectBack(address who, address token, uint256 amount) internal {
        uint256 before = IERC20(token).balanceOf(who);
        vm.prank(who);
        vault.withdrawContribution(t);
        assertEq(IERC20(token).balanceOf(who) - before, amount);
    }
}
