// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";

/// @title LastPingReactive — the watcher (Reactive Lasna).
/// @notice Subscribes to the owner's `Ping` events on the origin chain and to
///         Cron100 ticks on Lasna. It detects the *absence* of a ping:
///         silence longer than `inactivityPeriod` triggers the vault's grace
///         countdown; a ping during grace cancels the trigger; continued
///         silence past the grace period releases the vault. After release it
///         unsubscribes from CRON so it stops billing ticks — the job is done.
contract LastPingReactive is AbstractReactive {
    /// @notice topic0 of `Heartbeat.Ping(address,uint256)` (keccak256 of the signature).
    uint256 internal constant PING_TOPIC = 0xfd8d0c1dc3ab254ec49463a1192bb2423b3b851adedec1aa94dcd362dc063c9d;

    /// @notice topic0 of the system contract's Cron100 event (official CRON demo table).
    uint256 internal constant CRON100_TOPIC = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;

    /// @notice Legacy system contract that emits CRON events.
    address internal constant CRON_CONTRACT = 0x0000000000000000000000000000000000fffFfF;

    /// @notice Callback gas limit (minimum accepted is 100_000; oversized on purpose —
    ///         the proxy withholds a cut for its own accounting).
    uint64 internal constant CALLBACK_GAS_LIMIT = 1000000;

    enum Phase {
        Armed,
        Triggered,
        Released
    }

    error NotOwner();

    event VaultSet(address indexed vault);
    event PingRecorded(uint256 at);
    event TriggerRequested(uint256 triggeredAt);
    event CancelRequested();
    event ReleaseRequested();

    /// @notice Deployer; the only account allowed to set the vault.
    address public owner;

    /// @notice Origin chain (Base Sepolia, 84532) — also the callback destination chain.
    uint256 public immutable originChainId;

    /// @notice Heartbeat contract on the origin chain.
    address public immutable heartbeat;

    /// @notice The asset owner whose pings count (subscription topic1 filter).
    address public immutable switchOwner;

    /// @notice Silence longer than this (seconds) starts the trigger.
    uint256 public immutable inactivityPeriod;

    /// @notice Cancel-by-ping window mirrored from the vault.
    uint256 public immutable gracePeriod;

    /// @notice SwitchVault on the origin chain; set after deployment (deploy order:
    ///         reactive first, then the vault that names it as callback sender, then this setter).
    address public vault;

    /// @notice Timestamp of the owner's most recent ping (from the Ping event payload).
    uint256 public lastPingAt;

    /// @notice Lasna timestamp when the current trigger fired (0 when not triggered).
    uint256 public triggeredAt;

    Phase public phase;

    /// @notice Whether the CRON subscription is still live (dropped after release).
    bool public cronSubscribed;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        uint256 originChainId_,
        address heartbeat_,
        address switchOwner_,
        uint256 inactivityPeriod_,
        uint256 gracePeriod_
    ) payable {
        owner = msg.sender;
        originChainId = originChainId_;
        heartbeat = heartbeat_;
        switchOwner = switchOwner_;
        inactivityPeriod = inactivityPeriod_;
        gracePeriod = gracePeriod_;
        lastPingAt = block.timestamp;
        phase = Phase.Armed;

        // Watch the owner's pings on the origin chain (topic1 = owner).
        SYSTEM.subscribe(
            originChainId_, heartbeat_, PING_TOPIC, uint256(uint160(switchOwner_)), REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        // Wake up on Cron100 ticks to check for silence.
        SYSTEM.subscribe(block.chainid, CRON_CONTRACT, CRON100_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        cronSubscribed = true;
    }

    /// @notice Point the watcher at its vault (step 3 of the deploy order).
    function setVault(address vault_) external onlyOwner {
        vault = vault_;
        emit VaultSet(vault_);
    }

    /// @notice Settle any outstanding debt to the system contract from this
    ///         contract's balance. Public on purpose: anyone can revive the watcher.
    function coverDebt() external {
        _coverDebt();
    }

    /// @inheritdoc IReactive
    function react(IReactive.LogRecord calldata log_) external override onlySystem {
        if (log_.chainId == originChainId && log_.contractAddress == heartbeat && log_.topic0 == PING_TOPIC) {
            _onPing(log_);
        } else if (log_.chainId == block.chainid && log_.contractAddress == CRON_CONTRACT && log_.topic0 == CRON100_TOPIC) {
            _onCron();
        }
        // Non-matching logs fall through silently — reverting as a filter still bills.
    }

    function _onPing(IReactive.LogRecord calldata log_) internal {
        // `at` travels in the log data: LogRecord carries no timestamp field.
        uint256 at = abi.decode(log_.data, (uint256));
        lastPingAt = at;
        emit PingRecorded(at);

        if (phase == Phase.Triggered && vault != address(0)) {
            // The owner is alive — stand down.
            phase = Phase.Armed;
            triggeredAt = 0;
            _requestCallback("cancelTrigger(address)");
            emit CancelRequested();
        }
    }

    function _onCron() internal {
        if (vault == address(0)) return; // not wired up yet; stay quiet

        if (phase == Phase.Armed) {
            if (block.timestamp > lastPingAt + inactivityPeriod) {
                phase = Phase.Triggered;
                triggeredAt = block.timestamp;
                _requestCallback("triggerSwitch(address)");
                emit TriggerRequested(triggeredAt);
            }
        } else if (phase == Phase.Triggered) {
            if (block.timestamp > triggeredAt + gracePeriod) {
                phase = Phase.Released;
                _requestCallback("release(address)");
                emit ReleaseRequested();
                // The job is done — stop paying for ticks.
                SYSTEM.unsubscribe(
                    block.chainid, CRON_CONTRACT, CRON100_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
                );
                cronSubscribed = false;
            }
        }
    }

    function _requestCallback(string memory signature_) internal {
        // The first argument MUST be an address placeholder: the network
        // overwrites it with this contract's address so the vault can
        // authenticate the sender (onlyCallbackSender).
        bytes memory payload = abi.encodeWithSignature(signature_, address(0));
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: originChainId, recipient: vault, gasLimit: CALLBACK_GAS_LIMIT, payload: payload
            })
        );
    }
}
