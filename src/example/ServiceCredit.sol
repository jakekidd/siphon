// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {SiphonToken} from "../SiphonToken.sol";

/**
 * @title ServiceCredit: Subscription + pay-per-use via mandate and spend
 * @notice Demonstrates composing mandates (recurring base fee) with spend
 *         (one-time usage charges) from the same balance. The token IS the
 *         credit system: users hold tokens, the base subscription drains
 *         automatically, and usage charges deduct on demand.
 *
 *         Analogous to: cloud compute credits, API platforms, bandwidth
 *         billing, or any "base + overage" model.
 *
 * @dev This contract extends SiphonToken (is the token itself), unlike
 *      other examples that wrap an external SiphonToken instance.
 *      This pattern is natural when the service IS the credit system.
 */
contract ServiceCredit is SiphonToken {
    address public owner;
    address public operator; // backend/oracle that reports usage

    struct Tier {
        string name;
        uint128 baseFee;     // per-term recurring fee via mandate
        uint128 usageRate;   // cost per unit of usage via spend
        bool active;
    }

    mapping(uint256 => Tier) public tiers;
    uint256 public tierCount;

    mapping(address => uint256) public userTier; // 0 = not subscribed

    event TierCreated(uint256 indexed tierId, string name, uint128 baseFee, uint128 usageRate);
    event Enrolled(address indexed user, uint256 indexed tierId);
    event Unenrolled(address indexed user, uint256 indexed tierId);
    event UsageCharged(address indexed user, uint256 units, uint128 cost);

    error InvalidTier();
    error NotEnrolled();
    error AlreadyEnrolled();

    modifier onlyOwner() { if (msg.sender != owner) revert Unauthorized(); _; }
    modifier onlyOperator() { if (msg.sender != operator) revert Unauthorized(); _; }

    constructor(address _owner, address _operator) SiphonToken(0, 30, 16) {
        owner = _owner;
        operator = _operator;
    }

    function name() external pure returns (string memory) { return "ServiceCredit"; }
    function symbol() external pure returns (string memory) { return "SVC"; }
    function decimals() external pure returns (uint8) { return 18; }

    // ── Admin ──

    function createTier(
        string calldata _name,
        uint128 _baseFee,
        uint128 _usageRate
    ) external onlyOwner returns (uint256 id) {
        id = ++tierCount;
        tiers[id] = Tier(_name, _baseFee, _usageRate, true);
        emit TierCreated(id, _name, _baseFee, _usageRate);
    }

    function deactivateTier(uint256 _tierId) external onlyOwner {
        tiers[_tierId].active = false;
    }

    function mint(address _user, uint128 _amount) external onlyOwner {
        _mint(_user, _amount);
    }

    function setOperator(address _operator) external onlyOwner {
        operator = _operator;
    }

    // ── User flow ──

    /// @notice Enroll in a tier. Starts the recurring base fee mandate.
    ///         User must have called authorize(mandateId, 1) first.
    function enroll(uint256 _tierId) external {
        Tier storage tier = tiers[_tierId];
        if (!tier.active || tier.baseFee == 0) revert InvalidTier();

        uint256 oldTierId = userTier[msg.sender];
        if (oldTierId != 0) {
            Tier storage oldTier = tiers[oldTierId];
            bytes32 oldMid = _mandateId(address(this), oldTier.baseFee);
            if (_isTapActive(msg.sender, oldMid)) revert AlreadyEnrolled();
            // Old enrollment lapsed; clear it
        }

        userTier[msg.sender] = _tierId;
        // This contract IS the beneficiary (msg.sender on external tap,
        // but here we use _tap since we're the token)
        _tap(msg.sender, address(this), tier.baseFee);

        emit Enrolled(msg.sender, _tierId);
    }

    /// @notice Leave the service. Stops base fee. Works if lapsed.
    function unenroll() external {
        uint256 tierId = userTier[msg.sender];
        if (tierId == 0) revert NotEnrolled();

        Tier storage tier = tiers[tierId];
        bytes32 mid = _mandateId(address(this), tier.baseFee);
        if (_isTapActive(msg.sender, mid)) {
            _revoke(msg.sender, mid);
        }

        userTier[msg.sender] = 0;
        emit Unenrolled(msg.sender, tierId);
    }

    // ── Usage charges (operator reports, contract deducts) ──

    /// @notice Charge a user for usage. Operator reports units consumed;
    ///         contract deducts cost from the user's balance via _spend.
    ///         Fails if user doesn't have enough balance.
    function chargeUsage(address _user, uint256 _units) external onlyOperator {
        uint256 tierId = userTier[_user];
        if (tierId == 0) revert NotEnrolled();

        Tier storage tier = tiers[tierId];
        uint128 cost = uint128(_units * uint256(tier.usageRate));
        _spend(_user, cost);

        emit UsageCharged(_user, _units, cost);
    }

    // ── Views ──

    /// @notice Whether a user has an active subscription.
    function isEnrolled(address _user) external view returns (bool) {
        uint256 tierId = userTier[_user];
        if (tierId == 0) return false;
        Tier storage tier = tiers[tierId];
        bytes32 mid = _mandateId(address(this), tier.baseFee);
        return _isTapActive(_user, mid);
    }

    // ── Revenue ──

    /// @notice Collect base fee revenue.
    function collect(uint256 _tierId, uint256 _maxEpochs) external {
        Tier storage tier = tiers[_tierId];
        if (tier.baseFee == 0) revert InvalidTier();
        this.harvest(address(this), tier.baseFee, _maxEpochs);
    }

    /// @notice Withdraw collected revenue and spent fees.
    function withdraw(address _to, uint128 _amount) external onlyOwner {
        _transfer(address(this), _to, _amount);
    }

    // ── Internal ──

    /// @dev Internal isTapActive check (avoids external self-call).
    function _isTapActive(address _user, bytes32 _mid) internal view returns (bool) {
        if (_taps[_user][_mid].rate == 0) return false;
        return _periodsElapsed(_user) <= _funded(_accounts[_user]);
    }
}
