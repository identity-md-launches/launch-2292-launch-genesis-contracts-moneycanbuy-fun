// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "../Base.t.sol";
import "../../src/VaultTypes.sol";

/// @dev Fuzz with overlapping roles (the doer tries to dispute himself - that is DoerCannotDispute,
///      audit C-01; the author and a contributor dispute, the doer or a contributor calls the swarm / appeals). After all
///      payouts: the vault owes nothing and holds nothing; IMD is conserved; the reward (USDC) goes only to the doer,
///      the NFT votes and the treasury, contributors get back no more than they put in.
contract ReviewRoles is Base {
    struct Case {
        uint8 d0; // disputers: index in people (0 = none)
        uint8 d1;
        uint8 d2;
        uint8 caller; // who calls the swarm / appeals
        uint8 accept;
        uint8 reject;
        uint8 swarm; // 0 yes, 1 no, 2 silence, 3 nobody
        bool sidesDoer;
        uint32 basefeeGwei;
    }

    function _who(uint8 i) internal view returns (address) {
        address[5] memory people = [doer, author, alice, dave, erin];
        return people[i % 5];
    }

    function testFuzz_RoleOverlap(Case memory c) public {
        c.accept = uint8(bound(c.accept, 0, 120));
        c.reject = uint8(bound(c.reject, 0, 30));
        c.swarm = uint8(bound(c.swarm, 0, 3));
        vm.fee(bound(c.basefeeGwei, 0, 100) * 1 gwei);

        uint256 t = _create(author, address(usdc), 200e6);
        _topUp(alice, t, 50e6);
        uint256 s = _submit(doer, t);

        uint8[3] memory ds = [c.d0, c.d1, c.d2];
        uint256 n;
        for (uint256 i; i < 3; ++i) {
            address d = _who(ds[i]);
            if (vault.getDisputer(s, d).bond != 0) continue;
            if (d == doer) {
                vm.prank(doer);
                vm.expectRevert(DoerCannotDispute.selector);
                vault.dispute{value: 0.001 ether}(s, "ipfs://reason", 0.001 ether, _noSwap());
                continue;
            }
            _dispute(d, s);
            ++n;
        }
        if (n != 0 && c.accept != 0) _vote(s, 0, 1, 0, c.accept);
        if (_phase(s) == Phase.Voting && c.reject != 0) {
            _vote(s, 1, 2, 120, c.reject > 20 ? 20 : c.reject);
            if (c.reject > 20 && _phase(s) == Phase.Voting) _vote(s, 2, 2, 140, c.reject - 20);
        }
        if (_phase(s) == Phase.Voting) {
            _warp(24 hours);
            vault.poke(t);
        }
        address caller = _who(c.caller);
        // the doer never takes the swarm slot against his own submission (swarm audit #4)
        Phase ph = _phase(s);
        bool againstSelf =
            caller == doer && (ph == Phase.NoDecision ? !c.sidesDoer : _sub(s).nftDecision == Verdict.Accept);
        if (c.swarm != 3 && againstSelf && (ph == Phase.NoDecision || ph == Phase.Decided)) {
            vm.prank(doer);
            vm.expectRevert(DoerCannotDispute.selector);
            if (ph == Phase.NoDecision) {
                vault.callSwarm(s, false, "ipfs://caller-reason", type(uint256).max, _noSwap());
            } else {
                vault.appeal(s, "ipfs://appeal", type(uint256).max, _noSwap());
            }
        } else if (c.swarm != 3) {
            if (_phase(s) == Phase.NoDecision) {
                _callSwarm(caller, s, c.sidesDoer);
            } else if (_phase(s) == Phase.Decided) {
                _appeal(caller, s);
                _warp(12 hours);
                vault.poke(t);
            }
            if (_phase(s) == Phase.Asked) {
                if (c.swarm == 2) _silent(s);
                else _answer(s, c.swarm == 0);
            }
        }
        _claimEverythingAndCheck();

        // IMD is conserved
        uint256 total = imd.balanceOf(address(vault)) + imd.balanceOf(swarmPayee) + imd.balanceOf(address(adapter));
        for (uint256 i; i < actors.length; ++i) {
            total += imd.balanceOf(actors[i]);
        }
        assertEq(total, imd.totalSupply(), "IMD conservation");
        // reward: disputers who are not contributors (dave, erin) get no USDC
        assertLe(usdc.balanceOf(dave), 1_000_000e6, "reward to dave");
        assertLe(usdc.balanceOf(erin), 1_000_000e6, "reward to erin");
        // contributor alice gets back no more than she put in
        assertLe(usdc.balanceOf(alice), 1_000_000e6, "alice got more than she put in");
        Submission memory sub = _sub(s);
        if (sub.outcome != Outcome.Accepted) {
            // not accepted: the doer (unless author/contributor) gets no USDC
            assertEq(usdc.balanceOf(doer), 1_000_000e6, "reward paid on a non-accepted outcome");
        }
    }
}
