// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {SiphonToken} from "../SiphonToken.sol";

/**
 * @title RentalAgreement: Multi-tenant rent collection via SiphonToken
 * @notice Demonstrates: one beneficiary (landlord) with many tenants.
 *         Each tenant authorizes a mandate, landlord taps them. Landlord
 *         harvests all rent in one call since all tenants share the same
 *         mandateId (same beneficiary + same rate = same hash).
 *
 *         Also shows: deposit handling separate from mandate principal,
 *         delinquency detection, and lease terms as wrapper state.
 */
contract RentalAgreement {
    SiphonToken public immutable token;
    address public landlord;
    uint128 public rent; // per term

    struct Lease {
        uint32 startDay;
        uint32 endDay; // 0 = month-to-month
        uint128 deposit;
        bool active;
    }

    mapping(address => Lease) public leases;
    /// @dev Append-only; ended leases remain. In production, cap the array
    ///      or swap-and-pop on endLease to bound gas for checkDelinquencies().
    address[] public tenants;

    event LeaseStarted(address indexed tenant, uint32 startDay, uint32 endDay, uint128 deposit);
    event LeaseEnded(address indexed tenant);
    event MovedOut(address indexed tenant);
    event Delinquent(address indexed tenant);

    error Unauthorized();
    error NotTenant();
    error AlreadyLeased();
    error InsufficientDeposit();

    modifier onlyLandlord() { if (msg.sender != landlord) revert Unauthorized(); _; }

    constructor(address _token, address _landlord, uint128 _rent) {
        token = SiphonToken(_token);
        landlord = _landlord;
        rent = _rent;
    }

    /// @notice The mandateId for this rental agreement. All tenants share it
    ///         (same beneficiary contract, same rent = same hash).
    function mandateId() public view returns (bytes32) {
        return token.mandateId(address(this), rent);
    }

    // ── Landlord flow ──

    /// @notice Onboard a tenant. Tenant must have authorized the mandate and
    ///         transferred a security deposit separately. The landlord taps them.
    function addTenant(
        address _tenant,
        uint32 _endDay,
        uint128 _deposit
    ) external onlyLandlord {
        if (leases[_tenant].active) revert AlreadyLeased();

        // Collect security deposit (separate from mandate; held by this contract)
        if (_deposit > 0) {
            token.transferFrom(_tenant, address(this), _deposit);
        }

        leases[_tenant] = Lease(
            uint32(token.currentDay()),
            _endDay,
            _deposit,
            true
        );
        tenants.push(_tenant);

        // Tap the tenant (landlord is msg.sender = beneficiary)
        token.tap(_tenant, rent);

        emit LeaseStarted(_tenant, leases[_tenant].startDay, _endDay, _deposit);
    }

    /// @notice End a lease. Revokes the mandate (if still active) and returns
    ///         the deposit. Works whether the tenant is current or already moved out.
    function endLease(address _tenant) external onlyLandlord {
        Lease storage lease = leases[_tenant];
        if (!lease.active) revert NotTenant();

        // Revoke mandate if tenant hasn't already moved out
        bytes32 mid = mandateId();
        if (token.isTapActive(_tenant, mid)) {
            token.revoke(_tenant, mid);
        }

        // Return deposit
        if (lease.deposit > 0) {
            token.transfer(_tenant, lease.deposit);
        }

        lease.active = false;
        emit LeaseEnded(_tenant);
    }

    /// @notice Harvest all rent. Since all tenants share the same mandateId,
    ///         one harvest call collects from everyone. Tokens go to this
    ///         contract; landlord withdraws via withdraw().
    function collectRent(uint256 _maxEpochs) external onlyLandlord {
        token.harvest(address(this), rent, _maxEpochs);
    }

    /// @notice Withdraw collected rent.
    function withdraw(address _to, uint128 _amount) external onlyLandlord {
        token.transfer(_to, _amount);
    }

    // ── Tenant flow ──

    /// @notice Tenant stops paying rent. Revokes mandate if still active (no-op
    ///         if already lapsed). Lease stays active until landlord calls
    ///         endLease to return deposit and finalize.
    function moveOut() external {
        Lease storage lease = leases[msg.sender];
        if (!lease.active) revert NotTenant();

        bytes32 mid = mandateId();
        if (token.isTapActive(msg.sender, mid)) {
            token.revoke(msg.sender, mid);
        }

        emit MovedOut(msg.sender);
    }

    // ── Views ──

    /// @notice Check if a tenant's rent is current.
    function isCurrentOnRent(address _tenant) external view returns (bool) {
        if (!leases[_tenant].active) return false;
        return token.isTapActive(_tenant, mandateId());
    }

    /// @notice Flag all delinquent tenants (rent mandate lapsed).
    function checkDelinquencies() external {
        bytes32 mid = mandateId();
        for (uint256 i; i < tenants.length; i++) {
            address tenant = tenants[i];
            if (leases[tenant].active && !token.isTapActive(tenant, mid)) {
                emit Delinquent(tenant);
            }
        }
    }

    function tenantCount() external view returns (uint256) {
        return tenants.length;
    }
}
