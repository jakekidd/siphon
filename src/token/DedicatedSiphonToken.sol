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
 *         Additionally supports fixed-term mandates via tapFor(): the beneficiary
 *         can set a hard termination after N billing periods. Both balanceOf and
 *         bucket accounting respect the cap. This enables "autopay for exactly 3
 *         months" without draining the user's full balance.
 *
 *         Use this when the token represents managed credits (prepaid balances,
 *         platform credits, service plans) where the issuer is the sole beneficiary
 *         and users consent to mandate assignment by holding the token.
 *
 * @dev Inheritors must implement name/symbol/decimals, access control, and
 *      provide a mechanism to update the beneficiary (e.g. onlyAdmin setter).
 *      Storage: adds 3 slots (beneficiary, _maxExit, _maxPeriods) at slots 14-16.
 *      Inheritors start at 17+.
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
    // State (slots 14-16)
    // ──────────────────────────────────────────────

    /// @notice The sole address allowed to create mandates (tap/comp).
    address public beneficiary;

    /// @notice Per-user per-mandate hard exit epoch for bucket accounting.
    mapping(address => mapping(bytes32 => uint32)) internal _maxExit;

    /// @notice Per-user max billing periods. Caps _periodsElapsed so balanceOf
    ///         stops decaying after this many periods. 0 = unlimited.
    mapping(address => uint256) internal _maxPeriods;

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

    /// @notice Tap a user into an unlimited mandate. Only the beneficiary can call.
    ///         No per-user authorization required.
    function tap(address _user, uint128 _rate) external virtual override {
        if (msg.sender != beneficiary) revert NotBeneficiary();
        _maxPeriods[_user] = 0; // clear any previous cap
        _tap(_user, msg.sender, _rate);
    }

    /// @notice Tap a user with a fixed-term cap. After _maxEpochs billing
    ///         periods the mandate auto-terminates regardless of balance.
    ///         Pass 0 for unlimited (same as tap()).
    function tapFor(address _user, uint128 _rate, uint16 _maxEpochs) external virtual {
        if (msg.sender != beneficiary) revert NotBeneficiary();

        if (_maxEpochs == 0) {
            _maxPeriods[_user] = 0;
        } else {
            _maxPeriods[_user] = _maxEpochs;
        }

        _tap(_user, msg.sender, _rate);

        if (_maxEpochs > 0) {
            // Cap the bucket exit epoch
            bytes32 mid = _mandateId(msg.sender, _rate);
            uint32 cap = uint32(_epochOf() + 1 + _maxEpochs);
            _maxExit[_user][mid] = cap;
            Tap storage t = _taps[_user][mid];
            if (t.exitEpoch > cap) {
                _exits[mid][t.exitEpoch]--;
                _exits[mid][cap]++;
                t.exitEpoch = cap;
            }
        }
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

    /// @notice Read the max exit epoch for a mandate (0 = unlimited).
    function maxExit(address _user, bytes32 _mid) external view returns (uint32) {
        return _maxExit[_user][_mid];
    }

    /// @notice Read the max billing periods for a user (0 = unlimited).
    function maxPeriods(address _user) external view returns (uint256) {
        return _maxPeriods[_user];
    }

    // ──────────────────────────────────────────────
    // Internal overrides
    // ──────────────────────────────────────────────

    /// @dev Cap periods elapsed at the user's maxPeriods. This makes balanceOf
    ///      stop decaying after the fixed term, even if the user has outflow.
    function _periodsElapsed(address _user) internal view virtual override returns (uint256) {
        uint32 anch = _anchor[_user];
        uint256 today = _today();
        if (today <= uint256(anch)) return 0;
        uint256 elapsed = (today - uint256(anch)) / uint256(TERM_DAYS);
        uint256 cap = _maxPeriods[_user];
        if (cap > 0 && elapsed > cap) return cap;
        return elapsed;
    }

    /// @dev Recompute exits with maxExit cap. If a tap has a maxExit set,
    ///      the exit epoch is capped at that value.
    function _recomputeAllExits(address _user) internal virtual override {
        Account storage a = _accounts[_user];
        bytes32[] storage taps = _userTaps[_user];
        uint256 baseEpoch = _anchorEpoch(_user);
        uint256 sharedFunded = _funded(a);
        uint256 naturalExit = baseEpoch + 1 + sharedFunded;

        for (uint256 i; i < taps.length; i++) {
            bytes32 mid = taps[i];
            Tap storage t = _taps[_user][mid];
            bool isBurn = _mandateId(address(0), t.rate) == mid;
            if (isBurn) continue;

            uint256 newExit = naturalExit;
            uint32 cap = _maxExit[_user][mid];
            if (cap > 0 && newExit > cap) {
                newExit = cap;
            }

            uint32 oldExit = t.exitEpoch;
            if (uint256(oldExit) != newExit) {
                if (oldExit > 0) _exits[mid][uint256(oldExit)]--;
                _exits[mid][newExit]++;
                t.exitEpoch = uint32(newExit);
            }
        }
    }

    /// @dev Set the beneficiary. Called by inheritor's admin setter.
    function _setBeneficiary(address _newBeneficiary) internal {
        beneficiary = _newBeneficiary;
    }
}
