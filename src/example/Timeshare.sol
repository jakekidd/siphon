// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {SiphonToken} from "../SiphonToken.sol";

/**
 * @title Timeshare — Rotating payment responsibility among multiple users
 * @notice Demonstrates mandate composability. Multiple users share a single
 *         recurring cost, but only one pays at a time. The active payer
 *         rotates on a meta-schedule (e.g., every 3 months).
 *
 *         Example: 4 friends share a cabin. The annual fee is split into
 *         quarterly rotations. Each quarter, one friend's mandate is active
 *         and the others are dormant.
 *
 *         The Timeshare contract IS the beneficiary. It taps the current
 *         payer and revokes them when the rotation happens.
 */
contract Timeshare {
    SiphonToken public immutable token;
    address public manager;
    uint128 public rate; // per term
    uint8 public rotationTerms; // how many terms per rotation (e.g., 3 for quarterly on a monthly token)

    address[] public members;
    uint256 public currentIndex;
    uint32 public lastRotationEpoch;

    event Rotated(address indexed from, address indexed to, uint256 epoch);
    event MemberAdded(address indexed member);
    event MemberRemoved(address indexed member);

    error Unauthorized();
    error NotMember();
    error AlreadyMember();
    error RotationNotDue();
    error NoMembers();

    modifier onlyManager() { if (msg.sender != manager) revert Unauthorized(); _; }

    constructor(
        address _token,
        address _manager,
        uint128 _rate,
        uint8 _rotationTerms
    ) {
        token = SiphonToken(_token);
        manager = _manager;
        rate = _rate;
        rotationTerms = _rotationTerms;
    }

    function mandateId() public view returns (bytes32) {
        return token.mandateId(address(this), rate);
    }

    // ── Setup ──

    /// @notice Add a member to the rotation. They must authorize the mandate
    ///         with enough count to cover their expected rotations.
    function addMember(address _member) external onlyManager {
        for (uint256 i; i < members.length; i++) {
            if (members[i] == _member) revert AlreadyMember();
        }
        members.push(_member);
        emit MemberAdded(_member);
    }

    function removeMember(address _member) external onlyManager {
        for (uint256 i; i < members.length; i++) {
            if (members[i] == _member) {
                // If this is the active payer, revoke first
                if (i == currentIndex) {
                    bytes32 mid = mandateId();
                    if (token.isTapActive(_member, mid)) {
                        token.revoke(_member, mid);
                    }
                }
                members[i] = members[members.length - 1];
                members.pop();
                if (currentIndex >= members.length && members.length > 0) {
                    currentIndex = 0;
                }
                emit MemberRemoved(_member);
                return;
            }
        }
        revert NotMember();
    }

    // ── Rotation ──

    /// @notice Start the first rotation. Taps member at currentIndex.
    function start() external onlyManager {
        if (members.length == 0) revert NoMembers();
        lastRotationEpoch = uint32(token.currentEpoch());
        token.tap(members[currentIndex], rate);
    }

    /// @notice Rotate to the next payer. Anyone can call once the rotation
    ///         period has elapsed. Revokes the current payer, taps the next.
    function rotate() external {
        if (members.length == 0) revert NoMembers();
        uint256 curEpoch = token.currentEpoch();
        if (curEpoch < uint256(lastRotationEpoch) + uint256(rotationTerms)) revert RotationNotDue();

        address outgoing = members[currentIndex];
        bytes32 mid = mandateId();

        // Revoke outgoing payer
        if (token.isTapActive(outgoing, mid)) {
            token.revoke(outgoing, mid);
        }

        // Advance to next member
        currentIndex = (currentIndex + 1) % members.length;
        address incoming = members[currentIndex];

        // Tap incoming payer (consumes one of their authorizations)
        token.tap(incoming, rate);
        lastRotationEpoch = uint32(curEpoch);

        emit Rotated(outgoing, incoming, curEpoch);
    }

    // ── Revenue ──

    /// @notice Collect payments. The Timeshare contract is the beneficiary.
    function collect(uint256 _maxEpochs) external {
        token.harvest(address(this), rate, _maxEpochs);
    }

    /// @notice Withdraw collected funds (e.g., to pay the actual property cost).
    function withdraw(address _to, uint128 _amount) external onlyManager {
        token.transfer(_to, _amount);
    }

    // ── Views ──

    function currentPayer() external view returns (address) {
        if (members.length == 0) return address(0);
        return members[currentIndex];
    }

    function isPayerActive() external view returns (bool) {
        if (members.length == 0) return false;
        return token.isTapActive(members[currentIndex], mandateId());
    }

    function memberCount() external view returns (uint256) {
        return members.length;
    }

    function nextRotationEpoch() external view returns (uint256) {
        return uint256(lastRotationEpoch) + uint256(rotationTerms);
    }
}
