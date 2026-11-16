// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { LastPingReactive } from "../src/LastPingReactive.sol";
import { Heartbeat } from "../src/Heartbeat.sol";
import { MockSystemContract } from "./mocks/MockSystemContract.sol";

contract LastPingReactiveTest is Test {
    address payable internal constant SYSTEM_ADDR = payable(0x8888888888888888888888888888888888888888);
    address internal constant CRON_CONTRACT = 0x0000000000000000000000000000000000fffFfF;
    uint256 internal constant PING_TOPIC = 0xfd8d0c1dc3ab254ec49463a1192bb2423b3b851adedec1aa94dcd362dc063c9d;
    uint256 internal constant CRON100_TOPIC = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;
    uint256 internal constant REACTIVE_IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    uint256 internal constant ORIGIN_CHAIN = 84532; // Base Sepolia
    uint256 internal constant INACTIVITY = 300;
    uint256 internal constant GRACE = 180;
    uint256 internal constant T0 = 1_700_000_000;

    MockSystemContract internal sys;
    Heartbeat internal heartbeat;
    LastPingReactive internal reactive;
    address internal switchOwner = makeAddr("switchOwner");
    address internal vault = makeAddr("vault");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(T0);
        // Etch the recording mock over the real system contract address so
        // AbstractReactive's SYSTEM constant talks to it.
        MockSystemContract mock = new MockSystemContract();
        vm.etch(SYSTEM_ADDR, address(mock).code);
        sys = MockSystemContract(SYSTEM_ADDR);

        heartbeat = new Heartbeat();
        reactive = new LastPingReactive{ value: 0.1 ether }(
            ORIGIN_CHAIN, address(heartbeat), switchOwner, INACTIVITY, GRACE
        );
        reactive.setVault(vault);
    }

    // ------------------------------------------------------------------
    // LogRecord builders
    // ------------------------------------------------------------------

    function _pingLog(uint256 at) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chainId: ORIGIN_CHAIN,
            contractAddress: address(heartbeat),
            topic0: PING_TOPIC,
            topic1: uint256(uint160(switchOwner)),
            topic2: 0,
            topic3: 0,
            data: abi.encode(at),
            blockNumber: 1,
            opCode: 2,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function _cronLog() internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
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
    }

    function _react(IReactive.LogRecord memory log) internal {
        vm.prank(SYSTEM_ADDR);
        reactive.react(log);
    }

    function _requestSelector(uint256 idx) internal view returns (bytes4 sel) {
        (,,,, bytes memory payload) = sys.callbackRequests(idx);
        assembly {
            sel := mload(add(payload, 32))
        }
    }

    // ------------------------------------------------------------------

    function testConstructorSubscriptions() public view {
        assertEq(sys.subscriptionsCount(), 2);

        (address sub0, uint256 chain0, address contract0, uint256 topic00, uint256 topic01,,, bool active0) =
            sys.subscriptions(0);
        assertEq(sub0, address(reactive));
        assertEq(chain0, ORIGIN_CHAIN);
        assertEq(contract0, address(heartbeat));
        assertEq(topic00, PING_TOPIC);
        assertEq(topic01, uint256(uint160(switchOwner)));
        assertTrue(active0);

        (address sub1, uint256 chain1, address contract1, uint256 topic10, uint256 topic11,,, bool active1) =
            sys.subscriptions(1);
        assertEq(sub1, address(reactive));
        assertEq(chain1, block.chainid);
        assertEq(contract1, CRON_CONTRACT);
        assertEq(topic10, CRON100_TOPIC);
        assertEq(topic11, REACTIVE_IGNORE);
        assertTrue(active1);

        assertEq(reactive.lastPingAt(), T0);
        assertEq(uint256(reactive.phase()), uint256(LastPingReactive.Phase.Armed));
        assertTrue(reactive.cronSubscribed());
    }

    function testReactRevertsForNonSystem() public {
        vm.expectRevert(
            abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), SYSTEM_ADDR)
        );
        reactive.react(_pingLog(T0));
    }

    function testPingUpdatesLastPing() public {
        _react(_pingLog(T0 + 42));
        assertEq(reactive.lastPingAt(), T0 + 42);
        assertEq(sys.callbackRequestsCount(), 0);
    }

    function testCronBeforeInactivityDoesNothing() public {
        vm.warp(T0 + INACTIVITY - 1);
        _react(_cronLog());
        assertEq(sys.callbackRequestsCount(), 0);
        assertEq(uint256(reactive.phase()), uint256(LastPingReactive.Phase.Armed));
    }

    function testCronAfterSilenceRequestsTrigger() public {
        vm.warp(T0 + INACTIVITY + 1);
        _react(_cronLog());

        assertEq(uint256(reactive.phase()), uint256(LastPingReactive.Phase.Triggered));
        assertEq(reactive.triggeredAt(), T0 + INACTIVITY + 1);
        assertEq(sys.callbackRequestsCount(), 1);

        (address subscriber, uint256 chainId, address recipient, uint64 gasLimit, bytes memory payload) =
            sys.callbackRequests(0);
        assertEq(subscriber, address(reactive));
        assertEq(chainId, ORIGIN_CHAIN);
        assertEq(recipient, vault);
        assertEq(gasLimit, 1000000);
        // Exact payload: selector + address(0) placeholder the network overwrites.
        assertEq(payload, abi.encodeWithSignature("triggerSwitch(address)", address(0)));
        assertEq(_requestSelector(0), bytes4(keccak256("triggerSwitch(address)")));
    }

    function testPingDuringGraceRequestsCancel() public {
        vm.warp(T0 + INACTIVITY + 1);
        _react(_cronLog());
        assertEq(sys.callbackRequestsCount(), 1);

        vm.warp(T0 + INACTIVITY + 60); // inside the grace window
        _react(_pingLog(block.timestamp));

        assertEq(uint256(reactive.phase()), uint256(LastPingReactive.Phase.Armed));
        assertEq(reactive.triggeredAt(), 0);
        assertEq(reactive.lastPingAt(), block.timestamp);
        assertEq(sys.callbackRequestsCount(), 2);
        (,,,, bytes memory payload) = sys.callbackRequests(1);
        assertEq(payload, abi.encodeWithSignature("cancelTrigger(address)", address(0)));
    }

    function testCronWhileTriggeredBeforeGraceDoesNothing() public {
        vm.warp(T0 + INACTIVITY + 1);
        _react(_cronLog());
        vm.warp(T0 + INACTIVITY + GRACE - 1);
        _react(_cronLog());
        assertEq(sys.callbackRequestsCount(), 1);
        assertEq(uint256(reactive.phase()), uint256(LastPingReactive.Phase.Triggered));
    }

    function testCronAfterGraceRequestsReleaseAndUnsubscribes() public {
        vm.warp(T0 + INACTIVITY + 1);
        _react(_cronLog());
        vm.warp(T0 + INACTIVITY + GRACE + 2);
        _react(_cronLog());

        assertEq(uint256(reactive.phase()), uint256(LastPingReactive.Phase.Released));
        assertEq(sys.callbackRequestsCount(), 2);
        (,,,, bytes memory payload) = sys.callbackRequests(1);
        assertEq(payload, abi.encodeWithSignature("release(address)", address(0)));

        // CRON subscription dropped: the watcher stops billing ticks.
        assertFalse(reactive.cronSubscribed());
        (,,,,,,, bool cronActive) = sys.subscriptions(1);
        assertFalse(cronActive);
        // Ping subscription is untouched.
        (,,,,,,, bool pingActive) = sys.subscriptions(0);
        assertTrue(pingActive);
    }

    function testSetVaultOnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(LastPingReactive.NotOwner.selector);
        reactive.setVault(stranger);
        assertEq(reactive.vault(), vault);
    }

    function testUnrelatedLogIgnored() public {
        IReactive.LogRecord memory log = _cronLog();
        log.topic0 = 0xdeadbeef;
        _react(log);
        log = _pingLog(T0 + 10);
        log.contractAddress = stranger;
        _react(log);
        assertEq(reactive.lastPingAt(), T0);
        assertEq(sys.callbackRequestsCount(), 0);
    }
}
