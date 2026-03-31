// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {SiphonLite} from "../SiphonLite.sol";

// Minimal SiphonLite implementation for testing
contract SimpleLite is SiphonLite {
    address public owner;

    modifier onlyOwner() { if (msg.sender != owner) revert Unauthorized(); _; }

    constructor(address _owner) SiphonLite(0, 30, 32) {
        owner = _owner;
    }

    function name() external pure returns (string memory) { return "SimpleLite"; }
    function symbol() external pure returns (string memory) { return "LITE"; }
    function decimals() external pure returns (uint8) { return 18; }

    function mint(address _user, uint128 _amount) external onlyOwner { _mint(_user, _amount); }
    function spend(address _user, uint128 _amount) external onlyOwner { _spend(_user, _amount); }
    function setListener(address _listener) external onlyOwner { _setListener(_listener); }
}
