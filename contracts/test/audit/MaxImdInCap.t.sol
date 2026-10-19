// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TaskVault} from "src/TaskVault.sol";
import {ITaskVault} from "src/interfaces/ITaskVault.sol";
import {ParamsRegistry} from "src/ParamsRegistry.sol";
import {CaseDesk} from "src/desks/CaseDesk.sol";
import {DisputeDesk} from "src/desks/DisputeDesk.sol";
import {TextRules} from "src/helpers/TextRules.sol";
import {SwarmQuestionBuilder} from "src/helpers/SwarmQuestion.sol";
import {AttestationChecker} from "src/helpers/AttestationChecker.sol";
import {VotePower} from "src/VotePower.sol";
import {YoloLockHub} from "src/YoloLockHub.sol";
import {BuybackBurner} from "src/BuybackBurner.sol";
import {DevPrices} from "src/DevPrices.sol";
import {IIntake} from "src/interfaces/IIntake.sol";
import {VoteLib} from "src/libraries/VoteLib.sol";
import "src/VaultTypes.sol";

contract AuditTok is ERC20 {
    uint8 internal immutable _dec;

    constructor(string memory n, uint8 d) ERC20(n, n) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

contract AuditNft is ERC721("id", "ID") {
    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

/// @dev Minimal Intake: sells every action for `price` IMD, pulls it from the caller, never answers.
contract AuditIntake is IIntake {
    address public immutable asset;
    uint256 public price;
    uint256 public nonce;
    mapping(bytes32 => bool) public known;

    constructor(address asset_, uint256 price_) {
        asset = asset_;
        price = price_;
    }

    function priceOf(bytes32, address token) external view returns (uint256) {
        return token == asset ? price : 0;
    }

    function requests(bytes32 id) external view returns (address, address, bytes4, bool) {
        return (known[id] ? address(1) : address(0), address(0), bytes4(0), false);
    }

    function request(bytes32, bytes calldata body, Callback calldata, address token, uint256 amount)
        external
        returns (bytes32 requestId)
    {
        require(token == asset && amount >= price && body.length != 0, "bad");
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        requestId = keccak256(abi.encode(block.chainid, address(this), ++nonce));
        known[requestId] = true;
    }
}

/// @dev Creates both desks and the vault inside one constructor (one transaction frame): Desk.wire's transient flag
///      must still be raised when the vault's constructor calls it. The creation code comes in as arguments, so this
///      deployer stays small and `forge build --sizes` (EIP-3860) does not count an 86 KB fixture.
contract AuditCore {
    address public caseDesk;
    address public disputeDesk;
    address public vault;

    constructor(bytes memory caseInit, bytes memory disputeInit, bytes memory vaultCode, bytes memory vaultArgs, address burner) {
        caseDesk = _create(caseInit);
        disputeDesk = _create(disputeInit);
        vault = _create(abi.encodePacked(vaultCode, vaultArgs, abi.encode(caseDesk, disputeDesk, burner)));
    }

    function _create(bytes memory init) private returns (address a) {
        assembly ("memory-safe") {
            a := create(0, add(init, 32), mload(init))
        }
        require(a != address(0), "create");
    }
}

/// @dev The fixture of both PoC tests: stateless helpers first, then the desks and the vault through AuditCore.
abstract contract AuditDeploy {
    function _deployCore(address registry, address imd, address usdc, address yolo, address prices, address nft)
        internal
        returns (YoloLockHub hub, CaseDesk caseDesk, DisputeDesk disputeDesk, address vault)
    {
        address text = address(new TextRules());
        hub = new YoloLockHub(yolo);
        address burner = address(new BuybackBurner(yolo, imd, usdc, prices, address(0xb0b)));
        address qb = address(new SwarmQuestionBuilder());
        address vp = address(new VotePower(nft, address(0)));
        address checker = address(new AttestationChecker(registry));
        AuditCore core = new AuditCore(
            abi.encodePacked(type(CaseDesk).creationCode, abi.encode(registry, imd, usdc, text, qb, yolo, address(hub))),
            abi.encodePacked(type(DisputeDesk).creationCode, abi.encode(registry, imd, usdc, text, vp, yolo, address(hub))),
            type(TaskVault).creationCode,
            abi.encode(registry, imd, usdc, yolo, checker, text),
            burner
        );
        caseDesk = CaseDesk(core.caseDesk());
        disputeDesk = DisputeDesk(core.disputeDesk());
        vault = core.vault();
    }
}

/// @dev Finding: DisputeDesk._fundCall caps only `bond.imd + pay` by `maxImdIn`, but on an IMD-reward task the bond's
///      "rew" part (1% of the author's own reward, also IMD) is pulled in the same collectImd call. The documented
///      "at most maxImdIn IMD" (ITaskVault.appeal / callSwarm, MECHANICS "capped by their maxImdIn") is exceeded.
contract MaxImdInCapTest is Test, AuditDeploy {
    AuditTok imd;
    AuditTok usdc;
    AuditTok yolo;
    AuditNft nft;
    AuditIntake intake;
    ParamsRegistry registry;
    ITaskVault vault;
    CaseDesk caseDesk;
    DisputeDesk disputeDesk;
    YoloLockHub hub;

    address multisig = makeAddr("multisig");
    address treasury = makeAddr("treasury");
    address devWallet = makeAddr("devWallet");
    address author = makeAddr("author");
    address doer = makeAddr("doer");
    address dave = makeAddr("dave");
    address erin = makeAddr("erin");
    address voter = makeAddr("voter");

    function setUp() public {
        vm.warp(1_800_000_000);
        imd = new AuditTok("IMD", 18);
        usdc = new AuditTok("USDC", 6);
        yolo = new AuditTok("YOLO", 18);
        nft = new AuditNft();
        intake = new AuditIntake(address(imd), 0.5e18);
        DevPrices prices = new DevPrices(devWallet, address(usdc), address(imd), address(yolo), 0.0001e18, 2500e18, 8e18);
        registry = new ParamsRegistry(
            multisig,
            address(intake),
            address(prices),
            makeAddr("swapAdapter"),
            address(nft),
            makeAddr("delegates"),
            treasury,
            makeAddr("attester")
        );
        address v;
        (hub, caseDesk, disputeDesk, v) =
            _deployCore(address(registry), address(imd), address(usdc), address(yolo), address(prices), address(nft));
        vault = ITaskVault(v);
        address[4] memory people = [author, doer, dave, erin];
        for (uint256 i; i < 4; ++i) {
            imd.mint(people[i], 10_000e18);
            vm.prank(people[i]);
            imd.approve(address(vault), type(uint256).max);
        }
        for (uint256 id; id < 20; ++id) {
            nft.mint(voter, id);
        }
    }

    function _noSwap() internal pure returns (ImdPay memory p) {}

    function test_AppealPullsMoreImdThanMaxImdIn() public {
        // IMD task: the author's own reward is 1000 IMD
        vm.prank(author);
        uint256 taskId = vault.createTask(
            address(imd),
            1_000e18,
            uint64(block.timestamp + 365 days),
            "Title",
            TaskRules("ipfs://task-condition", "PROOF: one https link, DOER CODE on the page", "NO if: unclear"),
            0,
            PROOF_LINK,
            "",
            _noSwap()
        );
        vm.prank(doer);
        uint256 subId =
            vault.submit(taskId, "https://x.com/doer/status/1", Evidence("", ""), 0, type(uint256).max, _noSwap());
        vm.prank(dave);
        vault.dispute(subId, "ipfs://reason", "ipfs://reason-proof", _noSwap());
        // 20 NFTs reject: instantDelta reached, the NFT decides (Phase.Decided)
        uint256[] memory ids = new uint256[](20);
        for (uint256 i; i < 20; ++i) {
            ids[i] = i;
        }
        vm.prank(voter);
        vault.vote(subId, VoteLib.SIDE_REJECT, voter, ids);
        assertEq(uint8(vault.getSubmission(subId).phase), uint8(Phase.Decided), "not decided");

        // the quoted cost: fixed bond 0.5 IMD + 1% of 1000 IMD = 10 IMD (also IMD here) + fee 0.5 IMD = 11 IMD
        Bond memory b = vault.quoteDisputeBond(subId);
        assertEq(b.imd, 0.5e18);
        assertEq(b.rew, 10e18);
        assertEq(vault.quoteSwarmFee(subId), 0.5e18);

        // a stranger caps the call at 1 IMD: "at most maxImdIn IMD" (ITaskVault.appeal) must refuse it
        uint256 before = imd.balanceOf(erin);
        vm.prank(erin);
        vm.expectRevert(CostAboveMax.selector);
        vault.appeal(subId, 1e18, _noSwap());
        assertEq(imd.balanceOf(erin), before, "IMD left the stranger's wallet above maxImdIn");
    }
}