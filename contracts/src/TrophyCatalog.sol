// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {TextLib} from "./helpers/TextRules.sol";

/// @title TrophyCatalog: the trophy designs of DareTrophy
/// @notice The project wallet (the owner, the same wallet that owns the ParamsRegistry) adds trophy designs (a name and
///         an SVG image) and chooses which design new trophies of each category get; it can switch a design off for
///         new mints. A design never changes once added, and a minted trophy keeps the design id it got at mint, so
///         nobody can redraw a trophy someone already owns. Design id 0 = the trophy's built-in badge of the category.
///         Holds and moves no money.
contract TrophyCatalog is Ownable2Step {
    uint256 public constant MAX_NAME_BYTES = 32;
    uint256 public constant MAX_IMAGE_BYTES = 8_192;
    uint8 public constant CATEGORIES = 9;

    struct Design {
        string name;
        bytes image; // SVG
        bool enabled;
        uint64 addedAt;
    }

    Design[] private _designs; // id = index + 1
    /// @notice The design new trophies of a category get (0 = the default design).
    mapping(uint8 => uint256) public categoryDesign;
    /// @notice The design new trophies of a category without its own design get (0 = the built-in badge).
    uint256 public defaultDesign;

    event DesignAdded(uint256 indexed id, string name, uint256 imageBytes);
    event DesignEnabled(uint256 indexed id, bool enabled);
    event CategoryDesignSet(uint8 indexed category, uint256 indexed id);
    event DefaultDesignSet(uint256 indexed id);

    error BadName();
    error BadImage();
    error BadCategory();
    error NoDesign(uint256 id);
    error DesignOff(uint256 id);

    constructor(address owner_) Ownable(owner_) {}

    /// @notice Add a design: `name` 1..32 bytes of printable ASCII (the text rules), `image` an SVG of 1..8192 bytes
    ///         of printable ASCII, tab or newline, from "<svg" to "</svg>". Returns its id; it is enabled but no
    ///         category gets it until assigned.
    function addDesign(string calldata name, bytes calldata image) external onlyOwner returns (uint256 id) {
        if (!TextLib.validText(name, MAX_NAME_BYTES)) revert BadName();
        if (!_validSvg(image)) revert BadImage();
        _designs.push(Design(name, image, true, uint64(block.timestamp)));
        id = _designs.length;
        emit DesignAdded(id, name, image.length);
    }

    /// @notice New trophies of `category` get design `id` (0 = the default design). The design must be enabled.
    function setCategoryDesign(uint8 category, uint256 id) external onlyOwner {
        if (category >= CATEGORIES) revert BadCategory();
        _requireUsable(id);
        categoryDesign[category] = id;
        emit CategoryDesignSet(category, id);
    }

    /// @notice New trophies of categories without their own design get design `id` (0 = the built-in badge).
    function setDefaultDesign(uint256 id) external onlyOwner {
        _requireUsable(id);
        defaultDesign = id;
        emit DefaultDesignSet(id);
    }

    /// @notice Switch a design on or off for new mints; trophies already minted with it keep it.
    function setDesignEnabled(uint256 id, bool enabled) external onlyOwner {
        if (id == 0 || id > _designs.length) revert NoDesign(id);
        _designs[id - 1].enabled = enabled;
        emit DesignEnabled(id, enabled);
    }

    /// @notice The design a trophy of `category` minted now gets: the category's, else the default, else 0 (the
    ///         built-in badge); a switched-off design is skipped.
    function designFor(uint8 category) external view returns (uint256) {
        uint256 id = category < CATEGORIES ? categoryDesign[category] : 0;
        if (id != 0 && _designs[id - 1].enabled) return id;
        id = defaultDesign;
        if (id != 0 && _designs[id - 1].enabled) return id;
        return 0;
    }

    function designCount() external view returns (uint256) {
        return _designs.length;
    }

    function design(uint256 id) external view returns (Design memory) {
        if (id == 0 || id > _designs.length) revert NoDesign(id);
        return _designs[id - 1];
    }

    /// @notice Name and SVG of a design (for the trophy's tokenURI).
    function nameAndImage(uint256 id) external view returns (string memory, bytes memory) {
        if (id == 0 || id > _designs.length) revert NoDesign(id);
        Design storage d = _designs[id - 1];
        return (d.name, d.image);
    }

    function _requireUsable(uint256 id) private view {
        if (id == 0) return;
        if (id > _designs.length) revert NoDesign(id);
        if (!_designs[id - 1].enabled) revert DesignOff(id);
    }

    function _validSvg(bytes calldata b) private pure returns (bool) {
        uint256 len = b.length;
        if (len < 11 || len > MAX_IMAGE_BYTES) return false;
        if (bytes4(b[0:4]) != "<svg" || bytes6(b[len - 6:len]) != "</svg>") return false;
        for (uint256 i; i < len; ++i) {
            uint8 c = uint8(b[i]);
            if ((c < 0x20 && c != 0x09 && c != 0x0a && c != 0x0d) || c >= 0x7f) return false;
        }
        return true;
    }
}
