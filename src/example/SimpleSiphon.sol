// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {SiphonToken} from "../SiphonToken.sol";

/**
 * @title SimpleSiphon — Example SiphonToken implementation
 * @notice Multi-schedule token with scheduler-managed assignments and burn schedules.
 *         TERM_DAYS=30, MAX_SUBS=16. Transfers enabled (standard ERC20).
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
    function setListener(address _listener) external onlyOwner { _setScheduleListener(_listener); }

    function mint(address _user, uint128 _amount) external onlyOwner { _mint(_user, _amount); }

    /// @notice Scheduler assigns a beneficiary schedule to a user.
    function assignSchedule(address _user, address _beneficiary, uint128 _rate) external onlyScheduler {
        _assign(_user, _beneficiary, _rate);
    }

    /// @notice Scheduler assigns a burn schedule to a user.
    function assignBurn(address _user, uint128 _rate) external onlyScheduler {
        _assign(_user, address(0), _rate);
    }

    /// @notice Scheduler terminates a specific schedule for a user.
    function terminateSub(address _user, bytes32 _sid) external onlyScheduler {
        _terminate(_user, _sid);
    }

    /// @notice Scheduler clears a specific schedule immediately.
    function clearSub(address _user, bytes32 _sid) external onlyScheduler {
        _clear(_user, _sid);
    }

    function spend(address _user, uint128 _amount) external onlySpender { _spend(_user, _amount); }
}
