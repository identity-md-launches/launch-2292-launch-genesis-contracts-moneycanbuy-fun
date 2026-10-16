// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ParamsRegistry} from "./ParamsRegistry.sol";
import {TextRules} from "./helpers/TextRules.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {Submission, Task, Outcome} from "./VaultTypes.sol";

/// @dev What the trophy reads from the vault and its CaseDesk (all set at deployment or once per task/submission).
interface ITrophyVault {
    function getTask(uint256 taskId) external view returns (Task memory);
    function caseDesk() external view returns (address);
    function registry() external view returns (address);
    function textRules() external view returns (TextRules);
    function imd() external view returns (IERC20);
    function usdc() external view returns (IERC20);
    function yolo() external view returns (IERC20);
}

interface ITrophyDesk {
    function getSubmission(uint256 subId) external view returns (Submission memory);
}

/// @title DareTrophy: an on-chain NFT trophy of an accepted submission
/// @notice The doer of an accepted submission may mint its trophy, once: the token id is the submission id. The price is
///         paid in $YOLO and burned (sent to 0x…dEaD: the token has no burn function). It is `priceUsd` at the
///         oracle's YOLO price (the highest recent sample, never below the pool's opening price), or `fallbackYolo` while YOLO
///         has no price or the oracle fails; both are fixed at deployment. Metadata live entirely on chain: tokenURI
///         is a JSON with a 24x24 pixel badge of the task's category (SVG), the task and submission numbers, the
///         title, the reward, the mint date and the proof link. The title is given by the doer at mint (the vault keeps
///         the task title only in its TaskCreated event), checked with the vault's text rules; everything else comes
///         from the vault. No owner, no admin.
contract DareTrophy is ERC721 {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant MAX_TITLE_BYTES = 64;
    uint256 private constant MAX_PRICE_USD = 100e18;
    uint256 private constant MAX_FALLBACK_YOLO = 10_000_000e18;

    ITrophyVault public immutable vault;
    ITrophyDesk public immutable caseDesk;
    ParamsRegistry public immutable registry;
    TextRules public immutable textRules;
    IERC20 public immutable yolo;
    address private immutable _imd;
    address private immutable _usdc;
    /// @notice Price of a trophy in USD (18 decimals) while YOLO has a price.
    uint256 public immutable priceUsd;
    /// @notice Price of a trophy in YOLO while YOLO has no price (or the oracle fails).
    uint256 public immutable fallbackYolo;

    struct Minted {
        uint64 time;
        uint64 taskId;
        uint256 yoloBurned;
        string title;
    }

    mapping(uint256 => Minted) private _minted;
    /// @notice YOLO burned by all trophies together.
    uint256 public totalBurned;

    event TrophyMinted(uint256 indexed subId, uint256 indexed taskId, address indexed doer, uint256 yoloBurned);

    error BadSetup();
    error NotTheDoer();
    error NotAccepted();
    error BadTitle();
    error PriceAboveMax(uint256 price);

    /// @dev 16x16 pixel icons, 2 bytes per row, in the order of the categories (social, stream, irl, onchain, dev,
    ///      art, other); drawn at (4,4) inside the 24x24 badge.
    bytes private constant ICONS =
        hex"00003ffc7ffe600660066db66db6600660067ffe3ffc0e001c0030000000000000007ffe40024202438243e243fa43e24382420240027ffe018007e00000000003c007e007e003c000000ff01ff837ec37ec37ec07e00660066006600e700000018007e01ff87ffe5ffa47e2418240824082408240826086189806a0018000000000000004200c301860306c60c6c0c36186318c19980b10060000000000000007e01ff83ffc73ce73ceffffcfffcfe7ffe7fffe79fc79f03fe01fc0078000000180018003c003c0ffff7ffe3ffc1ff80ff00ff01ff81e78381c300c40020000";

    constructor(address vault_, uint256 priceUsd_, uint256 fallbackYolo_) ERC721("moneycanbuy.fun trophy", "DARE") {
        if (
            vault_ == address(0) || priceUsd_ == 0 || priceUsd_ > MAX_PRICE_USD || fallbackYolo_ == 0
                || fallbackYolo_ > MAX_FALLBACK_YOLO
        ) revert BadSetup();
        ITrophyVault v = ITrophyVault(vault_);
        vault = v;
        caseDesk = ITrophyDesk(v.caseDesk());
        registry = ParamsRegistry(v.registry());
        textRules = v.textRules();
        yolo = v.yolo();
        _imd = address(v.imd());
        _usdc = address(v.usdc());
        priceUsd = priceUsd_;
        fallbackYolo = fallbackYolo_;
    }

    /// @notice YOLO a trophy costs now: `priceUsd` at the oracle's YOLO price, else `fallbackYolo`.
    /// @dev Reads the CURRENT parameter version's oracle, not the minting task's (audit round 2, finding 20; kept
    ///      as-is rather than taking `taskId`: the site/backend read this as one shared value for every unminted
    ///      trophy, so changing the signature is a bigger change than the finding's severity warrants, see
    ///      `docs/MECHANICS.md`, "Trust assumptions"). A new version's oracle therefore re-prices every unminted
    ///      trophy of every version, not just tasks created under it; bounded by `maxYolo` at mint and by the 48h
    ///      visibility any parameter change gets.
    function price() public view returns (uint256) {
        IPriceOracle o = IPriceOracle(registry.core(registry.currentVersion()).priceOracle);
        try o.hasPrice(address(yolo)) returns (bool ok) {
            if (!ok) return fallbackYolo;
        } catch {
            return fallbackYolo;
        }
        try o.usdValue(address(yolo), 1e18) returns (uint256 usdPerYolo) {
            return usdPerYolo == 0 ? fallbackYolo : Math.ceilDiv(priceUsd * 1e18, usdPerYolo);
        } catch {
            return fallbackYolo;
        }
    }

    /// @notice Mint the trophy of your accepted submission `subId`, burning its price in YOLO (pulled with
    ///         transferFrom, at most `maxYolo`). `title`: the task title, 1..64 bytes under the vault's text rules.
    function mint(uint256 subId, string calldata title, uint256 maxYolo) external {
        Submission memory s = caseDesk.getSubmission(subId);
        if (s.doer != msg.sender) revert NotTheDoer();
        if (s.outcome != Outcome.Accepted) revert NotAccepted();
        if (!textRules.validText(title, MAX_TITLE_BYTES)) revert BadTitle();
        uint256 p = price();
        if (p > maxYolo) revert PriceAboveMax(p);
        _minted[subId] = Minted(uint64(block.timestamp), s.taskId, p, title);
        totalBurned += p;
        _mint(msg.sender, subId); // reverts if this submission already has its trophy
        yolo.safeTransferFrom(msg.sender, DEAD, p);
        emit TrophyMinted(subId, s.taskId, msg.sender, p);
    }

    /// @notice Mint record of a trophy (time 0 = none).
    function mintedOf(uint256 subId) external view returns (Minted memory) {
        return _minted[subId];
    }

    function tokenURI(uint256 subId) public view override returns (string memory) {
        _requireOwned(subId);
        Minted memory m = _minted[subId];
        Task memory t = vault.getTask(m.taskId);
        Submission memory s = caseDesk.getSubmission(subId);
        string memory task = uint256(m.taskId).toString();
        string memory json = string.concat(
            '{"name":"Dare #',
            task,
            " trophy",
            '","description":"',
            m.title,
            ' (accepted on moneycanbuy.fun)","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(badge(t.category))),
            '","attributes":[{"trait_type":"Task","value":',
            task,
            '},{"trait_type":"Submission","value":',
            subId.toString(),
            '},{"trait_type":"Category","value":"',
            _categoryName(t.category),
            '"},{"trait_type":"Reward","value":"',
            _amount(s.reward, t.currency),
            '"},{"trait_type":"Proof","value":"',
            s.proofUri,
            '"},{"display_type":"date","trait_type":"Minted","value":',
            uint256(m.time).toString(),
            "}]}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    /// @notice The 24x24 pixel badge of a category: gold frame, the category's colour, its white icon.
    function badge(uint8 category) public pure returns (string memory svg) {
        uint256 c = category < 7 ? category : 6;
        svg = string.concat(
            "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' shape-rendering='crispEdges'>",
            "<rect width='24' height='24' fill='#f5c542'/><rect x='1' y='1' width='22' height='22' fill='#",
            _colour(c),
            "'/>"
        );
        for (uint256 y; y < 16; ++y) {
            uint256 row = (uint256(uint8(ICONS[c * 32 + y * 2])) << 8) | uint8(ICONS[c * 32 + y * 2 + 1]);
            uint256 x;
            while (x < 16) {
                if (row & (1 << (15 - x)) == 0) {
                    ++x;
                    continue;
                }
                uint256 w;
                while (x + w < 16 && row & (1 << (15 - x - w)) != 0) ++w;
                svg = string.concat(
                    svg,
                    "<rect x='",
                    (x + 4).toString(),
                    "' y='",
                    (y + 4).toString(),
                    "' width='",
                    w.toString(),
                    "' height='1' fill='#fff'/>"
                );
                x += w;
            }
        }
        svg = string.concat(svg, "</svg>");
    }

    function _colour(uint256 c) private pure returns (string memory) {
        return ["1d9bf0", "9146ff", "ff6b35", "627eea", "24292f", "e91e63", "7a7a7a"][c];
    }

    function _categoryName(uint8 c) private pure returns (string memory) {
        return ["Social", "Stream", "IRL", "Onchain", "Dev", "Art", "Other"][c < 7 ? c : 6];
    }

    /// @dev "1234.5678 SYM": whole part and at most 4 decimals, trailing zeros trimmed.
    function _amount(uint256 raw, address currency) private view returns (string memory) {
        (uint256 decimals, string memory symbol) = currency == address(0)
            ? (18, "ETH")
            : currency == _usdc ? (6, "USDC") : currency == _imd ? (18, "IMD") : (18, "YOLO");
        uint256 unit = 10 ** decimals;
        uint256 frac = (raw % unit) * 10_000 / unit;
        string memory out = (raw / unit).toString();
        if (frac != 0) {
            bytes memory f = bytes(string.concat(frac < 10 ? "000" : frac < 100 ? "00" : frac < 1000 ? "0" : "", frac.toString()));
            uint256 len = 4;
            while (f[len - 1] == "0") --len;
            assembly ("memory-safe") {
                mstore(f, len)
            }
            out = string.concat(out, ".", string(f));
        }
        return string.concat(out, " ", symbol);
    }
}
