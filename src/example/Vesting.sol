// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {SiphonToken} from "../SiphonToken.sol";

/**
 * @title Vesting: Token streaming via SiphonToken mandates
 * @notice Demonstrates vesting schedules as mandates. A grantor deposits
 *         tokens and creates vesting streams for recipients. The grantor's
 *         balance decays automatically as all streams drain simultaneously.
 *
 *         This is the Sablier/Drips pattern built into the token itself:
 *         no external escrow, no keeper, no per-second accounting.
 *         Streams are just mandates; vested amount = harvested amount.
 *
 * @dev Architecture: the Vesting contract IS the beneficiary on all streams
 *      (it calls tap(), making itself msg.sender to the token). Revenue is
 *      harvested into the contract, then forwarded to recipients on collect().
 *
 *      The grantor IS the token holder (payer). The grantor must authorize
 *      mandateId(address(this), rate) on the token before a recipient can
 *      activate. Different rates produce different mandateIds.
 *
 * @dev Limitation: multiple grants at the same rate share one mandateId.
 *      A single harvest collects for all of them. collect() forwards the
 *      full harvested amount to whichever recipient calls it. For
 *      production use, ensure unique rates per grant or add internal
 *      accounting to split shared harvests.
 */
contract Vesting {
    SiphonToken public immutable token;
    address public admin;

    struct Grant {
        address recipient;
        uint128 rate;       // tokens per term
        uint32 terms;       // total vesting terms
        bool created;
    }

    /// @dev The grantor address whose balance funds all streams.
    address public grantor;

    mapping(uint256 => Grant) public grants;
    uint256 public grantCount;

    /// @dev Tracks which grants have been activated (recipient called activate).
    mapping(uint256 => bool) public activated;

    event GrantCreated(uint256 indexed grantId, address indexed recipient, uint128 rate, uint32 terms);
    event GrantActivated(uint256 indexed grantId, address indexed recipient);
    event GrantRevoked(uint256 indexed grantId, address indexed recipient);

    error Unauthorized();
    error InvalidGrant();
    error AlreadyActivated();
    error NotRecipient();
    error NotActivated();

    modifier onlyAdmin() { if (msg.sender != admin) revert Unauthorized(); _; }

    /// @param _token   The SiphonToken instance.
    /// @param _admin   Admin who creates/revokes grants.
    /// @param _grantor The address holding tokens that fund all vesting streams.
    constructor(address _token, address _admin, address _grantor) {
        token = SiphonToken(_token);
        admin = _admin;
        grantor = _grantor;
    }

    // ── Admin ──

    /// @notice Create a vesting grant. The grantor must separately call
    ///         token.authorize(mandateId(address(this), rate), 1) to permit
    ///         activation. The grantor must hold enough tokens to cover
    ///         rate * terms.
    function createGrant(
        address _recipient,
        uint128 _rate,
        uint32 _terms
    ) external onlyAdmin returns (uint256 id) {
        if (_recipient == address(0) || _rate == 0 || _terms == 0) revert InvalidGrant();

        id = ++grantCount;
        grants[id] = Grant(_recipient, _rate, _terms, true);

        emit GrantCreated(id, _recipient, _rate, _terms);
    }

    /// @notice Revoke a vesting grant. Stops future vesting immediately.
    ///         Already-collected tokens are not clawed back. This contract
    ///         IS the beneficiary, so it can call revoke.
    function revokeGrant(uint256 _grantId) external onlyAdmin {
        Grant storage g = grants[_grantId];
        if (!g.created) revert InvalidGrant();
        if (!activated[_grantId]) revert NotActivated();

        bytes32 mid = token.mandateId(address(this), g.rate);
        if (token.isTapActive(grantor, mid)) {
            token.revoke(grantor, mid);
        }

        emit GrantRevoked(_grantId, g.recipient);
    }

    // ── Recipient ──

    /// @notice Activate your vesting stream. Grantor must have authorized
    ///         mandateId(address(this), rate). First term's tokens are
    ///         transferred to this contract immediately.
    function activate(uint256 _grantId) external {
        Grant storage g = grants[_grantId];
        if (!g.created) revert InvalidGrant();
        if (msg.sender != g.recipient) revert NotRecipient();
        if (activated[_grantId]) revert AlreadyActivated();

        activated[_grantId] = true;

        // This contract taps the grantor. This contract IS the beneficiary.
        token.tap(grantor, g.rate);

        emit GrantActivated(_grantId, g.recipient);
    }

    /// @notice Collect vested tokens. Harvests into this contract, then
    ///         forwards to the recipient. Anyone can call.
    function collect(uint256 _grantId, uint256 _maxEpochs) external {
        Grant storage g = grants[_grantId];
        if (!g.created) revert InvalidGrant();

        uint256 before = token.balanceOf(address(this));
        token.harvest(address(this), g.rate, _maxEpochs);
        uint256 harvested = token.balanceOf(address(this)) - before;

        if (harvested > 0) {
            token.transfer(g.recipient, harvested);
        }
    }

    // ── Views ──

    /// @notice Whether a grant's vesting stream is currently active.
    function isVesting(uint256 _grantId) external view returns (bool) {
        Grant storage g = grants[_grantId];
        if (!activated[_grantId]) return false;
        bytes32 mid = token.mandateId(address(this), g.rate);
        return token.isTapActive(grantor, mid);
    }

    /// @notice How many terms of funding remain for the grantor across all streams.
    function fundedTerms() external view returns (uint256) {
        return token.funded(grantor);
    }

    /// @notice Total tokens allocated to a grant (rate * terms).
    function totalAllocation(uint256 _grantId) external view returns (uint256) {
        Grant storage g = grants[_grantId];
        return uint256(g.rate) * uint256(g.terms);
    }
}
