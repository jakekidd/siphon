// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {SiphonToken} from "../SiphonToken.sol";
import {IScheduleListener} from "../interfaces/IScheduleListener.sol";

/**
 * @title Payroll — Employer pays employees via SiphonToken mandates
 * @notice Demonstrates: employer as user with multiple taps to different
 *         beneficiaries at different rates. Employees harvest their own pay.
 *         Uses IScheduleListener to detect when payroll taps lapse.
 *
 *         The employer holds tokens. Each employee is a beneficiary with a
 *         mandate at their salary rate. The employer's balance decays as
 *         salaries are paid. Employees call harvest() to collect.
 */
contract Payroll is IScheduleListener {
    SiphonToken public immutable token;
    address public employer;

    struct Employee {
        string title;
        uint128 salary; // per term
        bool active;
    }

    mapping(address => Employee) public employees;
    address[] public roster;

    event Hired(address indexed employee, string title, uint128 salary);
    event Terminated(address indexed employee);
    event PayrollLapsed(address indexed employer);

    error Unauthorized();
    error NotEmployee();
    error AlreadyEmployed();

    modifier onlyEmployer() { if (msg.sender != employer) revert Unauthorized(); _; }

    constructor(address _token, address _employer) {
        token = SiphonToken(_token);
        employer = _employer;
    }

    // ── Admin ──

    /// @notice Hire an employee. Employer must have authorized the mandate
    ///         for this employee's salary: token.authorize(mandateId, type(uint256).max)
    ///         (infinite authorization since payroll is ongoing).
    function hire(address _employee, string calldata _title, uint128 _salary) external onlyEmployer {
        if (employees[_employee].active) revert AlreadyEmployed();

        employees[_employee] = Employee(_title, _salary, true);
        roster.push(_employee);

        // Employee (beneficiary) taps the employer (user)
        // The employee calls tap() since they are the beneficiary (msg.sender)
        // Actually: the employer authorized the mandate. The employee calls tap().
        // But tap() requires msg.sender == beneficiary. So the employee must call it.
        // For onboarding, the employer can't call tap on behalf of the employee.
        // Solution: we call _tap internally if we inherit SiphonToken, or the
        // employee calls tap() themselves after being added to the roster.

        emit Hired(_employee, _title, _salary);
    }

    /// @notice Employee activates their payroll tap. Call after being hired.
    ///         The employee IS the beneficiary; they call tap() on the token
    ///         which draws from the employer's balance.
    function activate() external {
        Employee storage emp = employees[msg.sender];
        if (!emp.active) revert NotEmployee();

        // msg.sender (employee) is the beneficiary; employer is the user being tapped
        token.tap(employer, emp.salary);
    }

    /// @notice Terminate an employee's payroll. Employer revokes the mandate.
    function terminate(address _employee) external onlyEmployer {
        Employee storage emp = employees[_employee];
        if (!emp.active) revert NotEmployee();

        bytes32 mid = token.mandateId(_employee, emp.salary);
        token.revoke(employer, mid);
        emp.active = false;

        emit Terminated(_employee);
    }

    // ── Employee flow ──

    /// @notice Employee collects their salary.
    function collectSalary(uint256 _maxEpochs) external {
        Employee storage emp = employees[msg.sender];
        if (!emp.active) revert NotEmployee();

        token.harvest(msg.sender, emp.salary, _maxEpochs);
    }

    /// @notice Check if payroll is funded for an employee.
    function isPaid(address _employee) external view returns (bool) {
        Employee storage emp = employees[_employee];
        if (!emp.active) return false;
        bytes32 mid = token.mandateId(_employee, emp.salary);
        return token.isTapActive(employer, mid);
    }

    // ── Views ──

    function rosterSize() external view returns (uint256) {
        return roster.length;
    }

    function totalPayroll() external view returns (uint256 total) {
        for (uint256 i; i < roster.length; i++) {
            Employee storage emp = employees[roster[i]];
            if (emp.active) total += emp.salary;
        }
    }

    // ── Listener callback ──

    /// @notice Called by the token when the employer's schedule state changes.
    ///         Detects when payroll funds run out.
    function onScheduleUpdate(address _token, address _user, bool _active) external {
        if (msg.sender != address(token)) return;
        if (_user != employer && !_active) {
            emit PayrollLapsed(employer);
        }
    }
}
