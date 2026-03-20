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
 *     Each period's full cost is committed when the period starts. If you're
 *     1 day into a 30-day period, the full period is consumed. This is how
 *     real subscriptions work, not per-second streaming.
 *
 *   SKIP PERIODS (prepaid months)
 *     Schedules can have skipPeriods — periods where no balance is consumed.
 *     Used for prepaid months. After skip periods, normal siphoning resumes.
 *     Adding skip to an active schedule checkpoints first (settles consumed,
 *     restarts from current day).
 *
 *   LAZY SETTLEMENT
 *     balanceOf is computed on-the-fly. Storage only changes on interaction
 *     via _settle (after lapse/cancel) or _checkpoint (mid-schedule adjust).
 *     No keeper, no cron, no per-period transactions.
 *
 *   NON-TRANSFERABLE BY DEFAULT
 *     transfer/transferFrom/approve revert. Override _canTransfer for custom
 *     transfer logic (e.g. whitelist).
 *
 *   SCHEDULE STRUCT — TWO STORAGE SLOTS
 *     Slot 1: { uint128 principal, uint128 rate }
 *     Slot 2: { uint32 periodDays, uint48 startedAt, uint48 canceledDay,
 *               uint16 maxPeriods, uint16 skipPeriods }  [96 bits free]
 *
 *   IMPLEMENTER RESPONSIBILITIES
 *     Concrete contracts must implement: name(), symbol(), decimals(),
 *     _maxPrepaidPeriods(). They expose internal mutators (_mint, _spend,
 *     _setSchedule, etc.) behind their own access control.
 */
abstract contract SiphonToken is IERC20, IERC20Metadata {
    // ──────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────

    error InsufficientBalance();
    error NonTransferable();
    error NoSchedule();
    error ScheduleActive();

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    event ScheduleSet(address indexed user, uint128 rate, uint32 periodDays, uint16 maxPeriods, uint16 skipPeriods);
    event ScheduleCanceled(address indexed user, uint48 canceledDay);
    event ScheduleCleared(address indexed user);
    event ScheduleSettled(address indexed user, uint256 consumed);
    event SkipPeriodsAdded(address indexed user, uint16 added, uint16 total);
    event Siphoned(address indexed user, uint256 amount);
    event Spent(address indexed user, uint256 amount);
    event Checkpointed(address indexed user, uint256 consumed);

    // ──────────────────────────────────────────────
    // Structs
    // ──────────────────────────────────────────────

    /**
     * @dev Two storage slots per user.
     *   Slot 1 (256 bits): principal (128) + rate (128)
     *   Slot 2 (256 bits): periodDays (32) + startedAt (48) + canceledDay (48)
     *                      + maxPeriods (16) + skipPeriods (16) = 160 [96 free]
     */
    struct Schedule {
        uint128 principal; // net balance (reduced by settle + spend)
        uint128 rate; // amount siphoned per period (0 = no schedule)
        uint32 periodDays; // period length in days
        uint48 startedAt; // dayIndex when schedule started
        uint48 canceledDay; // dayIndex when canceled (0 = active)
        uint16 maxPeriods; // user cap on total periods (0 = auto)
        uint16 skipPeriods; // prepaid periods (not siphoned)
    }

    // ──────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────

    uint256 internal constant SECONDS_PER_DAY = 86_400;

    // ──────────────────────────────────────────────
    // State
    // ──────────────────────────────────────────────

    mapping(address => Schedule) internal _schedules;
    uint256 public totalMinted;
    uint256 public totalSiphoned;
    uint256 public totalSpent;

    /// @notice Optional callback for schedule state changes.
    address public scheduleListener;

    // ──────────────────────────────────────────────
    // Abstract — must implement
    // ──────────────────────────────────────────────

    /// @dev Max total periods (skip + funded). 0 = unlimited.
    function _maxPrepaidPeriods() internal pure virtual returns (uint256);

    // ──────────────────────────────────────────────
    // ERC20 Views
    // ──────────────────────────────────────────────

    function balanceOf(
        address _user
    ) external view returns (uint256) {
        return _balance(_schedules[_user]);
    }

    function totalSupply() external view returns (uint256) {
        return totalMinted - totalSiphoned - totalSpent;
    }

    // ── Non-transferable by default ──

    function transfer(address, uint256) external virtual returns (bool) {
        revert NonTransferable();
    }

    function transferFrom(address, address, uint256) external virtual returns (bool) {
        revert NonTransferable();
    }

    function approve(address, uint256) external virtual returns (bool) {
        revert NonTransferable();
    }

    function allowance(address, address) external view virtual returns (uint256) {
        return 0;
    }

    // ──────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────

    function getSchedule(
        address _user
    )
        external
        view
        returns (
            uint128 principal,
            uint128 rate,
            uint32 periodDays,
            uint48 startedAt,
            uint48 canceledDay,
            uint16 maxPeriods,
            uint16 skipPeriods
        )
    {
        Schedule storage s = _schedules[_user];
        return (s.principal, s.rate, s.periodDays, s.startedAt, s.canceledDay, s.maxPeriods, s.skipPeriods);
    }

    function consumed(
        address _user
    ) external view returns (uint256) {
        return _consumed(_schedules[_user]);
    }

    function expiry(
        address _user
    ) external view returns (uint256) {
        Schedule storage s = _schedules[_user];
        if (s.rate == 0) return 0;
        return _serviceEnd(s);
    }

    function isActive(
        address _user
    ) external view returns (bool) {
        Schedule storage s = _schedules[_user];
        if (s.rate == 0) return false;
        if (s.canceledDay > 0) return false;
        return _expiry(s) > _currentDay();
    }

    function isCanceled(
        address _user
    ) external view returns (bool) {
        Schedule storage s = _schedules[_user];
        if (s.rate == 0) return false;
        if (s.canceledDay == 0) return false;
        return _serviceEnd(s) > _currentDay();
    }

    function isLapsed(
        address _user
    ) external view returns (bool) {
        Schedule storage s = _schedules[_user];
        if (s.rate == 0) return false;
        if (s.canceledDay > 0) return false;
        return _expiry(s) <= _currentDay();
    }

    /// @notice True if the user is currently in a skip (prepaid) zone.
    function isInSkipZone(
        address _user
    ) external view returns (bool) {
        Schedule storage s = _schedules[_user];
        if (s.rate == 0 || s.skipPeriods == 0) return false;
        uint256 elapsed = _currentDay() - uint256(s.startedAt);
        uint256 periodsStarted = (elapsed / uint256(s.periodDays)) + 1;
        return periodsStarted <= uint256(s.skipPeriods);
    }

    function currentDay() external view returns (uint256) {
        return _currentDay();
    }

    // ──────────────────────────────────────────────
    // Internal: Mutations
    // ──────────────────────────────────────────────

    function _mint(address _user, uint128 _amount) internal {
        Schedule storage s = _schedules[_user];
        _settle(s, _user);
        s.principal += _amount;
        totalMinted += _amount;
        emit Transfer(address(0), _user, _amount);
    }

    function _spend(address _user, uint128 _amount) internal {
        Schedule storage s = _schedules[_user];
        _settle(s, _user);
        if (_balance(s) < _amount) revert InsufficientBalance();
        s.principal -= _amount;
        totalSpent += _amount;
        emit Transfer(_user, address(0), _amount);
        emit Spent(_user, _amount);
    }

    function _setSchedule(
        address _user,
        uint128 _rate,
        uint32 _periodDays,
        uint16 _maxPeriods,
        uint16 _skipPeriods
    ) internal {
        if (_rate == 0 || _periodDays == 0) revert NoSchedule();

        Schedule storage s = _schedules[_user];

        // If an existing schedule is active, checkpoint it first
        if (s.rate > 0) {
            _checkpoint(s, _user);
        } else {
            _settle(s, _user); // clear any stale ended schedule
        }

        if (s.principal < _rate && _skipPeriods == 0) revert InsufficientBalance();

        s.rate = _rate;
        s.periodDays = _periodDays;
        s.startedAt = uint48(_currentDay());
        s.canceledDay = 0;
        s.maxPeriods = _maxPeriods;
        s.skipPeriods = _skipPeriods;

        emit ScheduleSet(_user, _rate, _periodDays, _maxPeriods, _skipPeriods);
        _notifyListener(_user, true);
    }

    function _cancelSchedule(address _user) internal {
        Schedule storage s = _schedules[_user];
        if (s.rate == 0) revert NoSchedule();
        if (s.canceledDay > 0) revert NoSchedule();
        if (_expiry(s) <= _currentDay()) return; // already lapsed

        s.canceledDay = uint48(_currentDay());
        emit ScheduleCanceled(_user, s.canceledDay);
        // Still active until period end, so don't notify false yet
    }

    function _clearSchedule(address _user) internal {
        Schedule storage s = _schedules[_user];
        if (s.rate == 0) revert NoSchedule();

        uint256 c = _consumed(s);
        if (c > 0) {
            s.principal -= uint128(c);
            totalSiphoned += c;
            emit Transfer(_user, address(0), c);
            emit Siphoned(_user, c);
        }

        s.rate = 0;
        s.periodDays = 0;
        s.startedAt = 0;
        s.canceledDay = 0;
        s.maxPeriods = 0;
        s.skipPeriods = 0;

        emit ScheduleCleared(_user);
        _notifyListener(_user, false);
    }

    function _addSkipPeriods(address _user, uint16 _periods) internal {
        Schedule storage s = _schedules[_user];
        if (s.rate == 0) revert NoSchedule();
        if (s.canceledDay > 0) revert NoSchedule();

        // Checkpoint: settle consumed so far, restart from today
        _checkpoint(s, _user);

        s.skipPeriods += _periods;
        emit SkipPeriodsAdded(_user, _periods, s.skipPeriods);
        _notifyListener(_user, true);
    }

    function _setMaxPeriods(address _user, uint16 _maxPeriods) internal {
        Schedule storage s = _schedules[_user];
        if (s.rate == 0) revert NoSchedule();
        if (s.canceledDay > 0) revert NoSchedule();
        s.maxPeriods = _maxPeriods;
    }

    // ──────────────────────────────────────────────
    // Public: Settle
    // ──────────────────────────────────────────────

    /// @notice Trigger lazy settlement for a user. Anyone can call.
    function settle(
        address _user
    ) external {
        _settle(_schedules[_user], _user);
    }

    // ──────────────────────────────────────────────
    // Internal: Lazy Math
    // ──────────────────────────────────────────────

    function _currentDay() internal view returns (uint256) {
        return block.timestamp / SECONDS_PER_DAY;
    }

    function _balance(
        Schedule storage _s
    ) internal view returns (uint256) {
        if (_s.rate == 0) return uint256(_s.principal);
        uint256 c = _consumed(_s);
        return uint256(_s.principal) - c;
    }

    /// @dev Billable periods = periods started minus skip periods (floored at 0).
    ///      Capped by funded periods, maxPeriods, and MAX_PREPAID.
    function _consumed(
        Schedule storage _s
    ) internal view returns (uint256) {
        if (_s.rate == 0) return 0;

        uint256 dayRef = _s.canceledDay > 0 ? uint256(_s.canceledDay) : _currentDay();
        uint256 elapsed = dayRef - uint256(_s.startedAt);
        uint256 periodsStarted = (elapsed / uint256(_s.periodDays)) + 1;

        // Subtract skip periods
        uint256 skip = uint256(_s.skipPeriods);
        uint256 billable = periodsStarted > skip ? periodsStarted - skip : 0;

        uint256 funded = uint256(_s.principal) / uint256(_s.rate);
        uint256 capped = _capFunded(_s, funded);
        uint256 effective = billable < capped ? billable : capped;
        return effective * uint256(_s.rate);
    }

    /// @dev Cap funded (billable) periods by MAX_PREPAID and maxPeriods.
    ///      Both caps are on TOTAL periods (skip + billable).
    function _capFunded(
        Schedule storage _s,
        uint256 _funded
    ) internal view returns (uint256) {
        uint256 c = _funded;
        uint256 skip = uint256(_s.skipPeriods);
        uint256 maxTotal = _maxPrepaidPeriods();

        // Global cap on total periods
        if (maxTotal > 0 && skip + c > maxTotal) {
            c = maxTotal > skip ? maxTotal - skip : 0;
        }

        // User cap on total periods
        if (_s.maxPeriods > 0 && skip + c > uint256(_s.maxPeriods)) {
            c = uint256(_s.maxPeriods) > skip ? uint256(_s.maxPeriods) - skip : 0;
        }

        return c;
    }

    /// @dev DayIndex when all periods (skip + funded) are exhausted.
    function _expiry(
        Schedule storage _s
    ) internal view returns (uint256) {
        uint256 funded = uint256(_s.principal) / uint256(_s.rate);
        uint256 capped = _capFunded(_s, funded);
        uint256 totalPeriods = uint256(_s.skipPeriods) + capped;
        return uint256(_s.startedAt) + totalPeriods * uint256(_s.periodDays);
    }

    /// @dev For canceled users, service ends at the current period boundary.
    function _serviceEnd(
        Schedule storage _s
    ) internal view returns (uint256) {
        if (_s.canceledDay > 0) {
            uint256 elapsed = uint256(_s.canceledDay) - uint256(_s.startedAt);
            uint256 periodsStarted = (elapsed / uint256(_s.periodDays)) + 1;
            return uint256(_s.startedAt) + periodsStarted * uint256(_s.periodDays);
        }
        return _expiry(_s);
    }

    // ──────────────────────────────────────────────
    // Internal: Settlement
    // ──────────────────────────────────────────────

    /**
     * @dev Lazy cleanup after a schedule ends (lapsed or canceled+expired).
     *      Deducts consumed from principal, clears all schedule fields.
     *      Emits Transfer for ERC20 indexer compatibility.
     */
    function _settle(
        Schedule storage _s,
        address _user
    ) internal {
        if (_s.rate == 0) return;

        bool canceled = _s.canceledDay > 0;
        bool lapsed = _expiry(_s) <= _currentDay();
        if (!canceled && !lapsed) return;

        uint256 c = _consumed(_s);
        _s.principal -= uint128(c);
        _s.rate = 0;
        _s.periodDays = 0;
        _s.startedAt = 0;
        _s.canceledDay = 0;
        _s.maxPeriods = 0;
        _s.skipPeriods = 0;

        totalSiphoned += c;

        if (c > 0) {
            emit Transfer(_user, address(0), c);
            emit Siphoned(_user, c);
        }
        emit ScheduleSettled(_user, c);
        _notifyListener(_user, false);
    }

    /**
     * @dev Mid-schedule checkpoint. Settles consumed so far and restarts
     *      the schedule from current day. Used before adding skip periods
     *      or changing schedule parameters on an active schedule.
     */
    function _checkpoint(
        Schedule storage _s,
        address _user
    ) internal {
        if (_s.rate == 0) return;

        uint256 c = _consumed(_s);
        if (c > 0) {
            _s.principal -= uint128(c);
            totalSiphoned += c;
            emit Transfer(_user, address(0), c);
            emit Siphoned(_user, c);
            emit Checkpointed(_user, c);
        }

        // Restart from today
        _s.startedAt = uint48(_currentDay());
        _s.canceledDay = 0;
        _s.skipPeriods = 0;
    }

    // ──────────────────────────────────────────────
    // Internal: Listener
    // ──────────────────────────────────────────────

    function _notifyListener(address _user, bool _active) internal {
        address listener = scheduleListener;
        if (listener == address(0)) return;
        // Best-effort: don't revert if listener fails
        try IScheduleListener(listener).onScheduleUpdate(address(this), _user, _active) {} catch {}
    }
}
