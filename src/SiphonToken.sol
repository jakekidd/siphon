// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IScheduleListener} from "./interfaces/IScheduleListener.sol";

/**
 * @title SiphonToken — ERC20 with scheduled payment deductions
 * @author Ubitel
 *
 * @notice Abstract base for tokens whose balanceOf decays over time based on
 *         a payment schedule. Like a bank account with auto-pay: balance ticks
 *         down each period without any transaction.
 *
 * @dev Key concepts:
 *
 *   SIPHONING (period-based, not streaming)
 *     Payments happen at period boundaries (anchor + n*interval). The first
 *     term is paid immediately on assign. Subsequent deductions occur at each
 *     boundary via lazy math.
 *
 *   TWO PATHS: BURN vs BENEFICIARY
 *     to == address(0): consumed tokens are burned (totalSupply decreases).
 *     to != address(0): consumed tokens flow to a beneficiary via shared
 *     count buckets (joinoffs + dropoffs). The beneficiary calls collect().
 *
 *   SCHEDULE APPROVAL
 *     Users pre-approve schedules by ID: approveSchedule(scheduleId, count).
 *     Each assignment consumes one approval. type(uint256).max = infinite
 *     (beneficiary can reassign freely, e.g. auto-renew after lapse).
 *     Lapse or termination does NOT revoke remaining approvals.
 *
 *   SHARED COUNT BUCKETS
 *     scheduleId = keccak256(beneficiary, rate, termDays). All subscribers
 *     share count buckets. O(1) per user mutation, O(epochs) collect.
 *
 *   ONLY FULLY FUNDED PERIODS
 *     consumed = min(periodsElapsed, fundedPeriods) * rate, where
 *     fundedPeriods = principal / rate (floor division).
 *
 *   LAZY SETTLEMENT
 *     balanceOf computed on-the-fly. Storage only changes via _settle.
 *
 *   LAPSE = DONE
 *     Lapse always clears the schedule. To resume, the user must re-approve
 *     and the beneficiary must re-assign. No auto-resume on deposit.
 *
 *   SCHEDULE STRUCT — TWO STORAGE SLOTS
 *     Slot 1: { uint128 principal, uint128 rate }
 *     Slot 2: { address to, uint16 interval, uint32 anchor,
 *               uint32 terminatedAt }  [16 bits free]
 */
abstract contract SiphonToken is IERC20, IERC20Metadata {
    // ──────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────

    error InsufficientBalance();
    /// @notice ERC20 standard error (OpenZeppelin ERC20Errors.sol).
    error InsufficientAllowance();
    error NoSchedule();
    /// @notice ERC20 standard error (OpenZeppelin ERC20Errors.sol).
    error ERC20InvalidReceiver(address receiver);
    /// @notice ERC20 standard error (OpenZeppelin ERC20Errors.sol).
    error ERC20InvalidSender(address sender);
    error InvalidBeneficiary();
    error InvalidSchedule();
    error NotApproved();
    error Unauthorized();

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    event ScheduleSet(
        address indexed user, address indexed to, uint128 rate,
        uint16 interval, bytes32 scheduleId
    );
    event ScheduleTerminated(address indexed user, uint32 terminatedAt);
    event ScheduleCleared(address indexed user);
    event ScheduleSettled(address indexed user, uint256 amount);
    event ScheduleApproval(address indexed user, bytes32 indexed scheduleId, uint256 count);
    event ScheduleComped(address indexed user, bytes32 indexed scheduleId, uint8 periods);
    event Siphoned(address indexed from, address indexed to, uint256 amount);
    event Spent(address indexed user, uint256 amount);
    event Collected(address indexed beneficiary, bytes32 indexed scheduleId, uint256 amount, uint256 epochs);
    event ScheduleListenerSet(address listener);

    // ──────────────────────────────────────────────
    // Structs
    // ──────────────────────────────────────────────

    /**
     * @dev Two storage slots per user.
     *   Slot 1 (256 bits): principal (128) + rate (128)
     *   Slot 2 (256 bits): to (160) + interval (16) + anchor (32)
     *                      + terminatedAt (32) = 240  [16 bits free]
     */
    struct Schedule {
        uint128 principal;
        uint128 rate;
        address to;
        uint16 interval;
        uint32 anchor;
        uint32 terminatedAt;
    }

    /// @dev Collection checkpoint per scheduleId. Packed in one slot.
    struct Checkpoint {
        uint32 lastEpoch;
        uint224 count;
    }

    // ──────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────

    uint256 internal constant _SECONDS_PER_DAY = 86_400;

    // ──────────────────────────────────────────────
    // Immutables
    // ──────────────────────────────────────────────

    /// @notice Day index when the contract was deployed. Epoch boundaries are relative to this.
    uint32 public immutable DEPLOY_DAY;

    // ──────────────────────────────────────────────
    // State
    // ──────────────────────────────────────────────

    mapping(address => Schedule) internal _schedules;
    mapping(address => mapping(address => uint256)) internal _allowances;

    uint256 public totalMinted;
    uint256 public totalBurned;
    uint256 public totalSpent;

    /// @dev Schedule approval counts. user => scheduleId => remaining approvals.
    ///      type(uint256).max = infinite (beneficiary can reassign freely).
    mapping(address => mapping(bytes32 => uint256)) internal _scheduleApprovals;

    /// @dev Collection checkpoints per scheduleId.
    mapping(bytes32 => Checkpoint) internal _checkpoints;

    /// @dev Subscriber joinoff counts. scheduleId => epochNumber => count.
    mapping(bytes32 => mapping(uint256 => uint256)) internal _joinoffs;

    /// @dev Subscriber dropoff counts. scheduleId => epochNumber => count.
    mapping(bytes32 => mapping(uint256 => uint256)) internal _dropoffs;

    /// @dev Per-user hint: which epoch their dropoff is placed at.
    mapping(address => uint32) internal _userDropoffEpoch;

    /// @notice Optional callback for schedule state changes.
    address public scheduleListener;

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    constructor(uint32 _deployDay) {
        DEPLOY_DAY = _deployDay == 0 ? uint32(block.timestamp / _SECONDS_PER_DAY) : _deployDay;
    }

    // ──────────────────────────────────────────────
    // ERC20
    // ──────────────────────────────────────────────

    function balanceOf(address _user) external view returns (uint256) {
        return _balance(_schedules[_user]);
    }

    function totalSupply() external view returns (uint256) {
        return totalMinted - totalBurned - totalSpent;
    }

    function transfer(address _to, uint256 _amount) external virtual returns (bool) {
        _transfer(msg.sender, _to, _amount);
        return true;
    }

    function transferFrom(address _from, address _to, uint256 _amount) external virtual returns (bool) {
        uint256 allowed = _allowances[_from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < _amount) revert InsufficientAllowance();
            _allowances[_from][msg.sender] = allowed - _amount;
        }
        _transfer(_from, _to, _amount);
        return true;
    }

    function approve(address _spender, uint256 _amount) external virtual returns (bool) {
        _allowances[msg.sender][_spender] = _amount;
        emit Approval(msg.sender, _spender, _amount);
        return true;
    }

    function allowance(address _owner, address _spender) external view returns (uint256) {
        return _allowances[_owner][_spender];
    }

    // ──────────────────────────────────────────────
    // Schedule Approval
    // ──────────────────────────────────────────────

    /// @notice Pre-approve a schedule for assignment. Each assign() consumes one.
    ///         Use type(uint256).max for infinite (beneficiary can reassign freely).
    function approveSchedule(bytes32 _sid, uint256 _count) external {
        _scheduleApprovals[msg.sender][_sid] = _count;
        emit ScheduleApproval(msg.sender, _sid, _count);
    }

    /// @notice Check remaining schedule approvals.
    function scheduleAllowance(address _user, bytes32 _sid) external view returns (uint256) {
        return _scheduleApprovals[_user][_sid];
    }

    // ──────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────

    function getSchedule(address _user)
        external
        view
        returns (
            uint128 principal, uint128 rate, address to,
            uint16 interval, uint32 anchor, uint32 terminatedAt
        )
    {
        Schedule storage s = _schedules[_user];
        return (s.principal, s.rate, s.to, s.interval, s.anchor, s.terminatedAt);
    }

    function consumed(address _user) external view returns (uint256) {
        return _consumed(_schedules[_user]);
    }

    function expiry(address _user) external view returns (uint256) {
        Schedule storage s = _schedules[_user];
        if (s.rate == 0) return 0;
        return _expiry(s);
    }

    function isActive(address _user) external view returns (bool) {
        Schedule storage s = _schedules[_user];
        if (s.rate == 0) return false;
        if (s.terminatedAt > 0) return false;
        return _expiry(s) > _today();
    }

    /// @notice True if user explicitly terminated and service hasn't ended yet.
    function didTerminate(address _user) external view returns (bool) {
        Schedule storage s = _schedules[_user];
        if (s.rate == 0) return false;
        if (s.terminatedAt == 0) return false;
        return _serviceEnd(s) > _today();
    }

    /// @notice True if user ran out of funds without terminating.
    function didLapse(address _user) external view returns (bool) {
        Schedule storage s = _schedules[_user];
        if (s.rate == 0) return false;
        if (s.terminatedAt > 0) return false;
        return _expiry(s) <= _today();
    }

    function currentDay() external view returns (uint256) {
        return _today();
    }

    function scheduleId(address _to, uint128 _rate, uint16 _interval) external pure returns (bytes32) {
        return _scheduleId(_to, _rate, _interval);
    }

    function getCheckpoint(bytes32 _sid) external view returns (uint32 lastEpoch, uint224 count) {
        Checkpoint storage cp = _checkpoints[_sid];
        return (cp.lastEpoch, cp.count);
    }

    // ──────────────────────────────────────────────
    // Public: Settle
    // ──────────────────────────────────────────────

    function settle(address _user) external {
        _settle(_schedules[_user], _user);
    }

    // ──────────────────────────────────────────────
    // Public: Terminate
    // ──────────────────────────────────────────────

    /// @notice Terminate a user's schedule. Callable by the user or the beneficiary.
    ///         The schedule stays active through the current paid period, then clears
    ///         on next settle. Like revoking an autopay at the bank — service continues
    ///         until the paid period runs out.
    function terminate(address _user) external virtual {
        Schedule storage s = _schedules[_user];
        if (s.rate == 0) revert NoSchedule();
        if (msg.sender != _user && msg.sender != s.to) revert Unauthorized();
        _terminateSchedule(_user);
    }

    // ──────────────────────────────────────────────
    // Public: Assign (beneficiary sets schedule for user)
    // ──────────────────────────────────────────────

    /// @notice Assign a schedule to a user. Consumes one schedule approval.
    ///         Anyone can call — the user's prior approveSchedule() is the gate.
    ///         Immediate first-term payment is transferred directly to beneficiary.
    function assign(
        address _user,
        address _to,
        uint128 _rate,
        uint16 _interval
    ) external virtual {
        bytes32 sid = _scheduleId(_to, _rate, _interval);
        uint256 approvals = _scheduleApprovals[_user][sid];
        if (approvals == 0) revert NotApproved();
        if (approvals != type(uint256).max) {
            _scheduleApprovals[_user][sid] = approvals - 1;
        }
        _assign(_user, _to, _rate, _interval);
    }

    // ──────────────────────────────────────────────
    // Public: Collect (beneficiary claims income)
    // ──────────────────────────────────────────────

    /// @notice Collect accumulated income for a schedule. Anyone can call;
    ///         tokens always go to the beneficiary encoded in the scheduleId.
    ///         Caller provides schedule params; contract verifies hash.
    function collect(
        address _to,
        uint128 _rate,
        uint16 _interval,
        uint256 _maxEpochs
    ) external {
        bytes32 sid = _scheduleId(_to, _rate, _interval);
        Checkpoint storage cp = _checkpoints[sid];
        uint256 current = _epochOf(_interval);
        uint256 last = uint256(cp.lastEpoch);
        uint256 end = last + _maxEpochs;
        if (end > current) end = current;
        if (end <= last) return;

        uint256 running = uint256(cp.count);
        uint256 total;

        for (uint256 e = last + 1; e <= end; e++) {
            running += _joinoffs[sid][e];
            uint256 drops = _dropoffs[sid][e];
            if (drops > running) drops = running;
            running -= drops;
            delete _joinoffs[sid][e];
            delete _dropoffs[sid][e];
            total += running * uint256(_rate);
        }

        cp.lastEpoch = uint32(end);
        cp.count = uint224(running);

        if (total > 0) {
            _schedules[_to].principal += uint128(total);
            emit Transfer(address(this), _to, total);
            emit Collected(_to, sid, total, end - last);
        }
    }

    // ──────────────────────────────────────────────
    // Internal: Mutations
    // ──────────────────────────────────────────────

    function _mint(address _user, uint128 _amount) internal {
        Schedule storage s = _schedules[_user];
        _settle(s, _user);
        s.principal += _amount;
        totalMinted += _amount;

        if (s.rate > 0 && s.to != address(0)) {
            _updateDropoff(_user, s);
        }

        emit Transfer(address(0), _user, _amount);
    }

    function _spend(address _user, uint128 _amount) internal {
        Schedule storage s = _schedules[_user];
        _settle(s, _user);
        if (_balance(s) < _amount) revert InsufficientBalance();
        s.principal -= _amount;

        if (s.rate > 0 && s.to != address(0)) {
            _updateDropoff(_user, s);
        }

        totalSpent += _amount;
        emit Transfer(_user, address(0), _amount);
        emit Spent(_user, _amount);
    }

    function _transfer(address _from, address _to, uint256 _amount) internal {
        if (_from == address(0)) revert ERC20InvalidSender(address(0));
        if (_to == address(0)) revert ERC20InvalidReceiver(address(0));

        Schedule storage fromS = _schedules[_from];
        _settle(fromS, _from);
        if (_balance(fromS) < _amount) revert InsufficientBalance();
        fromS.principal -= uint128(_amount);

        if (fromS.rate > 0 && fromS.to != address(0)) {
            _updateDropoff(_from, fromS);
        }

        Schedule storage toS = _schedules[_to];
        _settle(toS, _to);
        toS.principal += uint128(_amount);

        if (toS.rate > 0 && toS.to != address(0)) {
            _updateDropoff(_to, toS);
        }

        emit Transfer(_from, _to, _amount);
    }

    /// @dev Assign a beneficiary schedule with immediate first-term payment.
    function _assign(
        address _user,
        address _to,
        uint128 _rate,
        uint16 _interval
    ) internal {
        if (_rate == 0 || _interval == 0) revert InvalidSchedule();
        if (_to == address(0) || _to == _user) revert InvalidBeneficiary();

        Schedule storage s = _schedules[_user];

        // Clean up existing schedule
        if (s.rate > 0) {
            if (s.to != address(0)) _removeUserFromBuckets(_user, s);
            _settleConsumed(s, _user);
        } else {
            _settle(s, _user);
        }

        // Immediate first-term payment: direct transfer to beneficiary
        if (_balance(s) < _rate) revert InsufficientBalance();
        s.principal -= _rate;
        _schedules[_to].principal += _rate;
        emit Transfer(_user, _to, _rate);

        // Set schedule
        s.rate = _rate;
        s.to = _to;
        s.interval = _interval;
        s.anchor = uint32(_today());
        s.terminatedAt = 0;

        // Bucket accounting: joinoff at next epoch (immediate payment covers current)
        bytes32 sid = _scheduleId(_to, _rate, _interval);
        uint256 currentEpoch = _epochOf(_interval);
        uint256 joinEpoch = currentEpoch + 1;
        _joinoffs[sid][joinEpoch]++;

        uint256 fundedTerms = uint256(s.principal) / uint256(_rate);
        uint256 dropoffEpoch = joinEpoch + fundedTerms;
        _dropoffs[sid][dropoffEpoch]++;
        _userDropoffEpoch[_user] = uint32(dropoffEpoch);

        emit ScheduleSet(_user, _to, _rate, _interval, sid);
        _notifyListener(_user, true);
    }

    /// @dev Set a burn-path schedule (to == address(0)). No bucket accounting.
    function _setSchedule(
        address _user,
        uint128 _rate,
        uint16 _interval
    ) internal {
        if (_rate == 0 || _interval == 0) revert InvalidSchedule();

        Schedule storage s = _schedules[_user];

        if (s.rate > 0) {
            if (s.to != address(0)) _removeUserFromBuckets(_user, s);
            _settleConsumed(s, _user);
        } else {
            _settle(s, _user);
        }

        s.rate = _rate;
        s.to = address(0);
        s.interval = _interval;
        s.anchor = uint32(_today());
        s.terminatedAt = 0;

        emit ScheduleSet(_user, address(0), _rate, _interval, bytes32(0));
        _notifyListener(_user, true);
    }

    function _terminateSchedule(address _user) internal {
        Schedule storage s = _schedules[_user];
        if (s.rate == 0) revert NoSchedule();
        if (s.terminatedAt > 0) revert NoSchedule();
        if (_expiry(s) <= _today()) return; // already lapsed

        // Move dropoff for beneficiary schedules
        if (s.to != address(0)) {
            bytes32 sid = _scheduleId(s.to, s.rate, s.interval);
            uint256 svcEnd = _serviceEnd(s);
            uint256 svcEndEpoch = _epochOfDay(svcEnd, s.interval);
            uint32 oldDropoff = _userDropoffEpoch[_user];

            if (oldDropoff > 0) {
                _dropoffs[sid][uint256(oldDropoff)]--;
            }
            _dropoffs[sid][svcEndEpoch + 1]++;
            _userDropoffEpoch[_user] = uint32(svcEndEpoch + 1);
        }

        s.terminatedAt = uint32(_today());
        emit ScheduleTerminated(_user, s.terminatedAt);
    }

    /// @dev Beneficiary comps N periods for a user. Settles consumed, moves anchor
    ///      forward by N intervals, writes dropoff (user pauses paying) and joinoff
    ///      (user resumes after N free periods). Existing dropoff stays for when
    ///      funds run out. Only for beneficiary schedules.
    function _comp(address _user, uint8 _periods) internal {
        Schedule storage s = _schedules[_user];
        if (s.rate == 0) revert NoSchedule();
        if (s.to == address(0)) revert InvalidBeneficiary();
        if (s.terminatedAt > 0) revert NoSchedule();
        if (_expiry(s) <= _today()) revert NoSchedule();
        if (_periods == 0) revert InvalidSchedule();

        bytes32 sid = _scheduleId(s.to, s.rate, s.interval);
        uint256 currentEpoch = _epochOf(s.interval);

        // Settle consumed so far, move anchor forward by N intervals
        _settleConsumed(s, _user);
        s.anchor = uint32(_today());

        // User stops paying at next epoch, resumes after N free epochs
        _dropoffs[sid][currentEpoch + 1]++;
        _joinoffs[sid][currentEpoch + 1 + uint256(_periods)]++;

        // Recalculate dropoff from new anchor (funded periods may differ)
        uint256 fundedTerms = uint256(s.principal) / uint256(s.rate);
        uint256 oldDropoff = uint256(_userDropoffEpoch[_user]);
        uint256 newDropoff = currentEpoch + 1 + uint256(_periods) + fundedTerms;

        if (oldDropoff > 0 && oldDropoff != newDropoff) {
            _dropoffs[sid][oldDropoff]--;
        }
        _dropoffs[sid][newDropoff]++;
        _userDropoffEpoch[_user] = uint32(newDropoff);

        emit ScheduleComped(_user, sid, _periods);
    }

    function _clearSchedule(address _user) internal {
        Schedule storage s = _schedules[_user];
        if (s.rate == 0) revert NoSchedule();

        if (s.to != address(0)) _removeUserFromBuckets(_user, s);
        _settleConsumed(s, _user);

        s.rate = 0;
        s.to = address(0);
        s.interval = 0;
        s.anchor = 0;
        s.terminatedAt = 0;

        emit ScheduleCleared(_user);
        _notifyListener(_user, false);
    }

    // ──────────────────────────────────────────────
    // Internal: Lazy Math
    // ──────────────────────────────────────────────

    function _today() internal view virtual returns (uint256) {
        return block.timestamp / _SECONDS_PER_DAY;
    }

    function _balance(Schedule storage _s) internal view returns (uint256) {
        if (_s.rate == 0) return uint256(_s.principal);
        uint256 c = _consumed(_s);
        return uint256(_s.principal) - c;
    }

    /// @dev consumed = min(periodsElapsed, fundedPeriods) * rate.
    ///      First payment at boundary (no +1). Immediate payment is separate.
    function _consumed(Schedule storage _s) internal view returns (uint256) {
        if (_s.rate == 0) return 0;

        uint256 dayRef = _s.terminatedAt > 0 ? uint256(_s.terminatedAt) : _today();
        if (dayRef <= uint256(_s.anchor)) return 0;
        uint256 elapsed = dayRef - uint256(_s.anchor);
        uint256 periodsElapsed = elapsed / uint256(_s.interval);

        uint256 funded = uint256(_s.principal) / uint256(_s.rate);
        uint256 effective = periodsElapsed < funded ? periodsElapsed : funded;
        return effective * uint256(_s.rate);
    }

    function _expiry(Schedule storage _s) internal view returns (uint256) {
        uint256 funded = uint256(_s.principal) / uint256(_s.rate);
        return uint256(_s.anchor) + funded * uint256(_s.interval);
    }

    function _serviceEnd(Schedule storage _s) internal view returns (uint256) {
        if (_s.terminatedAt > 0) {
            uint256 elapsed = uint256(_s.terminatedAt) - uint256(_s.anchor);
            uint256 periodsElapsed = elapsed / uint256(_s.interval);
            return uint256(_s.anchor) + (periodsElapsed + 1) * uint256(_s.interval);
        }
        return _expiry(_s);
    }

    // ──────────────────────────────────────────────
    // Internal: Epoch helpers
    // ──────────────────────────────────────────────

    function _scheduleId(address _to, uint128 _rate, uint16 _interval) internal pure returns (bytes32) {
        return keccak256(abi.encode(_to, _rate, _interval));
    }

    function _epochOf(uint16 _termDays) internal view returns (uint256) {
        uint256 today = _today();
        if (today <= uint256(DEPLOY_DAY)) return 0;
        return (today - uint256(DEPLOY_DAY)) / uint256(_termDays);
    }

    function _epochOfDay(uint256 _day, uint16 _termDays) internal view returns (uint256) {
        if (_day <= uint256(DEPLOY_DAY)) return 0;
        return (_day - uint256(DEPLOY_DAY)) / uint256(_termDays);
    }

    // ──────────────────────────────────────────────
    // Internal: Settlement
    // ──────────────────────────────────────────────

    function _settleConsumed(Schedule storage _s, address _user) internal returns (uint256 c) {
        c = _consumed(_s);
        if (c > 0) {
            _s.principal -= uint128(c);
            if (_s.to == address(0)) {
                totalBurned += c;
                emit Transfer(_user, address(0), c);
            } else {
                emit Siphoned(_user, _s.to, c);
            }
        }
    }

    /// @dev Lazy cleanup. Lapse or terminated+expired always clears the schedule.
    function _settle(Schedule storage _s, address _user) internal {
        if (_s.rate == 0) return;

        bool lapsed = _expiry(_s) <= _today();
        bool expired = _s.terminatedAt > 0 && _serviceEnd(_s) <= _today();

        if (!lapsed && !expired) return;

        uint256 c = _settleConsumed(_s, _user);

        // Always clear — no autorenew
        _s.rate = 0;
        _s.to = address(0);
        _s.interval = 0;
        _s.anchor = 0;
        _s.terminatedAt = 0;

        emit ScheduleSettled(_user, c);
        _notifyListener(_user, false);
    }

    // ──────────────────────────────────────────────
    // Internal: Bucket Management
    // ──────────────────────────────────────────────

    /// @dev Update a user's dropoff after their principal changed (mint/spend/transfer).
    function _updateDropoff(address _user, Schedule storage _s) internal {
        bytes32 sid = _scheduleId(_s.to, _s.rate, _s.interval);
        uint32 oldDropoff = _userDropoffEpoch[_user];
        uint256 currentEpoch = _epochOf(_s.interval);

        uint256 fundedTerms = uint256(_s.principal) / uint256(_s.rate);
        uint256 newDropoff = currentEpoch + 1 + fundedTerms;

        if (uint256(oldDropoff) != newDropoff) {
            if (oldDropoff > 0) {
                _dropoffs[sid][uint256(oldDropoff)]--;
            }
            _dropoffs[sid][newDropoff]++;
            _userDropoffEpoch[_user] = uint32(newDropoff);
        }
    }

    /// @dev Remove a user from the bucket system entirely.
    function _removeUserFromBuckets(address _user, Schedule storage _s) internal {
        bytes32 sid = _scheduleId(_s.to, _s.rate, _s.interval);
        Checkpoint storage cp = _checkpoints[sid];

        // Remove joinoff if it hasn't been collected yet
        uint256 joinEpoch = _epochOfDay(uint256(_s.anchor), _s.interval) + 1;
        if (joinEpoch > uint256(cp.lastEpoch)) {
            uint256 j = _joinoffs[sid][joinEpoch];
            if (j > 0) _joinoffs[sid][joinEpoch] = j - 1;
        }

        // Remove dropoff if it hasn't been collected yet
        uint32 dropoffEpoch = _userDropoffEpoch[_user];
        if (dropoffEpoch > 0 && uint256(dropoffEpoch) > uint256(cp.lastEpoch)) {
            uint256 d = _dropoffs[sid][uint256(dropoffEpoch)];
            if (d > 0) _dropoffs[sid][uint256(dropoffEpoch)] = d - 1;
        }

        _userDropoffEpoch[_user] = 0;
    }

    // ──────────────────────────────────────────────
    // Internal: Listener
    // ──────────────────────────────────────────────

    function _setScheduleListener(address _listener) internal {
        scheduleListener = _listener;
        emit ScheduleListenerSet(_listener);
    }

    function _notifyListener(address _user, bool _active) internal {
        address listener = scheduleListener;
        if (listener == address(0)) return;
        try IScheduleListener(listener).onScheduleUpdate(address(this), _user, _active) {} catch {}
    }
}
