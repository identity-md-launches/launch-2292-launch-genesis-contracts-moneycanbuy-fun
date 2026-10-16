// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ParamsCore} from "../VaultParams.sol";
import {ParamsRegistry} from "../ParamsRegistry.sol";
import {IIntake} from "../interfaces/IIntake.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
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
        // the vault must put this desk in its own slot: swapped desks used to deploy and then revert every
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

    /// @dev max(minBond, bondBase + bps of R in IMD); the whole bond is penalty (no swarm reserve inside)
    function _bondFor(uint256 rewardImd, uint16 bps, ParamsCore memory p) internal pure returns (uint256 b) {
        b = p.bondBase + rewardImd * bps / BPS;
        if (b < p.minBond) b = p.minBond;
    }

    /// @dev Doer bond: base x 2^(rejected submissions + submissions ahead in the queue), exponent capped.
    function _doerBond(uint256 rejected, uint256 ahead, ParamsCore memory p, uint256 rewardImd)
        internal
        pure
        returns (uint256)
    {
        uint256 n = rejected + ahead;
        if (n > p.maxDoublings) n = p.maxDoublings;
        return _bondFor(rewardImd, p.doerBondBps, p) << n;
    }

    /// @dev R in IMD, IMD per 1 ETH, and whether R reaches the mandatory-check threshold.
    function _priceReward(address currency, uint256 r, ParamsCore memory p)
        internal
        view
        returns (uint256 rewardImd, uint256 imdPerEth, bool large)
    {
        IPriceOracle o = IPriceOracle(p.priceOracle);
        if (currency == address(imd)) {
            // IMD tasks do not depend on the oracle: without a rate the relayer shortfall is simply not recorded
            try o.imdValue(ETH, 1e18) returns (uint256 rate) {
                imdPerEth = rate;
            } catch {}
            rewardImd = r;
            large = r >= p.largeRewardImd;
        } else if (currency == ETH || currency == address(usdc)) {
            imdPerEth = o.imdValue(ETH, 1e18);
            rewardImd = o.imdValue(currency, r);
            large = o.usdValue(currency, r) >= p.largeRewardUsd;
        } else {
            (rewardImd, imdPerEth, large) = _priceYolo(o, currency, r, p);
        }
    }

    /// @dev $YOLO (the vault takes no fourth currency). Without a reliable price (too few pool samples, or any oracle
    ///      call reverting) the task counts as large: mandatory swarm check, and Bonds sized as for a reward at the
    ///      large threshold (`largeRewardImd`), never below what a priced value gives. A missing price
    ///      can only make a submission dearer; the oracle's floor and highest-sample rule keep a low price out.
    function _priceYolo(IPriceOracle o, address yolo, uint256 r, ParamsCore memory p)
        private
        view
        returns (uint256 rewardImd, uint256 imdPerEth, bool large)
    {
        try o.imdValue(ETH, 1e18) returns (uint256 rate) {
            imdPerEth = rate; // 0 = no relayer shortfall recorded, as for IMD tasks
        } catch {}
        bool priced;
        try o.hasPrice(yolo) returns (bool ok) {
            priced = ok;
        } catch {}
        if (priced) {
            try o.imdValue(yolo, r) returns (uint256 v) {
                rewardImd = v;
            } catch {
                priced = false;
            }
            try o.usdValue(yolo, r) returns (uint256 usd) {
                large = usd >= p.largeRewardUsd;
            } catch {
                priced = false;
            }
        }
        if (!priced) {
            large = true;
            if (rewardImd < p.largeRewardImd) rewardImd = p.largeRewardImd;
        }
    }

    /// @dev Every user string sent to the swarm: TextLib.validText with the version's length limit.
    function _checkText(string calldata str, ParamsCore memory p) internal view {
        if (!textRules.validText(str, p.maxTextBytes)) revert BadText();
    }
}
