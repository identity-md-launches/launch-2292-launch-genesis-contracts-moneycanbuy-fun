// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";
import {AskTerms, Facts} from "../src/desks/DeskApi.sol";
import {LaunchParams} from "../src/VaultParams.sol";

/// @dev The launch split: one public vault, two desks behind it. Who may call what, and the forwarding itself.
contract DesksTest is Base {
    address internal stranger = makeAddr("stranger");

    // ------------------------------------------------------------------ wiring

    function test_DesksAreWiredToThisVaultOnce() public {
        assertEq(caseDesk.vault(), address(vault));
        assertEq(disputeDesk.vault(), address(vault));
        assertEq(vault.caseDesk(), address(caseDesk));
        assertEq(vault.disputeDesk(), address(disputeDesk));
        vm.prank(stranger);
        vm.expectRevert(WiringClosed.selector);
        caseDesk.wire(address(registry), address(imd), address(usdc), stranger, stranger);
        vm.expectRevert(WiringClosed.selector);
        disputeDesk.wire(address(registry), address(imd), address(usdc), stranger, stranger);
    }

    function test_VaultRefusesDesksOfAnotherEnvironment() public {
        TextRules text = new TextRules();
        CaseDesk cd = new CaseDesk(
            address(registry), address(imd), address(usdc), address(text), address(new SwarmQuestionBuilder())
        );
        DisputeDesk dd = new DisputeDesk(
            address(registry), address(usdc), address(usdc), address(text), address(new BallotChecker())
        );
        AttestationChecker checker = new AttestationChecker(address(registry));
        vm.expectRevert(WrongWiring.selector); // the dispute desk was built for another IMD address
        new TaskVault(
            address(registry),
            address(imd),
            address(usdc),
            address(yolo),
            address(checker),
            address(text),
            address(cd),
            address(dd)
        );
    }

    function test_VaultRefusesCheckerOfAnotherRegistry() public {
        TextRules text = new TextRules();
        CaseDesk cd = new CaseDesk(
            address(registry), address(imd), address(usdc), address(text), address(new SwarmQuestionBuilder())
        );
        DisputeDesk dd = new DisputeDesk(
            address(registry), address(imd), address(usdc), address(text), address(new BallotChecker())
        );
        AttestationChecker foreign = new AttestationChecker(stranger);
        vm.expectRevert(WrongWiring.selector);
        new TaskVault(
            address(registry),
            address(imd),
            address(usdc),
            address(yolo),
            address(foreign),
            address(text),
            address(cd),
            address(dd)
        );
    }

    // ------------------------------------------------------------------ desks accept only the vault and each other

    function test_DeskUserFunctionsOnlyThroughTheVault() public {
        uint256 t = _create(author, address(imd), 10e18);
        ImdPay memory none;
        vm.startPrank(doer);
        vm.expectRevert(NotAuthorized.selector);
        caseDesk.submit(t, "https://example.com/p", _noEvidence(), 0, 100e18, none);
        vm.expectRevert(NotAuthorized.selector);
        disputeDesk.claimDisputer(1);
        vm.stopPrank();
    }

    function test_DeskInternalFunctionsRefuseStrangers() public {
        vm.startPrank(stranger);
        vm.expectRevert(NotAuthorized.selector);
        caseDesk.step(1);
        vm.expectRevert(NotAuthorized.selector);
        caseDesk.finalize(1, Outcome.Unwound);
        vm.expectRevert(NotAuthorized.selector);
        caseDesk.advanced(1);
        vm.expectRevert(NotAuthorized.selector);
        caseDesk.startVote(1, 1, 1);
        vm.expectRevert(NotAuthorized.selector);
        caseDesk.markAppealed(1);
        vm.expectRevert(NotAuthorized.selector);
        caseDesk.askEscalation(1, 1);
        vm.expectRevert(NotAuthorized.selector);
        disputeDesk.appealAsked(1, 1);
        vm.expectRevert(NotAuthorized.selector);
        disputeDesk.dropCaller(1);
        Facts memory f;
        vm.expectRevert(NotAuthorized.selector);
        disputeDesk.settle(1, Outcome.Accepted, false, f);
        vm.stopPrank();
    }

    function test_VaultBankAndTaskHooksRefuseStrangers() public {
        TaskVault v = TaskVault(payable(address(vault)));
        ImdPay memory none;
        AskTerms memory at;
        vm.startPrank(stranger);
        vm.expectRevert(NotAuthorized.selector);
        v.collectImd(alice, 0, 1e18, address(0), none);
        vm.expectRevert(NotAuthorized.selector);
        v.credit(address(imd), stranger, 1e18);
        vm.expectRevert(NotAuthorized.selector);
        v.pay(address(imd), stranger, 1e18);
        vm.expectRevert(NotAuthorized.selector);
        v.addTreasury(address(imd), 1e18);
        vm.expectRevert(NotAuthorized.selector);
        v.bookEth(1, false);
        vm.expectRevert(NotAuthorized.selector);
        v.settleValue(stranger, 1 ether, 0);
        vm.expectRevert(NotAuthorized.selector);
        v.ask(at, "");
        vm.expectRevert(NotAuthorized.selector);
        v.advance(1);
        vm.expectRevert(NotAuthorized.selector);
        v.place(1, 1, false);
        vm.expectRevert(NotAuthorized.selector);
        v.closeSubmission(1, Outcome.Accepted, 0);
        vm.expectRevert(OnlySelf.selector);
        v.advanceFromSelf(1);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ forwarding

    function test_UnknownFunctionAndStrayEthRevert() public {
        (bool ok, bytes memory ret) = address(vault).call(abi.encodeWithSignature("nope()"));
        assertFalse(ok);
        assertEq(bytes4(ret), UnknownFunction.selector);
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (ok,) = address(vault).call{value: 1}("");
        assertFalse(ok, "plain ETH has no route");
    }

    function test_ValueOnlyToPayableRoutes() public {
        uint256 t = _create(author, address(imd), 10e18);
        uint256 s = _submit(doer, t);
        vm.deal(doer, 1 ether);
        vm.prank(doer);
        (bool ok, bytes memory ret) = address(vault).call{value: 1}(abi.encodeCall(ITaskVault.reply, (s, "r")));
        assertFalse(ok);
        assertEq(bytes4(ret), TaskVault.NotPayable.selector);
        vm.prank(doer);
        (ok,) = address(vault).call{value: 1}(abi.encodeCall(ITaskVault.getSubmission, (s)));
        assertFalse(ok, "views take no ETH");
    }

    function test_ForwardedCallsKeepTheSender() public {
        uint256 t = _create(author, address(imd), 10e18);
        uint256 s = _submit(doer, t);
        assertEq(vault.getSubmission(s).doer, doer, "the doer is the caller of the vault, not the vault");
        assertEq(vault.getTask(t).author, author);
    }

    function test_DeskErrorsBubbleUnchanged() public {
        vm.prank(stranger);
        vm.expectRevert(NotDoer.selector);
        vault.reply(1, "text");
    }

    function test_ParamsOfIsTheRegistrySnapshot() public view {
        assertEq(vault.paramsOf(1).minBond, registry.params(1).minBond);
        assertEq(vault.paramsOf(1).questionPrefix, registry.params(1).questionPrefix);
    }

    // ------------------------------------------------------------------ launch parameters

    /// @dev The numbers compiled into the registry are the ones the tests and the docs
    ///      use: the test defaults and LaunchParams must not drift apart.
    function test_LaunchParamsEqualTheTestedOnes() public view {
        Params memory a = LaunchParams.initial(
            address(intake), address(oracle), address(adapter), address(nft), address(delegates), treasury
        );
        assertEq(keccak256(abi.encode(a)), keccak256(abi.encode(defaultParams())));
        assertEq(keccak256(abi.encode(registry.params(1))), keccak256(abi.encode(a)));
    }
}
