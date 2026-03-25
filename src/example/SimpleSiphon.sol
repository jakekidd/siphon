// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {SiphonToken} from "../SiphonToken.sol";

/**
 * @title SimpleSiphon — Example SiphonToken implementation
 * @notice Multi-mandate token. TERM_DAYS=30, MAX_TAPS=16. Transfers enabled.
 */
contract SimpleSiphon is SiphonToken {
    address public owner;
    address public scheduler;
    address public spender;

    modifier onlyOwner() { if (msg.sender != owner) revert Unauthorized(); _; }
    modifier onlyScheduler() { if (msg.sender != scheduler) revert Unauthorized(); _; }
    modifier onlySpender() { if (msg.sender != spender) revert Unauthorized(); _; }

    constructor(address _owner) SiphonToken(0, 30, 16) {
        owner = _owner;
    }

    function name() external pure returns (string memory) { return "SimpleSiphon"; }
    function symbol() external pure returns (string memory) { return "SIPH"; }
    function decimals() external pure returns (uint8) { return 18; }

    function setScheduler(address _scheduler) external onlyOwner { scheduler = _scheduler; }
    function setSpender(address _spender) external onlyOwner { spender = _spender; }
    function setListener(address _listener) external onlyOwner { _setListener(_listener); }

    function mint(address _user, uint128 _amount) external onlyOwner { _mint(_user, _amount); }

    function tapUser(address _user, address _beneficiary, uint128 _rate) external onlyScheduler {
        _tap(_user, _beneficiary, _rate);
    }

    function revokeUser(address _user, bytes32 _mid) external onlyScheduler {
        _revoke(_user, _mid);
    }

    function spend(address _user, uint128 _amount) external onlySpender { _spend(_user, _amount); }
}
