// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

import {LaunchPlan, LocalFactory, IContractFactory} from "../../script/LaunchPlan.sol";
import {IProjectFactory} from "../fork/LaunchRehearsal.fork.t.sol";
import {ReviewLaunchForkBase} from "../fork/LaunchForkBase.sol";
import {Base} from "../Base.t.sol";

import {TaskVault} from "../../src/TaskVault.sol";
import {YoloSweetener} from "../../src/YoloSweetener.sol";
import {ProtocolDirectory} from "../../src/ProtocolDirectory.sol";
import {HiddenList} from "../../src/HiddenList.sol";
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

/// @dev The launch: docs/LAUNCH-TASK.md and the fork rehearsal against the code. The static tests hold the doc to
///      the plan (they fail when the two drift apart). Non-fork part first; the fork part (ReviewLaunchFork) skips
///      without FORK_URL, like test/fork/*.
contract ReviewLaunchStatic is Test {
    uint256 constant EIP170 = 24_576;
    uint256 constant EIP3860 = 49_152;

    // the project's wallets as the doc writes them (LaunchPlan.projectOwners). The owner is a single project key
    // (EOA): the treasury wallet owns the registry and the directory and takes the tax
    address constant TREASURY = LaunchPlan.PROJECT_TREASURY;
    address constant OWNER = TREASURY;
    address constant INCENTIVES = LaunchPlan.PROJECT_INCENTIVES;
    address constant YOLO_PLACEHOLDER = address(0x7010);
    address constant STABILIZER = LaunchPlan.PROJECT_STABILIZER;
    address constant DEV = LaunchPlan.PROJECT_DEV;
    address constant TEAM = LaunchPlan.PROJECT_TEAM;

    // ---- docs/LAUNCH-TASK.md as written: the constructorArgs lists copied verbatim. Change one, change both.
    string constant DOC0_GATE =
        '["0x0000ec93127baa929e58e97dd0095a2bfb38ec1d", "0x00000000000000447e69651d841bd8d104bed493"]';
    string constant DOC0_INCENTIVES = '["<INCENTIVES_WALLET>"]';
    string constant DOC0_DEV = '["<DEV_WALLET>"]';
    string constant DOC0_TEAM = '["<TEAM_WALLET>"]';
    string constant DOC0_TREASURY = '["<TREASURY_WALLET>"]';
    string constant DOC0_SPLITTER =
        '["$contract:IncentivesVesting", "$contract:DevVesting", "$contract:TeamVesting", "$contract:TreasuryVesting", "<STABILIZER_WALLET>"]';
    string constant DOC1_TOKEN = '["$poolManager", "<NFT_GATE>", "<TREASURY_WALLET>"]';
    string constant DOC1_POOL_BPS = "1500";
    string constant DOC1_TOTAL_SUPPLY = "1000000000000000000000000000";
    string constant DOC1_INITIAL_MCAP_WEI = "15000000000000000000000";
    string constant DOC1_ORACLE =
        '["0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7", "0x5f4ec3df9cbd43714fe2740f5e3616155c5b8419", "0x8fffffd4afb6115b954bd326cbe7b4ba576818f6", "0x894d4e6d3d2abc64fc0de0e4e2ea63a93bc9c520", "1800", "7200", "172800", "$token", "0x000000000004444c5dc75cb358380d2e3de08a90", "0x784ff9a3ac5d88a30bfff6f7f2a270161fbe6000", "12500", "60", "10000000000000000", "15000000000000"]';
    string constant DOC1_ADAPTER =
        '["0x68b3465833fb72a70ecdf485e0e4c7bd8665fc45", "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2"]';
    string constant DOC1_REGISTRY =
        '["<TREASURY_WALLET>", "0xa43e6f75ee006411f79ac1c84120606c2330de82", "$contract:ChainlinkUniV3PriceOracle", "$contract:UniswapV3SwapAdapter", "0x0000ec93127baa929e58e97dd0095a2bfb38ec1d", "0x00000000000000447e69651d841bd8d104bed493", "<TREASURY_WALLET>", "0x5598aa9146215bc13eb26f2c692ad1461fd32982"]';
    string constant DOC1_ATTESTATION = '["$contract:ParamsRegistry"]';
    string constant DOC2_CASE =
        '["<PARAMS_REGISTRY>", "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7", "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", "<TEXT_RULES>", "<SWARM_QUESTION_BUILDER>"]';
    string constant DOC2_DISPUTE =
        '["<PARAMS_REGISTRY>", "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7", "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", "<TEXT_RULES>", "<BALLOT_CHECKER>"]';
    string constant DOC2_VAULT =
        '["<PARAMS_REGISTRY>", "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7", "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", "<YOLO>", "<ATTESTATION_CHECKER>", "<TEXT_RULES>", "$contract:CaseDesk", "$contract:DisputeDesk"]';
    string constant DOC3_SWEETENER = '["<TASK_VAULT>"]';
    string constant DOC3_TROPHY = '["<TASK_VAULT>", "1500000000000000000", "10000000000000000000000"]';
    string constant DOC3_DIRECTORY =
        '["<TREASURY_WALLET>", "<TASK_VAULT>", "$contract:YoloSweetener", "$contract:DareTrophy", "<CORE_BLOCK>"]';
    string constant DOC3_HIDDENLIST =
        '["<TREASURY_WALLET>", "0x0000ec93127baa929e58e97dd0095a2bfb38ec1d", "0x00000000000000447e69651d841bd8d104bed493"]';
    // the per-contract room the doc states (EIP-170 margin, bytes)
    // after the swarm audit fixes: DisputeDesk 2_179 -> 1_896, TaskVault 4_732 -> 3_992, CaseDesk 4_087 -> 4_009,
    // YoloSweetener 17_694 -> 17_226, ParamsRegistry 8_645 -> 8_435
    uint256 constant DOC_MARGIN_DISPUTE = 1_896; // 2_050 before the C-02 (no instant decision) and C-01 (doer) fixes
    uint256 constant DOC_MARGIN_VAULT = 3_853; // 3_992 before audit round 2 (announceWithdraw gained checks)
    uint256 constant DOC_MARGIN_CASE = 4_009; // 3_691 before the C-02 fix (CaseDesk.decide removed)
    uint256 constant DOC_MARGIN_SWEETENER = 16_992; // 17_226 before audit round 2 (announceWithdraw gained checks)
    uint256 constant DOC_MARGIN_TROPHY = 12_163;
    uint256 constant DOC_MARGIN_DIRECTORY = 20_030;
    uint256 constant DOC_MARGIN_HIDDENLIST = 20_815; // 21_451 before audit round 2; the site's hide list, launch 3's fourth contract
    uint256 constant DOC_MARGIN_SUPPORT_MIN = 8_435; // ParamsRegistry

    /// @dev placeholder / factory reference of the doc -> the address the plan gives it
    mapping(string => address) internal resolved;

    function _owners() internal pure returns (LaunchPlan.Owners memory) {
        return LaunchPlan.projectOwners();
    }

    /// @dev the doc writes the project's wallets as placeholders; they resolve to LaunchPlan.projectOwners()
    function _resolveOwners() internal {
        resolved["<TREASURY_WALLET>"] = TREASURY;
        resolved["<INCENTIVES_WALLET>"] = INCENTIVES;
        resolved["<STABILIZER_WALLET>"] = STABILIZER;
        resolved["<DEV_WALLET>"] = DEV;
        resolved["<TEAM_WALLET>"] = TEAM;
    }

    function _plan1(LocalFactory f)
        internal
        view
        returns (bytes[] memory codes, bytes32[] memory names, LaunchPlan.Support memory s, LaunchPlan.Genesis memory g)
    {
        // launch 0 holds the gate and the splitter (remainderTo must be a fixed address), launch 1 has 7 contracts
        (,, g) = LaunchPlan.genesisLaunch(f, 0, _owners());
        (codes, names, s) =
            LaunchPlan.support(f, 1, LaunchPlan.mainnet(OWNER, TREASURY), LaunchPlan.yoloPool(YOLO_PLACEHOLDER));
    }

    /// @dev The ABI encoding of a doc constructorArgs list: hex addresses, decimal integers (all the doc's integers
    ///      are non-negative, so int24/uint24/uint32 encode as uint256), placeholders and $references via `resolved`.
    function _docArgs(string memory json) internal view returns (bytes memory out) {
        string[] memory a = vm.parseJsonStringArray(json, "$");
        for (uint256 i; i < a.length; ++i) {
            bytes memory b = bytes(a[i]);
            uint256 w;
            if (b[0] == "<" || b[0] == "$") {
                address r = resolved[a[i]];
                require(r != address(0), string.concat("unresolved doc placeholder ", a[i]));
                w = uint160(r);
            } else if (b.length == 42 && b[0] == "0" && b[1] == "x") {
                w = uint160(vm.parseAddress(a[i]));
            } else {
                w = vm.parseUint(a[i]);
            }
            out = abi.encodePacked(out, w);
        }
    }

    function _docCode(bytes memory creationCode, string memory json) internal view returns (bytes memory) {
        return abi.encodePacked(creationCode, _docArgs(json));
    }

    /// Runtime / initcode of every launched contract against EIP-170 / EIP-3860, and the per-contract room the doc
    /// states: the swarm's edits hit the 24,576-byte limit long before the gas cap.
    function test_L1_perContractCodeMargin_matchesDoc() public {
        LocalFactory f = new LocalFactory();
        (bytes[] memory codes0, bytes32[] memory names0, LaunchPlan.Genesis memory g) =
            LaunchPlan.genesisLaunch(f, 0, _owners());
        address[] memory deployed0 = f.launchContracts(0, codes0);
        (bytes[] memory codes1, bytes32[] memory names1, LaunchPlan.Support memory s,) = _plan1(f);
        f.launchContracts(1, codes1);
        address[13] memory a = [
            s.priceOracle,
            s.swapAdapter,
            s.registry,
            s.textRules,
            s.questionBuilder,
            s.ballotChecker,
            s.attestationChecker,
            deployed0[0],
            deployed0[1],
            deployed0[2],
            deployed0[3],
            deployed0[4],
            deployed0[5]
        ];
        assertEq(deployed0[5], g.splitter);
        uint256 supportMin = type(uint256).max;
        for (uint256 i; i < 13; ++i) {
            string memory name = i < 7
                ? string(abi.encodePacked(names1[i]))
                : string.concat(string(abi.encodePacked(names0[i - 7])), " (launch 0)");
            console.log(name, a[i].code.length, "runtime, margin", EIP170 - a[i].code.length);
            assertLt(i < 7 ? codes1[i].length : codes0[i - 7].length, EIP3860, "initcode limit");
            if (EIP170 - a[i].code.length < supportMin) supportMin = EIP170 - a[i].code.length;
        }
        bytes memory tokenCode = LaunchPlan.yoloTokenCode(g.gate, OWNER);
        address token;
        assembly ("memory-safe") {
            token := create(0, add(tokenCode, 32), mload(tokenCode))
        }
        console.log("YoloToken", token.code.length, "runtime, margin", EIP170 - token.code.length);
        if (EIP170 - token.code.length < supportMin) supportMin = EIP170 - token.code.length;
        assertEq(supportMin, DOC_MARGIN_SUPPORT_MIN, "doc: launches 0 and 1 have >= 8,435 bytes (ParamsRegistry)");
        (bytes[] memory codes2, bytes32[] memory names2, address[] memory core) =
            LaunchPlan.core(f, 2, s, LaunchPlan.IMD, LaunchPlan.USDC, token);
        f.launchContracts(2, codes2);
        for (uint256 i; i < 3; ++i) {
            console.log(
                string(abi.encodePacked(names2[i])),
                core[i].code.length,
                "runtime, margin",
                EIP170 - core[i].code.length
            );
            assertLt(codes2[i].length, EIP3860, "initcode limit");
        }
        assertEq(EIP170 - core[0].code.length, DOC_MARGIN_CASE, "doc: CaseDesk margin");
        assertEq(EIP170 - core[1].code.length, DOC_MARGIN_DISPUTE, "doc: DisputeDesk margin");
        assertEq(EIP170 - core[2].code.length, DOC_MARGIN_VAULT, "doc: TaskVault margin");
        (bytes[] memory codes3, bytes32[] memory names3, address[] memory extra) = LaunchPlan.extras(f, 3, core[2], OWNER, 1);
        f.launchContracts(3, codes3);
        for (uint256 i; i < 4; ++i) {
            console.log(string(abi.encodePacked(names3[i])), extra[i].code.length, "runtime, margin", EIP170 - extra[i].code.length);
            assertLt(codes3[i].length, EIP3860, "initcode limit");
        }
        assertEq(EIP170 - extra[0].code.length, DOC_MARGIN_SWEETENER, "doc: YoloSweetener margin");
        assertEq(EIP170 - extra[1].code.length, DOC_MARGIN_TROPHY, "doc: DareTrophy margin");
        assertEq(EIP170 - extra[2].code.length, DOC_MARGIN_DIRECTORY, "doc: ProtocolDirectory margin");
        assertEq(EIP170 - extra[3].code.length, DOC_MARGIN_HIDDENLIST, "doc: HiddenList margin");
    }

    /// Launch 0 of the doc (NftGate, four vestings, YoloSplitter) = LaunchPlan.genesisLaunch, byte for
    /// byte.
    function test_L0_docLaunch0Args_matchPlan() public {
        _resolveOwners();
        LocalFactory f = new LocalFactory();
        (bytes[] memory plan, bytes32[] memory names, LaunchPlan.Genesis memory g) =
            LaunchPlan.genesisLaunch(f, 0, _owners());
        assertEq(plan.length, 6, "doc: 6 contracts");
        string[6] memory docNames =
            ["NftGate", "IncentivesVesting", "DevVesting", "TeamVesting", "TreasuryVesting", "YoloSplitter"];
        for (uint256 i; i < 6; ++i) {
            assertEq(names[i], bytes32(bytes(docNames[i])), "doc order and names");
        }
        resolved["$contract:IncentivesVesting"] = g.incentives;
        resolved["$contract:DevVesting"] = g.dev;
        resolved["$contract:TeamVesting"] = g.team;
        resolved["$contract:TreasuryVesting"] = g.treasury;
        assertEq(_docCode(type(NftGate).creationCode, DOC0_GATE), plan[0], "NftGate");
        assertEq(_docCode(type(IncentivesVesting).creationCode, DOC0_INCENTIVES), plan[1], "IncentivesVesting");
        assertEq(_docCode(type(DevVesting).creationCode, DOC0_DEV), plan[2], "DevVesting");
        assertEq(_docCode(type(TeamVesting).creationCode, DOC0_TEAM), plan[3], "TeamVesting");
        assertEq(_docCode(type(TreasuryVesting).creationCode, DOC0_TREASURY), plan[4], "TreasuryVesting");
        assertEq(_docCode(type(YoloSplitter).creationCode, DOC0_SPLITTER), plan[5], "YoloSplitter");
    }

    /// Launch 1 of the doc (token, economics, 7 contracts) = LaunchPlan.yoloTokenCode / support, byte for byte, with
    /// $token, $contract:X and the owner's placeholders resolved to the plan's addresses.
    function test_L2_docLaunch1Args_matchPlan() public {
        _resolveOwners();
        LocalFactory f = new LocalFactory();
        (bytes[] memory plan, bytes32[] memory names, LaunchPlan.Support memory s, LaunchPlan.Genesis memory g) =
            _plan1(f);
        assertEq(plan.length, 7, "doc: 7 contracts");
        resolved["$poolManager"] = LaunchPlan.POOL_MANAGER;
        resolved["<NFT_GATE>"] = g.gate;
        assertEq(
            _docCode(type(YoloToken).creationCode, DOC1_TOKEN), LaunchPlan.yoloTokenCode(g.gate, OWNER), "YoloToken"
        );
        assertEq(vm.parseUint(DOC1_POOL_BPS), LaunchPlan.YOLO_POOL_BPS, "poolBps");
        assertEq(vm.parseUint(DOC1_TOTAL_SUPPLY), LaunchPlan.YOLO_SUPPLY, "totalSupply");
        assertEq(vm.parseUint(DOC1_INITIAL_MCAP_WEI), LaunchPlan.YOLO_OPENING_MCAP_IMD, "initialMarketCapWei");

        resolved["$token"] = YOLO_PLACEHOLDER;
        resolved["$contract:ChainlinkUniV3PriceOracle"] = s.priceOracle;
        resolved["$contract:UniswapV3SwapAdapter"] = s.swapAdapter;
        resolved["$contract:ParamsRegistry"] = s.registry;
        string[7] memory docNames = [
            "ChainlinkUniV3PriceOracle",
            "UniswapV3SwapAdapter",
            "ParamsRegistry",
            "TextRules",
            "SwarmQuestionBuilder",
            "BallotChecker",
            "AttestationChecker"
        ];
        for (uint256 i; i < 7; ++i) {
            assertEq(names[i], bytes32(bytes(docNames[i])), "doc order and names");
        }
        assertEq(_docCode(type(ChainlinkUniV3PriceOracle).creationCode, DOC1_ORACLE), plan[0], "oracle (15 args)");
        assertEq(_docCode(type(UniswapV3SwapAdapter).creationCode, DOC1_ADAPTER), plan[1], "adapter");
        assertEq(_docCode(type(ParamsRegistry).creationCode, DOC1_REGISTRY), plan[2], "registry");
        assertEq(type(TextRules).creationCode, plan[3], "TextRules");
        assertEq(type(SwarmQuestionBuilder).creationCode, plan[4], "SwarmQuestionBuilder");
        assertEq(type(BallotChecker).creationCode, plan[5], "BallotChecker");
        assertEq(_docCode(type(AttestationChecker).creationCode, DOC1_ATTESTATION), plan[6], "AttestationChecker");
    }

    /// Launch 2 of the doc (CaseDesk, DisputeDesk, TaskVault with `yolo` 4th) = LaunchPlan.core, byte for byte.
    function test_L3_docLaunch2Args_matchPlan() public {
        _resolveOwners();
        LocalFactory f = new LocalFactory();
        (,, LaunchPlan.Support memory s,) = _plan1(f);
        (bytes[] memory plan, bytes32[] memory names, address[] memory addrs) =
            LaunchPlan.core(f, 2, s, LaunchPlan.IMD, LaunchPlan.USDC, YOLO_PLACEHOLDER);
        assertEq(names[0], bytes32("CaseDesk"));
        assertEq(names[1], bytes32("DisputeDesk"));
        assertEq(names[2], bytes32("TaskVault"));
        assertEq(names.length, 3);
        resolved["<PARAMS_REGISTRY>"] = s.registry;
        resolved["<TEXT_RULES>"] = s.textRules;
        resolved["<SWARM_QUESTION_BUILDER>"] = s.questionBuilder;
        resolved["<BALLOT_CHECKER>"] = s.ballotChecker;
        resolved["<ATTESTATION_CHECKER>"] = s.attestationChecker;
        resolved["<YOLO>"] = YOLO_PLACEHOLDER;
        resolved["$contract:CaseDesk"] = addrs[0];
        resolved["$contract:DisputeDesk"] = addrs[1];
        assertEq(_docCode(type(CaseDesk).creationCode, DOC2_CASE), plan[0], "CaseDesk");
        assertEq(_docCode(type(DisputeDesk).creationCode, DOC2_DISPUTE), plan[1], "DisputeDesk");
        assertEq(_docCode(type(TaskVault).creationCode, DOC2_VAULT), plan[2], "TaskVault (8 args, yolo 4th)");
    }

    /// Launch 3 of the doc (YoloSweetener, DareTrophy: the vault of launch 2 their one address; ProtocolDirectory:
    /// version 1 = that vault and these modules) = LaunchPlan.extras.
    function test_L5_docLaunch3Args_matchPlan() public {
        _resolveOwners();
        address vault = address(0xBEEF);
        uint64 coreBlock = 24_000_000;
        (bytes[] memory plan, bytes32[] memory names, address[] memory addrs) =
            LaunchPlan.extras(new LocalFactory(), 3, vault, OWNER, coreBlock);
        assertEq(names.length, 4);
        assertEq(names[0], bytes32("YoloSweetener"));
        assertEq(names[1], bytes32("DareTrophy"));
        assertEq(names[2], bytes32("ProtocolDirectory"));
        assertEq(names[3], bytes32("HiddenList"));
        resolved["<TASK_VAULT>"] = vault;
        resolved["<CORE_BLOCK>"] = address(uint160(coreBlock)); // a number placeholder: _docArgs writes it as a word
        resolved["$contract:YoloSweetener"] = addrs[0];
        resolved["$contract:DareTrophy"] = addrs[1];
        assertEq(_docCode(type(YoloSweetener).creationCode, DOC3_SWEETENER), plan[0], "YoloSweetener");
        assertEq(_docCode(type(DareTrophy).creationCode, DOC3_TROPHY), plan[1], "DareTrophy (vault, $1.50, 10,000 YOLO)");
        assertEq(
            _docCode(type(ProtocolDirectory).creationCode, DOC3_DIRECTORY),
            plan[2],
            "ProtocolDirectory (owner, vault, modules, block of launch 2)"
        );
        assertEq(
            _docCode(type(HiddenList).creationCode, DOC3_HIDDENLIST), plan[3], "HiddenList (owner, nft, delegateRegistry)"
        );
    }
}

/// @dev Runtime claims that need the full system (mocks).
contract ReviewLaunchRuntime is Base {
    uint8 constant REJECT = 2;

    /// The IMD the relayer is paid from the loser penalty (DisputeDesk._reimburseRelayer, `shortImd = shortWei *
    /// imdPerEth / 1e18`, imdPerEth = oracle at submission) is the one oracle-priced payout; docs/LAUNCH-TASK.md says
    /// so in both launch texts. Same case, ETH price doubled at the oracle -> the relayer's IMD claim doubles.
    /// Since the swarm audit (#3) the claim is at most 20% of the penalty: the recorded IMD scales with the
    /// price, the payout is that up to the cap.
    function test_L4_oraclePriceSetsRelayerPayout() public {
        uint256 a = _shortfallAt(1250e18);
        uint256 b = _shortfallAt(2500e18);
        console.log("relayer IMD recorded at ETH $1250:", a);
        console.log("relayer IMD recorded at ETH $2500:", b);
        assertGt(a, 0);
        assertApproxEqRel(b, 2 * a, 0.0001e18, "the shortfall scales with the oracle price");
    }

    function _shortfallAt(uint256 ethUsd) internal returns (uint256 recorded) {
        uint256 snap = vm.snapshotState();
        oracle.set(ETH, ethUsd, 18);
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        vm.fee(10 gwei);
        _vote(s, 1, REJECT, 120, 20);
        recorded = vault.relayerShortfall(s, relayer);
        _warp(48 hours);
        vault.poke(t);
        uint256 before = imd.balanceOf(relayer);
        vm.prank(relayer);
        vault.claimRelayerShortfall(s);
        uint256 cap = 1e18 * disputeDesk.MAX_SHORTFALL_BPS() / 10_000; // of the 1 IMD loser penalty
        assertEq(imd.balanceOf(relayer) - before, recorded < cap ? recorded : cap, "paid up to 20% of the penalty");
        vm.revertToState(snap);
    }

    /// submitVotes is bounded only by the batch the relayer builds; a single ballot cannot be split by the relayer
    /// (the signature covers the tokenIds list). Gas per NFT here (mock NFT, so a lower bound for the real one) and
    /// the largest ballot that fits the 16,777,216 cap.
    function test_L5_submitVotes_gasPerNft() public {
        uint256 n = 1_000;
        uint256 key = 0xC0FFEE;
        address v = vm.addr(key);
        for (uint256 i; i < n; ++i) {
            nft.mint(v, 10_000 + i);
        }
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        Ballot[] memory small = new Ballot[](1);
        small[0] = _ballotByKey(s, key, REJECT, _ids(10_000, 10), v, _sub(s).voteEnd);
        Ballot[] memory big = new Ballot[](1);
        big[0] = _ballotByKey(s, key, REJECT, _ids(10_010, n - 10), v, _sub(s).voteEnd);
        vm.prank(relayer);
        uint256 g0 = gasleft();
        vault.submitVotes(s, small);
        uint256 gSmall = g0 - gasleft();
        vm.prank(relayer);
        g0 = gasleft();
        vault.submitVotes(s, big);
        uint256 gBig = g0 - gasleft();
        uint256 perNft = gBig / (n - 10);
        console.log("submitVotes 10 NFTs:", gSmall);
        console.log("submitVotes 990 NFTs:", gBig);
        console.log("gas per NFT (mock NFT):", perNft);
        console.log("max NFTs in one ballot under the cap (mock):", 16_777_216 / perNft);
        assertLt(gBig, 16_777_216);
    }
}

/// @dev Stands in for the deployer EOA (vm.etch at its address, so msg.sender at the factory is unchanged) and meters
///      the factory call from inside the EVM: the calldata is copied to memory before the first gasleft(), so the
///      figure is the factory frame's execution + the CALL. Foundry's gasleft() around a `vm.prank`ed top-level call
///      from the test (the rehearsal's method) already counts the calldata, which the rehearsal then adds once more.
///      Cross-check (scratch replays of real platform launches at their own blocks; receipt / this method /
///      rehearsal method): 0x218f2113… 14,955,519 / 15,003,607 / 16,182,791; 0x9c319bb2… 9,293,049 /
///      9,364,732 / 9,891,076; 0x3506bb74… 4,280,634 / 4,345,612 / 4,529,235.
contract DeployerMeter {
    function run(address target, bytes calldata data, uint256 gasLimit) external returns (bool ok, uint256 used) {
        bytes memory d = data;
        uint256 g = gasleft();
        assembly ("memory-safe") {
            ok := call(gasLimit, target, 0, add(d, 32), mload(d), 0, 0)
        }
        used = g - gasleft();
    }
}

/// @dev Gas of both launches as the chain charges it (DeployerMeter), against the cap and the figure the
///      rehearsal's method gives (it counts the calldata twice). Skips without FORK_URL.
contract ReviewLaunchFork is ReviewLaunchForkBase {
    function setUp() public override {
        super.setUp();
        vm.etch(deployer, type(DeployerMeter).runtimeCode);
    }

    function _intrinsic(bytes memory data) internal pure returns (uint256 g) {
        g = 21_000;
        for (uint256 i; i < data.length; ++i) {
            g += data[i] == 0 ? 4 : 16;
        }
    }

    function _floor(bytes memory data) internal pure returns (uint256 g) {
        g = 21_000;
        for (uint256 i; i < data.length; ++i) {
            g += data[i] == 0 ? 10 : 40;
        }
    }

    /// @dev Total transaction gas of the factory call `data` as the chain charges it (state kept if `keep`).
    function _total(bytes memory data, uint256 gasLimit, bool keep) internal returns (bool ok, uint256 total) {
        uint256 snap = vm.snapshotState();
        uint256 used;
        (ok, used) = DeployerMeter(deployer).run(address(FACTORY), data, gasLimit);
        total = used + _intrinsic(data);
        uint256 floor = _floor(data);
        if (floor > total) total = floor;
        if (!keep) vm.revertToState(snap);
    }

    /// @dev The rehearsal's method on the same call: gasleft() around a vm.prank'ed call, + _intrinsic again.
    function _rehearsalMethod(bytes memory data) internal returns (uint256 total) {
        uint256 snap = vm.snapshotState();
        bytes memory meter = deployer.code;
        vm.etch(deployer, "");
        vm.prank(deployer);
        uint256 g = gasleft();
        (bool ok,) = address(FACTORY).call(data);
        uint256 used = g - gasleft();
        require(ok, "rehearsal-method call failed");
        total = used + _intrinsic(data);
        vm.revertToState(snap);
        vm.etch(deployer, meter);
    }

    function _smallestLimit(bytes memory data) internal returns (uint256) {
        uint256 intrinsic = _intrinsic(data);
        uint256 lo = 5_000_000;
        uint256 hi = CAP - intrinsic;
        (bool okCap,) = _total(data, hi, false);
        assertTrue(okCap, "fits a transaction with gasLimit = cap");
        while (hi - lo > 1_000) {
            uint256 mid = (lo + hi) / 2;
            (bool okMid,) = _total(data, mid, false);
            if (okMid) hi = mid;
            else lo = mid;
        }
        return hi + intrinsic;
    }

    /// Launch 2 (evm_contracts, TaskVault with $YOLO): chain gas, smallest gas limit, rehearsal figure.
    function test_F1_core_realGas_vs_rehearsal() public {
        bytes memory data = _coreData();
        (bool ok, uint256 total) = _total(data, 30_000_000, false);
        assertTrue(ok);
        uint256 rehearsal = _rehearsalMethod(data);
        uint256 limit = _smallestLimit(data);
        console.log("launch 2 total gas (chain)       ", total);
        console.log("launch 2 smallest gas limit      ", limit);
        console.log("margin to the cap                ", CAP - limit);
        console.log("rehearsal method                  ", rehearsal);
        console.log("intrinsic (21000 + calldata)      ", _intrinsic(data));
        // 14.64M before the B-01, C-01 and C-02 fixes
        // 14.32M before the swarm audit fixes
        assertApproxEqRel(total, 14_560_000, 0.005e18, "docs/LAUNCH-TASK.md: launch 2 14.56M");
        assertApproxEqRel(rehearsal - total, _intrinsic(data), 0.005e18, "rehearsal counts the intrinsic gas twice");
    }

    /// Launch 1 (custom_token: $YOLO + pool + distributor + 7 support; the splitter is launch 0) the same way, at a fresh
    /// launch number.
    function test_F1b_support_realGas_vs_rehearsal() public {
        (bytes memory data,,) = _launch1Data(4_000_000_303);
        (bool ok, uint256 total) = _total(data, 40_000_000, false);
        assertTrue(ok);
        uint256 rehearsal = _rehearsalMethod(data);
        uint256 limit = _smallestLimit(data);
        console.log("launch 1 total gas (chain)       ", total);
        console.log("launch 1 smallest gas limit      ", limit);
        console.log("margin to the cap                ", CAP - limit);
        console.log("rehearsal method                  ", rehearsal);
        // 12.72M before the swarm audit fixes
        assertApproxEqRel(total, 12_980_000, 0.005e18, "docs/LAUNCH-TASK.md: launch 1 12.98M");
        assertApproxEqRel(rehearsal - total, _intrinsic(data), 0.005e18, "rehearsal counts the intrinsic gas twice");
    }

    /// Launch 0 (evm_contracts: NftGate, four vestings, YoloSplitter) the same way, at a fresh number.
    function test_F1d_genesis_realGas() public {
        uint64 n = 4_000_000_304;
        (bytes[] memory codes, bytes32[] memory names, LaunchPlan.Genesis memory g0) =
            LaunchPlan.genesisLaunch(FACTORY, n, _owners());
        address[] memory e = new address[](6);
        (e[0], e[1], e[2], e[3], e[4], e[5]) = (g0.gate, g0.incentives, g0.dev, g0.team, g0.treasury, g0.splitter);
        bytes memory data = _contractsData(n, codes, names, e);
        (bool ok, uint256 total) = _total(data, 30_000_000, false);
        assertTrue(ok);
        console.log("launch 0 total gas (chain)       ", total);
        // 2.90M before the vesting clocks (ProjectVesting `startOf`, YoloSplitter starts them: A-03)
        // 3.14M before the swarm audit fixes (only the YoloSplitter starts a clock: bindStarter)
        assertApproxEqRel(total, 3_520_000, 0.005e18, "docs/LAUNCH-TASK.md: launch 0 3.52M");
    }

    /// Mainnet runs Osaka rules; the repo's evm_version is cancun. The deploy path must not move.
    function test_F1c_core_osakaRules() public {
        bytes memory data = _coreData();
        (, uint256 cancun) = _total(data, 30_000_000, false);
        vm.setEvmVersion("osaka");
        (bool ok, uint256 osaka) = _total(data, 30_000_000, false);
        assertTrue(ok);
        console.log("launch 2 cancun / osaka rules", cancun, osaka);
        assertApproxEqAbs(cancun, osaka, 1_000);
    }

    /// Marginal gas per byte of new runtime code through the factory, and how much new code launch 2 could take
    /// before the cap (per-contract EIP-170 margins in test_L1 bind first).
    function test_F2_marginalGasPerRuntimeByte() public {
        uint256 g1 = _dummyLaunch(4_000_000_311, 1_000, 0xAA);
        uint256 g2 = _dummyLaunch(4_000_000_312, 9_000, 0xAA);
        uint256 perNonzero = (g2 - g1) / 8_000;
        (, uint256 core) = _total(_coreData(), 30_000_000, false);
        console.log("gas per runtime byte (nonzero)", perNonzero);
        console.log("bytes of new code that fit launch 2 under the cap:", (CAP - core) / perNonzero);
        // ~9.9 KB before the B-01, C-01 and C-02 fixes
        // ~11.4 KB before the swarm audit fixes
        assertApproxEqAbs((CAP - core) / perNonzero, 10_300, 300, "docs/LAUNCH-TASK.md: ~10.3 KB by gas");
    }

    function _dummyLaunch(uint64 n, uint256 size, bytes1 fill) internal returns (uint256 total) {
        bytes memory payload = new bytes(size);
        for (uint256 i; i < size; ++i) {
            payload[i] = fill;
        }
        bytes memory code = abi.encodePacked(hex"61", uint16(size), hex"80600c6000396000f3", payload);
        bytes[] memory codes = new bytes[](1);
        codes[0] = code;
        bytes32[] memory names = new bytes32[](1);
        names[0] = "Dummy";
        address[] memory exp = new address[](1);
        exp[0] = FACTORY.predictContract(n, 0, code);
        bool ok;
        (ok, total) = _total(_contractsData(n, codes, names, exp), 30_000_000, true);
        assertTrue(ok);
        assertEq(exp[0].code.length, size);
    }

    /// The real Intake's request() with bodies up to the 16,384-byte limit: part of every ask and of the 2.5M
    /// emergency advance budget.
    function test_F3_realIntakeRequestGas() public {
        IIntake intake = IIntake(LaunchPlan.INTAKE);
        bytes32 action = "oracle.request@oracle-1";
        uint256 price = intake.priceOf(action, LaunchPlan.IMD);
        deal(LaunchPlan.IMD, address(this), 100e18);
        IERC20(LaunchPlan.IMD).approve(address(intake), type(uint256).max);
        uint256[4] memory sizes = [uint256(1_000), 4_000, 8_000, 16_384];
        for (uint256 k; k < 4; ++k) {
            bytes memory body = new bytes(sizes[k]);
            for (uint256 i; i < body.length; ++i) {
                body[i] = "a";
            }
            uint256 g0 = gasleft();
            intake.request(action, body, IIntake.Callback(address(this), CALLBACK_SELECTOR), LaunchPlan.IMD, price);
            uint256 g = g0 - gasleft();
            console.log("Intake.request body bytes / gas:", sizes[k], g);
            if (k == 3) assertLt(g, 1_000_000, "a max-size request costs well under the 2.5M advance budget");
        }
    }
}
