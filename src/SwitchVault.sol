// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { IERC20 } from "./IERC20.sol";

/// @title SwitchVault — custody vault for LastPing (Base Sepolia).
/// @notice Holds the owner's ETH + ERC-20 and releases them to the beneficiary
///         only after a two-phase process driven by LastPingReactive:
///         Armed --triggerSwitch--> Triggered (grace running) --release--> Released.
///         The vault never blindly trusts the reactive contract: `release`
///         re-verifies the grace period against the vault's OWN clock
///         (`triggeredAt + gracePeriod`) before moving any assets.
///         A ping during grace produces a `cancelTrigger` callback and the
///         switch returns to Armed. After release the switch is inert.
contract SwitchVault is AbstractCallback {
    enum Phase {
        Armed,
        Triggered,
        Released,
        Disarmed
    }

    error NotOwner();
    error NotArmed();
    error NotTriggered();
    error GraceNotElapsed(uint256 releaseAfter_, uint256 now_);
    error SwitchInert();
    // TransferFailed is inherited from AbstractPayer.

    event Funded(address indexed from, uint256 amount);
    event TokenDeposited(address indexed from, uint256 amount);
    event Withdrawn(address indexed owner, uint256 ethAmount, uint256 tokenAmount);
    event BeneficiaryChanged(address indexed newBeneficiary);
    event Disarmed();
    event Rearmed();
    event SwitchTriggered(address indexed beneficiary, uint256 triggeredAt, uint256 releaseAfter);
    event TriggerCancelled();
    event Released(address indexed beneficiary, uint256 ethAmount, uint256 tokenAmount);

    /// @notice The asset owner; sovereign over the vault while alive.
    address public owner;

    /// @notice Receives everything on release. Has no power over the switch.
    address public beneficiary;

    /// @notice The ERC-20 held alongside ETH (a mock tUSD in the demo).
    IERC20 public token;

    /// @notice Mirrored for transparency; the inactivity clock itself is enforced by the reactive contract.
    uint256 public inactivityPeriod;

    /// @notice Length of the cancel-by-ping window after a trigger.
    uint256 public gracePeriod;

    /// @notice This chain's timestamp when the current trigger started (0 when not triggered).
    uint256 public triggeredAt;

    Phase public phase;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param callbackProxy_ Base Sepolia callback proxy (0x476F44b11F5C942c58f4c8E3d0300E5710743585).
    /// @param callbackSender_ Address of LastPingReactive on Lasna — immutable, deploy it first.
    constructor(
        IPayable callbackProxy_,
        address callbackSender_,
        address beneficiary_,
        IERC20 token_,
        uint256 inactivityPeriod_,
        uint256 gracePeriod_
    ) payable AbstractCallback(callbackProxy_, callbackSender_) {
        owner = msg.sender;
        beneficiary = beneficiary_;
        token = token_;
        inactivityPeriod = inactivityPeriod_;
        gracePeriod = gracePeriod_;
        phase = Phase.Armed;
    }

    // ------------------------------------------------------------------
    // Funding / owner controls
    // ------------------------------------------------------------------

    /// @notice ETH deposits land here. Blocked after release so funds can
    ///         never be stranded in a completed switch.
    receive() external payable override {
        if (phase == Phase.Released) revert SwitchInert();
        emit Funded(msg.sender, msg.value);
    }

    /// @notice Named top-up for the callback-fee float / vault balance.
    function fund() external payable {
        if (phase == Phase.Released) revert SwitchInert();
        emit Funded(msg.sender, msg.value);
    }

    /// @notice Pull ERC-20 from the owner into the vault (requires prior approve).
    function depositToken(uint256 amount_) external onlyOwner {
        if (phase == Phase.Released) revert SwitchInert();
        require(token.transferFrom(msg.sender, address(this), amount_), "SwitchVault: transferFrom");
        emit TokenDeposited(msg.sender, amount_);
    }

    /// @notice Withdraw everything back to the owner and disarm the switch.
    function withdrawAll() external onlyOwner {
        if (phase == Phase.Released) revert SwitchInert();
        phase = Phase.Disarmed;
        triggeredAt = 0;
        uint256 ethAmount = address(this).balance;
        uint256 tokenAmount = token.balanceOf(address(this));
        if (ethAmount > 0) {
            (bool success,) = payable(owner).call{ value: ethAmount }("");
            if (!success) revert TransferFailed();
        }
        if (tokenAmount > 0) {
            require(token.transfer(owner, tokenAmount), "SwitchVault: transfer");
        }
        emit Withdrawn(owner, ethAmount, tokenAmount);
        emit Disarmed();
    }

    /// @notice Change the beneficiary. Resets the switch to Armed and clears
    ///         any running trigger — a redirect mid-grace must never release
    ///         to a beneficiary the owner just replaced.
    function setBeneficiary(address newBeneficiary_) external onlyOwner {
        if (phase == Phase.Released) revert SwitchInert();
        beneficiary = newBeneficiary_;
        triggeredAt = 0;
        phase = Phase.Armed;
        emit BeneficiaryChanged(newBeneficiary_);
        emit Rearmed();
    }

    /// @notice Take the switch offline without withdrawing. Re-arm via setBeneficiary.
    function disarm() external onlyOwner {
        if (phase == Phase.Released) revert SwitchInert();
        phase = Phase.Disarmed;
        triggeredAt = 0;
        emit Disarmed();
    }

    // ------------------------------------------------------------------
    // Callbacks from LastPingReactive (via the callback proxy only)
    // ------------------------------------------------------------------

    /// @notice Phase 1: start the grace clock. Does not move any assets.
    function triggerSwitch(address reactive_) external onlyServiceProvider onlyCallbackSender(reactive_) {
        if (phase != Phase.Armed) revert NotArmed();
        phase = Phase.Triggered;
        triggeredAt = block.timestamp;
        emit SwitchTriggered(beneficiary, triggeredAt, triggeredAt + gracePeriod);
    }

    /// @notice The owner pinged during grace — stand down, back to Armed.
    function cancelTrigger(address reactive_) external onlyServiceProvider onlyCallbackSender(reactive_) {
        if (phase != Phase.Triggered) revert NotTriggered();
        phase = Phase.Armed;
        triggeredAt = 0;
        emit TriggerCancelled();
    }

    /// @notice Phase 2: after the grace period, release everything to the
    ///         beneficiary. The vault re-checks timing with its own clock —
    ///         an early release request reverts even from the genuine
    ///         reactive contract.
    function release(address reactive_) external onlyServiceProvider onlyCallbackSender(reactive_) {
        if (phase != Phase.Triggered) revert NotTriggered();
        uint256 releaseAfter = triggeredAt + gracePeriod;
        if (block.timestamp < releaseAfter) {
            revert GraceNotElapsed(releaseAfter, block.timestamp);
        }
        phase = Phase.Released;
        uint256 ethAmount = address(this).balance;
        uint256 tokenAmount = token.balanceOf(address(this));
        if (ethAmount > 0) {
            (bool success,) = payable(beneficiary).call{ value: ethAmount }("");
            if (!success) revert TransferFailed();
        }
        if (tokenAmount > 0) {
            require(token.transfer(beneficiary, tokenAmount), "SwitchVault: transfer");
        }
        emit Released(beneficiary, ethAmount, tokenAmount);
    }
}
