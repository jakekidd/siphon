// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {SiphonWallet} from "./SiphonWallet.sol";

contract SiphonFactory {
    error WalletExists();

    event WalletCreated(address indexed owner, address indexed wallet);

    mapping(address => address) public wallets;

    function createWallet() external returns (address wallet) {
        if (wallets[msg.sender] != address(0)) revert WalletExists();
        wallet = address(new SiphonWallet(msg.sender));
        wallets[msg.sender] = wallet;
        emit WalletCreated(msg.sender, wallet);
    }

    function getWallet(address _owner) external view returns (address) {
        return wallets[_owner];
    }
}
