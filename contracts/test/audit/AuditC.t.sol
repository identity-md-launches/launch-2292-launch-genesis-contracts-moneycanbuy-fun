// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../Base.t.sol";
import {TextLib} from "../../src/helpers/TextRules.sol";

/// @dev An ERC-1271 "wallet" that says "valid" in a simulation (eth_call / eth_estimateGas run with gas price 0) and
///      burns every unit of gas it gets in a real transaction. It needs no NFT to poison a batch: the signature is
///      checked before ownership.
contract GasBurner1271 {
    function isValidSignature(bytes32, bytes calldata) external view returns (bytes4) {
        if (tx.gasprice == 0) return 0x1626ba7e;
        uint256 x;
        while (true) {
            x = uint256(keccak256(abi.encode(x)));
        }
        return 0x1626ba7e;
    }
}

/// @dev A plain contract wallet: valid if its owner key signed the hash.
contract OwnerWallet1271 {
    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function isValidSignature(bytes32 h, bytes calldata sig) external view returns (bytes4) {
        (uint8 v, bytes32 r, bytes32 s) = (uint8(sig[64]), bytes32(sig[0:32]), bytes32(sig[32:64]));
        return ecrecover(h, v, r, s) == owner ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

/// @dev Harness: TextLib.validText against a byte-by-byte reference implementation.
contract TextHarness {
    function fast(string calldata s, uint256 maxLen) external pure returns (bool) {
        return TextLib.validText(s, maxLen);
    }
}

/// @title Audit C (submissions and disputes): regression tests and guards.
///        Acknowledged findings are described in docs/AUDIT-INTERNAL.md; each lists its impact and why it was accepted.
contract AuditCTest is Base {
    uint8 internal constant ACCEPT = 1;
    uint8 internal constant REJECT = 2;

    function _contains(bytes memory hay, bytes memory needle) internal pure returns (bool) {
        if (needle.length > hay.length) return false;
        for (uint256 i; i <= hay.length - needle.length; ++i) {
            uint256 k;
            while (k < needle.length && hay[i + k] == needle[k]) ++k;
            if (k == needle.length) return true;
        }
        return false;
    }

    function _disputeWith(address who, uint256 subId, string memory reason, uint256 fee) internal {
        vm.prank(who);
        vault.dispute{value: fee}(subId, reason, fee, _noSwap());
    }

    // =====================================================================================================
    // C-01  The inputs of a swarm question are first-come: the side the question is meant to hear can be
    //       locked out of it (appeal reply, appeal / call slot, first maxClaims reasons). C-01a is fixed (below);
    //       the Sybil remainder C-01b / C-01c is acknowledged (docs/AUDIT-INTERNAL.md).
    // =====================================================================================================

    /// @dev C-01a (fixed: the doer cannot dispute his own submission). Before, "appeal opponent: the doer, or
    ///      any disputer when the appeal sides with the doer" let the doer, disputing himself first, appeal the NFT
    ///      reject and answer his own appeal in the name of his opponents: the one reply was spent, the real disputer
    ///      locked out, and the question went out on the very next call. Now his dispute reverts, he is never "a
    ///      disputer", his own reply reverts NotOpponent, and the real disputer's reply reaches the swarm.
    function test_Fixed_C01a_DoerCannotAnswerHisOwnAppealInTheNameOfTheDisputers() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        vm.deal(doer, 1 ether);
        vm.prank(doer); // the doer tries to dispute himself first
        vm.expectRevert(DoerCannotDispute.selector);
        vault.dispute{value: 0.0003 ether}(s, "placeholder", 0.0003 ether, _noSwap());
        _disputeWith(dave, s, "The post was published before the task was created", 0.001 ether);
        _vote(s, 0, REJECT, 0, 120); // the NFT holders agree with dave
        _endVote(s); // decided at the vote end: reject
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));

        vm.prank(doer);
        vault.appeal(s, "My proof is valid", type(uint256).max, _noSwap());
        assertTrue(vault.getAppeal(s).sidesDoer);
        vm.prank(doer); // the doer is not a disputer: he cannot answer for them
        vm.expectRevert(NotOpponent.selector);
        vault.appealReply(s, "Disputers agree the proof is valid and withdraw the claim");

        vm.prank(dave); // the real opponent answers
        vault.appealReply(s, "The post predates the task, see its timestamp");

        (bytes memory body,) = vault.previewSwarmBody(s, SWARM_KIND_APPEAL);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.Asked));
        assertEq(intake.lastBodyHash(), keccak256(body), "this is the body the swarm got");
        assertTrue(_contains(body, bytes('"appeal_reply":"The post predates the task, see its timestamp"')));
        assertFalse(_contains(body, bytes("withdraw the claim")));
        assertFalse(_contains(body, bytes("placeholder")), "no claim of the doer");
    }

    // =====================================================================================================
    // C-02  Mixing sides in a relayed batch (an earlier mitigation) does not survive a public mempool: anyone can lift
    //       one side's ballots out of the pending batch and relay them first.
    // =====================================================================================================

    /// @dev C-02 (fixed: no instant decision on a partial count). Honest batch: 120 accept + 115 reject
    ///      (margin 5) -> NoDecision at vote end (margin < 10). Before, a front-runner without a single NFT copied the
    ///      accept ballot out of the pending transaction and relayed it alone: 120 >= 100 decided "accept" at once,
    ///      the honest batch reverted (WrongPhase) and the 115 reject votes were never counted. Now the lifted ballot
    ///      only counts; the honest batch still lands (its copied ballot is skipped as already voted), the 115 reject
    ///      votes count and the vote end gives the same result as the whole batch: no decision.
    function test_Fixed_C02_FrontRunnerCannotUnbundleAMixedBatch() public {
        uint256 rKey = 0xB0B6;
        address rVoter = vm.addr(rKey);
        for (uint256 id = 1000; id < 1115; ++id) {
            nft.mint(rVoter, id);
        }
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);

        Ballot[] memory batch = new Ballot[](2);
        batch[0] = _ballot(s, 0, ACCEPT, _ids(0, 120), voters[0]);
        batch[1] = _ballotByKey(s, rKey, REJECT, _ids(1000, 115), rVoter, _sub(s).voteEnd);

        vm.fee(1 gwei);
        address frontRunner = makeAddr("frontRunner");
        actors.push(frontRunner); // claims his relay credit at the end
        Ballot[] memory lifted = new Ballot[](1);
        lifted[0] = batch[0];
        vm.prank(frontRunner);
        vault.submitVotes(s, lifted);
        assertEq(uint8(_phase(s)), uint8(Phase.Voting), "a partial count decides nothing");
        assertEq(uint8(_sub(s).nftDecision), uint8(Verdict.None));
        vm.prank(relayer);
        vault.submitVotes(s, batch); // the honest batch lands after all
        assertEq(vault.getDispute(s).votesAccept, 120, "the lifted ballot counted once");
        assertEq(vault.getDispute(s).votesReject, 115, "115 reject votes counted");
        _endVote(s);
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision), "the full count: no decision");
        _claimEverythingAndCheck();
    }

    // =====================================================================================================
    // C-03  One ERC-1271 ballot can make a whole vote batch revert ("bad ballots are skipped, never revert")
    // =====================================================================================================

    function _poisonedBatch(uint256 s) internal returns (Ballot[] memory bs) {
        GasBurner1271 b1 = new GasBurner1271();
        GasBurner1271 b2 = new GasBurner1271();
        bs = new Ballot[](3);
        bs[0] = Ballot({voter: address(b1), side: ACCEPT, payTo: address(b1), tokenIds: _ids(9000, 1), signature: hex"00"});
        bs[1] = Ballot({voter: address(b2), side: ACCEPT, payTo: address(b2), tokenIds: _ids(9001, 1), signature: hex"00"});
        bs[2] = _ballot(s, 1, REJECT, _ids(120, 20), voters[1]); // an honest ballot in the same batch
    }

    /// @dev Original code: in a simulation (gas price 0) the batch passes; in the real transaction the two burners
    ///      eat 63/64 of the gas twice and the batch runs out of gas at any gas limit up to the EIP-7825 cap. The
    ///      honest votes in it are not counted; the relayer pays for the failed transaction.
    function test_Fixed_C03_GasBurningErc1271BallotDoesNotRevertTheBatch() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        Ballot[] memory bs = _poisonedBatch(s);
        bytes memory call = abi.encodeCall(ITaskVault.submitVotes, (s, bs));

        vm.txGasPrice(0); // the relayer's eth_call / estimateGas
        uint256 snap = vm.snapshotState();
        vm.prank(relayer);
        (bool simOk,) = address(vault).call{gas: 16_000_000}(call);
        assertTrue(simOk, "simulation passes");
        vm.revertToState(snap);

        vm.txGasPrice(1 gwei); // the real transaction, the full EIP-7825 gas cap
        vm.prank(relayer);
        (bool ok,) = address(vault).call{gas: 16_000_000}(call);
        // original code: out of gas, the honest ballot is lost with the batch; fixed: the burners are skipped
        if (!ok) emit log("C-03: the whole batch reverted (original code)");
        assertTrue(ok, "C-03: a poisoned ballot reverted the whole batch");
        assertEq(vault.getDispute(s).votesReject, 20, "the honest votes are counted");
        assertEq(vault.getDispute(s).votesAccept, 0, "the burners are skipped");
    }

    /// @dev Regression for the fix (gas cap on the ERC-1271 call): the batch survives two burners and a real contract
    ///      wallet in the same batch still votes through ERC-1271.
    function test_Fix_C03_GasBurnerSkipped_HonestErc1271StillVotes() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        uint256 ownerKey = 0xC0FFEE;
        OwnerWallet1271 w = new OwnerWallet1271(vm.addr(ownerKey));
        for (uint256 id = 9100; id < 9105; ++id) {
            nft.mint(address(w), id);
        }
        Ballot[] memory poisoned = _poisonedBatch(s);
        Ballot[] memory bs = new Ballot[](4);
        for (uint256 i; i < 3; ++i) {
            bs[i] = poisoned[i];
        }
        bs[3] = _ballotByKey(s, ownerKey, ACCEPT, _ids(9100, 5), address(w), _sub(s).voteEnd);
        bs[3].voter = address(w); // signed by the owner key, cast by the wallet

        vm.txGasPrice(1 gwei);
        vm.prank(relayer);
        (bool ok,) = address(vault).call{gas: 16_000_000}(abi.encodeCall(ITaskVault.submitVotes, (s, bs)));
        assertTrue(ok, "batch survives two burners");
        assertEq(vault.getDispute(s).votesReject, 20, "honest EOA ballot counted");
        assertEq(vault.getDispute(s).votesAccept, 5, "honest ERC-1271 wallet counted");
        (uint256 acc,) = vault.votesOf(s, address(w));
        assertEq(acc, 5);
    }

    // =====================================================================================================
    // Checked: the word-at-a-time ASCII path of TextLib.validText equals a byte-by-byte reference
    // =====================================================================================================

    function _refValid(bytes memory b, uint256 maxLen) internal pure returns (bool) {
        uint256 len = b.length;
        if (len == 0 || len > maxLen) return false;
        uint256 i;
        while (i < len) {
            uint8 c = uint8(b[i]);
            if (c < 0x80) {
                if (c < 0x20 || c == 0x22 || c == 0x5c || c == 0x7f) return false;
                ++i;
                continue;
            }
            uint256 n;
            uint8 lo = 0x80;
            uint8 hi = 0xbf;
            if (c >= 0xc2 && c <= 0xdf) n = 1;
            else if (c >= 0xe0 && c <= 0xef) {
                n = 2;
                if (c == 0xe0) lo = 0xa0;
                if (c == 0xed) hi = 0x9f;
            } else if (c >= 0xf0 && c <= 0xf4) {
                n = 3;
                if (c == 0xf0) lo = 0x90;
                if (c == 0xf4) hi = 0x8f;
            } else {
                return false;
            }
            if (i + n >= len) return false;
            if (uint8(b[i + 1]) < lo || uint8(b[i + 1]) > hi) return false;
            for (uint256 k = 2; k <= n; ++k) {
                if (uint8(b[i + k]) < 0x80 || uint8(b[i + k]) > 0xbf) return false;
            }
            i += n + 1;
        }
        return true;
    }

    function testFuzz_ValidTextMatchesReference(bytes memory raw, uint8 mode, uint8 at) public {
        TextHarness h = new TextHarness();
        // mostly printable ASCII (to exercise the 32-byte path), with one injected byte
        bytes memory b = new bytes(raw.length % 200 + 1);
        for (uint256 i; i < b.length; ++i) {
            b[i] = bytes1(uint8(0x20 + uint8(i < raw.length ? raw[i] : bytes1(0)) % 0x5f));
        }
        if (mode % 3 == 0) b[at % b.length] = bytes1(uint8(raw.length != 0 ? raw[0] : bytes1(0)));
        else if (mode % 3 == 1) b[at % b.length] = bytes1(uint8(mode));
        assertEq(h.fast(string(b), 256), _refValid(b, 256));
        assertEq(h.fast(string(raw), 256), _refValid(raw, 256));
    }
}
