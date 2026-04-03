// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title IMandateListener: Callback for SiphonToken mandate state changes
/// @notice Implement this on contracts that need to react when a user's
///         mandates change (e.g. subscription managers tracking validity).
interface IMandateListener {
    /// @notice Called by a SiphonToken when a user's mandate state changes.
    /// @param token The SiphonToken contract address
    /// @param user The user whose mandate changed
    /// @param active True if the user has active mandates, false if all ended
    function onMandateUpdate(address token, address user, bool active) external;
}
