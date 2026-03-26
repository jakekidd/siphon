// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {SiphonToken} from "../SiphonToken.sol";

/**
 * @title Timeshare — Rotating payment responsibility among multiple users
 *
 * @notice NAIVE IMPLEMENTATION. UNTESTED. DO NOT USE IN PRODUCTION.
 *
 *   This contract demonstrates the concept of rotating payment responsibility
 *   but is missing the core capability: automated rotation with configurable
 *   per-user payment schedules (e.g., user A pays 11 months, user B pays 1).
 *
 *   Current implementation uses manual rotate() calls which is not automatable
 *   and doesn't support asymmetric rotations.
 *
 * @dev TODO: Full timeshare implementation options:
 *
 *   OPTION A (preferred): Deploy a shared pool contract that all members pay
 *   into (each with their own Tap at their proportional rate). The pool holds
 *   the combined funds and has its own Tap to the actual beneficiary at the
 *   full rate. Members configure which epochs they cover; the pool contract
 *   handles the mapping of "which user funds which epoch." This keeps
 *   SiphonToken unchanged and pushes rotation logic to the pool layer.
 *
 *   OPTION B: Expand Tap to support an array of users with rotation config.
 *   The beneficiary still gets paid at the same rate; the cost is split among
 *   members per a rotation schedule. balanceOf for each user would need to
 *   account for which epochs they're responsible for. This is complex and
 *   would require a specialized SiphonToken variant.
 *
 *   OPTION C (current, naive): Manual rotate() that revokes one user and taps
 *   the next. Simple but requires external automation and doesn't support
 *   asymmetric cost splitting.
 *
 *   The key insight: the beneficiary doesn't care who pays. They get rate per
 *   term regardless. The rotation is purely a payer-side concern. Option A
 *   captures this cleanly; the pool is the single payer from the beneficiary's
 *   perspective, and internal accounting handles the split.
 */
contract Timeshare {
    constructor() {
        revert("Timeshare: not implemented; see contract comments for design options");
    }
}
