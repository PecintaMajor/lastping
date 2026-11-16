// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

/// @title Heartbeat — proof-of-life register for LastPing (Base Sepolia).
/// @notice The owner proves they are alive by calling `ping()`; each ping emits
///         `Ping(owner, at)`, which the LastPingReactive contract on Lasna
///         subscribes to. Silence — the absence of this event — is the signal
///         the dead-man's switch acts on.
contract Heartbeat {
    /// @notice Emitted on every proof-of-life ping. `owner` is indexed so the
    ///         reactive contract can subscribe per-owner via topic1; `at` is
    ///         carried in the log data because LogRecord has no timestamp field.
    event Ping(address indexed owner, uint256 at);

    /// @notice Emitted when a switch is first configured for an owner, so the
    ///         reactive contract (and indexers/UIs) can learn a switch exists.
    event Registered(address indexed owner, address indexed beneficiary);

    /// @notice Beneficiary configured per owner (informational mirror of the vault config).
    mapping(address => address) public beneficiaryOf;

    /// @notice Last ping timestamp per owner, as recorded on this chain.
    mapping(address => uint256) public lastPingAt;

    /// @notice Configure (or reconfigure) the beneficiary for the caller's switch.
    function register(address beneficiary_) external {
        beneficiaryOf[msg.sender] = beneficiary_;
        emit Registered(msg.sender, beneficiary_);
    }

    /// @notice One-click proof of life. Resets the caller's inactivity clock.
    function ping() external {
        lastPingAt[msg.sender] = block.timestamp;
        emit Ping(msg.sender, block.timestamp);
    }
}
