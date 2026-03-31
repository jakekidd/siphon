// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {SiphonToken} from "../SiphonToken.sol";

/**
 * @title StreamingSubscription: Subscription service backed by SiphonToken mandates
 * @notice Demonstrates: subscribe, upgrade/downgrade plans, comp (free months),
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

    event Subscribed(address indexed user, uint256 indexed planId);
    event Canceled(address indexed user, uint256 indexed planId);
    event PlanChanged(address indexed user, uint256 indexed oldPlanId, uint256 indexed newPlanId);

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
    ///         If the user had a previous subscription that lapsed (ran out of
    ///         funds), it is automatically cleared so they can re-subscribe.
    function subscribe(uint256 _planId) external {
        Plan storage plan = plans[_planId];
        if (!plan.active || plan.rate == 0) revert InvalidPlan();

        uint256 oldPlanId = userPlan[msg.sender];
        if (oldPlanId != 0) {
            // Allow re-subscribe if old subscription lapsed
            Plan storage oldPlan = plans[oldPlanId];
            bytes32 oldMid = token.mandateId(address(this), oldPlan.rate);
            if (token.isTapActive(msg.sender, oldMid)) revert AlreadySubscribed();
        }

        userPlan[msg.sender] = _planId;
        token.tap(msg.sender, plan.rate);

        emit Subscribed(msg.sender, _planId);
    }

    /// @notice Upgrade or downgrade to a different plan. Revokes old mandate
    ///         (if still active), taps new one. User must have authorized
    ///         the new mandateId. Works even if old subscription lapsed.
    function changePlan(uint256 _newPlanId) external {
        uint256 oldPlanId = userPlan[msg.sender];
        if (oldPlanId == 0) revert NotSubscribed();

        Plan storage oldPlan = plans[oldPlanId];
        Plan storage newPlan = plans[_newPlanId];
        if (!newPlan.active || newPlan.rate == 0) revert InvalidPlan();

        // Revoke old mandate if still active (skip if lapsed)
        bytes32 oldMid = token.mandateId(address(this), oldPlan.rate);
        if (token.isTapActive(msg.sender, oldMid)) {
            token.revoke(msg.sender, oldMid);
        }

        // Tap new mandate
        userPlan[msg.sender] = _newPlanId;
        token.tap(msg.sender, newPlan.rate);

        emit PlanChanged(msg.sender, oldPlanId, _newPlanId);
    }

    /// @notice Cancel subscription. Works whether the mandate is active or
    ///         already lapsed (ran out of funds). Revokes if still active.
    function cancel() external {
        uint256 planId = userPlan[msg.sender];
        if (planId == 0) revert NotSubscribed();

        Plan storage plan = plans[planId];
        bytes32 mid = token.mandateId(address(this), plan.rate);

        // Revoke if mandate is still active (skip if already lapsed)
        if (token.isTapActive(msg.sender, mid)) {
            token.revoke(msg.sender, mid);
        }

        userPlan[msg.sender] = 0;

        emit Canceled(msg.sender, planId);
    }

    // ── Comp (free months) ──

    /// @notice Give a user N free months. Billing pauses; resumes
    ///         automatically when the comp period ends. No tokens move.
    function comp(address _user, uint256 _planId, uint16 _months) external onlyOwner {
        Plan storage plan = plans[_planId];
        if (plan.rate == 0) revert InvalidPlan();
        token.comp(_user, plan.rate, _months);
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
