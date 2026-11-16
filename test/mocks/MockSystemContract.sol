// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";

/// @title MockSystemContract — test double for the Reactive system contract.
/// @notice Etched over the real system contract address (0x8888...8888) in
///         tests. Records every subscription and callback request so tests can
///         assert exactly what a reactive contract asked the network to do,
///         and lets tests deliver recorded callbacks the way the real
///         callback proxy would.
contract MockSystemContract is ISystemContract {
    struct Subscription {
        address subscriber;
        uint256 chainId;
        address contractAddress;
        uint256 topic0;
        uint256 topic1;
        uint256 topic2;
        uint256 topic3;
        bool active;
    }

    struct CallbackRequest {
        address subscriber;
        uint256 chainId;
        address recipient;
        uint64 gasLimit;
        bytes payload;
    }

    Subscription[] public subscriptions;
    CallbackRequest[] public callbackRequests;
    mapping(address => uint256) public debts;

    function subscribe(
        uint256 chainId_,
        address contract_,
        uint256 topic0_,
        uint256 topic1_,
        uint256 topic2_,
        uint256 topic3_
    ) external override {
        subscriptions.push(Subscription(msg.sender, chainId_, contract_, topic0_, topic1_, topic2_, topic3_, true));
    }

    function unsubscribe(
        uint256 chainId_,
        address contract_,
        uint256 topic0_,
        uint256 topic1_,
        uint256 topic2_,
        uint256 topic3_
    ) external override {
        for (uint256 i = 0; i < subscriptions.length; i++) {
            Subscription storage s = subscriptions[i];
            if (
                s.active && s.subscriber == msg.sender && s.chainId == chainId_ && s.contractAddress == contract_
                    && s.topic0 == topic0_ && s.topic1 == topic1_ && s.topic2 == topic2_ && s.topic3 == topic3_
            ) {
                s.active = false;
            }
        }
    }

    function requestCallbackV_1_0(CallbackConfiguration_V_1_0 memory config_) external override {
        callbackRequests.push(
            CallbackRequest(msg.sender, config_.chainId, config_.recipient, config_.gasLimit, config_.payload)
        );
    }

    function requestCallback(CallbackVersion version_, bytes memory config_) external override {
        version_;
        CallbackConfiguration_V_1_0 memory cfg = abi.decode(config_, (CallbackConfiguration_V_1_0));
        callbackRequests.push(CallbackRequest(msg.sender, cfg.chainId, cfg.recipient, cfg.gasLimit, cfg.payload));
    }

    function debt(address contract_) external view override returns (uint256) {
        return debts[contract_];
    }

    function setDebt(address contract_, uint256 amount_) external {
        debts[contract_] = amount_;
    }

    receive() external payable override { }

    function subscriptionsCount() external view returns (uint256) {
        return subscriptions.length;
    }

    function callbackRequestsCount() external view returns (uint256) {
        return callbackRequests.length;
    }
}
