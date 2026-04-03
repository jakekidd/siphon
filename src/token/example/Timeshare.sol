// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {SiphonToken} from "../SiphonToken.sol";
import {TimeshareEscrow} from "./TimeshareEscrow.sol";

/**
 * @title Timeshare: Rotating payment responsibility among multiple users
 * @notice Demonstrates: multiple users pooling funds into a shared escrow
 *         that pays a single beneficiary (this contract) via SiphonToken
 *         mandates. Members deposit their share each season; the escrow's
 *         balance drains at rate-per-term. Access rotates round-robin.
 *
 *         Two-contract architecture: Timeshare (beneficiary/manager) deploys
 *         one TimeshareEscrow per agreement. The escrow holds member deposits
 *         and gets tapped. Timeshare harvests the income.
 *
 * @dev Key pattern: the beneficiary doesn't care who pays. They get rate per
 *      term regardless. The pool is the single payer from the beneficiary's
 *      perspective; internal accounting handles the split among members.
 */
contract Timeshare {
    SiphonToken public immutable token;
    address public owner;

    uint256 public agreementCount;

    struct Agreement {
        address escrow;
        uint128 rate;
        uint16 termsPerSeason;
        uint8 memberCount;
        uint8 fundedCount;
        uint32 activatedDay;
        uint32 fundingStartDay;
        uint16 fundingDeadlineDays;
        uint8 season;
        bool active;
    }

    mapping(uint256 => Agreement) public agreements;
    mapping(uint256 => address[]) internal _members;
    mapping(uint256 => mapping(address => uint8)) internal _memberIndex; // 1-based (0 = not member)
    mapping(uint256 => mapping(address => bool)) internal _funded;

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    event AgreementCreated(uint256 indexed agreementId, address escrow, uint128 rate, uint16 termsPerSeason, uint8 memberCount);
    event MemberFunded(uint256 indexed agreementId, address indexed member, uint8 season);
    event Activated(uint256 indexed agreementId, uint8 season);
    event Renewed(uint256 indexed agreementId, uint8 season);
    event Revoked(uint256 indexed agreementId, uint8 season);
    event FundingReclaimed(uint256 indexed agreementId, address indexed member, uint128 amount);
    event Comped(uint256 indexed agreementId, uint16 epochs);

    // ──────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────

    error Unauthorized();
    error NotMember();
    error AlreadyFunded();
    error AlreadyActive();
    error StillActive();
    error NotActive();
    error InvalidParams();
    error DivisibilityRequired();
    error FundingOpen();
    error NothingToReclaim();
    error NoSeason();

    // ──────────────────────────────────────────────
    // Modifiers
    // ──────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    constructor(address _token, address _owner) {
        token = SiphonToken(_token);
        owner = _owner;
    }

    // ──────────────────────────────────────────────
    // Admin: Create
    // ──────────────────────────────────────────────

    /// @notice Create a timeshare agreement. Deploys a new escrow contract.
    ///         Members must call fund() to deposit their share before activation.
    function create(
        uint128 _rate,
        uint16 _termsPerSeason,
        uint16 _fundingDeadlineDays,
        address[] calldata _membersArr
    ) external onlyOwner returns (uint256 agreementId) {
        if (_rate == 0 || _termsPerSeason == 0) revert InvalidParams();
        if (_membersArr.length < 2 || _membersArr.length > 255) revert InvalidParams();
        if (uint256(_rate) * uint256(_termsPerSeason) % _membersArr.length != 0) {
            revert DivisibilityRequired();
        }

        agreementId = ++agreementCount;

        TimeshareEscrow escrow = new TimeshareEscrow(address(token), address(this));
        escrow.initialize(_rate, _termsPerSeason, uint8(_membersArr.length));

        agreements[agreementId] = Agreement({
            escrow: address(escrow),
            rate: _rate,
            termsPerSeason: _termsPerSeason,
            memberCount: uint8(_membersArr.length),
            fundedCount: 0,
            activatedDay: 0,
            fundingStartDay: uint32(token.currentDay()),
            fundingDeadlineDays: _fundingDeadlineDays,
            season: 0,
            active: false
        });

        for (uint256 i; i < _membersArr.length; i++) {
            _members[agreementId].push(_membersArr[i]);
            _memberIndex[agreementId][_membersArr[i]] = uint8(i + 1); // 1-based
        }

        emit AgreementCreated(agreementId, address(escrow), _rate, _termsPerSeason, uint8(_membersArr.length));
    }

    // ──────────────────────────────────────────────
    // Member: Fund
    // ──────────────────────────────────────────────

    /// @notice Deposit your share for the current season. Caller must have
    ///         approved this contract to spend their tokens. Auto-activates
    ///         when all members have funded.
    function fund(uint256 _agreementId) external {
        Agreement storage a = agreements[_agreementId];
        if (_memberIndex[_agreementId][msg.sender] == 0) revert NotMember();
        if (_funded[_agreementId][msg.sender]) revert AlreadyFunded();
        if (a.active) revert AlreadyActive();

        uint128 share = _share(a);
        token.transferFrom(msg.sender, a.escrow, share);

        _funded[_agreementId][msg.sender] = true;
        a.fundedCount++;

        emit MemberFunded(_agreementId, msg.sender, a.season + 1);

        if (a.fundedCount == a.memberCount) {
            _activate(_agreementId);
        }
    }

    // ──────────────────────────────────────────────
    // Admin: Revoke, Comp, Withdraw
    // ──────────────────────────────────────────────

    /// @notice Revoke an agreement mid-season. Stops billing immediately.
    ///         If the mandate already lapsed, just marks inactive.
    function revokeAgreement(uint256 _agreementId) external onlyOwner {
        Agreement storage a = agreements[_agreementId];
        if (!a.active) revert NotActive();

        bytes32 mid = token.mandateId(address(this), a.rate);
        if (token.isTapActive(a.escrow, mid)) {
            token.revoke(a.escrow, mid);
        }
        a.active = false;

        emit Revoked(_agreementId, a.season);
    }

    /// @notice Pause billing for N terms (e.g. property maintenance).
    ///         Access returns false during comp. Billing resumes automatically.
    function comp(uint256 _agreementId, uint16 _epochs) external onlyOwner {
        Agreement storage a = agreements[_agreementId];
        if (!a.active) revert NotActive();

        token.comp(a.escrow, a.rate, _epochs);
        emit Comped(_agreementId, _epochs);
    }

    /// @notice Withdraw harvested revenue from this contract.
    function withdraw(address _to, uint128 _amount) external onlyOwner {
        token.transfer(_to, _amount);
    }

    // ──────────────────────────────────────────────
    // Public: Renew, Harvest
    // ──────────────────────────────────────────────

    /// @notice Start a new season. If the mandate lapsed or was revoked,
    ///         refunds any leftover escrow balance to members, then resets
    ///         funding state. Members call fund() again to re-activate.
    function renew(uint256 _agreementId) external {
        Agreement storage a = agreements[_agreementId];
        if (a.season == 0) revert NoSeason();

        // Finalize if mandate lapsed naturally
        if (a.active) {
            bytes32 mid = token.mandateId(address(this), a.rate);
            if (token.isTapActive(a.escrow, mid)) revert StillActive();
            a.active = false;
        }

        address[] storage mems = _members[_agreementId];

        // Refund any remaining escrow balance to members equally
        uint256 remaining = token.balanceOf(a.escrow);
        if (remaining > 0) {
            uint128 perMember = uint128(remaining / uint256(a.memberCount));
            if (perMember > 0) {
                TimeshareEscrow escrow = TimeshareEscrow(a.escrow);
                for (uint256 i; i < mems.length; i++) {
                    escrow.refund(mems[i], perMember);
                }
            }
        }

        // Reset funding state
        a.fundedCount = 0;
        a.fundingStartDay = uint32(token.currentDay());
        for (uint256 i; i < mems.length; i++) {
            delete _funded[_agreementId][mems[i]];
        }

        emit Renewed(_agreementId, a.season + 1);
    }

    /// @notice Harvest income for all agreements at a given rate.
    ///         All escrows at the same rate share a mandateId, so one
    ///         harvest collects from all of them.
    function harvest(uint128 _rate, uint256 _maxEpochs) external {
        token.harvest(address(this), _rate, _maxEpochs);
    }

    // ──────────────────────────────────────────────
    // Member: Reclaim
    // ──────────────────────────────────────────────

    /// @notice Reclaim your deposit if the agreement failed to fully fund
    ///         and the funding deadline has passed.
    function reclaimFunding(uint256 _agreementId) external {
        Agreement storage a = agreements[_agreementId];
        if (a.active) revert AlreadyActive();
        if (a.fundedCount == a.memberCount) revert AlreadyFunded();
        if (!_funded[_agreementId][msg.sender]) revert NothingToReclaim();

        uint256 deadline = uint256(a.fundingStartDay) + uint256(a.fundingDeadlineDays);
        if (token.currentDay() < deadline) revert FundingOpen();

        uint128 share = _share(a);
        TimeshareEscrow(a.escrow).refund(msg.sender, share);

        _funded[_agreementId][msg.sender] = false;
        a.fundedCount--;

        emit FundingReclaimed(_agreementId, msg.sender, share);
    }

    // ──────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────

    /// @notice Who currently has access? Returns (true, member) during active
    ///         periods, (false, address(0)) otherwise. Round-robin rotation:
    ///         member index = termIndex % memberCount.
    function hasAccess(uint256 _agreementId) external view returns (bool, address) {
        Agreement storage a = agreements[_agreementId];
        if (!a.active) return (false, address(0));

        bytes32 mid = token.mandateId(address(this), a.rate);
        if (!token.isTapActive(a.escrow, mid)) return (false, address(0));
        if (token.isComped(a.escrow)) return (false, address(0));

        uint256 today = token.currentDay();
        uint256 termIndex = (today - uint256(a.activatedDay)) / uint256(token.TERM_DAYS());
        if (termIndex >= uint256(a.termsPerSeason)) return (false, address(0));

        address member = _members[_agreementId][termIndex % uint256(a.memberCount)];
        return (true, member);
    }

    /// @notice Check if a specific member currently has access.
    function memberHasAccess(uint256 _agreementId, address _member) external view returns (bool) {
        (bool active, address current) = this.hasAccess(_agreementId);
        return active && current == _member;
    }

    function getMembers(uint256 _agreementId) external view returns (address[] memory) {
        return _members[_agreementId];
    }

    function isFunded(uint256 _agreementId, address _member) external view returns (bool) {
        return _funded[_agreementId][_member];
    }

    // ──────────────────────────────────────────────
    // Internal
    // ──────────────────────────────────────────────

    function _activate(uint256 _agreementId) internal {
        Agreement storage a = agreements[_agreementId];

        TimeshareEscrow(a.escrow).setup(1);
        token.tap(a.escrow, a.rate);

        a.activatedDay = uint32(token.currentDay());
        a.season++;
        a.active = true;

        emit Activated(_agreementId, a.season);
    }

    function _share(Agreement storage _a) internal view returns (uint128) {
        return uint128(uint256(_a.rate) * uint256(_a.termsPerSeason) / uint256(_a.memberCount));
    }
}
