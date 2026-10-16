// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IStartableVesting {
    function bindStarter() external;
    function release(address token) external;
}

/// @dev Stands in for the YoloSplitter in unit tests of a vesting: deploys the vesting (`code`: creation code with its
///      constructor arguments) and binds itself as its starter in the same constructor, as the launch does in one
///      transaction, then starts clocks on request.
contract MockStarter {
    address public immutable vesting;

    constructor(bytes memory code) {
        address v;
        assembly ("memory-safe") {
            v := create(0, add(code, 0x20), mload(code))
        }
        require(v != address(0), "vesting not deployed");
        IStartableVesting(v).bindStarter();
        vesting = v;
    }

    function start(address token) external {
        IStartableVesting(vesting).release(token);
    }
}
