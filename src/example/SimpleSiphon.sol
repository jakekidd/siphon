// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {SiphonToken} from "../SiphonToken.sol";

/**
 * @title SimpleSiphon — Example SiphonToken implementation
 * @notice Demonstrates a subscription-style token where an authorized scheduler
 *         sets payment schedules and a spender makes one-time deductions.
 *         Mirrors the Ubitel use case: subscription service + marketplace.
 */
contract SimpleSiphon is SiphonToken {
    address public owner;
    address public scheduler;
    address public spender;

    uint256 public constant MAX_PREPAID = 12;

    error Unauthorized();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyScheduler() {
        if (msg.sender != scheduler) revert Unauthorized();
        _;
    }

    modifier onlySpender() {
        if (msg.sender != spender) revert Unauthorized();
        _;
    }

    constructor(address _owner) {
        owner = _owner;
    }

    function _maxPrepaidPeriods() internal pure override returns (uint256) {
        return MAX_PREPAID;
    }

    function name() external pure returns (string memory) {
        return "SimpleSiphon";
    }

    function symbol() external pure returns (string memory) {
        return "SIPH";
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    // ── Admin ──

    function setScheduler(
        address _scheduler
    ) external onlyOwner {
        scheduler = _scheduler;
    }

    function setSpender(
        address _spender
    ) external onlyOwner {
        spender = _spender;
    }

    function setListener(
        address _listener
    ) external onlyOwner {
        scheduleListener = _listener;
    }

    // ── Mint (owner only) ──

    function mint(address _user, uint128 _amount) external onlyOwner {
        _mint(_user, _amount);
    }

    // ── Scheduler ──

    function setSchedule(
        address _user,
        uint128 _rate,
        uint32 _periodDays,
        uint16 _maxPeriods,
        uint16 _skipPeriods
    ) external onlyScheduler {
        _setSchedule(_user, _rate, _periodDays, _maxPeriods, _skipPeriods);
    }

    function cancelSchedule(
        address _user
    ) external onlyScheduler {
        _cancelSchedule(_user);
    }

    function clearSchedule(
        address _user
    ) external onlyScheduler {
        _clearSchedule(_user);
    }

    function addSkipPeriods(
        address _user,
        uint16 _periods
    ) external onlyScheduler {
        _addSkipPeriods(_user, _periods);
    }

    // ── Spender ──

    function spend(
        address _user,
        uint128 _amount
    ) external onlySpender {
        _spend(_user, _amount);
    }

    // ── User ──

    function setMaxPeriods(
        uint16 _maxPeriods
    ) external {
        _setMaxPeriods(msg.sender, _maxPeriods);
    }
}
