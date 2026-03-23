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
 *   GRACE PERIODS (prepaid)
 *     Schedules can have gracePeriods — periods where no principal is consumed.
 *     After grace, normal siphoning resumes. Adding grace to an active schedule
 *     settles consumed so far and restarts the anchor from today.
 *
 *   LAZY SETTLEMENT
 *     balanceOf is computed on-the-fly from (principal, rate, anchor, interval).
 *     Storage only changes on interaction via _settle. No keeper, no cron.
 *
 *   FULLY TRANSFERABLE
 *     Standard ERC20 transfer/approve/transferFrom. Override to restrict.
 *     Schedule math automatically adjusts: transfers change principal,
 *     which changes funded periods and expiry.
 *
 *   SCHEDULE STRUCT — TWO STORAGE SLOTS
 *     Slot 1: { uint128 principal, uint128 rate }
 *     Slot 2: { uint32 interval, uint48 anchor, uint48 terminatedAt,
 *               uint16 cap, uint16 gracePeriods }  [96 bits free]
 *
 *   IMPLEMENTER RESPONSIBILITIES
 *     Concrete contracts must implement: name(), symbol(), decimals(),
 *     _maxTotalPeriods(). Override transfer/transferFrom to restrict.
 */
abstract contract SiphonToken is IERC20, IERC20Metadata {
    // ──────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────

    error InsufficientBalance();
    error InsufficientAllowance();
    error NoSchedule();
    error ERC20InvalidReceiver(address receiver);
    error ERC20InvalidSender(address sender);

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    event ScheduleSet(address indexed user, uint128 rate, uint32 interval, uint16 cap, uint16 gracePeriods);
    event ScheduleTerminated(address indexed user, uint48 terminatedAt);
    event ScheduleCleared(address indexed user);
    event ScheduleSettled(address indexed user, uint256 amount);
    event GracePeriodsSet(address indexed user, uint16 gracePeriods);
    event Siphoned(address indexed user, uint256 amount);
    event Spent(address indexed user, uint256 amount);
    event ScheduleListenerSet(address listener);

    // ──────────────────────────────────────────────
    // Structs
    // ──────────────────────────────────────────────

    /**
     * @dev Two storage slots per user.
     *   Slot 1 (256 bits): principal (128) + rate (128)
     *   Slot 2 (256 bits): interval (32) + anchor (48) + terminatedAt (48)
     *                      + cap (16) + gracePeriods (16) = 160 [96 free]
     */
    struct Schedule {
        uint128 principal; // base balance (reduced by settle + spend)
        uint128 rate; // amount siphoned per period (0 = no schedule)
        uint32 interval; // period length in days
        uint48 anchor; // dayIndex when schedule started
        uint48 terminatedAt; // dayIndex when terminated (0 = active)
        uint16 cap; // user limit on total periods (0 = auto)
        uint16 gracePeriods; // prepaid periods not siphoned
    }

    // ──────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────

    uint256 internal constant _SECONDS_PER_DAY = 86_400;

    // ──────────────────────────────────────────────
    // State
    // ──────────────────────────────────────────────

    mapping(address => Schedule) internal _schedules;
    mapping(address => mapping(address => uint256)) internal _allowances;
    uint256 public totalMinted;
    uint256 public totalSiphoned;
    uint256 public totalSpent;

    /// @notice Optional callback for schedule state changes.
    address public scheduleListener;

    // ──────────────────────────────────────────────
    // Abstract — must implement
    // ──────────────────────────────────────────────

    /// @dev Global safety cap on total periods (grace + funded). 0 = unlimited.
    function _maxTotalPeriods() internal pure virtual returns (uint256);

    // ──────────────────────────────────────────────
    // ERC20
    // ──────────────────────────────────────────────

    function balanceOf(
        address _user
    ) external view returns (uint256) {
        return _balance(_schedules[_user]);
    }

    function totalSupply() external view returns (uint256) {
        return totalMinted - totalSiphoned - totalSpent;
    }

    function transfer(
        address _to,
        uint256 _amount
    ) external virtual returns (bool) {
        _transfer(msg.sender, _to, _amount);
        return true;
    }

    function transferFrom(
        address _from,
        address _to,
        uint256 _amount
    ) external virtual returns (bool) {
        uint256 allowed = _allowances[_from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < _amount) revert InsufficientAllowance();
            _allowances[_from][msg.sender] = allowed - _amount;
        }
        _transfer(_from, _to, _amount);
        return true;
    }

    function approve(
        address _spender,
        uint256 _amount
    ) external virtual returns (bool) {
        _allowances[msg.sender][_spender] = _amount;
        emit Approval(msg.sender, _spender, _amount);
        return true;
    }

    function allowance(
        address _owner,
        address _spender
    ) external view returns (uint256) {
        return _allowances[_owner][_spender];
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
            uint32 interval,
            uint48 anchor,
            uint48 terminatedAt,
            uint16 cap,
            uint16 gracePeriods
        )
    {
        Schedule storage s = _schedules[_user];
        return (s.principal, s.rate, s.interval, s.anchor, s.terminatedAt, s.cap, s.gracePeriods);
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
        if (s.terminatedAt > 0) return false;
        return _expiry(s) > _today();
    }

    function isTerminated(
        address _user
    ) external view returns (bool) {
        Schedule storage s = _schedules[_user];
        if (s.rate == 0) return false;
        if (s.terminatedAt == 0) return false;
        return _serviceEnd(s) > _today();
    }

    function isLapsed(
        address _user
    ) external view returns (bool) {
        Schedule storage s = _schedules[_user];
        if (s.rate == 0) return false;
        if (s.terminatedAt > 0) return false;
        return _expiry(s) <= _today();
    }

    function isGracePeriod(
        address _user
    ) external view returns (bool) {
        Schedule storage s = _schedules[_user];
        if (s.rate == 0 || s.gracePeriods == 0) return false;
        uint256 elapsed = _today() - uint256(s.anchor);
        uint256 started = (elapsed / uint256(s.interval)) + 1;
        return started <= uint256(s.gracePeriods);
    }

    function currentDay() external view returns (uint256) {
        return _today();
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

    function _transfer(address _from, address _to, uint256 _amount) internal {
        if (_from == address(0)) revert ERC20InvalidSender(address(0));
        if (_to == address(0)) revert ERC20InvalidReceiver(address(0));

        Schedule storage fromS = _schedules[_from];
        _settle(fromS, _from);
        if (_balance(fromS) < _amount) revert InsufficientBalance();
        fromS.principal -= uint128(_amount);

        Schedule storage toS = _schedules[_to];
        _settle(toS, _to);
        toS.principal += uint128(_amount);

        emit Transfer(_from, _to, _amount);
    }

    function _setSchedule(
        address _user,
        uint128 _rate,
        uint32 _interval,
        uint16 _cap,
        uint16 _gracePeriods
    ) internal {
        if (_rate == 0 || _interval == 0) revert NoSchedule();

        Schedule storage s = _schedules[_user];

        if (s.rate > 0) {
            _settleConsumed(s, _user);
        } else {
            _settle(s, _user);
        }

        if (s.principal < _rate && _gracePeriods == 0) revert InsufficientBalance();

        s.rate = _rate;
        s.interval = _interval;
        s.anchor = uint48(_today());
        s.terminatedAt = 0;
        s.cap = _cap;
        s.gracePeriods = _gracePeriods;

        emit ScheduleSet(_user, _rate, _interval, _cap, _gracePeriods);
        _notifyListener(_user, true);
    }

    function _terminateSchedule(address _user) internal {
        Schedule storage s = _schedules[_user];
        if (s.rate == 0) revert NoSchedule();
        if (s.terminatedAt > 0) revert NoSchedule();
        if (_expiry(s) <= _today()) return; // already lapsed

        s.terminatedAt = uint48(_today());
        emit ScheduleTerminated(_user, s.terminatedAt);
    }

    function _clearSchedule(address _user) internal {
        Schedule storage s = _schedules[_user];
        if (s.rate == 0) revert NoSchedule();

        _settleConsumed(s, _user);

        s.rate = 0;
        s.interval = 0;
        s.anchor = 0;
        s.terminatedAt = 0;
        s.cap = 0;
        s.gracePeriods = 0;

        emit ScheduleCleared(_user);
        _notifyListener(_user, false);
    }

    function _addGracePeriods(address _user, uint16 _periods) internal {
        Schedule storage s = _schedules[_user];
        if (s.rate == 0) revert NoSchedule();
        if (s.terminatedAt > 0) revert NoSchedule();
        if (_expiry(s) <= _today()) revert NoSchedule();

        // Settle consumed so far, restart anchor
        _settleConsumed(s, _user);
        s.anchor = uint48(_today());
        s.gracePeriods = _periods;

        emit GracePeriodsSet(_user, s.gracePeriods);
        _notifyListener(_user, true);
    }

    function _setCap(address _user, uint16 _cap) internal {
        Schedule storage s = _schedules[_user];
        if (s.rate == 0) revert NoSchedule();
        if (s.terminatedAt > 0) revert NoSchedule();
        s.cap = _cap;
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

    function _today() internal view virtual returns (uint256) {
        return block.timestamp / _SECONDS_PER_DAY;
    }

    /// @dev Computed balance = principal - consumed. Just principal if no schedule.
    function _balance(
        Schedule storage _s
    ) internal view returns (uint256) {
        if (_s.rate == 0) return uint256(_s.principal);
        uint256 c = _consumed(_s);
        return uint256(_s.principal) - c;
    }

    /// @dev Billable periods = periods elapsed minus grace (floored at 0).
    ///      Capped by funded periods, user cap, and _maxTotalPeriods.
    function _consumed(
        Schedule storage _s
    ) internal view returns (uint256) {
        if (_s.rate == 0) return 0;

        uint256 dayRef = _s.terminatedAt > 0 ? uint256(_s.terminatedAt) : _today();
        uint256 elapsed = dayRef - uint256(_s.anchor);
        uint256 started = (elapsed / uint256(_s.interval)) + 1;

        uint256 grace = uint256(_s.gracePeriods);
        uint256 billable = started > grace ? started - grace : 0;

        uint256 funded = uint256(_s.principal) / uint256(_s.rate);
        uint256 capped = _capFunded(_s, funded);
        uint256 effective = billable < capped ? billable : capped;
        return effective * uint256(_s.rate);
    }

    /// @dev Cap funded (billable) periods. _maxTotalPeriods is the global safety
    ///      limit (protocol-level). cap is the per-user preference. Both apply to
    ///      total periods (grace + funded).
    function _capFunded(
        Schedule storage _s,
        uint256 _funded
    ) internal view returns (uint256) {
        uint256 c = _funded;
        uint256 grace = uint256(_s.gracePeriods);
        uint256 maxTotal = _maxTotalPeriods();

        if (maxTotal > 0 && grace + c > maxTotal) {
            c = maxTotal > grace ? maxTotal - grace : 0;
        }

        if (_s.cap > 0 && grace + c > uint256(_s.cap)) {
            c = uint256(_s.cap) > grace ? uint256(_s.cap) - grace : 0;
        }

        return c;
    }

    /// @dev DayIndex when all periods (grace + funded) are exhausted.
    function _expiry(
        Schedule storage _s
    ) internal view returns (uint256) {
        uint256 funded = uint256(_s.principal) / uint256(_s.rate);
        uint256 capped = _capFunded(_s, funded);
        uint256 total = uint256(_s.gracePeriods) + capped;
        return uint256(_s.anchor) + total * uint256(_s.interval);
    }

    /// @dev For terminated schedules, service ends at the current period boundary.
    function _serviceEnd(
        Schedule storage _s
    ) internal view returns (uint256) {
        if (_s.terminatedAt > 0) {
            uint256 elapsed = uint256(_s.terminatedAt) - uint256(_s.anchor);
            uint256 started = (elapsed / uint256(_s.interval)) + 1;
            return uint256(_s.anchor) + started * uint256(_s.interval);
        }
        return _expiry(_s);
    }

    // ──────────────────────────────────────────────
    // Internal: Settlement
    // ──────────────────────────────────────────────

    /**
     * @dev Deduct consumed from principal and emit events. Returns the amount
     *      consumed. Does NOT clear or restart the schedule — callers handle that.
     */
    function _settleConsumed(
        Schedule storage _s,
        address _user
    ) internal returns (uint256 c) {
        c = _consumed(_s);
        if (c > 0) {
            _s.principal -= uint128(c);
            totalSiphoned += c;
            emit Transfer(_user, address(0), c);
            emit Siphoned(_user, c);
        }
    }

    /**
     * @dev Lazy cleanup. Only fires for ended schedules (lapsed or terminated+expired).
     *      Deducts consumed, clears all schedule fields, notifies listener.
     *      Safe to call on every interaction — no-op for active schedules.
     */
    function _settle(
        Schedule storage _s,
        address _user
    ) internal {
        if (_s.rate == 0) return;

        bool lapsed = _expiry(_s) <= _today();
        bool expired = _s.terminatedAt > 0 && _serviceEnd(_s) <= _today();
        if (!lapsed && !expired) return;

        uint256 c = _settleConsumed(_s, _user);

        _s.rate = 0;
        _s.interval = 0;
        _s.anchor = 0;
        _s.terminatedAt = 0;
        _s.cap = 0;
        _s.gracePeriods = 0;

        emit ScheduleSettled(_user, c);
        _notifyListener(_user, false);
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
