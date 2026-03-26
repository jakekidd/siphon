// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {SiphonToken} from "../SiphonToken.sol";

/**
 * @title StreamingSubscription — Subscription service backed by SiphonToken mandates
 * @notice Demonstrates: subscribe, upgrade/downgrade plans, sponsored trials,
 *         access gating via isTapActive, and harvest. The contract IS the
 *         beneficiary; it taps users and collects payments.
 */
contract StreamingSubscription {
    SiphonToken public immutable token;
    address public owner;

    struct Plan {
        string name;
        uint128 rate;
        bool active;
    }

    mapping(uint256 => Plan) public plans;
    uint256 public planCount;

    // user => current planId (0 = not subscribed)
    mapping(address => uint256) public userPlan;

    error Unauthorized();
    error InvalidPlan();
    error NotSubscribed();
    error AlreadySubscribed();

    modifier onlyOwner() { if (msg.sender != owner) revert Unauthorized(); _; }

    constructor(address _token, address _owner) {
        token = SiphonToken(_token);
        owner = _owner;
    }

    // ── Admin ──

    function createPlan(string calldata _name, uint128 _rate) external onlyOwner returns (uint256 id) {
        id = ++planCount;
        plans[id] = Plan(_name, _rate, true);
    }

    function deactivatePlan(uint256 _planId) external onlyOwner {
        plans[_planId].active = false;
    }

    // ── User flow ──

    /// @notice Subscribe to a plan. User must have called
    ///         token.authorize(mandateId, 1) first.
    function subscribe(uint256 _planId) external {
        Plan storage plan = plans[_planId];
        if (!plan.active || plan.rate == 0) revert InvalidPlan();
        if (userPlan[msg.sender] != 0) revert AlreadySubscribed();

        userPlan[msg.sender] = _planId;
        token.tap(msg.sender, plan.rate);
    }

    /// @notice Upgrade or downgrade to a different plan. Revokes old mandate,
    ///         taps new one. User must have authorized the new mandateId.
    function changePlan(uint256 _newPlanId) external {
        uint256 oldPlanId = userPlan[msg.sender];
        if (oldPlanId == 0) revert NotSubscribed();

        Plan storage oldPlan = plans[oldPlanId];
        Plan storage newPlan = plans[_newPlanId];
        if (!newPlan.active || newPlan.rate == 0) revert InvalidPlan();

        // Revoke old mandate
        bytes32 oldMid = token.mandateId(address(this), oldPlan.rate);
        token.revoke(msg.sender, oldMid);

        // Tap new mandate
        userPlan[msg.sender] = _newPlanId;
        token.tap(msg.sender, newPlan.rate);
    }

    /// @notice Cancel subscription. User or this contract can revoke.
    function cancel() external {
        uint256 planId = userPlan[msg.sender];
        if (planId == 0) revert NotSubscribed();

        Plan storage plan = plans[planId];
        bytes32 mid = token.mandateId(address(this), plan.rate);
        token.revoke(msg.sender, mid);
        userPlan[msg.sender] = 0;
    }

    // ── Comp (free months) ──

    /// @notice Give a user N free months. Billing pauses; resumes
    ///         automatically when the comp period ends. No tokens move.
    function comp(address _user, uint256 _planId, uint16 _months) external onlyOwner {
        Plan storage plan = plans[_planId];
        if (plan.rate == 0) revert InvalidPlan();
        token.comp(_user, plan.rate, _months);
    }

    // ── Sponsored trial ──

    /// @notice Sponsor tokens for a user's mandate. Locked and consumed
    ///         before the user's own balance (extends runway, not free months).
    function sponsorTrial(address _user, uint256 _planId, uint8 _months) external {
        Plan storage plan = plans[_planId];
        if (plan.rate == 0) revert InvalidPlan();

        bytes32 mid = token.mandateId(address(this), plan.rate);
        uint128 amount = plan.rate * uint128(_months);
        token.sponsor(_user, mid, amount);
    }

    // ── Access gating ──

    /// @notice Check if a user has an active subscription to any plan.
    function hasAccess(address _user) external view returns (bool) {
        uint256 planId = userPlan[_user];
        if (planId == 0) return false;
        Plan storage plan = plans[planId];
        bytes32 mid = token.mandateId(address(this), plan.rate);
        return token.isTapActive(_user, mid);
    }

    // ── Revenue ──

    /// @notice Collect revenue for a specific plan's mandate.
    function collect(uint256 _planId, uint256 _maxEpochs) external {
        Plan storage plan = plans[_planId];
        if (plan.rate == 0) revert InvalidPlan();
        token.harvest(address(this), plan.rate, _maxEpochs);
    }

    /// @notice Withdraw collected tokens from the contract's token balance.
    function withdraw(address _to, uint128 _amount) external onlyOwner {
        token.transfer(_to, _amount);
    }
}
