// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {SiphonToken} from "./SiphonToken.sol";

/**
 * @title DedicatedSiphonToken: SiphonToken with a single trusted beneficiary
 * @author jakekidd
 *
 * @notice Variant of SiphonToken where a single designated beneficiary can set up
 *         mandates on any user without per-user authorization. The authorize()
 *         system from the base contract is disabled.
 *
 *         Use this when the token represents managed credits (prepaid balances,
 *         platform credits, service plans) where the issuer is the sole beneficiary
 *         and users consent to mandate assignment by holding the token.
 *
 *         The trust model is simple: by depositing or receiving tokens, users
 *         accept that the beneficiary can tap them. The beneficiary is a protocol
 *         contract (e.g. a subscription manager), not an arbitrary address.
 *
 * @dev Inheritors must implement name/symbol/decimals, access control, and
 *      provide a mechanism to update the beneficiary (e.g. onlyAdmin setter).
 *      Storage: adds 1 slot (beneficiary) at slot 14. Inheritors start at 15+.
 */
abstract contract DedicatedSiphonToken is SiphonToken {
    // ──────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────

    /// @notice Caller is not the designated beneficiary.
    error NotBeneficiary();

    /// @notice Authorization is disabled on this token variant.
    error AuthorizationDisabled();

    // ──────────────────────────────────────────────
    // State (slot 14)
    // ──────────────────────────────────────────────

    /// @notice The sole address allowed to create mandates (tap/comp).
    ///         Typically a subscription manager contract (e.g. uCovenant).
    address public beneficiary;

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    constructor(
        uint32 _genesisDay,
        uint16 _termDays,
        uint8 _maxTaps
    ) SiphonToken(_genesisDay, _termDays, _maxTaps) {}

    // ──────────────────────────────────────────────
    // Overrides
    // ──────────────────────────────────────────────

    /// @notice Tap a user into a mandate. Only the beneficiary can call.
    ///         No per-user authorization required.
    function tap(address _user, uint128 _rate) external virtual override {
        if (msg.sender != beneficiary) revert NotBeneficiary();
        _tap(_user, msg.sender, _rate);
    }

    /// @notice Comp a user. Only the beneficiary can call.
    function comp(address _user, uint128 _rate, uint16 _epochs) external virtual override {
        if (msg.sender != beneficiary) revert NotBeneficiary();
        bytes32 mid = _mandateId(msg.sender, _rate);
        _comp(_user, mid, _epochs);
    }

    /// @notice Authorization is disabled. Reverts unconditionally.
    function authorize(bytes32, uint256) external pure override {
        revert AuthorizationDisabled();
    }

    // ──────────────────────────────────────────────
    // Internal
    // ──────────────────────────────────────────────

    /// @dev Set the beneficiary. Called by inheritor's admin setter.
    function _setBeneficiary(address _newBeneficiary) internal {
        beneficiary = _newBeneficiary;
    }
}
