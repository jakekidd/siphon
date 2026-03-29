// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {SiphonToken} from "../SiphonToken.sol";
import {IMandateListener} from "../interfaces/IMandateListener.sol";

/**
 * @title Payroll : Employer pays employees via SiphonToken mandates
 * @notice Demonstrates the "one payer, many beneficiaries" pattern.
 *
 *         The employer holds tokens. Each employee is a beneficiary at their
 *         salary rate. The employer's balance decays as salaries are paid.
 *
 *         This contract is bookkeeping only : it tracks the roster and
 *         provides views. The employer and employees interact with the
 *         token directly for mandate operations:
 *
 *         1. Employer: token.authorize(mandateId(employee, salary), max)
 *         2. Employee: token.tap(employer, salary)   : activates pay
 *         3. Employee: token.harvest(employee, salary, epochs) : collects pay
 *         4. Employer: token.revoke(employer, mandateId)  : terminates pay
 *
 *         Uses IMandateListener to detect when payroll funds lapse.
 */
contract Payroll is IMandateListener {
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

    /// @notice Add an employee to the roster. Employer must separately
    ///         authorize the mandate on the token. Employee then calls
    ///         token.tap(employer, salary) to activate their pay.
    function hire(address _employee, string calldata _title, uint128 _salary) external onlyEmployer {
        if (employees[_employee].active) revert AlreadyEmployed();
        employees[_employee] = Employee(_title, _salary, true);
        roster.push(_employee);
        emit Hired(_employee, _title, _salary);
    }

    /// @notice Remove an employee from the roster. Employer must separately
    ///         revoke the mandate on the token.
    function terminate(address _employee) external onlyEmployer {
        Employee storage emp = employees[_employee];
        if (!emp.active) revert NotEmployee();
        emp.active = false;
        emit Terminated(_employee);
    }

    // ── Views ──

    /// @notice Check if payroll is funded for an employee.
    function isPaid(address _employee) external view returns (bool) {
        Employee storage emp = employees[_employee];
        if (!emp.active) return false;
        bytes32 mid = token.mandateId(_employee, emp.salary);
        return token.isTapActive(employer, mid);
    }

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
    function onMandateUpdate(address, address _user, bool _active) external {
        if (msg.sender != address(token)) return;
        if (_user == employer && !_active) {
            emit PayrollLapsed(employer);
        }
    }
}
