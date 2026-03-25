// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {SiphonToken} from "../SiphonToken.sol";

/**
 * @title SimpleSiphon — Example SiphonToken implementation
 * @notice Demonstrates both burn-path and beneficiary schedules.
 *         Scheduler manages assignments, spender makes one-time deductions.
 *         Transfers are enabled (standard ERC20).
 */
contract SimpleSiphon is SiphonToken {
    address public owner;
    address public scheduler;
    address public spender;

    error Unauthorized();

    modifier onlyOwner() { if (msg.sender != owner) revert Unauthorized(); _; }
    modifier onlyScheduler() { if (msg.sender != scheduler) revert Unauthorized(); _; }
    modifier onlySpender() { if (msg.sender != spender) revert Unauthorized(); _; }

    constructor(address _owner) SiphonToken(0) {
        owner = _owner;
    }

    function name() external pure returns (string memory) { return "SimpleSiphon"; }
    function symbol() external pure returns (string memory) { return "SIPH"; }
    function decimals() external pure returns (uint8) { return 18; }

    function setScheduler(address _scheduler) external onlyOwner { scheduler = _scheduler; }
    function setSpender(address _spender) external onlyOwner { spender = _spender; }
    function setListener(address _listener) external onlyOwner { _setScheduleListener(_listener); }

    function mint(address _user, uint128 _amount) external onlyOwner { _mint(_user, _amount); }

    /// @notice Scheduler assigns a beneficiary schedule to a user (consumes schedule approval).
    function assignSchedule(
        address _user, address _to, uint128 _rate, uint16 _interval
    ) external onlyScheduler {
        _assign(_user, _to, _rate, _interval);
    }

    /// @notice Scheduler sets a burn-path schedule (no beneficiary, no buckets).
    function setSchedule(
        address _user, uint128 _rate, uint16 _interval
    ) external onlyScheduler {
        _setSchedule(_user, _rate, _interval);
    }

    function comp(address _user, uint8 _periods) external onlyScheduler { _comp(_user, _periods); }
    function terminateSchedule(address _user) external onlyScheduler { _terminateSchedule(_user); }
    function clearSchedule(address _user) external onlyScheduler { _clearSchedule(_user); }

    function spend(address _user, uint128 _amount) external onlySpender { _spend(_user, _amount); }
}
