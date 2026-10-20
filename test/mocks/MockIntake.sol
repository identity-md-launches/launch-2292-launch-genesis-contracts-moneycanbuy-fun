// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IIntake} from "../../src/interfaces/IIntake.sol";
import {OracleAttestation} from "../../src/OracleAttestation.sol";

/// @dev Models the verified mainnet Intake: requestId = keccak256(chainid, this, ++nonce); pulls `amount` of the
///      asset to `payTo`; stores (payer, target, selector, completed); `complete` by the writer calls the callback
///      with a fixed gas stipend for status 0 only and never reverts on a failing callback.
contract MockIntake is IIntake {
    struct Req {
        address payer;
        address callbackTarget;
        bytes4 callbackSelector;
        bool completed;
    }

    event Requested(
        bytes32 indexed requestId,
        address indexed payer,
        bytes32 indexed action,
        bytes body,
        address callbackTarget,
        bytes4 callbackSelector,
        address asset,
        uint256 amount
    );
    event Completed(bytes32 indexed requestId, uint8 status, bool delivered);

    address public immutable payTo;
    bytes32 public immutable action;
    address public immutable asset;
    uint256 public price;
    uint64 public callbackGas = 200_000;
    uint256 public nonce;
    mapping(bytes32 => Req) internal _reqs;
    bytes32 public lastBodyHash;
    uint256 public lastBodyLength;
    bytes32 public lastRequestId;
    bool public lastDelivered;
    uint256 public lastCallbackGasUsed;

    constructor(address payTo_, bytes32 action_, address asset_, uint256 price_) {
        payTo = payTo_;
        action = action_;
        asset = asset_;
        price = price_;
    }

    function setPrice(uint256 p) external {
        price = p;
    }

    bool public broken;

    function setBroken(bool b) external {
        broken = b;
    }

    function setCallbackGas(uint64 g) external {
        callbackGas = g;
    }

    function priceOf(bytes32 a, address token) external view returns (uint256) {
        return a == action && token == asset ? price : 0;
    }

    function requests(bytes32 id) external view returns (address, address, bytes4, bool) {
        Req storage r = _reqs[id];
        return (r.payer, r.callbackTarget, r.callbackSelector, r.completed);
    }

    function request(bytes32 a, bytes calldata body, Callback calldata cb, address token, uint256 amount)
        external
        returns (bytes32 requestId)
    {
        require(!broken, "broken");
        require(a == action && token == asset, "ActionNotSold");
        require(amount >= price && price != 0, "PriceNotMet");
        require(body.length != 0 && body.length <= 16_384, "body");
        IERC20(token).transferFrom(msg.sender, payTo, amount);
        requestId = keccak256(abi.encode(block.chainid, address(this), ++nonce));
        _reqs[requestId] = Req(msg.sender, cb.target, cb.selector, false);
        lastBodyHash = keccak256(body); // the real Intake only emits the body
        lastBodyLength = body.length;
        lastRequestId = requestId;
        emit Requested(requestId, msg.sender, a, body, cb.target, cb.selector, token, amount);
    }

    /// @dev status 0: deliver the answer; 1 refused / 2 no consensus: no callback.
    function complete(
        bytes32 requestId,
        uint8 status,
        OracleAttestation.Attestation calldata att,
        bytes calldata signature
    ) external returns (bool delivered) {
        Req storage r = _reqs[requestId];
        require(r.payer != address(0) && !r.completed, "state");
        r.completed = true;
        if (status == 0 && r.callbackTarget != address(0)) {
            bytes memory data = abi.encodeWithSelector(r.callbackSelector, requestId, att, signature);
            uint256 g = gasleft();
            (delivered,) = r.callbackTarget.call{gas: callbackGas}(data);
            lastCallbackGasUsed = g - gasleft();
        }
        lastDelivered = delivered;
        emit Completed(requestId, status, delivered);
    }

    /// @dev Marks a request completed without calling back (models a failed / undelivered callback).
    function completeWithoutCallback(bytes32 requestId) external {
        _reqs[requestId].completed = true;
    }

    /// @dev Calls an arbitrary target as if the Intake were calling back (for spoofing tests).
    function rawCallback(address target, bytes calldata data) external returns (bool ok) {
        (ok,) = target.call(data);
    }
}
