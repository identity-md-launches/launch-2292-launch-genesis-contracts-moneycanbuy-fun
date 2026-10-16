// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

import {LaunchPlan, IContractFactory} from "../../script/LaunchPlan.sol";
import {ITaskVault} from "../../src/interfaces/ITaskVault.sol";
import {ParamsRegistry} from "../../src/ParamsRegistry.sol";
import {ChainlinkUniV3PriceOracle} from "../../src/oracles/ChainlinkUniV3PriceOracle.sol";
import {ProjectVesting} from "../../src/token/ProjectVesting.sol";
import {YoloToken} from "../../src/token/YoloToken.sol";
import {NftGate} from "../../src/token/NftGate.sol";
import {YoloSplitter} from "../../src/token/YoloSplitter.sol";
import {YoloSweetener} from "../../src/YoloSweetener.sol";
import {ProtocolDirectory} from "../../src/ProtocolDirectory.sol";
import {DareTrophy} from "../../src/DareTrophy.sol";
import "../../src/VaultTypes.sol";

interface IAggregatorRound {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @dev The live factory's launch entry points and their parameter structs (Identity-md/protocol ProjectFactory.sol,
///      source verified on Sourcify for 0xfF03410d…7120). `Currency` is an address in the ABI.
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
}

/// @dev Put at the platform deployer's address: the launch call starts here, as the deployer's own transaction would,
///      and the gas is counted once (gasleft() around a pranked call from the test would count the
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

/// @dev Uniswap v4 periphery on mainnet: the Universal Router (V4_SWAP) and Permit2, as wallets and buy front-ends use
///      them; delegate.xyz v2 (writing a delegation) and the identity.md NFT.
interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IDelegateRegistryV2 {
    function delegateERC721(address to, address contract_, uint256 tokenId, bytes32 rights, bool enable)
        external
        payable
        returns (bytes32);
}

interface IERC721Min {
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/// @notice All four launches rehearsed through the REAL mainnet ProjectFactory (impersonating its deployer, the
///         plane's key), with the gas of each launch transaction measured against the EIP-7825 cap: execution measured
///         at the deployer's address (LaunchGasMeter) plus the intrinsic cost (21,000 + 16 per nonzero byte + 4 per
///         zero byte), at least the EIP-7623 calldata floor; every contract against the EIP-170 size limit. Then the
///         project's 75% is split, $YOLO's first hour is traded through the live Universal Router (the NFT gate with
///         real identity.md holders and a real delegate.xyz delegation, the buy tax at its edges), the oracle samples
///         its pool, and tasks in IMD and in YOLO go through the deployed vault. Read-only: nothing leaves the fork.
///         0. evm_contracts: NftGate, IncentivesVesting, DevVesting, TeamVesting, TreasuryVesting, YoloSplitter.
///         1. custom_token: $YOLO + its YOLO/IMD pool (15%) + the swarm's distributor (10%) + the seven support
///            contracts; the remainder (75%) goes to the YoloSplitter.
///         2. evm_contracts: the desks and the vault (YOLO is a static argument).
///         3. evm_contracts: YoloSweetener, DareTrophy and the ProtocolDirectory (version 1 = this vault).
///   FORK_URL=<archive mainnet RPC> forge test --match-contract LaunchRehearsal -vv
///   (or: forge test --match-contract LaunchRehearsal --fork-url <RPC> -vv)
contract LaunchRehearsalForkTest is Test {
    IProjectFactory constant FACTORY = IProjectFactory(0xfF03410d0Fe5fa8f7F59F743de35E333D9857120);
    IUniversalRouter constant UR = IUniversalRouter(0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af);
    IPermit2 constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IDelegateRegistryV2 constant DELEGATES = IDelegateRegistryV2(LaunchPlan.DELEGATE_XYZ);
    IERC721Min constant NFT = IERC721Min(LaunchPlan.NFT);
    uint256 constant TX_GAS_CAP = 16_777_216;
    uint256 constant EIP170 = 24_576;
    uint64 constant LAUNCH_GENESIS = 4_000_000_100;
    uint64 constant LAUNCH_SUPPORT = 4_000_000_101;
    uint64 constant LAUNCH_CORE = 4_000_000_102;
    uint64 constant LAUNCH_EXTRAS = 4_000_000_103;
    // the project's wallets, placeholders here: the project wallet <TREASURY> (the owner is a single project key,
    // EOA: owner of the registry and the directory, the buy tax, the treasury vesting; also the launch 1 payer, so the
    // pool's requester from the first block), the incentives wallet, the Stabilizer wallet, the dev and the future team
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
    uint8 constant SWEEP = 0x04;
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
    LaunchPlan.Genesis internal genesis;
    uint64 internal coreBlock; // the block of launch 2: version 1 of the directory starts there

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
        (address[] memory extra, uint256 gasExtras) = _launchExtras(core[2]);
        emit log_named_uint("launch 0 (evm_contracts: gate, vestings, splitter) total gas", gasGenesis);
        emit log_named_uint("launch 1 (custom_token: YOLO + support) total gas", gasSupport);
        emit log_named_uint("launch 2 (evm_contracts: core) total gas", gasCore);
        emit log_named_uint("launch 3 (evm_contracts: YoloSweetener + DareTrophy + ProtocolDirectory) total gas", gasExtras);
        assertLt(gasGenesis, TX_GAS_CAP, "launch 0 must fit one transaction");
        assertLt(gasSupport, TX_GAS_CAP, "launch 1 must fit one transaction");
        assertLt(gasCore, TX_GAS_CAP, "launch 2 must fit one transaction");
        assertLt(gasExtras, TX_GAS_CAP, "launch 3 must fit one transaction");
        assertEq(address(YoloSweetener(extra[0]).vault()), core[2], "sweetener reads this vault");
        assertEq(address(YoloSweetener(extra[0]).yolo()), yolo);
        assertEq(address(DareTrophy(extra[1]).vault()), core[2], "trophy reads this vault");
        assertEq(address(DareTrophy(extra[1]).caseDesk()), core[0]);
        assertEq(DareTrophy(extra[1]).price(), LaunchPlan.TROPHY_FALLBACK_YOLO, "no YOLO price yet: the fixed amount");
        ProtocolDirectory dir = ProtocolDirectory(extra[2]);
        ProtocolDirectory.Version memory v1 = dir.version(1);
        assertEq(dir.safe(), OWNER, "directory: the project wallet, as the registry");
        assertEq(dir.current(), 1);
        assertEq(dir.versionCount(), 1);
        assertEq(v1.vault, core[2], "version 1 = the vault of launch 2");
        assertEq(v1.sweetener, extra[0]);
        assertEq(v1.trophy, extra[1]);
        assertEq(v1.fromBlock, coreBlock);
        assertEq(v1.label, "v1");

        ITaskVault vault = ITaskVault(core[2]);
        assertEq(vault.caseDesk(), core[0]);
        assertEq(vault.disputeDesk(), core[1]);
        assertEq(vault.registry(), s.registry);
        assertEq(vault.yolo(), yolo);
        assertEq(ParamsRegistry(s.registry).owner(), OWNER);
        assertTrue(ParamsRegistry(s.registry).isAttester(LaunchPlan.ATTESTER));
        _checkSupplyAndSplit();
        _yoloFirstHour(); // first: the schedule runs in the first hour after the launch
        _smoke(vault);
        _yoloOracleAndTask(vault, ChainlinkUniV3PriceOracle(s.priceOracle));
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
        bytes memory tokenCode = LaunchPlan.yoloTokenCode(genesis.gate, OWNER);
        yolo = FACTORY.predictToken(LAUNCH_SUPPORT, tokenCode);
        bytes[] memory codes;
        bytes32[] memory names;
        (codes, names, s) =
            LaunchPlan.support(FACTORY, LAUNCH_SUPPORT, LaunchPlan.mainnet(OWNER, TREASURY), LaunchPlan.yoloPool(yolo));
        address[] memory expected = new address[](codes.length);
        (expected[0], expected[1], expected[2], expected[3], expected[4], expected[5], expected[6]) =
        (
            s.priceOracle,
            s.swapAdapter,
            s.registry,
            s.textRules,
            s.questionBuilder,
            s.ballotChecker,
            s.attestationChecker
        );
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
        p.merkleRoot = keccak256("swarm round");
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
    ///      out as the tokenomics has it. The factory keeps nothing.
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
        // the split starts the four clocks (A-03) and pays the at-once parts in the same transaction
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

    // ---- the Universal Router, as a wallet or the buy page drives it

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

    /// @dev The token's reason inside the PoolManager's WrappedError(target, selector, reason, details), as a wallet
    ///      or the buy page decodes it.
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

    function _next(uint256 secondsAfterStart) internal {
        vm.warp(YoloToken(yolo).start() + secondsAfterStart);
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// @dev $YOLO's first hour on the live pool, through the live Universal Router:
    ///      minutes 0-30 only registered identity.md NFTs (real holders, a real delegate.xyz delegation), the
    ///      allowance per NFT, routes through a router refused, the NFT bound for good; at minute 30 the gate ends
    ///      and the buy tax starts at 30%, falls to 0 at minute 60, goes to the treasury; the factory's fee claim
    ///      is exempt; after minute 60 a plain ERC-20.
    function _yoloFirstHour() internal {
        NftGate gate = NftGate(genesis.gate);
        YoloToken token = YoloToken(yolo);
        assertEq(token.start(), vm.getBlockTimestamp(), "the clock starts with the pool");
        address bot = makeAddr("bot");
        address holder = NFT.ownerOf(0);
        address cold = NFT.ownerOf(1999);
        address hot = makeAddr("hotWallet");
        require(holder != cold, "two different real holders");
        address[3] memory buyers = [bot, holder, hot];
        for (uint256 i; i < buyers.length; ++i) {
            deal(LaunchPlan.IMD, buyers[i], 1_000e18);
            _approveRouter(buyers[i], LaunchPlan.IMD);
        }
        _next(12);
        // the treasury's at-once third, paid by the split (A-03), sits with the tax recipient already
        uint256 ownerAtStart = IERC20(yolo).balanceOf(OWNER);

        // minute 0: not registered -> NotWhitelisted, decoded from the router's revert data
        (bool ok,, bytes memory ret,) = _urBuy(bot, 5e18, false);
        assertFalse(ok);
        assertEq(_innerReason(ret), abi.encodeWithSelector(YoloToken.NotWhitelisted.selector, bot));

        // a real holder registers NFT #0 and buys straight through TAKE_ALL, untaxed
        uint256[] memory ids = new uint256[](1);
        vm.prank(holder);
        uint256 g0 = gasleft();
        gate.register(ids);
        emit log_named_uint("register 1 NFT (owner) gas", g0 - gasleft());
        assertEq(gate.registeredCount(), 1);
        uint256 got;
        uint256 g;
        (ok, got,, g) = _urBuy(holder, 5e18, false);
        assertTrue(ok, "a registered holder buys through the Universal Router");
        emit log_named_decimal_uint("minute 0, NFT holder: YOLO for 5 IMD", got, 18);
        emit log_named_uint("  router buy gas (gate, first buy)", g);
        assertEq(IERC20(yolo).balanceOf(OWNER), ownerAtStart, "no tax in the whitelist window");
        // the same holder through a route that takes the output to the router: refused, the router holds no NFT
        (ok,, ret,) = _urBuy(holder, 1e18, true);
        assertFalse(ok);
        assertEq(_innerReason(ret), abi.encodeWithSelector(YoloToken.NotWhitelisted.selector, address(UR)));
        // above the 500,000 allowance of one NFT
        uint256 left = gate.left(yolo, holder);
        (ok,, ret,) = _urBuy(holder, 10e18, false);
        assertFalse(ok);
        bytes memory reason = _innerReason(ret);
        assertEq(bytes4(reason), YoloToken.NftAllowanceExceeded.selector);
        (, uint256 leftSaid,) = abi.decode(_tail(reason), (address, uint256, uint256));
        assertEq(leftSaid, left, "the error says what is left");

        // a cold wallet delegates its NFT #1999 to a hot wallet (delegate.xyz v2, this token only); the hot one registers
        vm.prank(cold);
        DELEGATES.delegateERC721(hot, address(NFT), 1999, bytes32(0), true);
        ids[0] = 1999;
        vm.prank(hot);
        g0 = gasleft();
        gate.register(ids);
        emit log_named_uint("register 1 NFT (delegate.xyz delegate) gas", g0 - gasleft());
        assertEq(gate.boundTo(1999), hot);
        (ok, got,,) = _urBuy(hot, 5e18, false);
        assertTrue(ok, "the delegate's wallet buys");

        // the NFT is bound for good: moved to someone else, it gives no second allowance
        vm.prank(holder);
        NFT.transferFrom(holder, bot, 0);
        ids[0] = 0;
        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(NftGate.AlreadyRegistered.selector, 0, holder));
        gate.register(ids);

        // the edge of minute 30
        _next(30 minutes - 1);
        (ok,,,) = _urBuy(bot, 5e18, false);
        assertFalse(ok, "29:59 still the whitelist");
        _next(30 minutes);
        _taxedBuy(bot, 50e18, 30 minutes, "minute 30");
        _next(45 minutes);
        _taxedBuy(bot, 50e18, 45 minutes, "minute 45");
        // a sell is never taxed: a trader who bought in the tax window sells half of it; then the factory's fee
        // claim in YOLO: exempt
        _approveRouter(bot, yolo);
        uint256 treasuryBefore = IERC20(yolo).balanceOf(OWNER);
        uint256 traderBefore = IERC20(yolo).balanceOf(bot);
        uint256 sold = traderBefore / 2;
        assertGt(sold, 0);
        _urSell(bot, sold);
        assertEq(IERC20(yolo).balanceOf(bot), traderBefore - sold, "a sell is never taxed");
        assertEq(IERC20(yolo).balanceOf(OWNER), treasuryBefore, "no tax on a sell");
        (uint256 f0, uint256 f1) = FACTORY.claimFees(LAUNCH_SUPPORT);
        emit log_named_uint("claimFees in the tax window, amount0", f0);
        emit log_named_uint("claimFees in the tax window, amount1", f1);
        uint256 yoloFee = LaunchPlan.IMD < yolo ? f1 : f0;
        assertGt(yoloFee, 0, "YOLO fees collected by the factory");
        // the requester (the treasury, launch 1's payer) gets its 80% from the factory, untaxed
        assertEq(IERC20(yolo).balanceOf(OWNER), treasuryBefore + yoloFee * 8_000 / 10_000, "the fee claim is untaxed");
        _next(60 minutes - 1);
        _taxedBuy(bot, 50e18, 60 minutes - 1, "minute 59:59");
        _next(60 minutes);
        uint256 treasuryNow = IERC20(yolo).balanceOf(OWNER);
        (ok, got,, g) = _urBuy(bot, 50e18, false);
        assertTrue(ok);
        assertEq(IERC20(yolo).balanceOf(OWNER), treasuryNow, "minute 60: no tax, a plain ERC-20");
        emit log_named_uint("  router buy gas after minute 60", g);
    }

    /// @dev A buy at `e` seconds after the opening: the treasury gets exactly 30% x (60 min - e) / 30 min of it.
    function _taxedBuy(address who, uint256 imdIn, uint256 e, string memory label) internal {
        uint256 treasuryBefore = IERC20(yolo).balanceOf(OWNER);
        (bool ok, uint256 got,, uint256 g) = _urBuy(who, imdIn, false);
        assertTrue(ok, label);
        uint256 tax = IERC20(yolo).balanceOf(OWNER) - treasuryBefore;
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

    /// @dev The oracle samples the YOLO/IMD pool; a YOLO task is created from the vesting's unlocked part and gets
    ///      an IMD Bond sized by that price.
    function _yoloOracleAndTask(ITaskVault vault, ChainlinkUniV3PriceOracle oracle) internal {
        assertFalse(oracle.hasPrice(yolo));
        for (uint256 i; i < oracle.MIN_SAMPLES(); ++i) {
            vm.prank(address(0x5EED), address(0x5EED)); // a keeper (anyone can run one), a plain EOA: a read ...
            assertFalse(oracle.sampleYoloPrice());
            vm.roll(vm.getBlockNumber() + 1);
            vm.prank(address(0x5EED), address(0x5EED)); // ... stored a block later (swarm audit #1)
            assertTrue(oracle.sampleYoloPrice());
            vm.warp(vm.getBlockTimestamp() + oracle.SAMPLE_SPACING());
            vm.roll(vm.getBlockNumber() + 75);
        }
        // the live Chainlink rounds are older than the warp now: read them as fresh
        _freshChainlink(LaunchPlan.CL_USDC_USD);
        _freshChainlink(LaunchPlan.CL_ETH_USD);
        assertTrue(oracle.hasPrice(yolo));
        uint256 usdPerMillion = oracle.usdValue(yolo, 1_000_000e18);
        emit log_named_decimal_uint("USD per 1M YOLO (highest sample x IMD TWAP)", usdPerMillion, 18);
        assertGt(usdPerMillion, 0);
        assertLe(usdPerMillion, 1_000_000 * LaunchPlan.YOLO_MAX_USD);

        // through the live factory the splitter bound itself as the only clock starter (swarm audit #2)
        assertEq(ProjectVesting(genesis.dev).starter(), genesis.splitter, "the splitter starts the dev clock");
        assertEq(ProjectVesting(genesis.treasury).starter(), genesis.splitter, "the splitter starts the treasury clock");
        ProjectVesting(genesis.dev).release(yolo); // the dev stream so far, to the dev
        assertGt(IERC20(yolo).balanceOf(DEV), 0);
        uint256 r = 10_000_000e18;
        // the project's own YOLO for a task: the incentives wallet creates it
        address doer = makeAddr("yoloDoer");
        deal(LaunchPlan.IMD, doer, 100e18);
        vm.deal(INCENTIVES, 1 ether);
        vm.prank(INCENTIVES);
        IERC20(yolo).approve(address(vault), r);
        vm.prank(doer);
        IERC20(LaunchPlan.IMD).approve(address(vault), type(uint256).max);
        ImdPay memory none;
        vm.prank(INCENTIVES);
        uint256 taskId = vault.createTask{value: 0.0005 ether}(
            yolo, r, 0, "YOLO task", "Post the doer code on X", 0, 3, "", 0.0005 ether, none
        );
        Evidence memory noEvidence;
        vm.prank(doer);
        uint256 subId = vault.submit(taskId, "https://example.com/proof", noEvidence, r, 100e18, none);
        Submission memory sub = vault.getSubmission(subId);
        emit log_named_decimal_uint("10M YOLO task: R in IMD", sub.rewardImd, 18);
        emit log_named_decimal_uint("10M YOLO task: doer Bond, IMD", sub.bond, 18);
        assertEq(sub.rewardImd, oracle.imdValue(yolo, r));
        assertGe(sub.bond, 1e18);
    }

    /// @dev Chainlink's last round with the current block time (fork only: the test warped past the heartbeat).
    function _freshChainlink(address feed) internal {
        (uint80 id, int256 answer, uint256 startedAt,, uint80 answeredIn) = IAggregatorRound(feed).latestRoundData();
        vm.mockCall(
            feed,
            abi.encodeWithSelector(IAggregatorRound.latestRoundData.selector),
            abi.encode(id, answer, startedAt, vm.getBlockTimestamp(), answeredIn)
        );
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
        vm.prank(author);
        uint256 taskId = vault.createTask{value: 0.0005 ether}(
            LaunchPlan.IMD, 10e18, 0, "Smoke", "Post the doer code on X", 0, 3, "", 0.0005 ether, none
        );
        Evidence memory noEvidence;
        vm.prank(doer);
        uint256 subId = vault.submit(taskId, "https://example.com/proof", noEvidence, 10e18, 100e18, none);
        (bytes memory body,) = vault.previewSwarmBody(subId, 1);
        assertGt(body.length, 300, "the question builder reads the launched desks");
        vm.warp(vm.getBlockTimestamp() + 25 hours);
        vault.poke(taskId);
        assertEq(uint8(vault.getSubmission(subId).outcome), uint8(Outcome.Accepted));
        assertEq(vault.credits(LaunchPlan.IMD, doer), 9e18 + vault.getSubmission(subId).bond, "R - 10% fee + bond");
        uint256 before = IERC20(LaunchPlan.IMD).balanceOf(doer);
        vm.prank(doer);
        vault.withdraw(LaunchPlan.IMD);
        assertEq(IERC20(LaunchPlan.IMD).balanceOf(doer) - before, 9e18 + vault.getSubmission(subId).bond);
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
