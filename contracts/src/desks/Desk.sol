// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ParamsCore} from "../VaultParams.sol";
import {ParamsRegistry} from "../ParamsRegistry.sol";
import {IIntake} from "../interfaces/IIntake.sol";
import {TextRules} from "../helpers/TextRules.sol";
import {IVault} from "./DeskApi.sol";
import "../VaultTypes.sol";

/// @title Desk
/// @notice Common base of the two desks that hold the judging state of the vault (CaseDesk, DisputeDesk).
///
///         Wiring. The desks are deployed first, the vault last with their addresses; the vault's constructor calls
///         `wire` on each desk. `wire` works once and only inside the deployment transaction: the desk's constructor
///         raises a transient flag (EIP-1153), which disappears when that transaction ends. The launch deploys every
///         contract in one transaction, so nobody else can wire a desk first, and nobody can rewire it later.
///
///         Calls. Users call the vault; the vault forwards the call here and appends 52 bytes: the original sender
///         (20) and msg.value (32), the ETH itself stays in the vault. Functions marked `routed` accept only the
///         vault and read the user from `_sender()`. The other non-view functions accept only the vault or the named
///         sibling. The desks hold no money and make no transfer: every amount moves through the vault (IVault),
///         which also keeps the tasks.
abstract contract Desk {
    /// @dev transient slot: 1 from the constructor until the end of the deployment transaction
    bytes32 private constant WIRING_SLOT = keccak256("imd.taskvault.desk.wiring");
    uint256 internal constant SUFFIX = 52;

    address public immutable registry;
    IERC20 public immutable imd;
    IERC20 public immutable usdc;
    TextRules internal immutable textRules;

    address public vault;
    address internal caseDesk;
    address internal disputeDesk;

    constructor(address registry_, address imd_, address usdc_, address textRules_) {
        registry = registry_;
        imd = IERC20(imd_);
        usdc = IERC20(usdc_);
        textRules = TextRules(textRules_);
        bytes32 slot = WIRING_SLOT;
        assembly ("memory-safe") {
            tstore(slot, 1)
        }
    }

    /// @notice True for the CaseDesk, false for the DisputeDesk: which slot of the vault this desk belongs in.
    function isCaseDesk() public pure virtual returns (bool);

    /// @notice Called once by the vault's constructor. Checks that the vault and this desk agree on the environment.
    function wire(address registry_, address imd_, address usdc_, address caseDesk_, address disputeDesk_) external {
        bytes32 slot = WIRING_SLOT;
        uint256 open;
        assembly ("memory-safe") {
            open := tload(slot)
            tstore(slot, 0)
        }
        if (open == 0 || vault != address(0)) revert WiringClosed();
        if (registry_ != registry || imd_ != address(imd) || usdc_ != address(usdc)) revert WrongWiring();
        if (caseDesk_ == address(0) || disputeDesk_ == address(0)) revert WrongWiring();
        // the vault must put this desk in its own slot: swapped desks would deploy and then revert every
        // submission
        if ((isCaseDesk() ? caseDesk_ : disputeDesk_) != address(this)) revert WrongWiring();
        vault = msg.sender;
        caseDesk = caseDesk_;
        disputeDesk = disputeDesk_;
    }

    modifier routed() {
        if (msg.sender != vault) revert NotAuthorized();
        _;
    }

    modifier only(address caller) {
        if (msg.sender != caller) revert NotAuthorized();
        _;
    }

    /// @dev The user who called the vault (valid in `routed` functions only).
    function _sender() internal pure returns (address a) {
        assembly ("memory-safe") {
            a := shr(96, calldataload(sub(calldatasize(), 52)))
        }
    }

    /// @dev The msg.value the user sent to the vault (valid in `routed` functions only).
    function _value() internal pure returns (uint256 v) {
        assembly ("memory-safe") {
            v := calldataload(sub(calldatasize(), 32))
        }
    }

    function _bank() internal view returns (IVault) {
        return IVault(vault);
    }

    /// @dev The parameter snapshot of `version` (never changes once activated).
    function _params(uint32 version) internal view returns (ParamsCore memory) {
        return ParamsRegistry(registry).core(version);
    }

    /// @dev Live swarm price that never reverts (0 = not available now).
    function _swarmPrice(ParamsCore memory p) internal view returns (uint256) {
        try IIntake(p.intake).priceOf(p.swarmAction, address(imd)) returns (uint256 price) {
            return price;
        } catch {
            return 0;
        }
    }

    /// @dev Percent part of a bond (no escalation, always the same
    ///      bps, never above `amount` itself). No oracle: `amount` (the author's own reward) is already in the
    ///      task's currency.
    function _pctBond(uint256 amount, uint16 bps) internal pure returns (uint256 b) {
        if (amount == 0) return 0;
        b = amount * bps / BPS;
        if (b > amount) b = amount;
    }

    /// @dev The doer bond of a submission: 0.5 IMD fixed + 3% of the author's own reward `base` (no top-ups of
    ///      others, no $YOLO add-on), always the same regardless of rejected submissions or the
    ///      queue.
    function _doerBond(uint256 base, ParamsCore memory p) internal pure returns (Bond memory b) {
        b.imd = p.bondFixedImd;
        b.rew = _pctBond(base, p.doerBondBps);
    }

    /// @dev The dispute/appeal bond of a submission: the fixed IMD part plus 1% of the author's own reward `base`
    ///      (no top-ups of others, no $YOLO add-on).
    function _disputeBond(uint256 base, ParamsCore memory p) internal pure returns (Bond memory b) {
        b.imd = p.bondFixedImd;
        b.rew = _pctBond(base, p.disputeBondBps);
    }

    /// @dev Every user string sent to the swarm: TextLib.validText with the version's length limit.
    function _checkText(string calldata str, ParamsCore memory p) internal view {
        if (!textRules.validText(str, p.maxTextBytes)) revert BadText();
    }
}
