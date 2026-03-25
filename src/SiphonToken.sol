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
 *         payment mandates. Like a bank account with multiple autopays.
 *
 * @dev Key concepts:
 *
 *   MULTI-MANDATE
 *     Users can have up to MAX_TAPS active mandates, each paying a different
 *     beneficiary. All mandates share one principal and use the same billing
 *     interval (TERM_DAYS). balanceOf is O(1) via outflow.
 *
 *   BENEFICIARY = SCHEDULER
 *     The beneficiary IS the entity that taps users. msg.sender on tap() is
 *     the beneficiary. Users pre-authorize via authorize().
 *     mandateId = keccak256(beneficiary, rate).
 *
 *   BURN PATH
 *     Burn mandates have beneficiary=address(0). Same array, same outflow.
 *     No authorization needed (self-assigned). No bucket ops (no harvest).
 *
 *   SPONSORSHIP
 *     Anyone can sponsor tokens for a user's specific mandate. Sponsored
 *     tokens are locked and consumed BEFORE principal. A sponsored mandate
 *     can survive past shared lapse.
 *
 *   PRIORITY
 *     When funds run out, mandates are resolved in tap order (first-tapped
 *     = first-paid). Lower-priority mandates lapse first.
 *
 *   LAZY SETTLEMENT
 *     balanceOf = principal - min(elapsed, principal/outflow) * outflow.
 *     O(1). Storage only changes via _settle on interaction.
 *
 *   STRUCTS
 *     Account: { uint128 principal, uint128 outflow }  [1 slot shared per user]
 *     Tap: { uint128 rate, uint32 entryEpoch, uint32 revokedAt }  [1 slot per mandate]
 */
abstract contract SiphonToken is IERC20, IERC20Metadata {
    // ──────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────

    error InsufficientBalance();
    /// @notice ERC20 standard (OpenZeppelin ERC20Errors.sol).
    error InsufficientAllowance();
    /// @notice ERC20 standard (OpenZeppelin ERC20Errors.sol).
    error ERC20InvalidReceiver(address receiver);
    /// @notice ERC20 standard (OpenZeppelin ERC20Errors.sol).
    error ERC20InvalidSender(address sender);
    error InvalidBeneficiary();
    error InvalidMandate();
    error NotApproved();
    error Unauthorized();
    error MaxTaps();
    error TapNotFound();
    error NotActive();

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    event Tapped(address indexed user, bytes32 indexed mandateId, address beneficiary, uint128 rate);
    event Revoked(address indexed user, bytes32 indexed mandateId, uint32 revokedAt);
    event Settled(address indexed user, uint256 amount);
    event Authorized(address indexed user, bytes32 indexed mandateId, uint256 count);
    event Sponsored(address indexed user, bytes32 indexed mandateId, uint256 amount);
    event Siphoned(address indexed from, address indexed to, uint256 amount);
    event Spent(address indexed user, uint256 amount);
    event Harvested(address indexed beneficiary, bytes32 indexed mandateId, uint256 amount, uint256 epochs);
    event ListenerSet(address listener);

    // ──────────────────────────────────────────────
    // Structs
    // ──────────────────────────────────────────────

    /// @dev Shared per user. 1 storage slot.
    struct Account {
        uint128 principal;
        uint128 outflow;
    }

    /// @dev Per user per mandateId. 1 storage slot.
    struct Tap {
        uint128 rate;
        uint32 entryEpoch;
        uint32 revokedAt;
    }

    /// @dev Collection checkpoint per mandateId. 1 storage slot.
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
    uint8 public immutable MAX_TAPS;

    // ──────────────────────────────────────────────
    // State
    // ──────────────────────────────────────────────

    mapping(address => Account) internal _accounts;
    mapping(address => uint32) internal _anchor;
    mapping(address => mapping(address => uint256)) internal _allowances;

    uint256 public totalMinted;
    uint256 public totalBurned;
    uint256 public totalSpent;

    mapping(address => mapping(bytes32 => uint256)) internal _authorizations;
    mapping(bytes32 => Checkpoint) internal _checkpoints;
    mapping(bytes32 => mapping(uint256 => uint256)) internal _entries;
    mapping(bytes32 => mapping(uint256 => uint256)) internal _exits;

    mapping(address => bytes32[]) internal _userTaps;
    mapping(address => mapping(bytes32 => Tap)) internal _taps;
    mapping(address => mapping(bytes32 => uint32)) internal _mandateExitEpoch;
    mapping(address => mapping(bytes32 => uint256)) internal _sponsored;

    /// @dev Per-user burn outflow (subset of outflow that's burn mandates).
    mapping(address => uint128) internal _burnOutflow;

    address public scheduleListener;

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    constructor(uint32 _deployDay, uint16 _termDays, uint8 _maxTaps) {
        DEPLOY_DAY = _deployDay == 0 ? uint32(block.timestamp / _SECONDS_PER_DAY) : _deployDay;
        require(_termDays > 0, "term must be > 0");
        require(_maxTaps > 0, "max taps must be > 0");
        TERM_DAYS = _termDays;
        MAX_TAPS = _maxTaps;
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
    // Authorization (mandate approval)
    // ──────────────────────────────────────────────

    /// @notice Pre-authorize a mandate. Each tap() consumes one.
    ///         type(uint256).max = infinite (beneficiary can re-tap freely).
    function authorize(bytes32 _mid, uint256 _count) external {
        _authorizations[msg.sender][_mid] = _count;
        emit Authorized(msg.sender, _mid, _count);
    }

    function authorization(address _user, bytes32 _mid) external view returns (uint256) {
        return _authorizations[_user][_mid];
    }

    // ──────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────

    function getAccount(address _user) external view returns (uint128 principal, uint128 outflow, uint32 anchor) {
        Account storage a = _accounts[_user];
        return (a.principal, a.outflow, _anchor[_user]);
    }

    function getTap(address _user, bytes32 _mid) external view returns (uint128 rate, uint32 entryEpoch, uint32 revokedAt, uint256 sponsored) {
        Tap storage t = _taps[_user][_mid];
        return (t.rate, t.entryEpoch, t.revokedAt, _sponsored[_user][_mid]);
    }

    function getUserTaps(address _user) external view returns (bytes32[] memory) {
        return _userTaps[_user];
    }

    function consumed(address _user) external view returns (uint256) {
        return _consumed(_user);
    }

    function isActive(address _user) external view returns (bool) {
        Account storage a = _accounts[_user];
        if (a.outflow == 0) return false;
        return _funded(a) > 0 || _hasAnySponsoredActive(_user);
    }

    function isTapActive(address _user, bytes32 _mid) external view returns (bool) {
        Tap storage t = _taps[_user][_mid];
        if (t.rate == 0) return false;
        if (t.revokedAt > 0) return false;
        Account storage a = _accounts[_user];
        uint256 elapsed = _periodsElapsed(_user);
        uint256 funded = _funded(a);
        if (elapsed <= funded) return true;
        return _sponsored[_user][_mid] >= t.rate;
    }

    function currentDay() external view returns (uint256) {
        return _today();
    }

    function currentEpoch() external view returns (uint256) {
        return _epochOf();
    }

    function mandateId(address _beneficiary, uint128 _rate) external pure returns (bytes32) {
        return _mandateId(_beneficiary, _rate);
    }

    function getCheckpoint(bytes32 _mid) external view returns (uint32 lastEpoch, uint224 count) {
        Checkpoint storage cp = _checkpoints[_mid];
        return (cp.lastEpoch, cp.count);
    }

    // ──────────────────────────────────────────────
    // Public: Settle
    // ──────────────────────────────────────────────

    function settle(address _user) external {
        _settle(_user);
    }

    // ──────────────────────────────────────────────
    // Public: Revoke (terminate a mandate)
    // ──────────────────────────────────────────────

    /// @notice Revoke a mandate. Callable by the user or the mandate's beneficiary.
    ///         Service continues through the current paid period, then clears on settle.
    function revoke(address _user, bytes32 _mid) external virtual {
        Tap storage t = _taps[_user][_mid];
        if (t.rate == 0) revert TapNotFound();
        // Verify caller is user or beneficiary (beneficiary recoverable from hash)
        if (msg.sender != _user) {
            if (_mandateId(msg.sender, t.rate) != _mid) revert Unauthorized();
        }
        _settle(_user);
        _revoke(_user, _mid);
    }

    // ──────────────────────────────────────────────
    // Public: Tap (beneficiary activates mandate for user)
    // ──────────────────────────────────────────────

    /// @notice Tap a user. msg.sender IS the beneficiary.
    ///         Consumes one authorization. Immediate first-term payment.
    function tap(address _user, uint128 _rate) external virtual {
        bytes32 mid = _mandateId(msg.sender, _rate);
        uint256 auth = _authorizations[_user][mid];
        if (auth == 0) revert NotApproved();
        if (auth != type(uint256).max) {
            _authorizations[_user][mid] = auth - 1;
        }
        _tap(_user, msg.sender, _rate);
    }

    // ──────────────────────────────────────────────
    // Public: Harvest (beneficiary collects income)
    // ──────────────────────────────────────────────

    /// @notice Harvest income for a mandate. Caller passes beneficiary + rate;
    ///         contract verifies the mandateId hash. Tokens go to beneficiary.
    function harvest(address _beneficiary, uint128 _rate, uint256 _maxEpochs) external {
        bytes32 mid = _mandateId(_beneficiary, _rate);
        Checkpoint storage cp = _checkpoints[mid];
        uint256 current = _epochOf();
        uint256 last = uint256(cp.lastEpoch);
        uint256 end = last + _maxEpochs;
        if (end > current) end = current;
        if (end <= last) return;

        uint256 running = uint256(cp.count);
        uint256 total;

        for (uint256 e = last + 1; e <= end; e++) {
            running += _entries[mid][e];
            uint256 ex = _exits[mid][e];
            if (ex > running) ex = running;
            running -= ex;
            delete _entries[mid][e];
            delete _exits[mid][e];
            total += running * uint256(_rate);
        }

        cp.lastEpoch = uint32(end);
        cp.count = uint224(running);

        if (total > 0) {
            _accounts[_beneficiary].principal += uint128(total);
            emit Harvested(_beneficiary, mid, total, end - last);
        }
    }

    // ──────────────────────────────────────────────
    // Public: Sponsor
    // ──────────────────────────────────────────────

    /// @notice Sponsor tokens for a user's specific mandate. Tokens are locked
    ///         and consumed before principal for that mandate.
    function sponsor(address _user, bytes32 _mid, uint128 _amount) external {
        Tap storage t = _taps[_user][_mid];
        if (t.rate == 0) revert TapNotFound();

        _debit(msg.sender, _amount);
        totalSpent += _amount;
        _sponsored[_user][_mid] += _amount;
        _recomputeTapExit(_user, _mid);

        emit Transfer(msg.sender, address(this), _amount);
        emit Sponsored(_user, _mid, _amount);
    }

    // ──────────────────────────────────────────────
    // Internal: Mutations
    // ──────────────────────────────────────────────

    function _mint(address _user, uint128 _amount) internal {
        _settle(_user);
        _accounts[_user].principal += _amount;
        totalMinted += _amount;
        _recomputeAllExits(_user);
        emit Transfer(address(0), _user, _amount);
    }

    function _spend(address _user, uint128 _amount) internal {
        _settle(_user);
        if (_balance(_user) < _amount) revert InsufficientBalance();
        _accounts[_user].principal -= _amount;
        _recomputeAllExits(_user);
        totalSpent += _amount;
        emit Transfer(_user, address(0), _amount);
        emit Spent(_user, _amount);
    }

    function _transfer(address _from, address _to, uint256 _amount) internal {
        if (_from == address(0)) revert ERC20InvalidSender(address(0));
        if (_to == address(0)) revert ERC20InvalidReceiver(address(0));

        _settle(_from);
        if (_balance(_from) < _amount) revert InsufficientBalance();
        _accounts[_from].principal -= uint128(_amount);
        _recomputeAllExits(_from);

        _settle(_to);
        _accounts[_to].principal += uint128(_amount);
        _recomputeAllExits(_to);

        emit Transfer(_from, _to, _amount);
    }

    /// @dev Debit principal from a user (for sponsor). Settles + balance check.
    function _debit(address _from, uint128 _amount) internal {
        _settle(_from);
        if (_balance(_from) < _amount) revert InsufficientBalance();
        _accounts[_from].principal -= _amount;
        _recomputeAllExits(_from);
    }

    /// @dev Tap a user into a mandate.
    function _tap(address _user, address _beneficiary, uint128 _rate) internal {
        if (_rate == 0) revert InvalidMandate();
        if (_beneficiary == _user) revert InvalidBeneficiary();

        _settle(_user);

        Account storage a = _accounts[_user];
        bytes32 mid = _mandateId(_beneficiary, _rate);

        if (_taps[_user][mid].rate > 0) revert InvalidMandate();
        if (_userTaps[_user].length >= uint256(MAX_TAPS)) revert MaxTaps();

        // Immediate first-term payment
        if (_balance(_user) < _rate) revert InsufficientBalance();
        a.principal -= _rate;

        if (_beneficiary == address(0)) {
            totalBurned += _rate;
            emit Transfer(_user, address(0), _rate);
        } else {
            _accounts[_beneficiary].principal += _rate;
            emit Transfer(_user, _beneficiary, _rate);
        }

        // Update account
        a.outflow += _rate;
        if (_beneficiary == address(0)) _burnOutflow[_user] += _rate;
        _anchor[_user] = uint32(_today());

        // Create tap
        uint256 curEpoch = _epochOf();
        _taps[_user][mid] = Tap(_rate, uint32(curEpoch + 1), 0);
        _userTaps[_user].push(mid);

        // Bucket accounting (skip for burn)
        if (_beneficiary != address(0)) {
            _entries[mid][curEpoch + 1]++;
        }

        _recomputeAllExits(_user);

        emit Tapped(_user, mid, _beneficiary, _rate);
        _notifyListener(_user, true);
    }

    /// @dev Revoke a mandate. Immediate termination — the bank stops the payment.
    ///      Service continuation is the consumer's concern, not the token's.
    function _revoke(address _user, bytes32 _mid) internal {
        Tap storage t = _taps[_user][_mid];
        if (t.rate == 0) revert TapNotFound();
        if (t.revokedAt > 0) revert NotActive();

        t.revokedAt = uint32(_today());

        Account storage a = _accounts[_user];
        a.outflow -= t.rate;
        bool isBurn = _mandateId(address(0), t.rate) == _mid;
        if (isBurn) _burnOutflow[_user] -= t.rate;
        _anchor[_user] = uint32(_today());

        // Remove from buckets immediately (no service continuation)
        if (!isBurn) {
            _removeTapFromBuckets(_user, _mid);
        }

        delete _mandateExitEpoch[_user][_mid];
        _removeFromUserTaps(_user, _mid);
        _recomputeAllExits(_user);

        emit Revoked(_user, _mid, t.revokedAt);
        if (_userTaps[_user].length == 0) _notifyListener(_user, false);
    }

    // ──────────────────────────────────────────────
    // Internal: Lazy Math
    // ──────────────────────────────────────────────

    function _today() internal view virtual returns (uint256) {
        return block.timestamp / _SECONDS_PER_DAY;
    }

    function _balance(address _user) internal view returns (uint256) {
        Account storage a = _accounts[_user];
        if (a.outflow == 0) return uint256(a.principal);
        uint256 c = _consumed(_user);
        return uint256(a.principal) - c;
    }

    function _consumed(address _user) internal view returns (uint256) {
        Account storage a = _accounts[_user];
        if (a.outflow == 0) return 0;
        uint256 elapsed = _periodsElapsed(_user);
        uint256 funded = _funded(a);
        uint256 effective = elapsed < funded ? elapsed : funded;
        return effective * uint256(a.outflow);
    }

    function _periodsElapsed(address _user) internal view returns (uint256) {
        uint32 anch = _anchor[_user];
        uint256 today = _today();
        if (today <= uint256(anch)) return 0;
        return (today - uint256(anch)) / uint256(TERM_DAYS);
    }

    function _funded(Account storage _a) internal view returns (uint256) {
        if (_a.outflow == 0) return 0;
        return uint256(_a.principal) / uint256(_a.outflow);
    }

    // ──────────────────────────────────────────────
    // Internal: Epoch helpers
    // ──────────────────────────────────────────────

    function _mandateId(address _beneficiary, uint128 _rate) internal pure returns (bytes32) {
        return keccak256(abi.encode(_beneficiary, _rate));
    }

    function _epochOf() internal view returns (uint256) {
        uint256 today = _today();
        if (today <= uint256(DEPLOY_DAY)) return 0;
        return (today - uint256(DEPLOY_DAY)) / uint256(TERM_DAYS);
    }

    // ──────────────────────────────────────────────
    // Internal: Settlement
    // ──────────────────────────────────────────────

    /// @dev Settle: deduct consumed, reset anchor. On lapse, resolve priority.
    function _settle(address _user) internal {
        Account storage a = _accounts[_user];
        if (a.outflow == 0) return;

        uint256 elapsed = _periodsElapsed(_user);
        if (elapsed == 0) return;

        uint256 funded = _funded(a);
        uint256 periods = elapsed < funded ? elapsed : funded;
        uint256 con = periods * uint256(a.outflow);

        if (con > 0) {
            a.principal -= uint128(con);
            // Attribute burn portion to totalBurned
            uint128 burnRate = _burnOutflow[_user];
            if (burnRate > 0) {
                totalBurned += periods * uint256(burnRate);
            }
            emit Settled(_user, con);
        }

        _anchor[_user] = uint32(_today());

        if (elapsed > funded) {
            _resolvePriority(_user);
        }
    }

    /// @dev Priority resolution: first-tapped survives, later taps lapse.
    function _resolvePriority(address _user) internal {
        Account storage a = _accounts[_user];
        uint256 remaining = uint256(a.principal);
        bytes32[] storage taps = _userTaps[_user];

        uint256 i = 0;
        while (i < taps.length) {
            bytes32 mid = taps[i];
            Tap storage t = _taps[_user][mid];
            uint256 sponsoredBal = _sponsored[_user][mid];
            uint256 avail = remaining + sponsoredBal;

            if (avail >= uint256(t.rate)) {
                if (sponsoredBal >= uint256(t.rate)) {
                    _sponsored[_user][mid] = sponsoredBal - uint256(t.rate);
                } else {
                    uint256 fromPrincipal = uint256(t.rate) - sponsoredBal;
                    _sponsored[_user][mid] = 0;
                    remaining -= fromPrincipal;
                }
                i++;
            } else {
                // Lapse — clean up
                bool isBurn = _mandateId(address(0), t.rate) == mid;
                if (!isBurn) {
                    _removeTapFromBuckets(_user, mid);
                }
                a.outflow -= t.rate;
                if (isBurn) _burnOutflow[_user] -= t.rate;
                delete _taps[_user][mid];
                delete _mandateExitEpoch[_user][mid];
                if (sponsoredBal > 0) {
                    delete _sponsored[_user][mid];
                    // Sponsored tokens were already counted as totalSpent on sponsor()
                }

                for (uint256 j = i; j < taps.length - 1; j++) {
                    taps[j] = taps[j + 1];
                }
                taps.pop();

                emit Revoked(_user, mid, uint32(_today()));
            }
        }

        a.principal = uint128(remaining);

        if (taps.length == 0) {
            _notifyListener(_user, false);
        }
    }

    // ──────────────────────────────────────────────
    // Internal: Bucket Management
    // ──────────────────────────────────────────────

    function _recomputeAllExits(address _user) internal {
        Account storage a = _accounts[_user];
        bytes32[] storage taps = _userTaps[_user];
        uint256 curEpoch = _epochOf();
        uint256 sharedFunded = _funded(a);

        for (uint256 i; i < taps.length; i++) {
            bytes32 mid = taps[i];
            bool isBurn = _mandateId(address(0), _taps[_user][mid].rate) == mid;
            if (isBurn) continue;

            uint256 extraFunded = _sponsored[_user][mid] / uint256(_taps[_user][mid].rate);
            uint256 newExit = curEpoch + 1 + sharedFunded + extraFunded;
            uint32 oldExit = _mandateExitEpoch[_user][mid];

            if (uint256(oldExit) != newExit) {
                if (oldExit > 0) _exits[mid][uint256(oldExit)]--;
                _exits[mid][newExit]++;
                _mandateExitEpoch[_user][mid] = uint32(newExit);
            }
        }
    }

    function _recomputeTapExit(address _user, bytes32 _mid) internal {
        bool isBurn = _mandateId(address(0), _taps[_user][_mid].rate) == _mid;
        if (isBurn) return;

        Account storage a = _accounts[_user];
        uint256 curEpoch = _epochOf();
        uint256 sharedFunded = _funded(a);
        uint256 extraFunded = _sponsored[_user][_mid] / uint256(_taps[_user][_mid].rate);
        uint256 newExit = curEpoch + 1 + sharedFunded + extraFunded;
        uint32 oldExit = _mandateExitEpoch[_user][_mid];

        if (uint256(oldExit) != newExit) {
            if (oldExit > 0) _exits[_mid][uint256(oldExit)]--;
            _exits[_mid][newExit]++;
            _mandateExitEpoch[_user][_mid] = uint32(newExit);
        }
    }

    function _removeTapFromBuckets(address _user, bytes32 _mid) internal {
        Checkpoint storage cp = _checkpoints[_mid];
        Tap storage t = _taps[_user][_mid];

        uint256 entryEpoch = uint256(t.entryEpoch);
        if (entryEpoch > uint256(cp.lastEpoch)) {
            uint256 e = _entries[_mid][entryEpoch];
            if (e > 0) _entries[_mid][entryEpoch] = e - 1;
        }

        uint32 exitEpoch = _mandateExitEpoch[_user][_mid];
        if (exitEpoch > 0 && uint256(exitEpoch) > uint256(cp.lastEpoch)) {
            uint256 x = _exits[_mid][uint256(exitEpoch)];
            if (x > 0) _exits[_mid][uint256(exitEpoch)] = x - 1;
        }
    }

    function _removeFromUserTaps(address _user, bytes32 _mid) internal {
        bytes32[] storage taps = _userTaps[_user];
        for (uint256 i; i < taps.length; i++) {
            if (taps[i] == _mid) {
                for (uint256 j = i; j < taps.length - 1; j++) {
                    taps[j] = taps[j + 1];
                }
                taps.pop();
                return;
            }
        }
    }

    function _hasAnySponsoredActive(address _user) internal view returns (bool) {
        bytes32[] storage taps = _userTaps[_user];
        for (uint256 i; i < taps.length; i++) {
            if (_sponsored[_user][taps[i]] > 0) return true;
        }
        return false;
    }

    // ──────────────────────────────────────────────
    // Internal: Listener
    // ──────────────────────────────────────────────

    function _setListener(address _listener) internal {
        scheduleListener = _listener;
        emit ListenerSet(_listener);
    }

    function _notifyListener(address _user, bool _active) internal {
        address listener = scheduleListener;
        if (listener == address(0)) return;
        try IScheduleListener(listener).onScheduleUpdate(address(this), _user, _active) {} catch {}
    }
}
