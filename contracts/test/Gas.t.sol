// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";

/// @dev Steady-state gas of the main functions (warm-ish storage like on mainnet after the first task). Printed with
///      -vv; numbers are also asserted against loose ceilings. Since the launch split (vault + two desks, parameters
///      read from the registry per call) createTask and submit cost ~25k / ~75k more than the single-contract vault
///      (331k / 379k); the ceilings were raised from 350k / 450k accordingly.
contract GasTest is Base {
    function setUp() public override {
        super.setUp();
        _create(author, address(usdc), 50e6); // the first task of the version: warms the registry and the desks
    }

    uint256 internal g0;

    function _start() internal {
        g0 = gasleft();
    }

    /// @dev Gas between _start and here, minus the test's own overhead of ~3k (SLOAD/SSTORE of g0 + prank).
    function _measure(string memory name) internal returns (uint256 g) {
        g = g0 - gasleft();
        emit log_named_uint(name, g);
    }

    function test_GasProfile() public {
        _start();
        uint256 t = _create(author, address(usdc), 100e6);
        assertLt(_measure("createTask (USDC, mode B)"), 400_000);

        _start();
        _create(author, ETH, 0.05 ether);
        _measure("createTask (ETH)");

        _start();
        _topUp(alice, t, 10e6);
        _measure("topUp (idle task)");

        _start();
        uint256 s = _submit(doer, t);
        assertLt(_measure("submit (small task, mode B)"), 500_000);

        _start();
        _topUp(bob, t, 10e6);
        _measure("topUp (pending, during submission)");

        _start();
        _dispute(dave, s);
        _measure("dispute (first: starts the vote)");

        _start();
        _dispute(erin, s);
        _measure("dispute (second)");

        _start();
        vm.prank(doer);
        vault.reply(s, "ipfs://reply");
        _measure("reply");

        Ballot[] memory bs = new Ballot[](1);
        bs[0] = _ballot(s, 1, 2, _ids(120, 20), voters[1]);
        _start();
        vm.prank(relayer);
        vault.submitVotes(s, bs);
        _measure("submitVotes (1 ballot, 20 NFTs)");

        Ballot[] memory bs3 = new Ballot[](3);
        bs3[0] = _ballot(s, 2, 2, _ids(140, 10), voters[2]);
        bs3[1] = _ballot(s, 3, 1, _ids(150, 5), voters[3]);
        bs3[2] = _ballot(s, 4, 1, _ids(155, 2), voters[4]);
        _start();
        vm.prank(relayer);
        vault.submitVotes(s, bs3);
        _measure("submitVotes (3 ballots, 17 NFTs)");

        _warp(24 hours);
        _start();
        vault.poke(t);
        _measure("poke (vote end -> decided)");

        _start();
        _appeal(doer, s);
        _measure("appeal");

        _warp(12 hours);
        _start();
        vault.poke(t);
        _measure("poke (reply window over -> asks the appeal; builds body, pays Intake)");

        OracleAttestation.Attestation memory a = _attestation(false);
        bytes memory sig = _sign(a, attesterKey);
        intake.complete(_sub(s).request, 0, a, sig);
        emit log_named_uint("onOracleResult (inside the 200k callback budget)", intake.lastCallbackGasUsed());

        _start();
        vault.poke(t);
        _measure("poke (final settlement, rejected)");

        _start();
        vm.prank(dave);
        vault.claimDisputer(s);
        _measure("claimDisputer (bond + share + ETH)");

        _start();
        vault.claimVoterReward(s, voters[1]);
        _measure("claimVoterReward (bond share)");

        // next submission on the same task: accepted without dispute
        uint256 s2 = _submit(doer2, t);
        _warp(24 hours);
        _start();
        vault.poke(t);
        _measure("poke (accept + fee split)");
        assertEq(uint8(_sub(s2).outcome), uint8(Outcome.Accepted));

        _start();
        vm.prank(doer2);
        vault.withdraw(address(imd));
        _measure("withdraw (IMD credit)");

        uint256 t4 = _create(author, address(usdc), 100e6);
        _topUp(bob, t4, 10e6);
        _start();
        vm.prank(bob);
        vault.announceWithdraw(t4);
        _measure("announceWithdraw (idle task)");
        _warp(WITHDRAW_NOTICE);
        _start();
        vm.prank(bob);
        vault.withdrawContribution(t4);
        _measure("withdrawContribution (idle task)");

        // NFT undecided: a paid call to the swarm
        uint256 t3 = _create(author, address(usdc), 100e6);
        uint256 s3 = _submit(doer3, t3);
        _dispute(dave, s3);
        _warp(24 hours);
        vault.poke(t3);
        _start();
        _callSwarm(erin, s3);
        _measure("callSwarm (no NFT decision: bond + fee, builds body, pays Intake)");
        _silent(s3);
        _warp(6 hours);
        _start();
        vault.poke(t3);
        _measure("poke (swarm silent -> back to the undecided window)");

        // large task: submission asks the mandatory check in the same transaction
        uint256 tl = _create(author, address(usdc), 500e6);
        _start();
        _submit(doer, tl);
        _measure("submit (large task, includes the Intake request)");
    }

    /// @dev Submit with and without the doer's evidence from the same state (snapshot): the difference is the cost
    ///      of the screenshot digest and the note alone.
    function test_GasSubmitEvidence() public {
        bytes memory note = new bytes(MAX_NOTE_BYTES);
        for (uint256 i; i < note.length; ++i) {
            note[i] = "n";
        }
        Evidence[4] memory variants = [
            _noEvidence(),
            Evidence(keccak256("picture"), true, ""),
            Evidence(bytes32(0), false, "Reply is the 3rd one under the post"),
            Evidence(keccak256("picture"), true, string(note))
        ];
        string[4] memory names = [
            "submit, proof link only",
            "submit, + screenshot",
            "submit, + 35-byte note",
            "submit, + screenshot + 200-byte note"
        ];
        uint256[2] memory amounts = [uint256(100e6), 500e6]; // small, large (asks the check in the same call)
        for (uint256 a; a < 2; ++a) {
            uint256 t = _create(author, address(usdc), amounts[a]);
            uint256 base;
            for (uint256 v; v < 4; ++v) {
                uint256 snap = vm.snapshotState();
                _start();
                vm.prank(doer);
                vault.submit(t, "https://x.com/doer/status/1", variants[v], 0, type(uint256).max, _noSwap());
                uint256 g = _measure(string.concat(a == 0 ? "small task: " : "large task: ", names[v]));
                if (v == 0) base = g;
                else emit log_named_uint("  extra gas", g - base);
                vm.revertToState(snap);
            }
        }
    }
}
