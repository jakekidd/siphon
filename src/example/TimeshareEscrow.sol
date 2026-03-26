// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {SiphonToken} from "../SiphonToken.sol";

/**
 * @title TimeshareEscrow — Per-agreement pool for Timeshare
 * @notice Holds deposited tokens from timeshare members. Gets tapped by the
 *         Timeshare contract (beneficiary). Authorizes the mandate, stores
 *         agreement metadata, and supports refunds.
 *
 *         One escrow is deployed per agreement. Members cannot withdraw
 *         directly; only the Timeshare contract can move tokens out.
 */
contract TimeshareEscrow {
    SiphonToken public immutable token;
    address public immutable timeshare;

    uint128 public rate;
    uint16 public termsPerSeason;
    uint8 public memberCount;
    bool public initialized;

    error Unauthorized();
    error AlreadyInitialized();

    modifier onlyTimeshare() {
        if (msg.sender != timeshare) revert Unauthorized();
        _;
    }

    constructor(address _token, address _timeshare) {
        token = SiphonToken(_token);
        timeshare = _timeshare;
    }

    /// @notice Set agreement parameters. Called once by Timeshare after deploy.
    function initialize(uint128 _rate, uint16 _termsPerSeason, uint8 _memberCount) external onlyTimeshare {
        if (initialized) revert AlreadyInitialized();
        rate = _rate;
        termsPerSeason = _termsPerSeason;
        memberCount = _memberCount;
        initialized = true;
    }

    /// @notice Authorize the mandate on the token. The escrow computes the
    ///         mandateId from its own state and authorizes itself to be tapped.
    function setup(uint256 _count) external onlyTimeshare {
        bytes32 mid = token.mandateId(timeshare, rate);
        token.authorize(mid, _count);
    }

    /// @notice Transfer tokens out. Used for refunds on failed activations
    ///         or returning leftover after mid-season revoke.
    function refund(address _to, uint128 _amount) external onlyTimeshare {
        token.transfer(_to, _amount);
    }

    /// @notice The mandateId this escrow is subject to.
    function mandateId() external view returns (bytes32) {
        return token.mandateId(timeshare, rate);
    }

    /// @notice Total deposit required before activation.
    function totalRequired() external view returns (uint128) {
        return uint128(uint256(rate) * uint256(termsPerSeason));
    }

    /// @notice Each member's share of the total deposit.
    function sharePerMember() external view returns (uint128) {
        return uint128(uint256(rate) * uint256(termsPerSeason) / uint256(memberCount));
    }
}
