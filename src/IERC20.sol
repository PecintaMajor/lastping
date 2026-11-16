// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

/// @title Minimal ERC-20 surface used by SwitchVault.
interface IERC20 {
    function balanceOf(address account_) external view returns (uint256);
    function transfer(address to_, uint256 amount_) external returns (bool);
    function transferFrom(address from_, address to_, uint256 amount_) external returns (bool);
}
