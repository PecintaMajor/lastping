// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { SwitchVault } from "../src/SwitchVault.sol";
import { MockERC20 } from "../src/MockERC20.sol";
import { IERC20 } from "../src/IERC20.sol";

contract SwitchVaultTest is Test {
    /// @notice The real Base Sepolia callback proxy, used here purely as the
    ///         authorized-caller identity (tests prank it).
    address payable internal constant PROXY = payable(0x476F44b11F5C942c58f4c8E3d0300E5710743585);

    uint256 internal constant INACTIVITY = 300; // 5 min (demo parameters)
    uint256 internal constant GRACE = 180; // 3 min
    uint256 internal constant ETH_DEPOSIT = 0.05 ether;
    uint256 internal constant TOKEN_DEPOSIT = 500e6; // 500 tUSD (6 decimals)

    SwitchVault internal vault;
    MockERC20 internal token;
    address internal reactive = makeAddr("lastPingReactive");
    address internal beneficiary = makeAddr("beneficiary");
    address internal stranger = makeAddr("stranger");

    /// @notice The test contract is the vault owner and must be able to
    ///         receive the ETH that withdrawAll sends back.
    receive() external payable { }

    function setUp() public {
        vm.warp(1_700_000_000);
        vm.deal(address(this), 10 ether);
        token = new MockERC20("Test USD", "tUSD", 6);
        token.mint(address(this), 1_000e6);
        // The test contract is the vault owner in this suite.
        vault = new SwitchVault(
            IPayable(PROXY), reactive, beneficiary, IERC20(address(token)), INACTIVITY, GRACE
        );
        (bool ok,) = address(vault).call{ value: ETH_DEPOSIT }("");
        require(ok, "eth deposit failed");
        token.approve(address(vault), TOKEN_DEPOSIT);
        vault.depositToken(TOKEN_DEPOSIT);
    }

    function _trigger() internal {
        vm.prank(PROXY);
        vault.triggerSwitch(reactive);
    }

    function _release() internal {
        vm.prank(PROXY);
        vault.release(reactive);
    }

    // ----------------------------------------------------------------

    function testDepositEthAndToken() public view {
        assertEq(address(vault).balance, ETH_DEPOSIT);
        assertEq(token.balanceOf(address(vault)), TOKEN_DEPOSIT);
        assertEq(uint256(vault.phase()), uint256(SwitchVault.Phase.Armed));
        assertEq(vault.beneficiary(), beneficiary);
        assertEq(vault.gracePeriod(), GRACE);
    }

    function testTriggerSwitchStartsGrace() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit SwitchVault.SwitchTriggered(beneficiary, block.timestamp, block.timestamp + GRACE);
        _trigger();
        assertEq(uint256(vault.phase()), uint256(SwitchVault.Phase.Triggered));
        assertEq(vault.triggeredAt(), block.timestamp);
    }

    function testTriggerSwitchRevertsForDirectCaller() public {
        vm.expectRevert(
            abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), PROXY)
        );
        vault.triggerSwitch(reactive);
    }

    function testTriggerSwitchRevertsForWrongReactive() public {
        vm.prank(PROXY);
        vm.expectRevert(
            abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, stranger, reactive)
        );
        vault.triggerSwitch(stranger);
    }

    function testSecondTriggerReverts() public {
        _trigger();
        vm.prank(PROXY);
        vm.expectRevert(SwitchVault.NotArmed.selector);
        vault.triggerSwitch(reactive);
    }

    function testReleaseBeforeGraceReverts() public {
        _trigger();
        uint256 releaseAfter = vault.triggeredAt() + GRACE;
        vm.warp(block.timestamp + GRACE - 1);
        uint256 now_ = block.timestamp;
        vm.prank(PROXY);
        vm.expectRevert(abi.encodeWithSelector(SwitchVault.GraceNotElapsed.selector, releaseAfter, now_));
        vault.release(reactive);
        // Nothing moved.
        assertEq(token.balanceOf(beneficiary), 0);
        assertEq(beneficiary.balance, 0);
    }

    function testReleaseAfterGraceMovesAssets() public {
        _trigger();
        vm.warp(block.timestamp + GRACE);
        vm.expectEmit(true, false, false, true, address(vault));
        emit SwitchVault.Released(beneficiary, ETH_DEPOSIT, TOKEN_DEPOSIT);
        _release();
        assertEq(uint256(vault.phase()), uint256(SwitchVault.Phase.Released));
        assertEq(beneficiary.balance, ETH_DEPOSIT);
        assertEq(token.balanceOf(beneficiary), TOKEN_DEPOSIT);
        assertEq(address(vault).balance, 0);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function testReleaseRevertsWhenArmed() public {
        vm.prank(PROXY);
        vm.expectRevert(SwitchVault.NotTriggered.selector);
        vault.release(reactive);
    }

    function testCancelTriggerReturnsToArmed() public {
        _trigger();
        vm.prank(PROXY);
        vault.cancelTrigger(reactive);
        assertEq(uint256(vault.phase()), uint256(SwitchVault.Phase.Armed));
        assertEq(vault.triggeredAt(), 0);
        // And a release is impossible again.
        vm.prank(PROXY);
        vm.expectRevert(SwitchVault.NotTriggered.selector);
        vault.release(reactive);
    }

    function testCancelRevertsWhenArmed() public {
        vm.prank(PROXY);
        vm.expectRevert(SwitchVault.NotTriggered.selector);
        vault.cancelTrigger(reactive);
    }

    function testWithdrawAllDisarmsAndReturnsFunds() public {
        uint256 ethBefore = address(this).balance;
        uint256 tokBefore = token.balanceOf(address(this));
        vault.withdrawAll();
        assertEq(uint256(vault.phase()), uint256(SwitchVault.Phase.Disarmed));
        assertEq(address(this).balance, ethBefore + ETH_DEPOSIT);
        assertEq(token.balanceOf(address(this)), tokBefore + TOKEN_DEPOSIT);
        // A disarmed switch cannot be triggered.
        vm.prank(PROXY);
        vm.expectRevert(SwitchVault.NotArmed.selector);
        vault.triggerSwitch(reactive);
    }

    function testSetBeneficiaryResetsTrigger() public {
        address newBeneficiary = makeAddr("newBeneficiary");
        _trigger();
        vault.setBeneficiary(newBeneficiary);
        assertEq(vault.beneficiary(), newBeneficiary);
        assertEq(uint256(vault.phase()), uint256(SwitchVault.Phase.Armed));
        assertEq(vault.triggeredAt(), 0);
    }

    function testNonOwnerCannotControl() public {
        vm.startPrank(stranger);
        vm.expectRevert(SwitchVault.NotOwner.selector);
        vault.withdrawAll();
        vm.expectRevert(SwitchVault.NotOwner.selector);
        vault.setBeneficiary(stranger);
        vm.expectRevert(SwitchVault.NotOwner.selector);
        vault.disarm();
        vm.expectRevert(SwitchVault.NotOwner.selector);
        vault.depositToken(1);
        vm.stopPrank();
    }

    function testBeneficiaryCannotTriggerOrRelease() public {
        // Even the beneficiary gets nothing by calling directly — the only
        // road in is through the proxy, and the proxy only carries our RSC.
        vm.startPrank(beneficiary);
        vm.expectRevert(
            abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, beneficiary, PROXY)
        );
        vault.triggerSwitch(reactive);
        vm.expectRevert(
            abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, beneficiary, PROXY)
        );
        vault.release(reactive);
        vm.stopPrank();
    }

    function testDisarmBlocksTrigger() public {
        vault.disarm();
        assertEq(uint256(vault.phase()), uint256(SwitchVault.Phase.Disarmed));
        vm.prank(PROXY);
        vm.expectRevert(SwitchVault.NotArmed.selector);
        vault.triggerSwitch(reactive);
    }

    function testInertAfterRelease() public {
        _trigger();
        vm.warp(block.timestamp + GRACE);
        _release();

        vm.prank(PROXY);
        vm.expectRevert(SwitchVault.NotArmed.selector);
        vault.triggerSwitch(reactive);

        vm.prank(PROXY);
        vm.expectRevert(SwitchVault.NotTriggered.selector);
        vault.release(reactive);

        vm.expectRevert(SwitchVault.SwitchInert.selector);
        vault.withdrawAll();

        vm.expectRevert(SwitchVault.SwitchInert.selector);
        vault.setBeneficiary(stranger);

        (bool ok,) = address(vault).call{ value: 1 wei }("");
        assertFalse(ok, "post-release ETH deposit must be rejected by receive()");
    }
}
