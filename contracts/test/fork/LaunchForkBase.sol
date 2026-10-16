// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

import {LaunchPlan, LocalFactory, IContractFactory} from "../../script/LaunchPlan.sol";
import {IProjectFactory} from "./LaunchRehearsal.fork.t.sol";
import {Base} from "../Base.t.sol";

import {TaskVault} from "../../src/TaskVault.sol";
import {YoloSweetener} from "../../src/YoloSweetener.sol";
import {ProtocolDirectory} from "../../src/ProtocolDirectory.sol";
import {DareTrophy} from "../../src/DareTrophy.sol";
import {ParamsRegistry} from "../../src/ParamsRegistry.sol";
import {CaseDesk} from "../../src/desks/CaseDesk.sol";
import {DisputeDesk} from "../../src/desks/DisputeDesk.sol";
import {TextRules} from "../../src/helpers/TextRules.sol";
import {SwarmQuestionBuilder} from "../../src/helpers/SwarmQuestion.sol";
import {AttestationChecker} from "../../src/helpers/AttestationChecker.sol";
import {BallotChecker, Ballot} from "../../src/libraries/VoteLib.sol";
import {UniswapV3SwapAdapter} from "../../src/adapters/UniswapV3SwapAdapter.sol";
import {ChainlinkUniV3PriceOracle} from "../../src/oracles/ChainlinkUniV3PriceOracle.sol";
import {YoloToken} from "../../src/token/YoloToken.sol";
import {ProjectVesting} from "../../src/token/ProjectVesting.sol";
import {NftGate} from "../../src/token/NftGate.sol";
import {YoloSplitter} from "../../src/token/YoloSplitter.sol";
import {IncentivesVesting, DevVesting, TeamVesting, TreasuryVesting} from "../../src/token/Vestings.sol";
import {IIntake} from "../../src/interfaces/IIntake.sol";
import "../../src/VaultTypes.sol";

/// @dev Launches 0 (gate, vestings, splitter) and 1 as the plan has them now: custom_token ($YOLO + pool + distributor + 7 support
///      contracts, remainder to the YoloSplitter of launch 0), economics as in test/fork/LaunchRehearsal.fork.t.sol. Shared by the fork
///      reviews; kept outside test/review/ so that a copy without it builds.
abstract contract ReviewLaunchForkBase is Test {
    IProjectFactory constant FACTORY = IProjectFactory(0xfF03410d0Fe5fa8f7F59F743de35E333D9857120);
    uint256 constant CAP = 16_777_216;
    uint64 constant N0 = 4_000_000_300;
    uint64 constant N1 = 4_000_000_301;
    uint64 constant N2 = 4_000_000_302;
    address constant TREASURY = address(0x7EA5);
    address constant OWNER = TREASURY; // the project wallet: a single project key (EOA)
    uint16 constant POOL_BPS = LaunchPlan.YOLO_POOL_BPS;
    uint256 constant START_FDV_IMD = LaunchPlan.YOLO_OPENING_MCAP_IMD; // 15,000 IMD for 1B, as in the plan

    LaunchPlan.Support internal s;
    LaunchPlan.Genesis internal g;
    address internal yolo;
    address internal deployer;

    function _owners() internal pure returns (LaunchPlan.Owners memory) {
        return LaunchPlan.Owners(TREASURY, address(0x1CE7), address(0x57AB), address(0xDE7), address(0x7EA0));
    }

    function setUp() public virtual {
        string memory url = vm.envOr("FORK_URL", string(""));
        if (address(FACTORY).code.length == 0 && bytes(url).length != 0) vm.createSelectFork(url);
        if (address(FACTORY).code.length == 0) vm.skip(true);
        deployer = FACTORY.deployer();
        assertEq(deployer.code.length, 0, "the platform deployer is an EOA: launches are direct transactions");
        (bytes[] memory codes0, bytes32[] memory names0, LaunchPlan.Genesis memory g0) =
            LaunchPlan.genesisLaunch(FACTORY, N0, _owners());
        address[] memory e0 = new address[](6);
        (e0[0], e0[1], e0[2], e0[3], e0[4], e0[5]) =
            (g0.gate, g0.incentives, g0.dev, g0.team, g0.treasury, g0.splitter);
        vm.prank(deployer);
        (bool ok0,) = address(FACTORY).call(_contractsData(N0, codes0, names0, e0));
        require(ok0, "launch 0 failed");
        g = g0;
        bytes memory data;
        (data, s, yolo) = _launch1Data(N1);
        vm.prank(deployer);
        (bool ok,) = address(FACTORY).call(data);
        require(ok, "launch 1 failed");
    }

    function _launch1Data(uint64 n)
        internal
        view
        returns (bytes memory data, LaunchPlan.Support memory sup, address token)
    {
        (,, LaunchPlan.Genesis memory g0) = LaunchPlan.genesisLaunch(FACTORY, N0, _owners());
        bytes memory tokenCode = LaunchPlan.yoloTokenCode(g0.gate, OWNER);
        token = FACTORY.predictToken(n, tokenCode);
        bytes[] memory codes;
        bytes32[] memory names;
        (codes, names, sup) =
            LaunchPlan.support(FACTORY, n, LaunchPlan.mainnet(OWNER, TREASURY), LaunchPlan.yoloPool(token));
        address[] memory e = new address[](7);
        (e[0], e[1], e[2], e[3], e[4], e[5], e[6]) =
        (
            sup.priceOracle,
            sup.swapAdapter,
            sup.registry,
            sup.textRules,
            sup.questionBuilder,
            sup.ballotChecker,
            sup.attestationChecker
        );
        IProjectFactory.CustomParams memory p;
        p.launchNumber = n;
        p.tokenCreationCode = tokenCode;
        p.tokenName = "YoloToken";
        p.contractCreationCodes = codes;
        p.contractNames = names;
        p.expectedContracts = e;
        p.totalSupply = LaunchPlan.YOLO_SUPPLY;
        p.poolBps = POOL_BPS;
        p.remainderTo = g0.splitter;
        p.merkleRoot = keccak256("swarm round");
        p.contributorLockSeconds = 1 hours;
        p.sweepDelaySeconds = 365 days;
        p.pairedCurrency = LaunchPlan.IMD;
        p.tickSpacing = LaunchPlan.POOL_TICK_SPACING;
        (p.sqrtPriceX96, p.tickLower, p.tickUpper, p.liquidity) =
            _seed(token, LaunchPlan.POOL_TICK_SPACING, LaunchPlan.YOLO_SUPPLY * POOL_BPS / 10_000 - 1e18);
        p.record.kind = "custom_token";
        p.record.launchNumber = n;
        p.record.sourceRepoUrl = "https://github.com/example/moneycanbuy";
        p.requester = OWNER;
        data = abi.encodeCall(IProjectFactory.launchCustom, (p));
    }

    function _contractsData(uint64 n, bytes[] memory codes, bytes32[] memory names, address[] memory exp)
        internal
        pure
        returns (bytes memory)
    {
        IProjectFactory.ContractsParams memory p;
        p.launchNumber = n;
        p.contractCreationCodes = codes;
        p.contractNames = names;
        p.expectedContracts = exp;
        p.record.kind = "evm_contracts";
        p.record.launchNumber = n;
        p.record.sourceRepoUrl = "https://github.com/example/moneycanbuy";
        return abi.encodeCall(IProjectFactory.launchContracts, (p));
    }

    function _coreData() internal view returns (bytes memory) {
        (bytes[] memory codes, bytes32[] memory names, address[] memory addrs) =
            LaunchPlan.core(FACTORY, N2, s, LaunchPlan.IMD, LaunchPlan.USDC, yolo);
        return _contractsData(N2, codes, names, addrs);
    }

    function _launchCore() internal returns (address[] memory addrs) {
        (,, addrs) = LaunchPlan.core(FACTORY, N2, s, LaunchPlan.IMD, LaunchPlan.USDC, yolo);
        bytes memory data = _coreData();
        vm.prank(deployer);
        (bool ok,) = address(FACTORY).call(data);
        require(ok, "launch 2 failed");
    }

    /// @dev Single-sided token above the opening price, as in the rehearsal: START_FDV_IMD for the whole supply.
    function _seed(address token, int24 spacing, uint256 amount)
        internal
        pure
        returns (uint160 sqrtP, int24 lo, int24 hi, uint128 liq)
    {
        bool tokenIs0 = token < LaunchPlan.IMD;
        uint256 priceX192 = tokenIs0
            ? FullMath.mulDiv(START_FDV_IMD, 1 << 192, LaunchPlan.YOLO_SUPPLY)
            : FullMath.mulDiv(LaunchPlan.YOLO_SUPPLY, 1 << 192, START_FDV_IMD);
        sqrtP = uint160(_sqrt(priceX192));
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtP);
        int24 maxT = TickMath.MAX_TICK / spacing * spacing;
        if (tokenIs0) {
            lo = (tick / spacing + 1) * spacing;
            hi = maxT;
            uint256 a = TickMath.getSqrtPriceAtTick(lo);
            uint256 b = TickMath.getSqrtPriceAtTick(hi);
            liq = uint128(FullMath.mulDiv(amount, FullMath.mulDiv(a, b, 1 << 96), b - a));
        } else {
            hi = (tick / spacing) * spacing;
            if (hi > tick) hi -= spacing;
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
