// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

import {LaunchPlan, IContractFactory} from "../../script/LaunchPlan.sol";
import {ITaskVault} from "../../src/interfaces/ITaskVault.sol";
import {ParamsRegistry} from "../../src/ParamsRegistry.sol";
import {DevPrices} from "../../src/DevPrices.sol";
import {ProjectVesting} from "../../src/token/ProjectVesting.sol";
import {YoloToken} from "../../src/token/YoloToken.sol";
import {NftGate} from "../../src/token/NftGate.sol";
import {YoloSplitter} from "../../src/token/YoloSplitter.sol";
import {YoloSweetener} from "../../src/YoloSweetener.sol";
import {ProtocolDirectory} from "../../src/ProtocolDirectory.sol";
import {DareTrophy} from "../../src/DareTrophy.sol";
import {YoloPredict} from "../../src/YoloPredict.sol";
import {YoloLockHub} from "../../src/YoloLockHub.sol";
import {BuybackBurner} from "../../src/BuybackBurner.sol";
import {DisputeDesk} from "../../src/desks/DisputeDesk.sol";
import "../../src/VaultTypes.sol";
import {rulesOf} from "../mocks/TaskRulesFixture.sol";

/// @dev The live factory's launch entry points and their parameter structs (Identity-md/protocol ProjectFactory.sol,
///      source verified on Sourcify for 0xfF03410d...7120). `Currency` is an address in the ABI.
interface IProjectFactory is IContractFactory {
    struct Launch {
        bytes32 kind;
        uint64 launchNumber;
        uint64 recordedAt;
        bytes32 sourceCommit;
        bytes32 manifestHash;
        bytes32 attestationHash;
        bytes32 verifierKey;
        string sourceRepoUrl;
    }

    struct ContractsParams {
        uint64 launchNumber;
        bytes[] contractCreationCodes;
        bytes32[] contractNames;
        address[] expectedContracts;
        Launch record;
        uint256[] agentIds;
    }

    struct CustomParams {
        uint64 launchNumber;
        bytes tokenCreationCode;
        bytes32 tokenName;
        bytes[] contractCreationCodes;
        bytes32[] contractNames;
        address[] expectedContracts;
        uint256 totalSupply;
        uint16 poolBps;
        address remainderTo;
        bytes32 merkleRoot;
        uint64 contributorLockSeconds;
        uint64 sweepDelaySeconds;
        address pairedCurrency;
        int24 tickSpacing;
        uint160 sqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        Launch record;
        uint256[] agentIds;
        address requester;
    }

    function deployer() external view returns (address);
    function launchContracts(ContractsParams calldata p) external returns (address[] memory contracts);
    function launchCustom(CustomParams calldata p) external returns (address, address[] memory, address);
    function predictToken(uint64 launchNumber, bytes calldata code) external view returns (address);
    function claimFees(uint64 launchNumber) external returns (uint256 amount0, uint256 amount1);
    function distributorOf(uint64 launchNumber) external view returns (address);
}

/// @dev Put at the platform deployer's address: the launch call starts here, as the deployer's own transaction would,
///      and the gas is counted once (gasleft() around a pranked call from the test would otherwise count the
///      intrinsic gas a second time).
contract LaunchGasMeter {
    function run(address target, bytes calldata data) external returns (bool ok, uint256 used, bytes memory ret) {
        bytes memory d = data;
        uint256 g = gasleft();
        (ok, ret) = target.call(d);
        used = g - gasleft();
    }
}

/// @dev Uniswap v4 PoolManager: just what a buy needs.
interface IPoolManagerSwap {
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256);
    function sync(address currency) external;
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
}

/// @dev Buys YOLO for an exact IMD amount on the factory's YOLO/IMD pool, like a router would (fork only).
contract V4Buyer {
    IPoolManagerSwap constant PM = IPoolManagerSwap(LaunchPlan.POOL_MANAGER);
    uint160 constant MIN_SQRT_PRICE_PLUS_1 = 4_295_128_740;
    uint160 constant MAX_SQRT_PRICE_MINUS_1 = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;

    function buy(address yolo, uint256 imdIn, address to) external returns (uint256 out) {
        return abi.decode(PM.unlock(abi.encode(yolo, imdIn, to)), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(PM));
        (address yolo, uint256 imdIn, address to) = abi.decode(data, (address, uint256, address));
        bool imdIs0 = LaunchPlan.IMD < yolo;
        IPoolManagerSwap.PoolKey memory key = IPoolManagerSwap.PoolKey(
            imdIs0 ? LaunchPlan.IMD : yolo,
            imdIs0 ? yolo : LaunchPlan.IMD,
            LaunchPlan.POOL_FEE,
            LaunchPlan.POOL_TICK_SPACING,
            LaunchPlan.POOL_GUARD
        );
        int256 delta = PM.swap(
            key,
            IPoolManagerSwap.SwapParams(
                imdIs0, -int256(imdIn), imdIs0 ? MIN_SQRT_PRICE_PLUS_1 : MAX_SQRT_PRICE_MINUS_1
            ),
            ""
        );
        int128 a0 = int128(delta >> 128);
        int128 a1 = int128(delta);
        uint256 owed = uint256(uint128(-(imdIs0 ? a0 : a1)));
        uint256 out = uint256(uint128(imdIs0 ? a1 : a0));
        PM.sync(LaunchPlan.IMD);
        IERC20(LaunchPlan.IMD).transfer(address(PM), owed);
        PM.settle();
        PM.take(yolo, to, out);
        return abi.encode(out);
    }
}

/// @dev Uniswap v4 periphery on mainnet: the Universal Router (V3_SWAP_EXACT_IN, WRAP_ETH, V4_SWAP) and Permit2, as
///      wallets and the site use them; the identity.md NFT.
interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IERC721Min {
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/// @dev The live factory's MerkleDistributor of a launch (its Sourcify-verified source): the
///      swarm's 10% is claimed with an OpenZeppelin StandardMerkleTree proof once the round unlocks.
interface IMerkleDistributorMin {
    function claim(uint256 round, address account, uint256 amount, bytes32[] calldata proof) external;
    function roundCount() external view returns (uint256);
}

/// @notice All four launches rehearsed through the REAL mainnet ProjectFactory (impersonating its deployer, the
///         plane's key), with the gas of each launch transaction measured against the EIP-7825 cap: execution measured
///         at the deployer's address (LaunchGasMeter) plus the intrinsic cost (21,000 + 16 per nonzero byte + 4 per
///         zero byte), at least the EIP-7623 calldata floor; every contract against the EIP-170 size limit. Then the
///         project's 75% is split, $YOLO's opening and first hour are traded through the live Universal Router (no buy
///         before openAt, the snapshot of real identity.md holders, USDC and ETH routed through IMD, the buy tax at
///         its edges), and tasks in IMD
///         and in YOLO go through the deployed vault (DevPrices: a fixed parameter, no oracle to sample).
///         Read-only: nothing leaves the fork.
///         0. evm_contracts: NftGate, IncentivesVesting, DevVesting, TeamVesting, TreasuryVesting, YoloSplitter.
///         1. custom_token: $YOLO + its YOLO/IMD pool (15%) + the swarm's distributor (10%) + the seven support
///            contracts (DevPrices, no oracle); the remainder (75%) goes to the
///            YoloSplitter.
///         2. evm_contracts: the desks and the vault (YOLO is a static argument).
///         3. evm_contracts: YoloSweetener, TrophyCatalog, DareTrophy, the ProtocolDirectory (version 1 = this
///            vault), HiddenList, YoloPredict.
///   FORK_URL=<archive mainnet RPC> forge test --match-contract LaunchRehearsal -vv
///   (or: forge test --match-contract LaunchRehearsal --fork-url <RPC> -vv)
contract LaunchRehearsalForkTest is Test {
    IProjectFactory constant FACTORY = IProjectFactory(0xfF03410d0Fe5fa8f7F59F743de35E333D9857120);
    IUniversalRouter constant UR = IUniversalRouter(0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af);
    IPermit2 constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IERC721Min constant NFT = IERC721Min(LaunchPlan.NFT);
    uint256 constant TX_GAS_CAP = 16_777_216;
    uint256 constant EIP170 = 24_576;
    uint64 constant LAUNCH_GENESIS = 4_000_000_100;
    uint64 constant LAUNCH_SUPPORT = 4_000_000_101;
    uint64 constant LAUNCH_CORE = 4_000_000_102;
    uint64 constant LAUNCH_EXTRAS = 4_000_000_103;
    // placeholders here: the project wallet <TREASURY> (no Safe; owner of the
    // registry and the directory, the buy tax, the treasury vesting; here also the launch payer), the incentives
    // wallet, the Stabilizer wallet, the dev and the future team
    address constant TREASURY = address(0x7EA5);
    address constant OWNER = TREASURY;
    address constant INCENTIVES = address(0x1CE7);
    address constant STABILIZER = address(0x57AB);
    address constant DEV = address(0xDE7);
    address constant TEAM = address(0x7EA0);
    // the launch economics: 15% of the supply in the pool, opening at 15,000 IMD for 1B
    uint16 constant POOL_BPS = LaunchPlan.YOLO_POOL_BPS;
    uint256 constant START_FDV_IMD = LaunchPlan.YOLO_OPENING_MCAP_IMD;
    // Universal Router: commands and v4 actions
    uint8 constant V4_SWAP = 0x10;
    uint8 constant V3_SWAP_EXACT_IN = 0x00;
    uint8 constant WRAP_ETH = 0x0b;
    uint8 constant SWEEP = 0x04;
    uint8 constant SETTLE = 0x0b; // v4 action: pay a currency from the router's balance or the user
    uint256 constant CONTRACT_BALANCE = 1 << 255; // ActionConstants: the router's whole balance
    // mainnet v3 pools of IMD (factory.getPool, liquidity()): USDC/IMD 0.3% (0x894D...c520) is the only one
    // with liquidity (WETH/IMD 1% and USDC/IMD 1% hold none), so ETH goes WETH -> USDC (0.05%) -> IMD
    uint24 constant V3_FEE_USDC_IMD = 3_000;
    uint24 constant V3_FEE_WETH_USDC = 500;
    // trading opens this long after the token launch (the plan's openAt is an input of launch 1)
    uint256 constant OPEN_DELAY = 2 hours;
    uint8 constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 constant SETTLE_ALL = 0x0c;
    uint8 constant TAKE = 0x0e;
    uint8 constant TAKE_ALL = 0x0f;
    bytes4 constant WRAPPED_ERROR = bytes4(keccak256("WrappedError(address,bytes4,bytes,bytes)"));

    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }

    address internal yolo;
    uint256 internal openAt;
    LaunchPlan.Genesis internal genesis;
    uint64 internal coreBlock; // the block of launch 2: version 1 of the directory starts there
    bytes32 internal swarmRoot; // the swarm round's merkle root of launch 1 (0 = a placeholder root)

    function setUp() public {
        string memory url = vm.envOr("FORK_URL", string(""));
        if (address(FACTORY).code.length == 0 && bytes(url).length != 0) vm.createSelectFork(url);
        // the factory exists only on Ethereum mainnet (or a fork of it)
        if (address(FACTORY).code.length == 0) vm.skip(true);
        vm.etch(FACTORY.deployer(), type(LaunchGasMeter).runtimeCode);
    }

    /// @dev One launch transaction from the platform deployer: what it returned and its total gas.
    function _send(bytes memory data) internal returns (bytes memory ret, uint256 total) {
        (bool ok, uint256 used, bytes memory r) = LaunchGasMeter(FACTORY.deployer()).run(address(FACTORY), data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(r, 32), mload(r))
            }
        }
        ret = r;
        total = used + _intrinsic(data);
        uint256 floor = _floor(data);
        if (floor > total) total = floor;
        emit log_named_uint("execution gas", used);
        emit log_named_uint("calldata bytes", data.length);
    }

    function test_fourLaunchesFitAndWork() public {
        emit log_named_uint("mainnet fork block", block.number);
        uint256 gasGenesis = _launchGenesis();
        (LaunchPlan.Support memory s, uint256 gasSupport) = _launchSupportWithToken();
        (address[] memory core, uint256 gasCore) = _launchCore(s);
        (address[] memory extra, uint256 gasExtras) = _launchExtras(core[LaunchPlan.CORE_VAULT]);
        emit log_named_uint("launch 0 (evm_contracts: gate, vestings, splitter) total gas", gasGenesis);
        emit log_named_uint("launch 1 (custom_token: YOLO + support) total gas", gasSupport);
        emit log_named_uint("launch 2 (evm_contracts: core) total gas", gasCore);
        emit log_named_uint("launch 3 (evm_contracts: $YOLO modules, catalog, directory, hide list) total gas", gasExtras);
        assertLt(gasGenesis, TX_GAS_CAP, "launch 0 must fit one transaction");
        assertLt(gasSupport, TX_GAS_CAP, "launch 1 must fit one transaction");
        assertLt(gasCore, TX_GAS_CAP, "launch 2 must fit one transaction");
        assertLt(gasExtras, TX_GAS_CAP, "launch 3 must fit one transaction");
        assertEq(address(YoloSweetener(extra[0]).vault()), core[LaunchPlan.CORE_VAULT], "sweetener reads this vault");
        assertEq(address(YoloSweetener(extra[0]).yolo()), yolo);
        assertEq(address(DareTrophy(extra[2]).vault()), core[LaunchPlan.CORE_VAULT], "trophy reads this vault");
        assertEq(address(DareTrophy(extra[2]).caseDesk()), core[LaunchPlan.CORE_CASE]);
        assertEq(DareTrophy(extra[2]).price(), 7_777e18, "fixed 7,777 YOLO");
        assertEq(address(DareTrophy(extra[2]).catalog()), extra[1], "trophy reads the catalog deployed before it");
        ProtocolDirectory dir = ProtocolDirectory(extra[3]);
        ProtocolDirectory.Version memory v1 = dir.version(1);
        assertEq(dir.safe(), OWNER, "directory: the project wallet, as the registry");
        assertEq(dir.current(), 1);
        assertEq(dir.versionCount(), 1);
        assertEq(v1.vault, core[LaunchPlan.CORE_VAULT], "version 1 = the vault of launch 2");
        assertEq(v1.sweetener, extra[0]);
        assertEq(v1.trophy, extra[2]);
        assertEq(v1.fromBlock, coreBlock);
        assertEq(v1.label, "v1");
        assertEq(address(YoloPredict(extra[5]).vault()), core[LaunchPlan.CORE_VAULT], "YoloPredict reads this vault");
        assertEq(address(YoloLockHub(core[LaunchPlan.CORE_HUB]).yolo()), yolo, "the doer stake is in $YOLO");
        assertEq(address(DisputeDesk(core[LaunchPlan.CORE_DISPUTE]).doerStake()), core[LaunchPlan.CORE_HUB], "the DisputeDesk reads the hub of launch 2");
        assertEq(ITaskVault(core[LaunchPlan.CORE_VAULT]).burner(), s.burner, "the vault burns through this burner");

        ITaskVault vault = ITaskVault(core[LaunchPlan.CORE_VAULT]);
        assertEq(vault.caseDesk(), core[LaunchPlan.CORE_CASE]);
        assertEq(vault.disputeDesk(), core[LaunchPlan.CORE_DISPUTE]);
        assertEq(vault.registry(), s.registry);
        assertEq(vault.yolo(), yolo);
        assertEq(ParamsRegistry(s.registry).owner(), OWNER);
        assertTrue(ParamsRegistry(s.registry).isAttester(LaunchPlan.ATTESTER));
        _checkSupplyAndSplit();
        _yoloFirstHour(); // first: the opening and the schedule run in the hours after the launch
        _smoke(vault);
        _yoloPriceAndTask(vault, DevPrices(s.devPrices));
        _burner(BuybackBurner(payable(s.burner)), DevPrices(s.devPrices));
    }

    /// @dev The BuybackBurner swaps nothing: a stranger sends the live USDC, IMD and
    ///      ETH it holds to the buyback wallet and burns its $YOLO; the dev wallet (owner of the DevPrices) alone
    ///      changes the buyback wallet.
    function _burner(BuybackBurner burner, DevPrices prices) internal {
        address dead = 0x000000000000000000000000000000000000dEaD;
        address stranger = makeAddr("stranger");
        address wallet = burner.buybackWallet();
        assertEq(wallet, LaunchPlan.PROJECT_BUYBACK, "the owner's buyback wallet");
        assertEq(burner.dev(), prices.owner(), "the dev wallet = owner of the DevPrices");
        assertEq(burner.dev(), LaunchPlan.PROJECT_DEV, "the dev wallet of the plan");
        deal(LaunchPlan.USDC, address(burner), 250e6);
        deal(LaunchPlan.IMD, address(burner), 30e18);
        vm.deal(address(burner), 0.1 ether);
        uint256 u0 = IERC20(LaunchPlan.USDC).balanceOf(wallet);
        uint256 i0 = IERC20(LaunchPlan.IMD).balanceOf(wallet);
        uint256 e0 = wallet.balance;
        vm.startPrank(stranger);
        burner.forward(LaunchPlan.USDC);
        burner.forward(LaunchPlan.IMD);
        burner.forward(address(0));
        vm.stopPrank();
        assertEq(IERC20(LaunchPlan.USDC).balanceOf(wallet) - u0, 250e6);
        assertEq(IERC20(LaunchPlan.IMD).balanceOf(wallet) - i0, 30e18);
        assertEq(wallet.balance - e0, 0.1 ether);
        deal(yolo, address(burner), 1_000e18);
        vm.prank(stranger);
        vm.expectRevert(BuybackBurner.NotReserve.selector);
        burner.forward(yolo);
        uint256 deadBefore = IERC20(yolo).balanceOf(dead);
        vm.prank(stranger);
        burner.burnYolo();
        assertEq(IERC20(yolo).balanceOf(dead) - deadBefore, 1_000e18, "straight to 0x...dEaD");
        vm.prank(stranger);
        vm.expectRevert(BuybackBurner.NotDev.selector);
        burner.setBuybackWallet(stranger);
    }

    // ------------------------------------------------------------------ launches

    function _launchGenesis() internal returns (uint256 total) {
        (bytes[] memory codes, bytes32[] memory names, LaunchPlan.Genesis memory g) = LaunchPlan.genesisLaunch(
            FACTORY, LAUNCH_GENESIS, LaunchPlan.Owners(TREASURY, INCENTIVES, STABILIZER, DEV, TEAM)
        );
        address[] memory expected = new address[](6);
        (expected[0], expected[1], expected[2], expected[3], expected[4], expected[5]) =
            (g.gate, g.incentives, g.dev, g.team, g.treasury, g.splitter);
        (, total) = _launchContracts(LAUNCH_GENESIS, codes, names, expected);
        genesis = g;
        for (uint256 i; i < codes.length; ++i) {
            _logSize(names[i], expected[i]);
        }
    }

    function _launchSupportWithToken() internal returns (LaunchPlan.Support memory s, uint256 total) {
        openAt = vm.getBlockTimestamp() + OPEN_DELAY;
        bytes memory tokenCode = LaunchPlan.yoloTokenCode(genesis.gate, OWNER, openAt);
        yolo = FACTORY.predictToken(LAUNCH_SUPPORT, tokenCode);
        bytes[] memory codes;
        bytes32[] memory names;
        (codes, names, s) =
            LaunchPlan.support(FACTORY, LAUNCH_SUPPORT, LaunchPlan.mainnet(OWNER, TREASURY), LaunchPlan.yoloPool(yolo));
        address[] memory expected = new address[](codes.length);
        (expected[0], expected[1], expected[2], expected[3], expected[4], expected[5], expected[6]) =
        (
            s.devPrices,
            s.swapAdapter,
            s.registry,
            s.textRules,
            s.questionBuilder,
            s.votePower,
            s.attestationChecker
        );
        expected[7] = s.burner;
        IProjectFactory.CustomParams memory p;
        p.launchNumber = LAUNCH_SUPPORT;
        p.tokenCreationCode = tokenCode;
        p.tokenName = "YoloToken";
        p.contractCreationCodes = codes;
        p.contractNames = names;
        p.expectedContracts = expected;
        p.totalSupply = LaunchPlan.YOLO_SUPPLY;
        p.poolBps = POOL_BPS;
        p.remainderTo = genesis.splitter;
        p.merkleRoot = swarmRoot != bytes32(0) ? swarmRoot : keccak256("swarm round");
        p.contributorLockSeconds = 1 hours;
        p.sweepDelaySeconds = 365 days;
        p.pairedCurrency = LaunchPlan.IMD;
        p.tickSpacing = LaunchPlan.POOL_TICK_SPACING;
        (p.sqrtPriceX96, p.tickLower, p.tickUpper, p.liquidity) =
            _seed(yolo, LaunchPlan.POOL_TICK_SPACING, LaunchPlan.YOLO_SUPPLY * POOL_BPS / 10_000 - 1e18);
        p.record.kind = "custom_token";
        p.record.launchNumber = LAUNCH_SUPPORT;
        p.record.sourceRepoUrl = "https://github.com/example/moneycanbuy";
        p.requester = OWNER;
        (, total) = _send(abi.encodeCall(IProjectFactory.launchCustom, (p)));
        assertEq(yolo.code.length != 0, true, "YOLO deployed at the predicted address");
        for (uint256 i; i < codes.length; ++i) {
            assertGt(expected[i].code.length, 0);
            _logSize(names[i], expected[i]);
        }
        _logSize("YoloToken", yolo);
    }

    function _launchCore(LaunchPlan.Support memory s) internal returns (address[] memory deployed, uint256 total) {
        (bytes[] memory codes, bytes32[] memory names, address[] memory addrs) =
            LaunchPlan.core(FACTORY, LAUNCH_CORE, s, LaunchPlan.IMD, LaunchPlan.USDC, yolo);
        (deployed, total) = _launchContracts(LAUNCH_CORE, codes, names, addrs);
        coreBlock = uint64(block.number);
        for (uint256 i; i < codes.length; ++i) {
            _logSize(names[i], deployed[i]);
        }
    }

    function _launchExtras(address vault) internal returns (address[] memory deployed, uint256 total) {
        (bytes[] memory codes, bytes32[] memory names, address[] memory addrs) =
            LaunchPlan.extras(FACTORY, LAUNCH_EXTRAS, vault, OWNER, coreBlock);
        (deployed, total) = _launchContracts(LAUNCH_EXTRAS, codes, names, addrs);
        for (uint256 i; i < codes.length; ++i) {
            _logSize(names[i], deployed[i]);
        }
    }

    function _logSize(bytes32 name, address a) internal {
        emit log_named_uint(string(abi.encodePacked("  runtime bytes ", _name(name))), a.code.length);
        assertLe(a.code.length, EIP170, "EIP-170 contract size limit");
    }

    function _launchContracts(uint64 n, bytes[] memory codes, bytes32[] memory names, address[] memory expected)
        internal
        returns (address[] memory deployed, uint256 total)
    {
        IProjectFactory.ContractsParams memory p;
        p.launchNumber = n;
        p.contractCreationCodes = codes;
        p.contractNames = names;
        p.expectedContracts = expected;
        p.record.kind = "evm_contracts";
        p.record.launchNumber = n;
        p.record.sourceRepoUrl = "https://github.com/example/moneycanbuy";
        bytes memory ret;
        (ret, total) = _send(abi.encodeCall(IProjectFactory.launchContracts, (p)));
        deployed = abi.decode(ret, (address[]));
        for (uint256 i; i < deployed.length; ++i) {
            assertEq(deployed[i], expected[i]);
        }
    }

    /// @dev 21,000 + calldata at 16 per nonzero / 4 per zero byte.
    function _intrinsic(bytes memory data) internal pure returns (uint256 g) {
        g = 21_000;
        for (uint256 i; i < data.length; ++i) {
            g += data[i] == 0 ? 4 : 16;
        }
    }

    /// @dev EIP-7623: a transaction pays at least 21,000 + 10 per zero / 40 per nonzero calldata byte.
    function _floor(bytes memory data) internal pure returns (uint256 g) {
        g = 21_000;
        for (uint256 i; i < data.length; ++i) {
            g += data[i] == 0 ? 10 : 40;
        }
    }

    // ------------------------------------------------------------------ $YOLO after the launch

    /// @dev Where the 1B went: the pool 15%, the swarm's 10%, the remainder (75%) in the splitter; one split hands it
    ///      out. The factory keeps nothing.
    function _checkSupplyAndSplit() internal {
        IERC20 y = IERC20(yolo);
        uint256 inPool = y.balanceOf(LaunchPlan.POOL_MANAGER);
        uint256 inSplitter = y.balanceOf(genesis.splitter);
        emit log_named_decimal_uint("YOLO in the pool (PoolManager)", inPool, 18);
        emit log_named_decimal_uint("YOLO in YoloSplitter (remainder)", inSplitter, 18);
        emit log_named_decimal_uint("YOLO left with the factory", y.balanceOf(address(FACTORY)), 18);
        assertApproxEqRel(inPool, LaunchPlan.YOLO_SUPPLY * POOL_BPS / 10_000, 0.001e18);
        assertApproxEqAbs(inSplitter, 750_000_000e18, 1_000e18, "the project's 75%");
        uint256 incBefore = y.balanceOf(INCENTIVES);
        uint256 treBefore = y.balanceOf(TREASURY);
        YoloSplitter(genesis.splitter).split(yolo);
        // the split starts the four clocks and pays the at-once parts in the same transaction
        assertEq(y.balanceOf(genesis.incentives) + y.balanceOf(INCENTIVES) - incBefore, 250_000_000e18, "incentives 25%");
        assertEq(y.balanceOf(INCENTIVES) - incBefore, 62_500_000e18, "incentives: a quarter at the split");
        assertEq(y.balanceOf(STABILIZER), 150_000_000e18, "Stabilizer 15%");
        assertEq(y.balanceOf(genesis.dev), 77_777_777e18, "dev 7.777777%");
        assertEq(y.balanceOf(genesis.team), 50_000_000e18, "team 5%");
        assertEq(y.balanceOf(TREASURY) - treBefore, 74_074_074e18, "treasury: a third at the split");
        assertEq(
            y.balanceOf(genesis.treasury) + y.balanceOf(TREASURY) - treBefore,
            inSplitter - 527_777_777e18,
            "treasury: the rest + dust"
        );
        emit log_named_decimal_uint("  treasury vesting (the rest + the factory's dust)", y.balanceOf(genesis.treasury), 18);
        assertEq(y.balanceOf(address(FACTORY)), 0, "the factory keeps nothing");
        assertEq(ProjectVesting(genesis.incentives).beneficiary(), INCENTIVES);
        assertEq(ProjectVesting(genesis.dev).beneficiary(), DEV);
        assertEq(ProjectVesting(genesis.team).startOf(yolo), block.timestamp, "the clocks start at the split");
        uint256 snap = vm.snapshotState(); // a day later, then back: the first hour after the launch follows
        skip(1 days);
        uint256 since = block.timestamp - ProjectVesting(genesis.team).startOf(yolo);
        assertEq(
            ProjectVesting(genesis.team).releasable(yolo), uint256(50_000_000e18) * since / 365 days, "team: from day one"
        );
        assertEq(
            ProjectVesting(genesis.treasury).releasable(yolo),
            y.balanceOf(genesis.treasury) * since / 365 days,
            "treasury: a third at once, the rest from the split"
        );
        assertEq(
            ProjectVesting(genesis.incentives).releasable(yolo),
            uint256(187_500_000e18) * since / 730 days,
            "incentives: a quarter at once, the rest over 24 months"
        );
        vm.revertToState(snap);
    }

    // ---- the Universal Router, as a wallet or the site drives it

    function _key() internal view returns (PoolKey memory k) {
        bool imdIs0 = LaunchPlan.IMD < yolo;
        k = PoolKey(
            imdIs0 ? LaunchPlan.IMD : yolo,
            imdIs0 ? yolo : LaunchPlan.IMD,
            LaunchPlan.POOL_FEE,
            LaunchPlan.POOL_TICK_SPACING,
            LaunchPlan.POOL_GUARD
        );
    }

    function _approveRouter(address who, address token) internal {
        vm.startPrank(who);
        IERC20(token).approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(token, address(UR), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    /// @dev `who` buys YOLO for `imdIn`: V4_SWAP (exact in, settle all IMD, then TAKE_ALL YOLO straight to `who`), or
    ///      with `viaRouter` TAKE to the router and SWEEP to `who` (how aggregators route). Returns ok, YOLO received,
    ///      the revert data and the gas of the router call.
    function _urBuy(address who, uint256 imdIn, bool viaRouter)
        internal
        returns (bool ok, uint256 got, bytes memory ret, uint256 gasUsed)
    {
        PoolKey memory k = _key();
        bool imdIs0 = k.currency0 == LaunchPlan.IMD;
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactInputSingleParams(k, imdIs0, uint128(imdIn), 0, bytes("")));
        params[1] = abi.encode(LaunchPlan.IMD, imdIn);
        bytes memory commands;
        bytes[] memory inputs;
        if (!viaRouter) {
            params[2] = abi.encode(yolo, uint256(0));
            commands = abi.encodePacked(V4_SWAP);
            inputs = new bytes[](1);
            inputs[0] = abi.encode(abi.encodePacked(SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL), params);
        } else {
            params[2] = abi.encode(yolo, address(2), uint256(0)); // ADDRESS_THIS = the router, 0 = the whole credit
            commands = abi.encodePacked(V4_SWAP, SWEEP);
            inputs = new bytes[](2);
            inputs[0] = abi.encode(abi.encodePacked(SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE), params);
            inputs[1] = abi.encode(yolo, who, uint256(0));
        }
        uint256 before = IERC20(yolo).balanceOf(who);
        vm.prank(who, who);
        uint256 g = gasleft();
        (ok, ret) = address(UR).call(abi.encodeCall(IUniversalRouter.execute, (commands, inputs, block.timestamp + 60)));
        gasUsed = g - gasleft();
        got = IERC20(yolo).balanceOf(who) - before;
    }

    /// @dev `who` sells `yoloIn` YOLO for IMD through the router.
    function _urSell(address who, uint256 yoloIn) internal {
        PoolKey memory k = _key();
        bool yoloIs0 = k.currency0 == yolo;
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactInputSingleParams(k, yoloIs0, uint128(yoloIn), 0, bytes("")));
        params[1] = abi.encode(yolo, yoloIn);
        params[2] = abi.encode(LaunchPlan.IMD, uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL), params);
        vm.prank(who, who);
        UR.execute(abi.encodePacked(V4_SWAP), inputs, block.timestamp + 60);
    }

    /// @dev `who` sells `yoloIn` YOLO for USDC routed through IMD, one router call: V4_SWAP YOLO -> IMD (SETTLE_ALL the
    ///      YOLO from `who` through Permit2, TAKE the IMD to the router), then v3 IMD -> USDC 0.3% to `who`.
    function _urSellRouted(address who, uint256 yoloIn) internal returns (bool ok, uint256 usdcGot, bytes memory ret) {
        PoolKey memory k = _key();
        bool yoloIs0 = k.currency0 == yolo;
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactInputSingleParams(k, yoloIs0, uint128(yoloIn), 0, bytes("")));
        params[1] = abi.encode(yolo, yoloIn);
        params[2] = abi.encode(LaunchPlan.IMD, address(2), uint256(0)); // the whole IMD credit to the router
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(abi.encodePacked(SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE), params);
        inputs[1] = abi.encode(
            who, CONTRACT_BALANCE, uint256(0), abi.encodePacked(LaunchPlan.IMD, V3_FEE_USDC_IMD, LaunchPlan.USDC), false
        );
        uint256 before = IERC20(LaunchPlan.USDC).balanceOf(who);
        vm.prank(who, who);
        (ok, ret) = address(UR).call(
            abi.encodeCall(
                IUniversalRouter.execute, (abi.encodePacked(V4_SWAP, V3_SWAP_EXACT_IN), inputs, block.timestamp + 60)
            )
        );
        usdcGot = IERC20(LaunchPlan.USDC).balanceOf(who) - before;
    }

    /// @dev A sell of `yoloIn` into the pool at `e` seconds after the opening, through the router for IMD: the pool
    ///      gets `yoloIn`, the seller pays the tax on top, the treasury gets exactly that share of all they parted with.
    function _taxedSell(address who, uint256 yoloIn, uint256 e, string memory label) internal {
        uint256 num = e < 30 minutes ? 3_000 * 30 minutes : (e < 60 minutes ? 3_000 * (60 minutes - e) : 0);
        uint256 tax = num == 0 ? 0 : yoloIn * num / (10_000 * 30 minutes - num);
        uint256 safeBefore = IERC20(yolo).balanceOf(OWNER);
        uint256 b0 = IERC20(yolo).balanceOf(who);
        uint256 i0 = IERC20(LaunchPlan.IMD).balanceOf(who);
        _urSell(who, yoloIn);
        assertEq(b0 - IERC20(yolo).balanceOf(who), yoloIn + tax, string.concat(label, ": the seller pays yoloIn + tax"));
        assertEq(IERC20(yolo).balanceOf(OWNER) - safeBefore, tax, string.concat(label, ": the sell tax to the treasury"));
        assertGt(IERC20(LaunchPlan.IMD).balanceOf(who), i0, "IMD received");
        emit log_named_decimal_uint(string.concat(label, ": sell, YOLO into the pool"), yoloIn, 18);
        emit log_named_decimal_uint(string.concat(label, ": sell tax to the treasury"), tax, 18);
        emit log_named_decimal_uint(string.concat(label, ": IMD received"), IERC20(LaunchPlan.IMD).balanceOf(who) - i0, 18);
    }

    /// @dev The token's reason inside the PoolManager's WrappedError(target, selector, reason, details), as a wallet
    ///      or the site decodes it.
    function _innerReason(bytes memory ret) internal view returns (bytes memory reason) {
        assertEq(bytes4(ret), WRAPPED_ERROR, "the PoolManager wraps the token's error");
        bytes memory body = new bytes(ret.length - 4);
        for (uint256 i; i < body.length; ++i) {
            body[i] = ret[i + 4];
        }
        address target;
        (target,, reason,) = abi.decode(body, (address, bytes4, bytes, bytes));
        assertEq(target, yolo, "the wrapped error is the token's");
    }

    function _next(uint256 secondsAfterOpen) internal {
        vm.warp(openAt + secondsAfterOpen);
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// @dev `who` buys YOLO with USDC or ETH routed through IMD, as a wallet does it on mainnet: the first hop on
    ///      v3 (USDC/IMD 0.3%, or WRAP_ETH then WETH/USDC 0.05% and USDC/IMD 0.3%) into the router, then V4_SWAP: SETTLE the
    ///      router's IMD, swap the whole credit, TAKE_ALL YOLO straight to `who` (or with `viaRouter` TAKE to the
    ///      router and SWEEP to `who`).
    function _urBuyRouted(address who, bool withEth, uint256 amountIn, bool viaRouter)
        internal
        returns (bool ok, uint256 got, bytes memory ret)
    {
        PoolKey memory k = _key();
        bool imdIs0 = k.currency0 == LaunchPlan.IMD;
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(LaunchPlan.IMD, CONTRACT_BALANCE, false); // SETTLE the router's IMD
        params[1] = abi.encode(ExactInputSingleParams(k, imdIs0, 0, 0, bytes(""))); // 0 = the whole open credit
        bytes memory actions;
        if (!viaRouter) {
            params[2] = abi.encode(yolo, uint256(0));
            actions = abi.encodePacked(SETTLE, SWAP_EXACT_IN_SINGLE, TAKE_ALL);
        } else {
            params[2] = abi.encode(yolo, address(2), uint256(0));
            actions = abi.encodePacked(SETTLE, SWAP_EXACT_IN_SINGLE, TAKE);
        }
        bytes memory v4 = abi.encode(actions, params);
        bytes memory commands;
        bytes[] memory inputs = new bytes[](withEth ? 3 : 2);
        uint256 i;
        if (withEth) {
            commands = abi.encodePacked(WRAP_ETH);
            inputs[i++] = abi.encode(address(2), amountIn);
            inputs[i++] = abi.encode(
                address(2), CONTRACT_BALANCE, uint256(0),
                abi.encodePacked(LaunchPlan.WETH, V3_FEE_WETH_USDC, LaunchPlan.USDC, V3_FEE_USDC_IMD, LaunchPlan.IMD), false
            );
        } else {
            inputs[i++] = abi.encode(
                address(2), amountIn, uint256(0), abi.encodePacked(LaunchPlan.USDC, V3_FEE_USDC_IMD, LaunchPlan.IMD), true
            );
        }
        commands = abi.encodePacked(commands, V3_SWAP_EXACT_IN, V4_SWAP);
        inputs[i++] = v4;
        if (viaRouter) {
            commands = abi.encodePacked(commands, SWEEP);
            bytes[] memory more = new bytes[](inputs.length + 1);
            for (uint256 j; j < inputs.length; ++j) {
                more[j] = inputs[j];
            }
            more[inputs.length] = abi.encode(yolo, who, uint256(0));
            inputs = more;
        }
        uint256 before = IERC20(yolo).balanceOf(who);
        vm.prank(who, who);
        (ok, ret) = address(UR).call{value: withEth ? amountIn : 0}(
            abi.encodeCall(IUniversalRouter.execute, (commands, inputs, block.timestamp + 60))
        );
        got = IERC20(yolo).balanceOf(who) - before;
    }

    /// @dev $YOLO's opening and first hour on the live pool, through the live Universal Router:
    ///      before openAt nobody buys, not even a snapshot wallet; the project wallet writes the snapshot of real
    ///      identity.md holders and seals it before openAt; minutes 0-30 after openAt only the snapshot's wallets
    ///      buy, up to 500,000 YOLO per NFT, with IMD or with USDC and ETH routed through IMD, YOLO straight to the
    ///      buyer; a route through a router or a contract in between is refused; an NFT moved after the snapshot
    ///      gives nothing; every sell pays 30% from openAt (for IMD, and YOLO -> IMD -> USDC); at minute 30 the
    ///      buy and the sell tax are 30% and fall to 0 at minute 60, to the treasury; the factory's fee claim is
    ///      exempt; after minute 60 a plain ERC-20.
    function _yoloFirstHour() internal {
        NftGate gate = NftGate(genesis.gate);
        YoloToken token = YoloToken(yolo);
        assertEq(token.openAt(), openAt, "openAt as launched");
        assertEq(gate.writer(), TREASURY, "the project wallet writes the snapshot");
        address bot = makeAddr("bot");
        address holder = NFT.ownerOf(0);
        address second = NFT.ownerOf(1999);
        require(holder != second, "two different real holders");
        address[4] memory buyers = [bot, holder, second, STABILIZER];
        for (uint256 i; i < buyers.length; ++i) {
            deal(LaunchPlan.IMD, buyers[i], 1_000e18);
            _approveRouter(buyers[i], LaunchPlan.IMD);
        }
        deal(LaunchPlan.USDC, second, 1_000e6);
        _approveRouter(second, LaunchPlan.USDC);
        vm.deal(second, 1 ether);
        // the treasury's at-once third, paid by the split, sits with the tax recipient already
        uint256 ownerAtStart = IERC20(yolo).balanceOf(OWNER);

        // before openAt the pool is seeded but nobody buys, a holder neither
        vm.warp(vm.getBlockTimestamp() + 12);
        vm.roll(vm.getBlockNumber() + 1);
        assertFalse(token.tradingOpen());
        (bool ok,, bytes memory ret,) = _urBuy(holder, 5e18, false);
        assertFalse(ok);
        assertEq(_innerReason(ret), abi.encodeWithSelector(YoloToken.TradingNotOpen.selector, openAt));

        // the snapshot shortly before the opening: the project wallet writes the holders (one NFT each here: the
        // mechanics; script/snapshot reads the real counts at a block) and seals it
        address[] memory w = new address[](2);
        uint256[] memory n = new uint256[](2);
        (w[0], n[0], w[1], n[1]) = (holder, 1, second, 1);
        vm.prank(bot);
        vm.expectRevert(NftGate.NotWriter.selector);
        gate.record(w, n);
        vm.prank(TREASURY);
        uint256 g0 = gasleft();
        gate.record(w, n);
        emit log_named_uint("snapshot: record 2 wallets gas", g0 - gasleft());
        vm.prank(TREASURY);
        gate.seal(block.number);
        vm.prank(TREASURY);
        vm.expectRevert(NftGate.AlreadySealed.selector);
        gate.record(w, n);
        assertEq(gate.totalNfts(), 2);
        _next(0); // openAt itself
        assertTrue(token.tradingOpen());
        _next(12);

        // minute 0: not in the snapshot -> NotWhitelisted, decoded from the router's revert data
        (ok,, ret,) = _urBuy(bot, 5e18, false);
        assertFalse(ok);
        assertEq(_innerReason(ret), abi.encodeWithSelector(YoloToken.NotWhitelisted.selector, bot));

        // a snapshot wallet buys with IMD straight through TAKE_ALL, untaxed
        uint256 got;
        uint256 g;
        (ok, got,, g) = _urBuy(holder, 5e18, false);
        assertTrue(ok, "a snapshot wallet buys through the Universal Router");
        emit log_named_decimal_uint("minute 0, snapshot wallet: YOLO for 5 IMD", got, 18);
        emit log_named_uint("  router buy gas (gate, first buy)", g);
        assertEq(IERC20(yolo).balanceOf(OWNER), ownerAtStart, "no tax in the whitelist window");
        // the same wallet through a route that takes the output to the router: refused, the router is not listed
        (ok,, ret,) = _urBuy(holder, 1e18, true);
        assertFalse(ok);
        assertEq(_innerReason(ret), abi.encodeWithSelector(YoloToken.NotWhitelisted.selector, address(UR)));
        // a contract buying in between (it takes the YOLO itself to pass it on): refused
        V4Buyer middle = new V4Buyer();
        deal(LaunchPlan.IMD, address(middle), 5e18);
        vm.expectRevert();
        middle.buy(yolo, 5e18, address(middle));
        // above the 500,000 allowance of one NFT
        uint256 left = gate.left(yolo, holder);
        (ok,, ret,) = _urBuy(holder, 10e18, false);
        assertFalse(ok);
        bytes memory reason = _innerReason(ret);
        assertEq(bytes4(reason), YoloToken.NftAllowanceExceeded.selector);
        (, uint256 leftSaid,) = abi.decode(_tail(reason), (address, uint256, uint256));
        assertEq(leftSaid, left, "the error says what is left");

        // USDC -> IMD (v3) -> YOLO (v4) and ETH -> WETH -> USDC -> IMD (v3) -> YOLO (v4), one router call each, YOLO straight
        // to the snapshot wallet
        (ok, got,) = _urBuyRouted(second, false, 20e6, false);
        assertTrue(ok, "USDC -> IMD -> YOLO in the window");
        emit log_named_decimal_uint("minute 0, snapshot wallet: YOLO for 20 USDC via IMD", got, 18);
        assertGt(got, 0);
        (ok, got, ret) = _urBuyRouted(second, true, 0.001 ether, false);
        if (!ok) emit log_named_bytes("ETH route revert", ret);
        assertTrue(ok, "ETH -> IMD -> YOLO in the window");
        emit log_named_decimal_uint("minute 0, snapshot wallet: YOLO for 0.001 ETH via IMD", got, 18);
        assertGt(got, 0);
        assertEq(IERC20(LaunchPlan.IMD).balanceOf(address(UR)), 0, "no IMD left in the router");
        // the same route paying the router first: refused
        (ok,, ret) = _urBuyRouted(second, false, 20e6, true);
        assertFalse(ok, "USDC route through the router refused");
        assertEq(_innerReason(ret), abi.encodeWithSelector(YoloToken.NotWhitelisted.selector, address(UR)));

        // minute 0: every sell pays 30%, the Stabilizer's for IMD and a snapshot wallet's
        // YOLO -> IMD -> USDC, both through the Universal Router
        _approveRouter(STABILIZER, yolo);
        _taxedSell(STABILIZER, 100_000e18, vm.getBlockTimestamp() - openAt, "minute 0, Stabilizer");
        _approveRouter(second, yolo);
        {
            uint256 yb = IERC20(yolo).balanceOf(second);
            uint256 sIn = yb * 7_000 / 10_000; // 70% of the wallet into the pool, 30% tax: the most it can sell
            uint256 safe0 = IERC20(yolo).balanceOf(OWNER);
            uint256 usdcGot;
            (ok, usdcGot, ret) = _urSellRouted(second, sIn);
            if (!ok) emit log_named_bytes("YOLO -> IMD -> USDC revert", ret);
            assertTrue(ok, "YOLO -> IMD -> USDC in the window");
            uint256 sTax = sIn * 3_000 / 7_000;
            assertEq(IERC20(yolo).balanceOf(OWNER) - safe0, sTax, "30% of what the wallet parted with");
            assertEq(yb - IERC20(yolo).balanceOf(second), sIn + sTax);
            assertGt(usdcGot, 0);
            emit log_named_decimal_uint("minute 0, snapshot wallet sells YOLO", sIn + sTax, 18);
            emit log_named_decimal_uint("  of it sell tax 30%", sTax, 18);
            emit log_named_decimal_uint("  USDC received via IMD", usdcGot, 6);
            // the whole wallet without room for the tax: refused
            (ok,,) = _urSellRouted(second, IERC20(yolo).balanceOf(second));
            assertFalse(ok, "a sell of the whole balance has no room for the tax");
        }

        // an NFT moved after the snapshot gives nothing: the bot gets #0, still refused; the holder keeps their allowance
        vm.prank(holder);
        NFT.transferFrom(holder, bot, 0);
        (ok,, ret,) = _urBuy(bot, 1e18, false);
        assertFalse(ok);
        assertEq(_innerReason(ret), abi.encodeWithSelector(YoloToken.NotWhitelisted.selector, bot));
        assertEq(gate.allowanceOf(holder), gate.ALLOWANCE_PER_NFT());

        // the edge of minute 30
        _next(30 minutes - 1);
        (ok,,,) = _urBuy(bot, 5e18, false);
        assertFalse(ok, "29:59 still the whitelist");
        _next(30 minutes);
        _taxedBuy(bot, 50e18, 30 minutes, "minute 30");
        _next(45 minutes);
        _taxedBuy(bot, 50e18, 45 minutes, "minute 45");
        // the Stabilizer sells at minute 45: 15%; then the factory's fee claim in YOLO: exempt
        _taxedSell(STABILIZER, 2_500_000e18, 45 minutes, "minute 45, Stabilizer");
        uint256 safeBefore = IERC20(yolo).balanceOf(OWNER);
        (uint256 f0, uint256 f1) = FACTORY.claimFees(LAUNCH_SUPPORT);
        emit log_named_uint("claimFees in the tax window, amount0", f0);
        emit log_named_uint("claimFees in the tax window, amount1", f1);
        uint256 yoloFee = LaunchPlan.IMD < yolo ? f1 : f0;
        assertGt(yoloFee, 0, "YOLO fees collected by the factory");
        // the requester (here the treasury stand-in, the launch payer of this rehearsal) gets its 80% from the factory, untaxed
        assertEq(IERC20(yolo).balanceOf(OWNER), safeBefore + yoloFee * 8_000 / 10_000, "the fee claim is untaxed");
        _next(60 minutes - 1);
        _taxedBuy(bot, 50e18, 60 minutes - 1, "minute 59:59");
        _next(60 minutes);
        uint256 safeNow = IERC20(yolo).balanceOf(OWNER);
        (ok, got,, g) = _urBuy(bot, 50e18, false);
        assertTrue(ok);
        assertEq(IERC20(yolo).balanceOf(OWNER), safeNow, "minute 60: no tax, a plain ERC-20");
        _taxedSell(STABILIZER, 1_000_000e18, 60 minutes, "minute 60, Stabilizer");
        emit log_named_uint("  router buy gas after minute 60", g);
    }

    /// @dev A swarm worker's YOLO: the live factory puts the swarm's 10% into
    ///      its MerkleDistributor at launch 1; the worker claims their leaf with a real proof after the contributor lock
    ///      (1 h, before openAt), sells through the Universal Router at minutes 0, 15, 45 and 60 (30% / 30% / 15% / 0
    ///      of what they part with, to the treasury), passes YOLO to a fresh wallet untaxed, the fresh wallet sells at
    ///      the same minutes with the same tax; the worker is not in the snapshot, so their buys in minutes 0-30 revert.
    function test_swarmWorkerSellTax() public {
        address worker = makeAddr("swarm worker");
        address peer = makeAddr("swarm peer");
        address fresh = makeAddr("fresh wallet");
        uint256 aWorker = 1_000_000e18;
        uint256 aPeer = 2_000_000e18;
        // a two-leaf StandardMerkleTree: leaf = keccak(keccak(abi.encode(account, amount))), pairs hashed sorted
        bytes32 lw = keccak256(bytes.concat(keccak256(abi.encode(worker, aWorker))));
        bytes32 lp = keccak256(bytes.concat(keccak256(abi.encode(peer, aPeer))));
        swarmRoot = lw < lp ? keccak256(abi.encode(lw, lp)) : keccak256(abi.encode(lp, lw));
        _launchGenesis();
        _launchSupportWithToken();
        IMerkleDistributorMin dist = IMerkleDistributorMin(FACTORY.distributorOf(LAUNCH_SUPPORT));
        assertGt(address(dist).code.length, 0, "the launch's distributor");
        assertEq(IERC20(yolo).balanceOf(address(dist)), LaunchPlan.YOLO_SUPPLY / 10, "the swarm's 10% in the distributor");
        assertEq(dist.roundCount(), 1);
        emit log_named_address("swarm distributor (factory.distributorOf)", address(dist));
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = lp;
        // the contributor lock (1 h) holds the claim
        vm.expectRevert();
        dist.claim(0, worker, aWorker, proof);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.roll(vm.getBlockNumber() + 300);
        vm.prank(makeAddr("anyone")); // anyone may submit, the YOLO goes only to the leaf's account
        dist.claim(0, worker, aWorker, proof);
        assertEq(IERC20(yolo).balanceOf(worker), aWorker, "the worker claimed their leaf in full");
        assertLt(vm.getBlockTimestamp(), openAt, "claimed before trading opens");

        // the snapshot before openAt: one real identity.md holder (10 NFTs here, so the pool gets IMD to sell into)
        address holder = NFT.ownerOf(0);
        {
            address[] memory w = new address[](1);
            uint256[] memory n = new uint256[](1);
            (w[0], n[0]) = (holder, 10);
            vm.startPrank(TREASURY);
            NftGate(genesis.gate).record(w, n);
            NftGate(genesis.gate).seal(block.number);
            vm.stopPrank();
        }
        deal(LaunchPlan.IMD, holder, 1_000e18);
        _approveRouter(holder, LaunchPlan.IMD);
        deal(LaunchPlan.IMD, worker, 1_000e18);
        _approveRouter(worker, LaunchPlan.IMD);
        _approveRouter(worker, yolo);
        _approveRouter(fresh, yolo);

        _next(0);
        (bool ok, uint256 got, bytes memory ret,) = _urBuy(holder, 60e18, false);
        assertTrue(ok, "a snapshot holder buys at minute 0");
        emit log_named_decimal_uint("minute 0, snapshot holder: YOLO for 60 IMD", got, 18);
        // the worker is not in the snapshot: their buy reverts in minutes 0-30
        (ok,, ret,) = _urBuy(worker, 5e18, false);
        assertFalse(ok, "worker buy at minute 0");
        assertEq(_innerReason(ret), abi.encodeWithSelector(YoloToken.NotWhitelisted.selector, worker));

        // the worker passes 400,000 YOLO to a fresh wallet inside the tax window: untaxed
        uint256 t0 = IERC20(yolo).balanceOf(TREASURY);
        vm.prank(worker);
        IERC20(yolo).transfer(fresh, 400_000e18);
        assertEq(IERC20(yolo).balanceOf(fresh), 400_000e18, "transfer between wallets: all of it arrives");
        assertEq(IERC20(yolo).balanceOf(TREASURY), t0, "transfer between wallets: no tax");

        _workerSell(worker, fresh, 0, 70_000e18, 3_000);
        _next(15 minutes);
        (ok,, ret,) = _urBuy(worker, 5e18, false);
        assertFalse(ok, "worker buy at minute 15");
        assertEq(_innerReason(ret), abi.encodeWithSelector(YoloToken.NotWhitelisted.selector, worker));
        _workerSell(worker, fresh, 15 minutes, 70_000e18, 3_000);
        _next(30 minutes - 1);
        (ok,, ret,) = _urBuy(worker, 5e18, false);
        assertFalse(ok, "worker buy at 29:59");
        assertEq(_innerReason(ret), abi.encodeWithSelector(YoloToken.NotWhitelisted.selector, worker));
        _next(45 minutes);
        _workerSell(worker, fresh, 45 minutes, 85_000e18, 1_500);
        _next(60 minutes);
        _workerSell(worker, fresh, 60 minutes, 100_000e18, 0);
    }

    /// @dev At `e` after openAt the worker, then the fresh wallet, each sells `yoloIn` into the pool: the treasury gets
    ///      exactly `bps` of what each parts with.
    function _workerSell(address worker, address fresh, uint256 e, uint256 yoloIn, uint256 bps) internal {
        address[2] memory who = [worker, fresh];
        string[2] memory name = ["worker", "fresh wallet"];
        for (uint256 i; i < 2; ++i) {
            uint256 t0 = IERC20(yolo).balanceOf(TREASURY);
            uint256 b0 = IERC20(yolo).balanceOf(who[i]);
            string memory label = string.concat("minute ", vm.toString(e / 60), ", ", name[i]);
            _taxedSell(who[i], yoloIn, e, label);
            uint256 spent = b0 - IERC20(yolo).balanceOf(who[i]);
            uint256 tax = IERC20(yolo).balanceOf(TREASURY) - t0;
            assertEq(tax * 10_000, spent * bps, string.concat(label, ": exact share of what was parted with"));
            emit log_named_decimal_uint(string.concat(label, ": parted with"), spent, 18);
            emit log_named_uint(string.concat(label, ": tax bps of it"), spent == 0 ? 0 : tax * 10_000 / spent);
        }
    }

    /// @dev A buy at `e` seconds after the opening: the treasury gets exactly 30% x (60 min - e) / 30 min of it.
    function _taxedBuy(address who, uint256 imdIn, uint256 e, string memory label) internal {
        uint256 safeBefore = IERC20(yolo).balanceOf(OWNER);
        (bool ok, uint256 got,, uint256 g) = _urBuy(who, imdIn, false);
        assertTrue(ok, label);
        uint256 tax = IERC20(yolo).balanceOf(OWNER) - safeBefore;
        uint256 gross = got + tax;
        assertEq(tax, gross * 3_000 * (60 minutes - e) / (10_000 * 30 minutes), "exact tax");
        emit log_named_decimal_uint(string.concat(label, ": buyer got"), got, 18);
        emit log_named_decimal_uint(string.concat(label, ": treasury got (tax)"), tax, 18);
        emit log_named_uint(string.concat(label, ": router buy gas"), g);
    }

    function _tail(bytes memory b) internal pure returns (bytes memory out) {
        out = new bytes(b.length - 4);
        for (uint256 i; i < out.length; ++i) {
            out[i] = b[i + 4];
        }
    }

    /// @dev DevPrices is a dev-set parameter, not an oracle: a price always exists from deployment;
    ///      a YOLO task is created from the vesting's unlocked part; its doer bond (0.5 IMD fixed + 3% of R in
    ///      $YOLO) reads no price.
    function _yoloPriceAndTask(ITaskVault vault, DevPrices prices) internal {
        assertTrue(prices.hasPrice(yolo));
        uint256 usdPerMillion = prices.usdValue(yolo, 1_000_000e18);
        emit log_named_decimal_uint("USD per 1M YOLO (DevPrices)", usdPerMillion, 18);
        assertGt(usdPerMillion, 0);

        // through the live factory the splitter bound itself as the only clock starter (swarm audit 117cf05a #2)
        assertEq(ProjectVesting(genesis.dev).starter(), genesis.splitter, "the splitter starts the dev clock");
        assertEq(ProjectVesting(genesis.treasury).starter(), genesis.splitter, "the splitter starts the treasury clock");
        ProjectVesting(genesis.dev).release(yolo); // the dev stream so far, to the dev
        assertGt(IERC20(yolo).balanceOf(DEV), 0);
        uint256 r = 1_000_000e18; // ~$100 at the opening price
        vm.prank(STABILIZER); // the project's own YOLO for a task: here from the Stabilizer wallet
        IERC20(yolo).transfer(OWNER, r);
        address doer = makeAddr("yoloDoer");
        deal(LaunchPlan.IMD, doer, 100e18);
        // the doer bond's rew part is paid in R's own currency (here $YOLO, 3% of r = 30,000e18): fund and
        // approve it, same as the IMD fixed part below (a cap under this amount reverts CostAboveMax).
        deal(yolo, doer, r * 300 / 10_000);
        vm.deal(OWNER, 1 ether);
        vm.prank(OWNER);
        IERC20(yolo).approve(address(vault), r);
        vm.prank(doer);
        IERC20(LaunchPlan.IMD).approve(address(vault), type(uint256).max);
        vm.prank(doer);
        IERC20(yolo).approve(address(vault), type(uint256).max);
        ImdPay memory none;
        vm.prank(OWNER);
        uint256 taskId = vault.createTask(
            yolo, r, uint64(vm.getBlockTimestamp() + 7 days), "YOLO task", rulesOf("Post the doer code on X"), 0, 3, "", none
        );
        Evidence memory noEvidence;
        // maxBondRew caps the bond's `rew` part (CostAboveMax otherwise), which is doerBondBps percent of R in R's
        // own currency (Desk._doerBond) -- here 3% of 1,000,000 YOLO = 30,000 YOLO, not a USD figure.
        vm.prank(doer);
        uint256 subId = vault.submit(taskId, "https://github.com/proof", noEvidence, r, r, none);
        Submission memory sub = vault.getSubmission(subId);
        emit log_named_decimal_uint("1M YOLO task: R", r, 18);
        emit log_named_decimal_uint("1M YOLO task: doer bond.rew, in YOLO", sub.bond.rew, 18);
        // no oracle, no USD floor; the fixed part is a flat IMD parameter, the
        // percent part is 3% of R in R's own currency ($YOLO here).
        assertEq(sub.bond.imd, 0.5e18, "fixed part");
        assertEq(sub.bond.rew, r * 300 / 10_000, "3% of R, in $YOLO itself");
        // only the dev wallet cancels a task: the DevPrices owner is PROJECT_DEV, not the parameter owner
        assertEq(prices.owner(), LaunchPlan.PROJECT_DEV, "DevPrices owner = the dev wallet");
        address[2] memory notDev = [OWNER, doer];
        for (uint256 i; i < notDev.length; ++i) {
            vm.prank(notDev[i]);
            vm.expectRevert(NotAuthorized.selector);
            vault.cancelTask(taskId);
        }
        vm.prank(LaunchPlan.PROJECT_DEV);
        vault.cancelTask(taskId);
        assertEq(uint8(vault.getTask(taskId).status), uint8(TaskStatus.Unwound), "the dev wallet cancelled it");
    }

    // ------------------------------------------------------------------ the deployed vault works

    /// @dev An IMD task end to end on the launched contracts: create, submit, nobody disputes, accepted, paid.
    function _smoke(ITaskVault vault) internal {
        address author = makeAddr("author");
        address doer = makeAddr("doer");
        deal(LaunchPlan.IMD, author, 100e18);
        deal(LaunchPlan.IMD, doer, 100e18);
        vm.deal(author, 1 ether);
        vm.prank(author);
        IERC20(LaunchPlan.IMD).approve(address(vault), type(uint256).max);
        vm.prank(doer);
        IERC20(LaunchPlan.IMD).approve(address(vault), type(uint256).max);

        ImdPay memory none;
        TaskRules memory rules = rulesOf("Post the doer code on X");
        vm.prank(author);
        uint256 taskId = vault.createTask(
            LaunchPlan.IMD, 10e18, uint64(vm.getBlockTimestamp() + 7 days), "Smoke", rules, 0, 3, "", none
        );
        Evidence memory noEvidence;
        vm.prank(doer);
        uint256 subId = vault.submit(taskId, "https://github.com/proof", noEvidence, 10e18, 100e18, none);
        (bytes memory body,) = vault.previewSwarmBody(
            subId, 2, RuleTexts(rules.task, rules.proof, rules.noIf, "", "")
        );
        assertGt(body.length, 300, "the question builder reads the launched desks");
        vm.warp(vm.getBlockTimestamp() + 25 hours);
        vault.poke(taskId);
        assertEq(uint8(vault.getSubmission(subId).outcome), uint8(Outcome.Accepted));
        Bond memory bond = vault.getSubmission(subId).bond;
        assertEq(
            vault.credits(LaunchPlan.IMD, doer), 9e18 + bond.imd + bond.rew, "R - 10% fee + bond (reward currency is IMD)"
        );
        uint256 before = IERC20(LaunchPlan.IMD).balanceOf(doer);
        vm.prank(doer);
        vault.withdraw(LaunchPlan.IMD);
        assertEq(IERC20(LaunchPlan.IMD).balanceOf(doer) - before, 9e18 + bond.imd + bond.rew);
        assertEq(IERC20(LaunchPlan.IMD).balanceOf(address(vault)), vault.liabilities(LaunchPlan.IMD), "money invariant");
    }

    // ------------------------------------------------------------------ helpers

    function _name(bytes32 b) internal pure returns (string memory) {
        uint256 n;
        while (n < 32 && b[n] != 0) ++n;
        bytes memory out = new bytes(n);
        for (uint256 i; i < n; ++i) {
            out[i] = b[i];
        }
        return string(out);
    }

    /// @dev Single-sided token above the opening price (as the factory opens every pool): START_FDV_IMD for the whole
    ///      supply.
    function _seed(address token, int24 spacing, uint256 amount)
        internal
        pure
        returns (uint160 sqrtP, int24 lo, int24 hi, uint128 liq)
    {
        uint256 fdv = START_FDV_IMD;
        bool tokenIs0 = token < LaunchPlan.IMD;
        uint256 priceX192 = tokenIs0
            ? FullMath.mulDiv(fdv, 1 << 192, 1_000_000_000e18)
            : FullMath.mulDiv(1_000_000_000e18, 1 << 192, fdv);
        sqrtP = uint160(_sqrt(priceX192));
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtP);
        int24 maxT = TickMath.MAX_TICK / spacing * spacing;
        // the first multiple of the spacing beyond the opening tick, rounded like the live deployer (floor)
        int24 below = tick / spacing * spacing;
        if (below > tick) below -= spacing;
        if (tokenIs0) {
            lo = below + spacing;
            hi = maxT;
            uint256 a = TickMath.getSqrtPriceAtTick(lo);
            uint256 b = TickMath.getSqrtPriceAtTick(hi);
            liq = uint128(FullMath.mulDiv(amount, FullMath.mulDiv(a, b, 1 << 96), b - a));
        } else {
            hi = below;
            lo = -maxT;
            uint256 a = TickMath.getSqrtPriceAtTick(lo);
            uint256 b = TickMath.getSqrtPriceAtTick(hi);
            liq = uint128(FullMath.mulDiv(amount, 1 << 96, b - a));
        }
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x;
        uint256 z = (x >> 1) + 1;
        while (z < y) (y, z) = (z, (x / z + z) >> 1);
    }
}
