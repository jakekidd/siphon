// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IScheduleListener} from "./interfaces/IScheduleListener.sol";

/**
 * @title SiphonToken — ERC20 with scheduled payment deductions
 * @author Ubitel
 *
 * @notice ERC20 where balanceOf decays over time via multiple concurrent
 *         payment schedules. Like a bank account with multiple autopays.
 *
 * @dev Key concepts:
 *
 *   MULTI-SCHEDULE
 *     Users can have up to MAX_SUBS active schedules, each paying a different
 *     beneficiary. All schedules share one principal and use the same billing
 *     interval (TERM_DAYS). balanceOf is O(1) via totalRate.
 *
 *   BENEFICIARY = SCHEDULER
 *     The beneficiary IS the entity that assigns schedules. msg.sender on
 *     assign() is the beneficiary. Users pre-approve via approveSchedule().
 *     scheduleId = keccak256(beneficiary, rate).
 *
 *   BURN PATH
 *     Burn schedules have beneficiary=address(0). Same array, same totalRate.
 *     No approval needed (self-assigned). No bucket ops (no collect for burns).
 *
 *   SPONSORSHIP
 *     Anyone can sponsor tokens for a user's specific schedule. Sponsored
 *     tokens are locked (non-transferable) and consumed BEFORE principal.
 *     A sponsored schedule can survive past shared lapse.
 *
 *   PRIORITY
 *     When funds run out, schedules are resolved in subscription order
 *     (first-assigned = first-paid). Lower-priority schedules lapse first.
 *
 *   LAZY SETTLEMENT
 *     balanceOf = principal - min(elapsed, principal/totalRate) * totalRate.
 *     O(1). Storage only changes via checkpoint on interaction.
 *
 *   SCHEDULE STRUCT — 1 SLOT PER SUBSCRIPTION
 *     UserState: { uint128 principal, uint128 totalRate }  [1 slot shared]
 *     Subscription: { uint128 rate, uint32 joinedAtEpoch, uint32 terminatedAt }
 */
abstract contract SiphonToken is IERC20, IERC20Metadata {
    // ──────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────

    error InsufficientBalance();
    /// @notice ERC20 standard (OpenZeppelin ERC20Errors.sol).
    error InsufficientAllowance();
    error NoSchedule();
    /// @notice ERC20 standard (OpenZeppelin ERC20Errors.sol).
    error ERC20InvalidReceiver(address receiver);
    /// @notice ERC20 standard (OpenZeppelin ERC20Errors.sol).
    error ERC20InvalidSender(address sender);
    error InvalidBeneficiary();
    error InvalidSchedule();
    error NotApproved();
    error Unauthorized();
    error MaxSubscriptions();
    error ScheduleNotFound();

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    event ScheduleSet(address indexed user, bytes32 indexed scheduleId, address beneficiary, uint128 rate);
    event ScheduleTerminated(address indexed user, bytes32 indexed scheduleId, uint32 terminatedAt);
    event ScheduleCleared(address indexed user, bytes32 indexed scheduleId);
    event ScheduleSettled(address indexed user, uint256 amount);
    event ScheduleApproval(address indexed user, bytes32 indexed scheduleId, uint256 count);
    event ScheduleListed(bytes32 indexed scheduleId, address indexed beneficiary, uint128 rate);
    event Sponsored(address indexed user, bytes32 indexed scheduleId, uint256 amount);
    event Siphoned(address indexed from, address indexed to, uint256 amount);
    event Spent(address indexed user, uint256 amount);
    event Collected(address indexed beneficiary, bytes32 indexed scheduleId, uint256 amount, uint256 epochs);
    event ScheduleListenerSet(address listener);

    // ──────────────────────────────────────────────
    // Structs
    // ──────────────────────────────────────────────

    /// @dev Shared per user. 1 storage slot.
    struct UserState {
        uint128 principal;
        uint128 totalRate;
    }

    /// @dev Per user per scheduleId. 1 storage slot.
    struct Subscription {
        uint128 rate;
        uint32 joinedAtEpoch;
        uint32 terminatedAt;
    }

    /// @dev Shared schedule definition. Created lazily on first assign.
    struct ScheduleConfig {
        address beneficiary;
        uint128 rate;
    }

    /// @dev Collection checkpoint per scheduleId. 1 storage slot.
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

    uint32 public immutable DEPLOY_DAY;
    uint16 public immutable TERM_DAYS;
    uint8 public immutable MAX_SUBS;

    // ──────────────────────────────────────────────
    // State
    // ──────────────────────────────────────────────

    mapping(address => UserState) internal _users;
    mapping(address => uint32) internal _userAnchor;
    mapping(address => mapping(address => uint256)) internal _allowances;

    uint256 public totalMinted;
    uint256 public totalBurned;
    uint256 public totalSpent;

    mapping(bytes32 => ScheduleConfig) internal _configs;
    mapping(address => mapping(bytes32 => uint256)) internal _scheduleApprovals;
    mapping(bytes32 => Checkpoint) internal _checkpoints;
    mapping(bytes32 => mapping(uint256 => uint256)) internal _joinoffs;
    mapping(bytes32 => mapping(uint256 => uint256)) internal _dropoffs;

    mapping(address => bytes32[]) internal _userSubs;
    mapping(address => mapping(bytes32 => Subscription)) internal _subs;
    mapping(address => mapping(bytes32 => uint32)) internal _subDropoffEpoch;
    mapping(address => mapping(bytes32 => uint256)) internal _sponsored;

    address public scheduleListener;

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    constructor(uint32 _deployDay, uint16 _termDays, uint8 _maxSubs) {
        DEPLOY_DAY = _deployDay == 0 ? uint32(block.timestamp / _SECONDS_PER_DAY) : _deployDay;
        require(_termDays > 0, "term must be > 0");
        require(_maxSubs > 0, "max subs must be > 0");
        TERM_DAYS = _termDays;
        MAX_SUBS = _maxSubs;
    }

    // ──────────────────────────────────────────────
    // ERC20
    // ──────────────────────────────────────────────

    function balanceOf(address _user) external view returns (uint256) {
        return _balance(_user);
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

    function approveSchedule(bytes32 _sid, uint256 _count) external {
        _scheduleApprovals[msg.sender][_sid] = _count;
        emit ScheduleApproval(msg.sender, _sid, _count);
    }

    function scheduleAllowance(address _user, bytes32 _sid) external view returns (uint256) {
        return _scheduleApprovals[_user][_sid];
    }

    // ──────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────

    function getUser(address _user) external view returns (uint128 principal, uint128 totalRate, uint32 anchor) {
        UserState storage u = _users[_user];
        return (u.principal, u.totalRate, _userAnchor[_user]);
    }

    function getSub(address _user, bytes32 _sid) external view returns (uint128 rate, uint32 joinedAtEpoch, uint32 terminatedAt, uint256 sponsored) {
        Subscription storage sub = _subs[_user][_sid];
        return (sub.rate, sub.joinedAtEpoch, sub.terminatedAt, _sponsored[_user][_sid]);
    }

    function getUserSubs(address _user) external view returns (bytes32[] memory) {
        return _userSubs[_user];
    }

    function consumed(address _user) external view returns (uint256) {
        return _consumed(_user);
    }

    function isActive(address _user) external view returns (bool) {
        UserState storage u = _users[_user];
        if (u.totalRate == 0) return false;
        return _funded(u) > 0 || _hasAnySponsoredActive(_user);
    }

    function isSubActive(address _user, bytes32 _sid) external view returns (bool) {
        Subscription storage sub = _subs[_user][_sid];
        if (sub.rate == 0) return false;
        if (sub.terminatedAt > 0) return false;
        UserState storage u = _users[_user];
        uint256 elapsed = _periodsElapsed(_user);
        uint256 funded = _funded(u);
        if (elapsed <= funded) return true;
        return _sponsored[_user][_sid] >= sub.rate;
    }

    function currentDay() external view returns (uint256) {
        return _today();
    }

    function currentEpoch() external view returns (uint256) {
        return _epochOf();
    }

    function scheduleId(address _beneficiary, uint128 _rate) external pure returns (bytes32) {
        return _scheduleId(_beneficiary, _rate);
    }

    function getConfig(bytes32 _sid) external view returns (address beneficiary, uint128 rate) {
        ScheduleConfig storage c = _configs[_sid];
        return (c.beneficiary, c.rate);
    }

    function getCheckpoint(bytes32 _sid) external view returns (uint32 lastEpoch, uint224 count) {
        Checkpoint storage cp = _checkpoints[_sid];
        return (cp.lastEpoch, cp.count);
    }

    // ──────────────────────────────────────────────
    // Public: Settle
    // ──────────────────────────────────────────────

    function settle(address _user) external {
        _checkpoint(_user);
    }

    // ──────────────────────────────────────────────
    // Public: Terminate
    // ──────────────────────────────────────────────

    /// @notice Terminate a specific schedule. Callable by user or the schedule's beneficiary.
    function terminate(address _user, bytes32 _sid) external virtual {
        Subscription storage sub = _subs[_user][_sid];
        if (sub.rate == 0) revert ScheduleNotFound();
        ScheduleConfig storage cfg = _configs[_sid];
        if (msg.sender != _user && msg.sender != cfg.beneficiary) revert Unauthorized();
        _checkpoint(_user);
        _terminate(_user, _sid);
    }

    // ──────────────────────────────────────────────
    // Public: Assign
    // ──────────────────────────────────────────────

    /// @notice Assign a schedule to a user. msg.sender IS the beneficiary.
    ///         Consumes one schedule approval. Immediate first-term payment.
    function assign(address _user, uint128 _rate) external virtual {
        bytes32 sid = _scheduleId(msg.sender, _rate);
        uint256 approvals = _scheduleApprovals[_user][sid];
        if (approvals == 0) revert NotApproved();
        if (approvals != type(uint256).max) {
            _scheduleApprovals[_user][sid] = approvals - 1;
        }
        _assign(_user, msg.sender, _rate);
    }

    // ──────────────────────────────────────────────
    // Public: Collect
    // ──────────────────────────────────────────────

    function collect(bytes32 _sid, uint256 _maxEpochs) external {
        ScheduleConfig storage cfg = _configs[_sid];
        if (cfg.beneficiary == address(0)) revert InvalidSchedule();

        Checkpoint storage cp = _checkpoints[_sid];
        uint256 current = _epochOf();
        uint256 last = uint256(cp.lastEpoch);
        uint256 end = last + _maxEpochs;
        if (end > current) end = current;
        if (end <= last) return;

        uint256 running = uint256(cp.count);
        uint256 total;

        for (uint256 e = last + 1; e <= end; e++) {
            running += _joinoffs[_sid][e];
            uint256 drops = _dropoffs[_sid][e];
            if (drops > running) drops = running;
            running -= drops;
            delete _joinoffs[_sid][e];
            delete _dropoffs[_sid][e];
            total += running * uint256(cfg.rate);
        }

        cp.lastEpoch = uint32(end);
        cp.count = uint224(running);

        if (total > 0) {
            _users[cfg.beneficiary].principal += uint128(total);
            emit Transfer(address(this), cfg.beneficiary, total);
            emit Collected(cfg.beneficiary, _sid, total, end - last);
        }
    }

    // ──────────────────────────────────────────────
    // Public: Sponsor
    // ──────────────────────────────────────────────

    /// @notice Sponsor tokens for a user's specific schedule. Tokens are locked
    ///         (non-transferable) and consumed before principal for that schedule.
    function sponsor(address _user, bytes32 _sid, uint128 _amount) external {
        Subscription storage sub = _subs[_user][_sid];
        if (sub.rate == 0) revert ScheduleNotFound();

        // Transfer tokens from sponsor to contract
        _transferFrom(msg.sender, address(this), _amount);
        _sponsored[_user][_sid] += _amount;

        // Recompute this sub's dropoff (it now lasts longer)
        _recomputeSubDropoff(_user, _sid);

        emit Sponsored(_user, _sid, _amount);
    }

    // ──────────────────────────────────────────────
    // Internal: Mutations
    // ──────────────────────────────────────────────

    function _mint(address _user, uint128 _amount) internal {
        _checkpoint(_user);
        _users[_user].principal += _amount;
        totalMinted += _amount;
        _recomputeAllDropoffs(_user);
        emit Transfer(address(0), _user, _amount);
    }

    function _spend(address _user, uint128 _amount) internal {
        _checkpoint(_user);
        if (_balance(_user) < _amount) revert InsufficientBalance();
        _users[_user].principal -= _amount;
        _recomputeAllDropoffs(_user);
        totalSpent += _amount;
        emit Transfer(_user, address(0), _amount);
        emit Spent(_user, _amount);
    }

    function _transfer(address _from, address _to, uint256 _amount) internal {
        if (_from == address(0)) revert ERC20InvalidSender(address(0));
        if (_to == address(0)) revert ERC20InvalidReceiver(address(0));

        _checkpoint(_from);
        if (_balance(_from) < _amount) revert InsufficientBalance();
        _users[_from].principal -= uint128(_amount);
        _recomputeAllDropoffs(_from);

        _checkpoint(_to);
        _users[_to].principal += uint128(_amount);
        _recomputeAllDropoffs(_to);

        emit Transfer(_from, _to, _amount);
    }

    /// @dev Internal transfer helper for sponsor (moves tokens from sender to contract).
    function _transferFrom(address _from, address _to, uint128 _amount) internal {
        _checkpoint(_from);
        if (_balance(_from) < _amount) revert InsufficientBalance();
        _users[_from].principal -= _amount;
        _recomputeAllDropoffs(_from);

        if (_to == address(this)) {
            // Tokens held by contract for sponsorship — still in totalSupply
        } else {
            _checkpoint(_to);
            _users[_to].principal += _amount;
            _recomputeAllDropoffs(_to);
        }

        emit Transfer(_from, _to, _amount);
    }

    /// @dev Assign a schedule to a user.
    function _assign(address _user, address _beneficiary, uint128 _rate) internal {
        if (_rate == 0) revert InvalidSchedule();
        if (_beneficiary == _user) revert InvalidBeneficiary();

        _checkpoint(_user);

        UserState storage u = _users[_user];
        bytes32 sid = _scheduleId(_beneficiary, _rate);

        // Can't double-subscribe to same schedule
        if (_subs[_user][sid].rate > 0) revert InvalidSchedule();
        if (_userSubs[_user].length >= uint256(MAX_SUBS)) revert MaxSubscriptions();

        // Ensure config exists
        if (_configs[sid].beneficiary == address(0)) {
            _configs[sid] = ScheduleConfig(_beneficiary, _rate);
            emit ScheduleListed(sid, _beneficiary, _rate);
        }

        // Immediate first-term payment
        if (_balance(_user) < _rate) revert InsufficientBalance();
        u.principal -= _rate;

        if (_beneficiary == address(0)) {
            // Burn path
            totalBurned += _rate;
            emit Transfer(_user, address(0), _rate);
        } else {
            // Beneficiary path
            _users[_beneficiary].principal += _rate;
            emit Transfer(_user, _beneficiary, _rate);
        }

        // Update user state
        u.totalRate += _rate;
        _userAnchor[_user] = uint32(_today());

        // Create subscription
        uint256 curEpoch = _epochOf();
        _subs[_user][sid] = Subscription(_rate, uint32(curEpoch + 1), 0);
        _userSubs[_user].push(sid);

        // Bucket accounting (skip for burn)
        if (_beneficiary != address(0)) {
            _joinoffs[sid][curEpoch + 1]++;
        }

        // Recompute all dropoffs (totalRate changed)
        _recomputeAllDropoffs(_user);

        emit ScheduleSet(_user, sid, _beneficiary, _rate);
        _notifyListener(_user, true);
    }

    /// @dev Terminate a specific subscription.
    function _terminate(address _user, bytes32 _sid) internal {
        Subscription storage sub = _subs[_user][_sid];
        if (sub.rate == 0) revert ScheduleNotFound();
        if (sub.terminatedAt > 0) revert NoSchedule();

        sub.terminatedAt = uint32(_today());

        UserState storage u = _users[_user];
        u.totalRate -= sub.rate;
        _userAnchor[_user] = uint32(_today());

        // Move dropoff for beneficiary schedules
        ScheduleConfig storage cfg = _configs[_sid];
        if (cfg.beneficiary != address(0)) {
            uint32 oldDropoff = _subDropoffEpoch[_user][_sid];
            uint256 svcEndEpoch = _epochOf() + 1; // service until end of current period
            if (oldDropoff > 0) _dropoffs[_sid][uint256(oldDropoff)]--;
            _dropoffs[_sid][svcEndEpoch + 1]++;
            _subDropoffEpoch[_user][_sid] = uint32(svcEndEpoch + 1);
        }

        // Remove from _userSubs (shift to preserve priority order)
        _removeFromUserSubs(_user, _sid);

        // Recompute remaining subs' dropoffs (totalRate changed)
        _recomputeAllDropoffs(_user);

        emit ScheduleTerminated(_user, _sid, sub.terminatedAt);
        if (_userSubs[_user].length == 0) _notifyListener(_user, false);
    }

    /// @dev Clear a subscription immediately (no service continuation).
    function _clear(address _user, bytes32 _sid) internal {
        Subscription storage sub = _subs[_user][_sid];
        if (sub.rate == 0) revert ScheduleNotFound();

        UserState storage u = _users[_user];
        u.totalRate -= sub.rate;
        _userAnchor[_user] = uint32(_today());

        // Remove from buckets
        ScheduleConfig storage cfg = _configs[_sid];
        if (cfg.beneficiary != address(0)) {
            _removeSubFromBuckets(_user, _sid);
        }

        // Clean up
        delete _subs[_user][_sid];
        delete _subDropoffEpoch[_user][_sid];
        _removeFromUserSubs(_user, _sid);

        // Return any sponsored balance (burn it or return — for now, burn)
        uint256 sponsoredBal = _sponsored[_user][_sid];
        if (sponsoredBal > 0) {
            delete _sponsored[_user][_sid];
            totalBurned += sponsoredBal;
        }

        _recomputeAllDropoffs(_user);

        emit ScheduleCleared(_user, _sid);
        if (_userSubs[_user].length == 0) _notifyListener(_user, false);
    }

    // ──────────────────────────────────────────────
    // Internal: Lazy Math
    // ──────────────────────────────────────────────

    function _today() internal view virtual returns (uint256) {
        return block.timestamp / _SECONDS_PER_DAY;
    }

    function _balance(address _user) internal view returns (uint256) {
        UserState storage u = _users[_user];
        if (u.totalRate == 0) return uint256(u.principal);
        uint256 c = _consumed(_user);
        return uint256(u.principal) - c;
    }

    function _consumed(address _user) internal view returns (uint256) {
        UserState storage u = _users[_user];
        if (u.totalRate == 0) return 0;
        uint256 elapsed = _periodsElapsed(_user);
        uint256 funded = _funded(u);
        uint256 effective = elapsed < funded ? elapsed : funded;
        return effective * uint256(u.totalRate);
    }

    function _periodsElapsed(address _user) internal view returns (uint256) {
        uint32 anchor = _userAnchor[_user];
        uint256 today = _today();
        if (today <= uint256(anchor)) return 0;
        return (today - uint256(anchor)) / uint256(TERM_DAYS);
    }

    function _funded(UserState storage _u) internal view returns (uint256) {
        if (_u.totalRate == 0) return 0;
        return uint256(_u.principal) / uint256(_u.totalRate);
    }

    // ──────────────────────────────────────────────
    // Internal: Epoch helpers
    // ──────────────────────────────────────────────

    function _scheduleId(address _beneficiary, uint128 _rate) internal pure returns (bytes32) {
        return keccak256(abi.encode(_beneficiary, _rate));
    }

    function _epochOf() internal view returns (uint256) {
        uint256 today = _today();
        if (today <= uint256(DEPLOY_DAY)) return 0;
        return (today - uint256(DEPLOY_DAY)) / uint256(TERM_DAYS);
    }

    // ──────────────────────────────────────────────
    // Internal: Checkpoint + Settlement
    // ──────────────────────────────────────────────

    /// @dev Checkpoint: settle consumed, reset anchor. Called on every interaction.
    ///      If lapsed, triggers priority resolution.
    function _checkpoint(address _user) internal {
        UserState storage u = _users[_user];
        if (u.totalRate == 0) return;

        uint256 elapsed = _periodsElapsed(_user);
        if (elapsed == 0) return;

        uint256 funded = _funded(u);
        uint256 periods = elapsed < funded ? elapsed : funded;
        uint256 consumed = periods * uint256(u.totalRate);

        if (consumed > 0) {
            u.principal -= uint128(consumed);
            // Accounting: for mixed burn+beneficiary, we attribute to totalBurned
            // only during priority resolution when we know which subs are burn.
            // For now, the consumed tokens are "in transit" (backed by bucket system
            // for beneficiary subs, or implicitly burned for burn subs).
            emit ScheduleSettled(_user, consumed);
        }

        _userAnchor[_user] = uint32(_today());

        // If lapsed: priority resolution
        if (elapsed > funded) {
            _resolvePriority(_user);
        }
    }

    /// @dev Priority resolution: process subs in subscription order.
    ///      Higher priority survives with remaining funds + sponsored.
    function _resolvePriority(address _user) internal {
        UserState storage u = _users[_user];
        uint256 remaining = uint256(u.principal);
        bytes32[] storage subs = _userSubs[_user];

        // Process in priority order — iterate backward for safe removal
        uint256 i = 0;
        while (i < subs.length) {
            bytes32 sid = subs[i];
            Subscription storage sub = _subs[_user][sid];
            uint256 sponsoredBal = _sponsored[_user][sid];
            uint256 avail = remaining + sponsoredBal;

            if (avail >= uint256(sub.rate)) {
                // Survives one more period
                if (sponsoredBal >= uint256(sub.rate)) {
                    _sponsored[_user][sid] = sponsoredBal - uint256(sub.rate);
                } else {
                    uint256 fromPrincipal = uint256(sub.rate) - sponsoredBal;
                    _sponsored[_user][sid] = 0;
                    remaining -= fromPrincipal;
                }
                i++;
            } else {
                // Lapses — clean up
                ScheduleConfig storage cfg = _configs[sid];
                if (cfg.beneficiary != address(0)) {
                    _removeSubFromBuckets(_user, sid);
                }
                u.totalRate -= sub.rate;
                delete _subs[_user][sid];
                delete _subDropoffEpoch[_user][sid];
                if (sponsoredBal > 0) {
                    delete _sponsored[_user][sid];
                    totalBurned += sponsoredBal;
                }

                // Shift array (preserve priority order)
                for (uint256 j = i; j < subs.length - 1; j++) {
                    subs[j] = subs[j + 1];
                }
                subs.pop();
                // Don't increment i — next element shifted into position

                emit ScheduleCleared(_user, sid);
            }
        }

        u.principal = uint128(remaining);

        if (subs.length == 0) {
            _notifyListener(_user, false);
        }
    }

    // ──────────────────────────────────────────────
    // Internal: Bucket Management
    // ──────────────────────────────────────────────

    /// @dev Recompute dropoffs for ALL of a user's active subscriptions.
    function _recomputeAllDropoffs(address _user) internal {
        UserState storage u = _users[_user];
        bytes32[] storage subs = _userSubs[_user];
        uint256 curEpoch = _epochOf();
        uint256 sharedFunded = _funded(u);

        for (uint256 i; i < subs.length; i++) {
            bytes32 sid = subs[i];
            ScheduleConfig storage cfg = _configs[sid];
            if (cfg.beneficiary == address(0)) continue; // skip burn

            uint256 extraFunded = _sponsored[_user][sid] / uint256(_subs[_user][sid].rate);
            uint256 newDropoff = curEpoch + 1 + sharedFunded + extraFunded;
            uint32 oldDropoff = _subDropoffEpoch[_user][sid];

            if (uint256(oldDropoff) != newDropoff) {
                if (oldDropoff > 0) _dropoffs[sid][uint256(oldDropoff)]--;
                _dropoffs[sid][newDropoff]++;
                _subDropoffEpoch[_user][sid] = uint32(newDropoff);
            }
        }
    }

    /// @dev Recompute dropoff for a single subscription.
    function _recomputeSubDropoff(address _user, bytes32 _sid) internal {
        ScheduleConfig storage cfg = _configs[_sid];
        if (cfg.beneficiary == address(0)) return;

        UserState storage u = _users[_user];
        uint256 curEpoch = _epochOf();
        uint256 sharedFunded = _funded(u);
        uint256 extraFunded = _sponsored[_user][_sid] / uint256(_subs[_user][_sid].rate);
        uint256 newDropoff = curEpoch + 1 + sharedFunded + extraFunded;
        uint32 oldDropoff = _subDropoffEpoch[_user][_sid];

        if (uint256(oldDropoff) != newDropoff) {
            if (oldDropoff > 0) _dropoffs[_sid][uint256(oldDropoff)]--;
            _dropoffs[_sid][newDropoff]++;
            _subDropoffEpoch[_user][_sid] = uint32(newDropoff);
        }
    }

    /// @dev Remove a subscription's joinoff and dropoff from buckets.
    function _removeSubFromBuckets(address _user, bytes32 _sid) internal {
        Checkpoint storage cp = _checkpoints[_sid];
        Subscription storage sub = _subs[_user][_sid];

        uint256 joinEpoch = uint256(sub.joinedAtEpoch);
        if (joinEpoch > uint256(cp.lastEpoch)) {
            uint256 j = _joinoffs[_sid][joinEpoch];
            if (j > 0) _joinoffs[_sid][joinEpoch] = j - 1;
        }

        uint32 dropoffEpoch = _subDropoffEpoch[_user][_sid];
        if (dropoffEpoch > 0 && uint256(dropoffEpoch) > uint256(cp.lastEpoch)) {
            uint256 d = _dropoffs[_sid][uint256(dropoffEpoch)];
            if (d > 0) _dropoffs[_sid][uint256(dropoffEpoch)] = d - 1;
        }
    }

    /// @dev Remove a scheduleId from _userSubs array (shift to preserve order).
    function _removeFromUserSubs(address _user, bytes32 _sid) internal {
        bytes32[] storage subs = _userSubs[_user];
        for (uint256 i; i < subs.length; i++) {
            if (subs[i] == _sid) {
                for (uint256 j = i; j < subs.length - 1; j++) {
                    subs[j] = subs[j + 1];
                }
                subs.pop();
                return;
            }
        }
    }

    /// @dev Check if user has any active sponsored schedule.
    function _hasAnySponsoredActive(address _user) internal view returns (bool) {
        bytes32[] storage subs = _userSubs[_user];
        for (uint256 i; i < subs.length; i++) {
            if (_sponsored[_user][subs[i]] > 0) return true;
        }
        return false;
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
