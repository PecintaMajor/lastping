// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { Heartbeat } from "../src/Heartbeat.sol";
import { SwitchVault } from "../src/SwitchVault.sol";
import { LastPingReactive } from "../src/LastPingReactive.sol";
import { MockERC20 } from "../src/MockERC20.sol";
import { IERC20 } from "../src/IERC20.sol";
import { MockSystemContract } from "./mocks/MockSystemContract.sol";

/// @title Full-lifecycle integration: Heartbeat + LastPingReactive + SwitchVault.
/// @notice The mock system contract records the RSC's callback requests; the
///         test then delivers them exactly like the real network would —
///         through the callback proxy identity, with the RSC's address
///         injected as the first payload argument.
contract LifecycleTest is Test {
    address payable internal constant SYSTEM_ADDR = payable(0x8888888888888888888888888888888888888888);
    address payable internal constant PROXY = payable(0x476F44b11F5C942c58f4c8E3d0300E5710743585); // Base Sepolia callback proxy
    address internal constant CRON_CONTRACT = 0x0000000000000000000000000000000000fffFfF;
    uint256 internal constant PING_TOPIC = 0xfd8d0c1dc3ab254ec49463a1192bb2423b3b851adedec1aa94dcd362dc063c9d;
    uint256 internal constant CRON100_TOPIC = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;

    uint256 internal constant ORIGIN_CHAIN = 84532;
    uint256 internal constant INACTIVITY = 300; // 5 min demo parameter
    uint256 internal constant GRACE = 180; // 3 min demo parameter
    uint256 internal constant T0 = 1_700_000_000;
    uint256 internal constant ETH_DEPOSIT = 0.05 ether;
    uint256 internal constant TOKEN_DEPOSIT = 500e6;

    MockSystemContract internal sys;
    Heartbeat internal heartbeat;
    SwitchVault internal vault;
    LastPingReactive internal reactive;
    MockERC20 internal token;

    address internal owner = makeAddr("owner");
    address internal beneficiary = makeAddr("beneficiary");

    function setUp() public {
        vm.warp(T0);
        MockSystemContract mock = new MockSystemContract();
        vm.etch(SYSTEM_ADDR, address(mock).code);
        sys = MockSystemContract(SYSTEM_ADDR);

        vm.deal(owner, 10 ether);
        vm.startPrank(owner);
        heartbeat = new Heartbeat();
        token = new MockERC20("Test USD", "tUSD", 6);
        token.mint(owner, 1_000e6);
        // Deploy order: RSC first, then the vault that names it, then the setter.
        reactive = new LastPingReactive{ value: 0.1 ether }(
            ORIGIN_CHAIN, address(heartbeat), owner, INACTIVITY, GRACE
        );
        vault = new SwitchVault(
            IPayable(PROXY), address(reactive), beneficiary, IERC20(address(token)), INACTIVITY, GRACE
        );
        reactive.setVault(address(vault));
        heartbeat.register(beneficiary);
        // Fund the vault: 0.05 ETH + 500 tUSD.
        (bool ok,) = address(vault).call{ value: ETH_DEPOSIT }("");
        require(ok, "vault eth funding failed");
        token.approve(address(vault), TOKEN_DEPOSIT);
        vault.depositToken(TOKEN_DEPOSIT);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Network simulation helpers
    // ------------------------------------------------------------------

    function _ping() internal {
        vm.prank(owner);
        heartbeat.ping();
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chainId: ORIGIN_CHAIN,
            contractAddress: address(heartbeat),
            topic0: PING_TOPIC,
            topic1: uint256(uint160(owner)),
            topic2: 0,
            topic3: 0,
            data: abi.encode(block.timestamp),
            blockNumber: 1,
            opCode: 2,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
        vm.prank(SYSTEM_ADDR);
        reactive.react(log);
    }

    function _cron() internal {
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chainId: block.chainid,
            contractAddress: CRON_CONTRACT,
            topic0: CRON100_TOPIC,
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: "",
            blockNumber: 1,
            opCode: 1,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
        vm.prank(SYSTEM_ADDR);
        reactive.react(log);
    }

    /// @notice Deliver recorded callback request `idx` the way the network
    ///         does: called by the proxy, first argument overwritten with
    ///         the requesting reactive contract's address.
    function _deliver(uint256 idx) internal {
        (address subscriber, uint256 chainId, address recipient, uint64 gasLimit, bytes memory payload) =
            sys.callbackRequests(idx);
        assertEq(subscriber, address(reactive));
        assertEq(chainId, ORIGIN_CHAIN);
        assertEq(recipient, address(vault));
        assertEq(gasLimit, 1000000);
        bytes4 sel;
        assembly {
            sel := mload(add(payload, 32))
        }
        bytes memory injected = abi.encodeWithSelector(sel, address(reactive));
        vm.prank(PROXY);
        (bool ok, bytes memory ret) = recipient.call(injected);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function _selectorOf(uint256 idx) internal view returns (bytes4 sel) {
        (,,,, bytes memory payload) = sys.callbackRequests(idx);
        assembly {
            sel := mload(add(payload, 32))
        }
    }

    // ------------------------------------------------------------------
    // Act 1 + Act 3: silence -> trigger -> grace -> release
    // ------------------------------------------------------------------

    function testFullLifecycle_SilenceTriggerGraceRelease() public {
        _ping();
        assertEq(reactive.lastPingAt(), T0);

        // Silence. One second before the deadline: nothing happens.
        vm.warp(T0 + INACTIVITY - 1);
        _cron();
        assertEq(sys.callbackRequestsCount(), 0);

        // Past the inactivity period: the watcher requests the trigger.
        vm.warp(T0 + INACTIVITY + 1);
        _cron();
        assertEq(sys.callbackRequestsCount(), 1);
        (,,,, bytes memory payload) = sys.callbackRequests(0);
        assertEq(payload, abi.encodeWithSignature("triggerSwitch(address)", address(0)));
        _deliver(0);
        assertEq(uint256(vault.phase()), uint256(SwitchVault.Phase.Triggered));
        assertEq(vault.triggeredAt(), T0 + INACTIVITY + 1);

        // The vault's own clock refuses an early release, even via the
        // genuine proxy + genuine RSC identity.
        vm.prank(PROXY);
        vm.expectRevert(
            abi.encodeWithSelector(
                SwitchVault.GraceNotElapsed.selector, T0 + INACTIVITY + 1 + GRACE, block.timestamp
            )
        );
        vault.release(address(reactive));

        // Grace runs out with no ping: the watcher requests release.
        vm.warp(T0 + INACTIVITY + 1 + GRACE + 1);
        _cron();
        assertEq(sys.callbackRequestsCount(), 2);
        assertEq(_selectorOf(1), bytes4(keccak256("release(address)")));
        _deliver(1);

        assertEq(uint256(vault.phase()), uint256(SwitchVault.Phase.Released));
        assertEq(uint256(reactive.phase()), uint256(LastPingReactive.Phase.Released));
        assertEq(beneficiary.balance, ETH_DEPOSIT);
        assertEq(token.balanceOf(beneficiary), TOKEN_DEPOSIT);
        assertEq(address(vault).balance, 0);
        assertFalse(reactive.cronSubscribed());
    }

    // ------------------------------------------------------------------
    // Act 2: the save — a ping during grace cancels the trigger
    // ------------------------------------------------------------------

    function testTheSave_PingDuringGraceCancels() public {
        _ping();
        vm.warp(T0 + INACTIVITY + 1);
        _cron();
        _deliver(0);
        assertEq(uint256(vault.phase()), uint256(SwitchVault.Phase.Triggered));

        // Owner reappears 100 s into the 180 s grace window.
        vm.warp(T0 + INACTIVITY + 101);
        _ping();
        assertEq(sys.callbackRequestsCount(), 2);
        assertEq(_selectorOf(1), bytes4(keccak256("cancelTrigger(address)")));
        _deliver(1);
        assertEq(uint256(vault.phase()), uint256(SwitchVault.Phase.Armed));
        assertEq(vault.triggeredAt(), 0);
        assertEq(beneficiary.balance, 0);
        assertEq(token.balanceOf(beneficiary), 0);

        // The switch is live again: fresh silence re-triggers (not releases).
        vm.warp(block.timestamp + INACTIVITY + 1);
        _cron();
        assertEq(sys.callbackRequestsCount(), 3);
        assertEq(_selectorOf(2), bytes4(keccak256("triggerSwitch(address)")));
        _deliver(2);
        assertEq(uint256(vault.phase()), uint256(SwitchVault.Phase.Triggered));
        assertEq(beneficiary.balance, 0);
    }

    // ------------------------------------------------------------------
    // After release, the whole switch is inert
    // ------------------------------------------------------------------

    function testInertAfterRelease() public {
        _ping();
        vm.warp(T0 + INACTIVITY + 1);
        _cron();
        _deliver(0);
        vm.warp(T0 + INACTIVITY + 1 + GRACE + 1);
        _cron();
        _deliver(1);
        assertEq(uint256(vault.phase()), uint256(SwitchVault.Phase.Released));
        uint256 requests = sys.callbackRequestsCount();

        // More ticks and even a stray ping produce no new callbacks.
        vm.warp(block.timestamp + 10_000);
        _cron();
        _ping();
        assertEq(sys.callbackRequestsCount(), requests);
        assertEq(uint256(reactive.phase()), uint256(LastPingReactive.Phase.Released));

        // The vault refuses everything.
        vm.prank(PROXY);
        vm.expectRevert(SwitchVault.NotArmed.selector);
        vault.triggerSwitch(address(reactive));

        vm.prank(owner);
        vm.expectRevert(SwitchVault.SwitchInert.selector);
        vault.withdrawAll();
    }
}
