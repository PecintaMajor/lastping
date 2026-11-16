// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { Heartbeat } from "../src/Heartbeat.sol";

contract HeartbeatTest is Test {
    Heartbeat internal heartbeat;
    address internal owner = makeAddr("owner");
    address internal other = makeAddr("other");
    address internal beneficiary = makeAddr("beneficiary");

    function setUp() public {
        heartbeat = new Heartbeat();
        vm.warp(1_700_000_000);
    }

    function testPingEmitsAndRecords() public {
        vm.expectEmit(true, false, false, true, address(heartbeat));
        emit Heartbeat.Ping(owner, block.timestamp);
        vm.prank(owner);
        heartbeat.ping();
        assertEq(heartbeat.lastPingAt(owner), block.timestamp);
    }

    function testRegisterEmitsAndStores() public {
        vm.expectEmit(true, true, false, false, address(heartbeat));
        emit Heartbeat.Registered(owner, beneficiary);
        vm.prank(owner);
        heartbeat.register(beneficiary);
        assertEq(heartbeat.beneficiaryOf(owner), beneficiary);
    }

    function testPingClocksArePerSender() public {
        vm.prank(owner);
        heartbeat.ping();
        vm.warp(block.timestamp + 600);
        vm.prank(other);
        heartbeat.ping();
        assertEq(heartbeat.lastPingAt(owner), 1_700_000_000);
        assertEq(heartbeat.lastPingAt(other), 1_700_000_600);
    }
}
