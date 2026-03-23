// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {SiphonToken} from "../SiphonToken.sol";

/**
 * @title SimpleSiphon — Example SiphonToken implementation
 * @notice Demonstrates a subscription-style token where an authorized scheduler
 *         sets payment schedules and a spender makes one-time deductions.
 *         Transfers are enabled by default (standard ERC20).
 */
contract SimpleSiphon is SiphonToken {
    address public owner;
    address public scheduler;
    address public spender;

    uint256 public constant MAX_TOTAL = 12;

    error Unauthorized();

    modifier onlyOwner() { if (msg.sender != owner) revert Unauthorized(); _; }
    modifier onlyScheduler() { if (msg.sender != scheduler) revert Unauthorized(); _; }
    modifier onlySpender() { if (msg.sender != spender) revert Unauthorized(); _; }

    constructor(address _owner) { owner = _owner; }

    function _maxTotalPeriods() internal pure override returns (uint256) { return MAX_TOTAL; }
    function name() external pure returns (string memory) { return "SimpleSiphon"; }
    function symbol() external pure returns (string memory) { return "SIPH"; }
    function decimals() external pure returns (uint8) { return 18; }

    function setScheduler(address _scheduler) external onlyOwner { scheduler = _scheduler; }
    function setSpender(address _spender) external onlyOwner { spender = _spender; }
    function setListener(address _listener) external onlyOwner { _setScheduleListener(_listener); }

    function mint(address _user, uint128 _amount) external onlyOwner { _mint(_user, _amount); }

    function setSchedule(address _user, uint128 _rate, uint32 _interval, uint16 _cap, uint16 _gracePeriods)
        external onlyScheduler { _setSchedule(_user, _rate, _interval, _cap, _gracePeriods); }
    function terminateSchedule(address _user) external onlyScheduler { _terminateSchedule(_user); }
    function clearSchedule(address _user) external onlyScheduler { _clearSchedule(_user); }
    function addGracePeriods(address _user, uint16 _periods) external onlyScheduler { _addGracePeriods(_user, _periods); }

    function spend(address _user, uint128 _amount) external onlySpender { _spend(_user, _amount); }

    function setCap(uint16 _cap) external { _setCap(msg.sender, _cap); }
}
