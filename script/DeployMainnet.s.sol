// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DevPrices} from "../src/DevPrices.sol";
import {BuybackBurner} from "../src/BuybackBurner.sol";
import {ETH} from "../src/VaultTypes.sol";
import {LaunchParams} from "../src/VaultParams.sol";
import {LaunchPlan, LocalFactory} from "./LaunchPlan.sol";
import {CaseDesk} from "../src/desks/CaseDesk.sol";
import {DisputeDesk} from "../src/desks/DisputeDesk.sol";
import {TaskVault} from "../src/TaskVault.sol";

interface IIntakePrice {
    function priceOf(bytes32 action, address asset) external view returns (uint256);
}

interface IErc721Owner {
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface ISafeThreshold {
    function getThreshold() external view returns (uint256);
}

/// @notice Ethereum mainnet deployment by our own key, the alternative to the launch through the IMD swarm
///         (docs/LAUNCH-TASK.md). WITHOUT `--broadcast` this is a dry run (a simulation that sends nothing), which is
///         how the rehearsal on a local fork is done. The same launches 1..3 as
///         LaunchPlan, each in one transaction through a LocalFactory (the vault wires its desks in the transaction
///         that deployed them).
///         The registry's numbers and question template are compiled in (LaunchParams); its counterparties come from
///         the environment.
contract DeployMainnet is Script {
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant ROUTER02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address constant DELEGATE_XYZ = 0x00000000000000447e69651d841bD8D104Bed493;
    // verified counterparties (the Intake is version 2, the swarm
    // reference "use version 2 for anything new", swarm audit 117cf05a #11); overridable from the environment
    address constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address constant NFT = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;
    address constant ATTESTER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;

    function run() external {
        // 31337: the rehearsal on a local fork of mainnet (the IMD address alone proves nothing, it is an
        // OFT and the same address exists in other chains)
        require(block.chainid == 1 || block.chainid == 31337, "Ethereum mainnet or a local fork of it only");
        require(IMD.code.length != 0 && USDC.code.length != 0, "not a fork of Ethereum mainnet state");
        uint256 key = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(key);
        address intake = vm.envOr("INTAKE", INTAKE); // the IMD swarm Intake contract
        address nft = vm.envOr("NFT", NFT); // the identity.md NFT collection
        address treasury = vm.envAddress("TREASURY"); // the project treasury (fees only, never pays)
        address paramsOwner = vm.envAddress("PARAMS_OWNER"); // the project wallet; parameter changes wait 48h
        address[] memory attesters = vm.envOr("ATTESTERS", ",", _one(ATTESTER)); // the swarm answer signers
        bytes32 action = vm.envOr("SWARM_ACTION", bytes32("oracle.request@oracle-1"));
        // $YOLO comes from its own custom_token launch through the IMD factory (docs/LAUNCH-TASK.md)
        address yolo = vm.envAddress("YOLO");
        require(yolo.code.length != 0, "YOLO: not a contract");

        require(action == LaunchParams.SWARM_ACTION, "SWARM_ACTION: version 1 uses the compiled-in action");
        _checkCounterparties(intake, nft, treasury, paramsOwner, attesters, action);

        vm.startBroadcast(key);
        LocalFactory factory = new LocalFactory();
        LaunchPlan.Counterparties memory c = LaunchPlan.mainnet(paramsOwner, treasury);
        (c.intake, c.nft, c.attester) = (intake, nft, attesters[0]);
        (bytes[] memory codes,, LaunchPlan.Support memory s) =
            LaunchPlan.support(factory, 1, c, LaunchPlan.yoloPool(yolo));
        factory.launchContracts(1, codes);
        address[] memory core;
        (codes,, core) = LaunchPlan.core(factory, 2, s, IMD, USDC, yolo);
        factory.launchContracts(2, codes);
        address[] memory extra;
        (codes,, extra) = LaunchPlan.extras(factory, 3, core[LaunchPlan.CORE_VAULT], paramsOwner, uint64(block.number), nft, DELEGATE_XYZ);
        factory.launchContracts(3, codes);
        vm.stopBroadcast();
        // the add-on counts with the reward only once the params owner binds the sweetener
        if (deployer == paramsOwner) {
            vm.broadcast(key);
            TaskVault(payable(core[LaunchPlan.CORE_VAULT])).bindSweetener(extra[0]);
        } else {
            console2.log("PARAMS_OWNER must call TaskVault.bindSweetener", extra[0]);
        }

        // the stake check never reverts a payout, so a wrong hub would only silently pay no bonus: check the wiring
        address hub = core[LaunchPlan.CORE_HUB];
        require(hub.code.length != 0, "YoloLockHub has no code");
        require(address(DisputeDesk(core[LaunchPlan.CORE_DISPUTE]).doerStake()) == hub, "DisputeDesk reads another hub");
        require(address(CaseDesk(core[LaunchPlan.CORE_CASE]).doerStake()) == hub, "CaseDesk reads another hub");
        require(TaskVault(payable(core[LaunchPlan.CORE_VAULT])).burner() == s.burner, "vault burns elsewhere");
        require(s.burner.code.length != 0, "BuybackBurner has no code");
        require(BuybackBurner(payable(s.burner)).buybackWallet() == LaunchPlan.PROJECT_BUYBACK, "buyback wallet");

        _checkPrices(DevPrices(s.devPrices));

        string memory o = "deploy";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeUint(o, "startBlock", block.number);
        vm.serializeAddress(o, "vault", core[LaunchPlan.CORE_VAULT]);
        vm.serializeAddress(o, "caseDesk", core[LaunchPlan.CORE_CASE]);
        vm.serializeAddress(o, "disputeDesk", core[LaunchPlan.CORE_DISPUTE]);
        vm.serializeAddress(o, "sweetener", extra[0]);
        vm.serializeAddress(o, "trophy", extra[2]);
        vm.serializeAddress(o, "directory", extra[3]);
        vm.serializeAddress(o, "hiddenList", extra[4]);
        vm.serializeAddress(o, "yoloPredict", extra[5]);
        vm.serializeAddress(o, "trophyCatalog", extra[1]);
        vm.serializeAddress(o, "yoloLockHub", core[LaunchPlan.CORE_HUB]);
        vm.serializeAddress(o, "buybackBurner", s.burner);
        vm.serializeUint(o, "hiddenListFromBlock", block.number);
        vm.serializeAddress(o, "registry", s.registry);
        vm.serializeAddress(o, "intake", intake);
        vm.serializeAddress(o, "nft", nft);
        vm.serializeAddress(o, "priceOracle", s.devPrices);
        vm.serializeAddress(o, "swapAdapter", s.swapAdapter);
        vm.serializeAddress(o, "imd", IMD);
        vm.serializeAddress(o, "usdc", USDC);
        vm.serializeAddress(o, "yolo", yolo);
        vm.serializeAddress(o, "weth", WETH);
        vm.serializeAddress(o, "attester", attesters[0]);
        string memory json = vm.serializeAddress(o, "treasury", treasury);
        console2.log("deployer", deployer);
        console2.log("vault", core[LaunchPlan.CORE_VAULT]);
        console2.log("registry (owner = the project wallet)", s.registry);
        console2.log("devPrices", s.devPrices);
        console2.log(string.concat("DEPLOYMENT_JSON ", json));
    }

    /// @dev Everything we do not control must answer before anything is deployed.
    function _checkCounterparties(
        address intake,
        address nft,
        address treasury,
        address paramsOwner,
        address[] memory attesters,
        bytes32 action
    ) internal view {
        require(treasury != address(0) && paramsOwner != address(0), "TREASURY / PARAMS_OWNER");
        // The owner of the rules is the project wallet, an EOA; every change waits 48 h. A multisig owner
        // must not be a 1-of-n.
        (bool okThreshold, bytes memory ret) = paramsOwner.code.length == 0
            ? (false, bytes(""))
            : paramsOwner.staticcall(abi.encodeCall(ISafeThreshold.getThreshold, ()));
        if (paramsOwner.code.length == 0) {
            console2.log("params owner is an EOA (the project wallet)");
        } else if (okThreshold && ret.length == 32) {
            uint256 threshold = abi.decode(ret, (uint256));
            require(threshold >= 2, "PARAMS_OWNER: multisig threshold is 1");
            console2.log("params owner threshold", threshold);
        } else {
            console2.log("WARNING: PARAMS_OWNER does not answer getThreshold(), check it by hand");
        }
        require(
            attesters.length == 1 && attesters[0] != address(0),
            "ATTESTERS: one at launch, more through proposeAttester"
        );
        require(intake.code.length != 0, "INTAKE: not a contract");
        require(nft.code.length != 0, "NFT: not a contract");
        uint256 price = IIntakePrice(intake).priceOf(action, IMD);
        require(price != 0, "INTAKE: the action is not priced in IMD");
        IErc721Owner(nft).ownerOf(1); // reverts if the collection is not ERC-721 / has no token 1
        console2.log("intake price, IMD wei", price);
    }

    function _one(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    /// @dev Sanity of the starting prices (DevPrices: fixed parameters, not an oracle): a wrong
    ///      starting value would misprice the doer stake bonus until it is corrected by hand.
    function _checkPrices(DevPrices prices) internal view {
        uint256 eth = prices.usdValue(ETH, 1 ether);
        uint256 imd = prices.usdValue(IMD, 1e18);
        uint256 usdc = prices.usdValue(USDC, 1e6);
        require(eth > 100e18 && eth < 100_000e18, "ETH/USD out of range");
        require(imd > 0.01e18 && imd < 10_000e18, "IMD/USD out of range");
        require(usdc > 0.9e18 && usdc < 1.1e18, "USDC/USD out of range");
        console2.log("ETH/USD", eth);
        console2.log("IMD/USD (dev-set starting value)", imd);
        console2.log("IMD for a 300 USDC task", prices.imdValue(USDC, 300e6));
    }
}
