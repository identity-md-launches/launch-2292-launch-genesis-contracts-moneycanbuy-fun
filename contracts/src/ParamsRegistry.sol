// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Params, ParamsCore, ParamsBounds, LaunchParams} from "./VaultParams.sol";

/// @title ParamsRegistry
/// @notice Versioned parameters and the swarm attester set, owned by the project wallet (behind a 48 h timelock).
///         Read by TaskVault and its desks.
///         - Parameter changes and attester changes wait `TIMELOCK` (48h) between proposal and execution;
///           execution is permissionless once the delay passed.
///         - A new parameter version applies to tasks created after activation only: a task records the version
///           current at its creation and every desk reads only that version's snapshot (`core`, `template`), which
///           never changes once activated.
///         - `newTasksPaused` stops task creation only; everything else keeps working.
///         - The owner has no function that moves, freezes or redirects deposited money.
///         - Trust (docs/MECHANICS.md "Trust assumptions"): the attester set is global, so a change reaches the swarm
///           answers of tasks already running (at least one attester always stays); and a new version may name other
///           counterparties (intake, nft, delegateRegistry, priceOracle), which then judge every task created under it.
contract ParamsRegistry is Ownable2Step {
    uint256 public constant TIMELOCK = 48 hours;

    /// @dev version => snapshot. Version 0 is never used.
    mapping(uint32 => Params) internal _params;
    uint32 public currentVersion;

    Params internal _pendingParams;
    uint64 public pendingParamsEta; // 0 = nothing pending

    /// @notice Signers accepted on swarm attestations (global: key rotation must reach old tasks too).
    mapping(address => bool) public isAttester;
    /// @notice How many signers are in the attester set; the last one cannot be removed (swarm audit #10).
    uint256 public attesterCount;
    /// @dev keccak256(attester, allowed) => eta
    mapping(bytes32 => uint64) public attesterChangeEta;

    bool public newTasksPaused;

    event ParamsProposed(uint64 eta);
    event ParamsCancelled();
    event ParamsActivated(uint32 indexed version);
    event AttesterChangeProposed(address indexed attester, bool allowed, uint64 eta);
    event AttesterChangeCancelled(address indexed attester, bool allowed);
    event AttesterChanged(address indexed attester, bool allowed);
    event NewTasksPaused(bool paused);

    error NothingPending();
    error TimelockNotPassed();
    error LastAttester();

    /// @notice Version 1 = `LaunchParams.initial` (the numbers and the question template are compiled in) with these
    ///         counterparties; `attester` is the first accepted signer of swarm answers.
    constructor(
        address owner_,
        address intake,
        address priceOracle,
        address swapAdapter,
        address nft,
        address delegateRegistry,
        address treasury,
        address attester
    ) Ownable(owner_) {
        Params memory initial = LaunchParams.initial(intake, priceOracle, swapAdapter, nft, delegateRegistry, treasury);
        ParamsBounds.validate(initial);
        if (attester == address(0)) revert ParamsBounds.ParamOutOfBounds("attester");
        currentVersion = 1;
        _params[1] = initial;
        emit ParamsActivated(1);
        isAttester[attester] = true;
        attesterCount = 1;
        emit AttesterChanged(attester, true);
    }

    // ------------------------------------------------------------------ parameters

    function proposeParams(Params calldata p) external onlyOwner {
        ParamsBounds.validate(p);
        _pendingParams = p;
        pendingParamsEta = uint64(block.timestamp + TIMELOCK);
        emit ParamsProposed(pendingParamsEta);
    }

    function cancelParams() external onlyOwner {
        if (pendingParamsEta == 0) revert NothingPending();
        pendingParamsEta = 0;
        emit ParamsCancelled();
    }

    /// @notice Anyone can activate a proposal after the timelock.
    function activateParams() external {
        uint64 eta = pendingParamsEta;
        if (eta == 0) revert NothingPending();
        if (block.timestamp < eta) revert TimelockNotPassed();
        pendingParamsEta = 0;
        uint32 v = currentVersion + 1;
        _params[v] = _pendingParams;
        currentVersion = v;
        emit ParamsActivated(v);
    }

    function params(uint32 version) external view returns (Params memory) {
        return _params[version];
    }

    /// @notice Same as `params`: the vault forwards its `paramsOf(version)` here.
    function paramsOf(uint32 version) external view returns (Params memory) {
        return _params[version];
    }

    /// @notice Every number and address of `version` without the question template (what the desks read per call).
    function core(uint32 version) external view returns (ParamsCore memory c) {
        Params storage p = _params[version];
        c.intake = p.intake;
        c.priceOracle = p.priceOracle;
        c.swapAdapter = p.swapAdapter;
        c.nft = p.nft;
        c.delegateRegistry = p.delegateRegistry;
        c.treasury = p.treasury;
        c.swarmAction = p.swarmAction;
        c.minRewardUsd = p.minRewardUsd;
        c.minRewardImd = p.minRewardImd;
        c.largeRewardUsd = p.largeRewardUsd;
        c.largeRewardImd = p.largeRewardImd;
        c.minAuthorFee = p.minAuthorFee;
        c.minBond = p.minBond;
        c.bondBase = p.bondBase;
        c.minDisputeFee = p.minDisputeFee;
        c.maxDisputeFee = p.maxDisputeFee;
        c.doerBondBps = p.doerBondBps;
        c.disputeBondBps = p.disputeBondBps;
        c.maxDoublings = p.maxDoublings;
        c.maxClaims = p.maxClaims;
        c.maxTextBytes = p.maxTextBytes;
        c.disputeWindow = p.disputeWindow;
        c.replyWindow = p.replyWindow;
        c.voteWindow = p.voteWindow;
        c.appealWindow = p.appealWindow;
        c.appealReplyWindow = p.appealReplyWindow;
        c.swarmTimeout = p.swarmTimeout;
        c.emergencyDelay = p.emergencyDelay;
        c.instantDelta = p.instantDelta;
        c.endDelta = p.endDelta;
        c.minWinnerWallets = p.minWinnerWallets;
        c.relayBaseGas = p.relayBaseGas;
        c.maxRelayGasPerVote = p.maxRelayGasPerVote;
        c.relayMarkupBps = p.relayMarkupBps;
        c.feeBps = p.feeBps;
        c.nftFeeBps = p.nftFeeBps;
        c.winnerBondBps = p.winnerBondBps;
        c.tieDoerBps = p.tieDoerBps;
        c.minPanelSize = p.minPanelSize;
        c.minQuorum = p.minQuorum;
    }

    /// @notice The swarm question template of `version`.
    function template(uint32 version)
        external
        view
        returns (bytes memory questionPrefix, bytes memory definitionFields, bytes memory bodyFields)
    {
        Params storage p = _params[version];
        return (p.questionPrefix, p.definitionFields, p.bodyFields);
    }

    function pendingParams() external view returns (Params memory) {
        return _pendingParams;
    }

    // ------------------------------------------------------------------ attesters

    /// @notice Propose adding (`allowed`) or removing a signer of swarm answers; anyone executes it after TIMELOCK.
    ///         A removal that would leave no attester is refused at execution (with none, every swarm answer of every
    ///         live task would be silence): to rotate a key, propose the new one with the removal and execute the
    ///         addition first.
    function proposeAttester(address attester, bool allowed) external onlyOwner {
        uint64 eta = uint64(block.timestamp + TIMELOCK);
        attesterChangeEta[_attesterKey(attester, allowed)] = eta;
        emit AttesterChangeProposed(attester, allowed, eta);
    }

    function cancelAttester(address attester, bool allowed) external onlyOwner {
        bytes32 key = _attesterKey(attester, allowed);
        if (attesterChangeEta[key] == 0) revert NothingPending();
        delete attesterChangeEta[key];
        emit AttesterChangeCancelled(attester, allowed);
    }

    function executeAttester(address attester, bool allowed) external {
        bytes32 key = _attesterKey(attester, allowed);
        uint64 eta = attesterChangeEta[key];
        if (eta == 0) revert NothingPending();
        if (block.timestamp < eta) revert TimelockNotPassed();
        delete attesterChangeEta[key];
        if (isAttester[attester] != allowed) {
            if (allowed) {
                ++attesterCount;
            } else {
                if (attesterCount == 1) revert LastAttester();
                --attesterCount;
            }
            isAttester[attester] = allowed;
        }
        emit AttesterChanged(attester, allowed);
    }

    // ------------------------------------------------------------------ pause (new tasks only)

    function setNewTasksPaused(bool paused) external onlyOwner {
        newTasksPaused = paused;
        emit NewTasksPaused(paused);
    }

    function _attesterKey(address attester, bool allowed) private pure returns (bytes32) {
        return keccak256(abi.encode(attester, allowed));
    }
}
