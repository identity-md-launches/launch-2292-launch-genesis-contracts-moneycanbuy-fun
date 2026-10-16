// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/console.sol";
import {Base} from "../Base.t.sol";
import "../../src/VaultTypes.sol";

/// @dev The Intake call in TaskVault.ask is wrapped in try/catch without checking the remaining
///      gas. Hypothesis: a transaction with "just enough" gas drives Intake into OOG, the catch fires, and the
///      mandatory check of a large submission is skipped / the appeal is voided. Sweeping the gas limit in steps of
///      2000 finds no such limit: after OOG the caller keeps 1/64, which is not enough for the catch branch, and
///      everything reverts. The tests pin that it cannot be bypassed (with a mock Intake); with an expensive real
///      Intake the margin may shrink.
contract ReviewGasGrief is Base {
    uint8 constant REJECT = 2;

    /// The doer of a large task switches off the mandatory swarm check himself.
    function test_R8_SubmitWithTightGas_CannotSkipMandatoryCheck() public {
        uint256 t = _create(author, address(usdc), 1_000e6); // large (>= $300)
        uint256 found;
        for (uint256 g = 200_000; g < 1_500_000; g += 2_000) {
            uint256 snap = vm.snapshotState();
            vm.prank(doer);
            try vault.submit{gas: g}(
                t, "https://x.com/doer/status/1", _noEvidence(), 0, type(uint256).max, _noSwap()
            ) returns (
                uint256 s
            ) {
                Submission memory sub = _sub(s);
                if (sub.large && sub.check == CheckState.None && sub.windowEnd != 0) {
                    found = g;
                    break;
                }
                vm.revertToState(snap);
                break; // went through normally, with a swarm question: no more gas needed
            } catch {
                vm.revertToState(snap);
            }
        }
        console.log("submit gas that skips the mandatory check:", found);
        assertEq(found, 0, "a gas limit skips the mandatory check");
    }

    /// The side that won at the NFT vote voids the other's appeal with a cheap poke with just enough gas.
    function test_R8_PokeWithTightGas_CannotVoidAppeal() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        _vote(s, 0, REJECT, 0, 100); // NFT: reject
        _endVote(s); // decision at the end of voting
        _appeal(doer, s);
        _warp(12 hours); // reply window passed, the question is asked by the first call
        uint256 found;
        for (uint256 g = 100_000; g < 2_000_000; g += 2_000) {
            uint256 snap = vm.snapshotState();
            vm.prank(dave);
            try vault.poke{gas: g}(t) {
                if (_phase(s) == Phase.Decided) {
                    found = g;
                    break;
                }
                vm.revertToState(snap);
                break;
            } catch {
                vm.revertToState(snap);
            }
        }
        console.log("poke gas that voids the appeal:", found);
        assertEq(found, 0, "a gas limit voids the appeal");
    }
}
