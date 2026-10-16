// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TaskVault} from "../src/TaskVault.sol";
import {YoloSweetener} from "../src/YoloSweetener.sol";
import {DareTrophy} from "../src/DareTrophy.sol";
import {ParamsRegistry} from "../src/ParamsRegistry.sol";
import {CaseDesk} from "../src/desks/CaseDesk.sol";
import {DisputeDesk} from "../src/desks/DisputeDesk.sol";
import {TextRules} from "../src/helpers/TextRules.sol";
import {SwarmQuestionBuilder} from "../src/helpers/SwarmQuestion.sol";
import {AttestationChecker} from "../src/helpers/AttestationChecker.sol";
import {BallotChecker} from "../src/libraries/VoteLib.sol";
import {UniswapV3SwapAdapter} from "../src/adapters/UniswapV3SwapAdapter.sol";
import {ChainlinkUniV3PriceOracle} from "../src/oracles/ChainlinkUniV3PriceOracle.sol";
import {YoloToken} from "../src/token/YoloToken.sol";
import {NftGate} from "../src/token/NftGate.sol";
import {YoloSplitter} from "../src/token/YoloSplitter.sol";
import {IncentivesVesting, DevVesting, TeamVesting, TreasuryVesting} from "../src/token/Vestings.sol";
import {ProtocolDirectory} from "../src/ProtocolDirectory.sol";
import {HiddenList} from "../src/HiddenList.sol";

/// @notice What the plan needs from a factory: the address a creation code (with its constructor arguments) gets at
///         a position of a launch. The IMD ProjectFactory and the LocalFactory both answer it.
interface IContractFactory {
    function predictContract(uint64 launchNumber, uint256 index, bytes calldata code) external view returns (address);
}

/// @notice The launch in code: which contracts, in which order, with which constructor arguments (`launch.json`
///         written as Solidity). The whole system does not fit one transaction under the 16,777,216 gas cap
///         (EIP-7825), so it goes in launches:
///         0. `genesisLaunch` (evm_contracts): the NFT gate of $YOLO's first 30 minutes, the four
///            vestings and the YoloSplitter, the fixed `remainderTo` of launch 1 that hands the project's 75% out.
///         1. `support` as the custom_token launch of $YOLO (`yoloTokenCode`): the token, its YOLO/IMD pool and the
///            swarm's share (the factory's), then the price oracle (it samples that pool), the swap adapter, the
///            parameter registry and the four stateless helpers. Nothing here holds user money.
///         2. `core` (the main launch): the two desks and the vault, last. The vault's constructor wires the desks
///            (Desk.wire), which only works inside the transaction that deployed them, so these three contracts must
///            be one launch. Every address of launch 1 is a static argument here.
///         3. `extras` (evm_contracts): the $YOLO modules of that vault and the ProtocolDirectory of versions.
///         Used by the fork rehearsal against the live ProjectFactory (test/fork/LaunchRehearsal.fork.t.sol) and by the
///         review tests (test/review/ReviewLaunch.t.sol). docs/LAUNCH-TASK.md is the same plan in words.
library LaunchPlan {
    // ---- Ethereum mainnet counterparties (verified sources; the fork tests run against them)
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant ROUTER02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address internal constant DELEGATE_XYZ = 0x00000000000000447e69651d841bD8D104Bed493;
    address internal constant CL_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address internal constant CL_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address internal constant POOL_USDC_IMD = 0x894D4e6d3d2Abc64Fc0de0e4e2Ea63A93BC9c520;
    // the swarm Intake, version 2 (the swarm reference: "use version 2 for anything new"; it keeps every function of
    // version 1, 0x1397434cd35e8a9c8ac312a61d3a285eb31dea56, which is still served; swarm audit #11)
    address internal constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address internal constant NFT = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;
    address internal constant ATTESTER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    // Chainlink heartbeats on mainnet: ETH/USD 1h, USDC/USD 24h. Doubled, so a normal delay is not an outage.
    uint256 internal constant ETH_STALENESS = 2 hours;
    uint256 internal constant USDC_STALENESS = 48 hours;
    uint32 internal constant TWAP_WINDOW = 30 minutes;
    // Uniswap v4 on mainnet: the PoolManager that holds the YOLO/IMD pool the launch factory opens
    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    // the key every launch-factory pool gets (Initialize of launch #1298, tx 0xf00465dd…): the factory's
    // PoolInitializationGuard hook, a 1.25% LP fee, tick spacing 60
    address internal constant POOL_GUARD = 0x784FF9a3ac5d88A30bfff6F7f2a270161FBE6000;
    uint24 internal constant POOL_FEE = 12_500;
    int24 internal constant POOL_TICK_SPACING = 60;
    // the highest USD value the oracle ever gives one YOLO: $0.01, a $10M valuation of the 1B supply
    uint256 internal constant YOLO_MAX_USD = 0.01e18;
    // $YOLO: 1B. Minutes 0-30 identity.md NFT holders only (NftGate, 500,000 per NFT), minutes 30-60 buy tax 30% -> 0
    // to the project wallet, then a plain ERC-20 (YoloToken)
    uint256 internal constant YOLO_SUPPLY = 1_000_000_000e18;
    // shares (docs/TOKENOMICS.md): swarm 10% and pool 15% by the
    // factory, the project's 75% through the YoloSplitter: incentives 25% (vesting), Stabilizer 15%, dev 7.777777%, team
    // 5%, treasury the rest (22.2222223%)
    uint16 internal constant YOLO_POOL_BPS = 1_500;
    // the opening valuation of the 1B YOLO in IMD (`economics.initialMarketCapWei` of launch 1, policy 250..250,000)
    uint256 internal constant YOLO_OPENING_MCAP_IMD = 15_000e18;
    // a trophy of an accepted submission (DareTrophy, launch 3): $1.50 in YOLO burned, 10,000 YOLO without a YOLO price
    // (~$1.15 at the opening price: 15,000 IMD / 1B YOLO x IMD ~$7.65)
    uint256 internal constant TROPHY_PRICE_USD = 1.5e18;
    uint256 internal constant TROPHY_FALLBACK_YOLO = 10_000e18;

    /// @notice Addresses of launch 1 (all of them are static constructor arguments of launch 2).
    struct Support {
        address priceOracle;
        address swapAdapter;
        address registry;
        address textRules;
        address questionBuilder;
        address ballotChecker;
        address attestationChecker;
    }

    /// @notice The counterparties of the parameter registry's version 1. Mainnet: `mainnet(owner, treasury)`.
    struct Counterparties {
        address owner; // ParamsRegistry owner: the project wallet PROJECT_TREASURY, a single key (EOA)
        address intake;
        address nft;
        address delegateRegistry;
        address treasury; // project treasury wallet
        address attester;
        address imd;
        address usdc;
    }

    function mainnet(address owner, address treasury) internal pure returns (Counterparties memory c) {
        c = Counterparties(owner, INTAKE, NFT, DELEGATE_XYZ, treasury, ATTESTER, IMD, USDC);
    }

    /// @notice The $YOLO/IMD pool the oracle samples: the token and the pool key the launch factory opens it with.
    struct YoloPool {
        address token;
        address hooks;
        uint24 fee;
        int24 tickSpacing;
        uint256 maxUsd; // 18 decimals per whole YOLO: the oracle never values it higher
        uint256 floorImd; // IMD wei per whole YOLO at the opening price: the oracle never values it lower
    }

    /// @notice The pool the launch factory opens for `token` against IMD.
    function yoloPool(address token) internal pure returns (YoloPool memory) {
        return YoloPool(
            token, POOL_GUARD, POOL_FEE, POOL_TICK_SPACING, YOLO_MAX_USD, YOLO_OPENING_MCAP_IMD * 1e18 / YOLO_SUPPLY
        );
    }

    /// @notice The $YOLO creation code (with its constructor arguments) as the factory deploys it: `$poolManager`, the
    ///         NftGate of launch 0 and the project wallet (the treasury) that receives the buy tax.
    function yoloTokenCode(address gate, address taxRecipient) internal pure returns (bytes memory) {
        return abi.encodePacked(type(YoloToken).creationCode, abi.encode(POOL_MANAGER, gate, taxRecipient));
    }

    // ---- the project's wallets (EOAs): plan arguments only, no contract holds them. PLACEHOLDERS in this public
    // repository: the real addresses are written here and into the launch texts (docs/LAUNCH-TASK.md, where they
    // stand as <TREASURY_WALLET> etc.) right before the launch.
    address internal constant PROJECT_TREASURY = address(0xF001); // treasury, buy tax, owner of registry + directory
    address internal constant PROJECT_INCENTIVES = address(0xF002);
    address internal constant PROJECT_STABILIZER = address(0xF003);
    address internal constant PROJECT_DEV = address(0xF004);
    address internal constant PROJECT_TEAM = address(0xF005);

    /// @notice The project's wallets for the mainnet launch (placeholders here, see above).
    function projectOwners() internal pure returns (Owners memory) {
        return Owners(PROJECT_TREASURY, PROJECT_INCENTIVES, PROJECT_STABILIZER, PROJECT_DEV, PROJECT_TEAM);
    }

    /// @notice The owner's addresses of launch 0 (mainnet: `projectOwners()`; tests use their own).
    struct Owners {
        address treasury; // the project wallet (an EOA): beneficiary of the treasury vesting, receives the buy tax,
        // owns ParamsRegistry and ProtocolDirectory (passed to `mainnet` and `extras`)
        address incentives; // beneficiary of the incentives vesting
        address stabilizer; // the Stabilizer / MM fund wallet, 150M at once
        address dev; // beneficiary of the dev vesting
        address team; // beneficiary of the team vesting
    }

    /// @notice Addresses of launch 0.
    struct Genesis {
        address gate;
        address incentives;
        address dev;
        address team;
        address treasury;
        address splitter;
    }

    /// @notice Launch 0 (evm_contracts, before the $YOLO launch): the NftGate of the first 30 minutes, the four
    ///         vestings and the YoloSplitter. The $YOLO launch's `remainderTo` must be a fixed address and the token
    ///         needs the gate's, so all of it exists first and knows no token in advance.
    function genesisLaunch(IContractFactory f, uint64 launchNumber, Owners memory o)
        internal
        view
        returns (bytes[] memory codes, bytes32[] memory names, Genesis memory g)
    {
        return genesisLaunchWith(f, launchNumber, o, NFT, DELEGATE_XYZ);
    }

    /// @notice Launch 0 with any NFT and delegate registry (tests pass mocks).
    function genesisLaunchWith(IContractFactory f, uint64 launchNumber, Owners memory o, address nft, address delegates)
        internal
        view
        returns (bytes[] memory codes, bytes32[] memory names, Genesis memory g)
    {
        codes = new bytes[](6);
        names = new bytes32[](6);
        codes[0] = abi.encodePacked(type(NftGate).creationCode, abi.encode(nft, delegates));
        names[0] = "NftGate";
        g.gate = f.predictContract(launchNumber, 0, codes[0]);
        codes[1] = abi.encodePacked(type(IncentivesVesting).creationCode, abi.encode(o.incentives));
        names[1] = "IncentivesVesting";
        g.incentives = f.predictContract(launchNumber, 1, codes[1]);
        codes[2] = abi.encodePacked(type(DevVesting).creationCode, abi.encode(o.dev));
        names[2] = "DevVesting";
        g.dev = f.predictContract(launchNumber, 2, codes[2]);
        codes[3] = abi.encodePacked(type(TeamVesting).creationCode, abi.encode(o.team));
        names[3] = "TeamVesting";
        g.team = f.predictContract(launchNumber, 3, codes[3]);
        codes[4] = abi.encodePacked(type(TreasuryVesting).creationCode, abi.encode(o.treasury));
        names[4] = "TreasuryVesting";
        g.treasury = f.predictContract(launchNumber, 4, codes[4]);
        codes[5] = abi.encodePacked(
            type(YoloSplitter).creationCode, abi.encode(g.incentives, g.dev, g.team, g.treasury, o.stabilizer)
        );
        names[5] = "YoloSplitter";
        g.splitter = f.predictContract(launchNumber, 5, codes[5]);
    }

    /// @notice Launch 1 on mainnet: real oracle and adapter.
    function support(IContractFactory f, uint64 launchNumber, Counterparties memory c, YoloPool memory y)
        internal
        view
        returns (bytes[] memory codes, bytes32[] memory names, Support memory s)
    {
        bytes memory oracle = abi.encodePacked(
            type(ChainlinkUniV3PriceOracle).creationCode,
            abi.encode(
                c.usdc, c.imd, CL_ETH_USD, CL_USDC_USD, POOL_USDC_IMD, TWAP_WINDOW, ETH_STALENESS, USDC_STALENESS
            ),
            abi.encode(y.token, POOL_MANAGER, y.hooks, y.fee, y.tickSpacing, y.maxUsd, y.floorImd)
        );
        bytes memory adapter = abi.encodePacked(type(UniswapV3SwapAdapter).creationCode, abi.encode(ROUTER02, WETH));
        return supportWith(f, launchNumber, c, oracle, adapter);
    }

    /// @notice Launch 1 with any price oracle and swap adapter creation codes (tests pass mocks).
    function supportWith(
        IContractFactory f,
        uint64 launchNumber,
        Counterparties memory c,
        bytes memory oracleCode,
        bytes memory adapterCode
    ) internal view returns (bytes[] memory codes, bytes32[] memory names, Support memory s) {
        codes = new bytes[](7);
        names = new bytes32[](7);
        codes[0] = oracleCode;
        names[0] = "ChainlinkUniV3PriceOracle";
        s.priceOracle = f.predictContract(launchNumber, 0, codes[0]);
        codes[1] = adapterCode;
        names[1] = "UniswapV3SwapAdapter";
        s.swapAdapter = f.predictContract(launchNumber, 1, codes[1]);
        codes[2] = abi.encodePacked(
            type(ParamsRegistry).creationCode,
            abi.encode(
                c.owner, c.intake, s.priceOracle, s.swapAdapter, c.nft, c.delegateRegistry, c.treasury, c.attester
            )
        );
        names[2] = "ParamsRegistry";
        s.registry = f.predictContract(launchNumber, 2, codes[2]);
        codes[3] = type(TextRules).creationCode;
        names[3] = "TextRules";
        s.textRules = f.predictContract(launchNumber, 3, codes[3]);
        codes[4] = type(SwarmQuestionBuilder).creationCode;
        names[4] = "SwarmQuestionBuilder";
        s.questionBuilder = f.predictContract(launchNumber, 4, codes[4]);
        codes[5] = type(BallotChecker).creationCode;
        names[5] = "BallotChecker";
        s.ballotChecker = f.predictContract(launchNumber, 5, codes[5]);
        codes[6] = abi.encodePacked(type(AttestationChecker).creationCode, abi.encode(s.registry));
        names[6] = "AttestationChecker";
        s.attestationChecker = f.predictContract(launchNumber, 6, codes[6]);
    }

    /// @notice Launch 2: the desks, then the vault with their addresses ($contract:...).
    function core(IContractFactory f, uint64 launchNumber, Support memory s, address imd, address usdc, address yolo)
        internal
        view
        returns (bytes[] memory codes, bytes32[] memory names, address[] memory addrs)
    {
        codes = new bytes[](3);
        names = new bytes32[](3);
        addrs = new address[](3);
        codes[0] = abi.encodePacked(
            type(CaseDesk).creationCode, abi.encode(s.registry, imd, usdc, s.textRules, s.questionBuilder)
        );
        names[0] = "CaseDesk";
        codes[1] = abi.encodePacked(
            type(DisputeDesk).creationCode, abi.encode(s.registry, imd, usdc, s.textRules, s.ballotChecker)
        );
        names[1] = "DisputeDesk";
        addrs[0] = f.predictContract(launchNumber, 0, codes[0]);
        addrs[1] = f.predictContract(launchNumber, 1, codes[1]);
        codes[2] = abi.encodePacked(
            type(TaskVault).creationCode,
            abi.encode(s.registry, imd, usdc, yolo, s.attestationChecker, s.textRules, addrs[0], addrs[1])
        );
        names[2] = "TaskVault";
        addrs[2] = f.predictContract(launchNumber, 2, codes[2]);
    }

    /// @notice Launch 3: the two $YOLO modules next to the vault of launch 2, which they only read (its address is
    ///         their one argument; registry, $YOLO and the CaseDesk come from it), then the ProtocolDirectory with
    ///         version 1 = that vault and these modules (`safe`, the project wallet, adds later versions after 48 h,
    ///         `coreBlock` is the block of launch 2). Outside the core so that launch 2 keeps its gas and code margin
    ///         for the swarm's fixes. Fourth: HiddenList, the site's hide list, its own standalone owner/nft/
    ///         delegateRegistry triple, same `safe` and the same NFT and delegate registry as the other
    ///         project-wallet contracts of this plan; it reads nothing here and nothing here reads it.
    function extras(IContractFactory f, uint64 launchNumber, address vault, address safe, uint64 coreBlock)
        internal
        view
        returns (bytes[] memory codes, bytes32[] memory names, address[] memory addrs)
    {
        codes = new bytes[](4);
        names = new bytes32[](4);
        addrs = new address[](4);
        codes[0] = abi.encodePacked(type(YoloSweetener).creationCode, abi.encode(vault));
        names[0] = "YoloSweetener";
        codes[1] = abi.encodePacked(
            type(DareTrophy).creationCode, abi.encode(vault, TROPHY_PRICE_USD, TROPHY_FALLBACK_YOLO)
        );
        names[1] = "DareTrophy";
        addrs[0] = f.predictContract(launchNumber, 0, codes[0]);
        addrs[1] = f.predictContract(launchNumber, 1, codes[1]);
        codes[2] = abi.encodePacked(
            type(ProtocolDirectory).creationCode, abi.encode(safe, vault, addrs[0], addrs[1], coreBlock)
        );
        names[2] = "ProtocolDirectory";
        addrs[2] = f.predictContract(launchNumber, 2, codes[2]);
        codes[3] = abi.encodePacked(type(HiddenList).creationCode, abi.encode(safe, NFT, DELEGATE_XYZ));
        names[3] = "HiddenList";
        addrs[3] = f.predictContract(launchNumber, 3, codes[3]);
    }
}

/// @notice Local stand-in for the IMD ProjectFactory's `launchContracts`: deploys creation codes in order with
///         CREATE2 and the same salt scheme, in ONE transaction (the vault's constructor wires the desks, which is only
///         possible in the transaction that deployed them). Local anvil only.
contract LocalFactory is IContractFactory {
    error DeploymentFailed(uint256 index);
    error NotTheDeployer();

    /// @dev Only its creator may launch through it: the salt is (launch number, index), so anyone watching the
    ///      mempool could otherwise deploy the real desks at the predicted addresses and wire them to a contract of
    ///      his own.
    address public immutable deployer = msg.sender;

    function contractSalt(uint64 launchNumber, uint256 index) public pure returns (bytes32) {
        return keccak256(abi.encode(uint256(launchNumber), index));
    }

    function predictContract(uint64 launchNumber, uint256 index, bytes calldata code) external view returns (address) {
        bytes32 h = keccak256(
            abi.encodePacked(bytes1(0xff), address(this), contractSalt(launchNumber, index), keccak256(code))
        );
        return address(uint160(uint256(h)));
    }

    function launchContracts(uint64 launchNumber, bytes[] calldata codes) external returns (address[] memory out) {
        if (msg.sender != deployer) revert NotTheDeployer();
        out = new address[](codes.length);
        for (uint256 i; i < codes.length; ++i) {
            bytes memory code = codes[i];
            bytes32 salt = contractSalt(launchNumber, i);
            address a;
            assembly ("memory-safe") {
                a := create2(0, add(code, 0x20), mload(code), salt)
            }
            if (a == address(0)) revert DeploymentFailed(i);
            out[i] = a;
        }
    }
}
