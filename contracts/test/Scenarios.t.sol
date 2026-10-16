// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";

/// @dev Fuzzed end-to-end cases. Whatever the path, after everyone claims: the vault holds exactly what it owes,
///      and owes nothing after the treasury is swept. Value only left to the swarm payee.
contract ScenariosTest is Base {
    bool internal callerSidesDoer;

    struct Case {
        uint8 currency; // 0 ETH, 1 USDC, 2 IMD
        uint256 amount;
        bool topUp;
        uint8 disputers; // 0..3
        uint8 acceptVotes; // 0..120 (voter0)
        uint8 rejectVotes; // 0..30 (voter1 + voter2)
        uint8 swarm; // first swarm call: 0 true, 1 false, 2 silent, 3 nobody calls
        uint8 swarm2; // call after a silence: same coding
        uint8 check; // mandatory check: 0 passes, 1 fails, 2 silent (status 2), 3 silent (timeout)
        bool callerSidesDoer; // side of a NoDecision swarm caller
        uint32 basefeeGwei;
        uint16 intakePriceCenti; // 10..100 => 0.1..1 IMD
        uint16 priceChangeCenti; // price at the time of the second call
    }

    function testFuzz_Scenario(Case memory c) public {
        c.currency = uint8(bound(c.currency, 0, 2));
        if (c.currency == 0) c.amount = bound(c.amount, 0.002 ether, 2 ether);
        else if (c.currency == 1) c.amount = bound(c.amount, 5e6, 2_000e6);
        else c.amount = bound(c.amount, 1e18, 300e18);
        c.disputers = uint8(bound(c.disputers, 0, 3));
        c.acceptVotes = uint8(bound(c.acceptVotes, 0, 120));
        c.rejectVotes = uint8(bound(c.rejectVotes, 0, 30));
        c.swarm = uint8(bound(c.swarm, 0, 3));
        c.swarm2 = uint8(bound(c.swarm2, 0, 3));
        c.check = uint8(bound(c.check, 0, 3));
        c.basefeeGwei = uint32(bound(c.basefeeGwei, 0, 200));
        c.intakePriceCenti = uint16(bound(c.intakePriceCenti, 10, 100));
        c.priceChangeCenti = uint16(bound(c.priceChangeCenti, 10, 150));
        _run(c);
        _claimEverythingAndCheck();
        // the reward never goes to a disputer or a swarm caller: dave, erin (disputers) and bob (caller) never
        // contributed, so they cannot end with more of the reward currency than they started with
        if (c.currency == 1) {
            assertLe(usdc.balanceOf(dave), 1_000_000e6, "reward to a disputer");
            assertLe(usdc.balanceOf(erin), 1_000_000e6, "reward to a disputer");
            assertLe(usdc.balanceOf(bob), 1_000_000e6, "reward to a caller");
        }
        // value conservation for IMD: everything minted is with actors, the vault, or the swarm payee
        uint256 total = imd.balanceOf(address(vault)) + imd.balanceOf(swarmPayee) + imd.balanceOf(address(adapter));
        for (uint256 i; i < actors.length; ++i) {
            total += imd.balanceOf(actors[i]);
        }
        assertEq(total, imd.totalSupply());
    }

    function _run(Case memory c) internal {
        address cur = c.currency == 0 ? ETH : c.currency == 1 ? address(usdc) : address(imd);
        intake.setPrice(uint256(c.intakePriceCenti) * 1e16);
        vm.fee(uint256(c.basefeeGwei) * 1 gwei);
        callerSidesDoer = c.callerSidesDoer;
        uint256 t = _create(author, cur, c.amount);
        if (c.topUp) _topUp(alice, t, c.amount / 2);
        uint256 s = _submit(doer, t);
        _submit(doer2, t); // a queued competitor, judged afterwards

        if (_sub(s).large) {
            if (c.check == 1) {
                _answer(s, false);
                return;
            }
            if (c.check == 2) _silent(s);
            else if (c.check == 3) _warp(6 hours + SWARM_DELIVERY_GRACE); // timeout + delivery grace (swarm #7)
            else _answer(s, true);
            vault.poke(t); // the dispute window opens from the answer / the silence
        }
        address[3] memory ds = [dave, erin, alice];
        for (uint256 i; i < c.disputers; ++i) {
            _dispute(ds[i], s);
        }
        if (c.disputers == 0) return; // accepted by the timer
        if (c.acceptVotes != 0) _vote(s, 0, 1, 0, c.acceptVotes);
        if (_phase(s) == Phase.Voting && c.rejectVotes != 0) {
            uint256 fromV1 = c.rejectVotes > 20 ? 20 : c.rejectVotes;
            _vote(s, 1, 2, 120, fromV1);
            if (c.rejectVotes > 20 && _phase(s) == Phase.Voting) _vote(s, 2, 2, 140, c.rejectVotes - 20);
        }
        if (_phase(s) == Phase.Voting) {
            _warp(24 hours);
            vault.poke(t);
        }
        // NoDecision: anyone calls the swarm paying; Decided: an appeal against the decision
        if (!_call(s, c.swarm, bob)) return;
        _warp(6 hours);
        vault.poke(t);
        if (_phase(s) != Phase.NoDecision && _phase(s) != Phase.Decided) return;
        intake.setPrice(uint256(c.priceChangeCenti) * 1e16);
        _call(s, c.swarm2, erin);
    }

    /// @dev One paid call to the swarm in the current state; true if the swarm stayed silent.
    function _call(uint256 s, uint8 mode, address who) internal returns (bool silent) {
        if (mode == 3) return false; // nobody calls: the standing state finalizes by the timer
        if (_phase(s) == Phase.NoDecision) {
            _callSwarm(who, s, callerSidesDoer);
        } else {
            address appellant = _sub(s).nftDecision == Verdict.Accept ? who : doer;
            _appeal(appellant, s);
            _warp(12 hours);
            vault.poke(_sub(s).taskId); // asks; may void the appeal if the price moved above the prepaid fee
            if (_phase(s) != Phase.Asked) return false;
        }
        if (mode == 2) {
            _silent(s);
            return true;
        }
        _answer(s, mode == 0);
        return false;
    }
}
