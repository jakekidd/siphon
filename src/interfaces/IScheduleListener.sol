// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title IScheduleListener — Callback for SiphonToken schedule changes
/// @notice Implement this on contracts that need to react to payment schedule
///         state changes (e.g. subscription managers tracking validity).
interface IScheduleListener {
    /// @notice Called by a SiphonToken when a user's schedule changes.
    /// @param token The SiphonToken contract address
    /// @param user The user whose schedule changed
    /// @param active True if the schedule is active, false if ended (settled/cleared/canceled-expired)
    function onScheduleUpdate(address token, address user, bool active) external;
}
