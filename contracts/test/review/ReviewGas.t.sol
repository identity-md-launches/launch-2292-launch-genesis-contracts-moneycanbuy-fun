// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/console.sol";
import {Base} from "../Base.t.sol";
import "../../src/VaultTypes.sol";

/// @dev Gas of the heaviest lazy steps at the maximum current parameters (16 disputers, 256-byte texts).
contract ReviewGas is Base {
    uint8 constant REJECT = 2;

    function _longText(bytes1 c) internal pure returns (string memory) {
        bytes memory b = new bytes(256);
        for (uint256 i; i < 256; ++i) {
            b[i] = c;
        }
        return string(b);
    }

    /// @dev The longest valid proof: a link to an X post (task type x_post), padded to 256 bytes with a query tail.
    function _longProof() internal pure returns (string memory) {
        bytes memory head = "https://x.com/doer/status/1?";
        bytes memory b = new bytes(256);
        for (uint256 i; i < 256; ++i) {
            b[i] = i < head.length ? head[i] : bytes1("p");
        }
        return string(b);
    }

    function _fullCase() internal returns (uint256 t, uint256 s) {
        t = _create(author, address(usdc), 100e6);
        vm.prank(doer);
        s = vault.submit(t, _longProof(), _noEvidence(), 0, type(uint256).max, _noSwap());
        for (uint256 i; i < 16; ++i) {
            address d = address(uint160(0xD15000 + i));
            vm.deal(d, 1 ether);
            imd.mint(d, 10e18);
            vm.startPrank(d);
            imd.approve(address(vault), type(uint256).max);
            vault.dispute{value: 0.001 ether}(s, _longText("r"), 0.001 ether, _noSwap());
            vm.stopPrank();
        }
        vm.prank(doer);
        vault.reply(s, _longText("d"));
    }

    /// The poke that asks the appeal question must fit EMERGENCY_ADVANCE_GAS (2.5M) with margin, otherwise the
    /// emergency exit unwinds a case the machine could have advanced.
    function test_R6_AppealAskGas_UnderEmergencyBudget() public {
        (uint256 t, uint256 s) = _fullCase();
        _vote(s, 0, REJECT, 0, 100);
        _endVote(s); // the NFT decides at the vote end
        vm.prank(doer);
        vault.appeal(s, _longText("a"), type(uint256).max, _noSwap());
        vm.prank(address(uint160(0xD15000)));
        vault.appealReply(s, _longText("b"));
        uint256 g = gasleft();
        vault.poke(t);
        g -= gasleft();
        console.log("poke -> appeal question, gas:", g);
        console.log("body bytes:", intake.lastBodyLength());
        assertEq(uint8(_phase(s)), uint8(Phase.Asked));
        assertLt(g, 1_500_000);
    }

    function test_R6_CallSwarmGas_MaxBody() public {
        (uint256 t, uint256 s) = _fullCase();
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        vm.prank(dave);
        uint256 g = gasleft();
        vault.callSwarm(s, false, "ipfs://caller-reason", type(uint256).max, _noSwap());
        g -= gasleft();
        console.log("callSwarm max body, gas:", g);
        console.log("body bytes:", intake.lastBodyLength());
    }
}
