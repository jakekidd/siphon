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
 *   COMP
 *     Beneficiary can pause billing for N terms via comp(). Moves the
 *     user's anchor forward; balance freezes, resumes automatically.
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
    error AlreadyComped();

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    event Tapped(address indexed user, bytes32 indexed mandateId, address beneficiary, uint128 rate);
    event Revoked(address indexed user, bytes32 indexed mandateId, uint32 revokedAt);
    event Settled(address indexed user, uint256 amount);
    event Authorized(address indexed user, bytes32 indexed mandateId, uint256 count);
    event Spent(address indexed user, uint256 amount);
    event Harvested(address indexed beneficiary, bytes32 indexed mandateId, uint256 amount, uint256 epochs);
    event Comped(address indexed user, bytes32 indexed mandateId, uint16 epochs);
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

    /// @notice Remaining authorization count for a mandate.
    function authorization(address _user, bytes32 _mid) external view returns (uint256) {
        return _authorizations[_user][_mid];
    }

    // ──────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────

    /// @notice User's account: stored principal, aggregate outflow rate, billing anchor day.
    function getAccount(address _user) external view returns (uint128 principal, uint128 outflow, uint32 anchor) {
        Account storage a = _accounts[_user];
        return (a.principal, a.outflow, _anchor[_user]);
    }

    /// @notice Details of a specific tap on a user.
    function getTap(address _user, bytes32 _mid) external view returns (uint128 rate, uint32 entryEpoch, uint32 revokedAt) {
        Tap storage t = _taps[_user][_mid];
        return (t.rate, t.entryEpoch, t.revokedAt);
    }

    /// @notice All active mandate IDs for a user (ordered by priority).
    function getUserTaps(address _user) external view returns (bytes32[] memory) {
        return _userTaps[_user];
    }

    /// @notice Tokens consumed by active mandates since last settlement (lazy, not yet materialized).
    function consumed(address _user) external view returns (uint256) {
        return _consumed(_user);
    }

    /// @notice True if the user has any active mandates with funded periods remaining.
    function isActive(address _user) external view returns (bool) {
        Account storage a = _accounts[_user];
        if (a.outflow == 0) return false;
        return _funded(a) > 0;
    }

    /// @notice True if a specific mandate is active and funded on this user.
    function isTapActive(address _user, bytes32 _mid) external view returns (bool) {
        Tap storage t = _taps[_user][_mid];
        if (t.rate == 0) return false;
        if (t.revokedAt > 0) return false;
        Account storage a = _accounts[_user];
        return _periodsElapsed(_user) <= _funded(a);
    }

    /// @notice Current day index (block.timestamp / 86400).
    function currentDay() external view returns (uint256) {
        return _today();
    }

    /// @notice Current epoch index ((today - DEPLOY_DAY) / TERM_DAYS).
    function currentEpoch() external view returns (uint256) {
        return _epochOf();
    }

    /// @notice Compute a mandateId from beneficiary address and rate.
    function mandateId(address _beneficiary, uint128 _rate) external pure returns (bytes32) {
        return _mandateId(_beneficiary, _rate);
    }

    /// @notice Harvest checkpoint for a mandate: last harvested epoch and running subscriber count.
    function getCheckpoint(bytes32 _mid) external view returns (uint32 lastEpoch, uint224 count) {
        Checkpoint storage cp = _checkpoints[_mid];
        return (cp.lastEpoch, cp.count);
    }

    /// @notice Number of full terms the user can fund at current outflow.
    function funded(address _user) external view returns (uint256) {
        return _funded(_accounts[_user]);
    }

    /// @notice Day when the user's balance will be fully consumed at current outflow.
    function expiryDay(address _user) external view returns (uint256) {
        return uint256(_anchor[_user]) + _funded(_accounts[_user]) * uint256(TERM_DAYS);
    }

    /// @notice True if the user is in a comp period (billing anchor is in the future).
    function isComped(address _user) external view returns (bool) {
        return _today() < uint256(_anchor[_user]);
    }

    // ──────────────────────────────────────────────
    // Public: Settle
    // ──────────────────────────────────────────────

    /// @notice Trigger lazy settlement for a user. Anyone can call. No-op if
    ///         no periods have elapsed since the last settlement.
    function settle(address _user) external {
        _settle(_user);
    }

    // ──────────────────────────────────────────────
    // Public: Revoke (terminate a mandate)
    // ──────────────────────────────────────────────

    /// @notice Revoke a mandate. Callable by the user or the mandate's beneficiary.
    ///         Immediate termination — billing stops, tap is deleted. Service
    ///         continuation (if any) is the consumer contract's concern.
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
    ///         Anyone can call; tokens always go to the beneficiary.
    /// @dev total is accumulated as uint256 but principal is uint128. If total
    ///      exceeds uint128.max (requires extreme rate * epochs * subscribers),
    ///      the call reverts. Harvest more frequently to stay under the cap.
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
            require(total <= type(uint128).max, "harvest overflow");
            _accounts[_beneficiary].principal += uint128(total);
            emit Harvested(_beneficiary, mid, total, end - last);
        }
    }

    // ──────────────────────────────────────────────
    // Public: Comp (beneficiary pauses billing)
    // ──────────────────────────────────────────────

    /// @notice Comp a user: pause billing for N terms. Caller must be the
    ///         mandate's beneficiary. The user's balance freezes; billing
    ///         resumes automatically when the comp period ends.
    ///         NOTE: Anchor is shared. This pauses ALL of the user's mandates.
    function comp(address _user, uint128 _rate, uint16 _epochs) external virtual {
        bytes32 mid = _mandateId(msg.sender, _rate);
        _comp(_user, mid, _epochs);
    }

    // ──────────────────────────────────────────────
    // Internal: Mutations
    // ──────────────────────────────────────────────

    /// @dev Mint tokens to a user. Settles first, then increases principal.
    function _mint(address _user, uint128 _amount) internal {
        _settle(_user);
        _accounts[_user].principal += _amount;
        totalMinted += _amount;
        _recomputeAllExits(_user);
        emit Transfer(address(0), _user, _amount);
    }

    /// @dev Burn tokens from a user. Settles first, checks balance, decreases principal.
    function _spend(address _user, uint128 _amount) internal {
        _settle(_user);
        if (_balance(_user) < _amount) revert InsufficientBalance();
        _accounts[_user].principal -= _amount;
        _recomputeAllExits(_user);
        totalSpent += _amount;
        emit Transfer(_user, address(0), _amount);
        emit Spent(_user, _amount);
    }

    /// @dev Transfer between users. Settles both sides. Recomputes exits for both
    ///      (principal changes affect funded periods and therefore bucket exits).
    ///      Calls _beforeTransfer hook for implementer-defined restrictions.
    function _transfer(address _from, address _to, uint256 _amount) internal {
        if (_from == address(0)) revert ERC20InvalidSender(address(0));
        if (_to == address(0)) revert ERC20InvalidReceiver(address(0));

        _beforeTransfer(_from, _to, _amount);

        _settle(_from);
        if (_balance(_from) < _amount) revert InsufficientBalance();
        _accounts[_from].principal -= uint128(_amount);
        _recomputeAllExits(_from);

        _settle(_to);
        _accounts[_to].principal += uint128(_amount);
        _recomputeAllExits(_to);

        emit Transfer(_from, _to, _amount);
    }

    /// @dev Hook called before every transfer. Override to add restrictions
    ///      (e.g. whitelist, pause, exchange regulation). Reverts block the transfer.
    ///      Default: no-op (open transfers).
    function _beforeTransfer(address _from, address _to, uint256 _amount) internal virtual {}

    /// @dev Tap a user into a mandate. Immediate first-term payment to beneficiary.
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
            _settle(_beneficiary);
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
    ///      Bucket entry is preserved so the beneficiary can harvest historical
    ///      epochs. Exit is moved to current epoch to stop future earnings.
    ///      Tap is deleted so the same mandateId can be re-tapped later.
    function _revoke(address _user, bytes32 _mid) internal {
        Tap storage t = _taps[_user][_mid];
        if (t.rate == 0) revert TapNotFound();
        if (t.revokedAt > 0) revert NotActive();

        uint128 rate = t.rate;
        Account storage a = _accounts[_user];
        a.outflow -= rate;
        bool isBurn = _mandateId(address(0), rate) == _mid;
        if (isBurn) _burnOutflow[_user] -= rate;
        _anchor[_user] = uint32(_today());

        // Move exit to current epoch (preserves entry for historical harvest)
        if (!isBurn) {
            uint32 oldExit = _mandateExitEpoch[_user][_mid];
            if (oldExit > 0) _exits[_mid][uint256(oldExit)]--;
            _exits[_mid][_epochOf() + 1]++;
        }

        delete _taps[_user][_mid];
        delete _mandateExitEpoch[_user][_mid];
        _removeFromUserTaps(_user, _mid);
        _recomputeAllExits(_user);

        emit Revoked(_user, _mid, uint32(_today()));
        if (_userTaps[_user].length == 0) _notifyListener(_user, false);
    }

    /// @dev Comp: pause billing for N terms by moving anchor forward.
    ///      Updates bucket entries/exits for all non-burn taps so
    ///      beneficiaries only harvest for periods actually billed.
    function _comp(address _user, bytes32 _mid, uint16 _epochs) internal {
        Tap storage t = _taps[_user][_mid];
        if (t.rate == 0) revert TapNotFound();
        if (t.revokedAt > 0) revert NotActive();
        if (_epochs == 0) revert InvalidMandate();
        if (_today() < uint256(_anchor[_user])) revert AlreadyComped();

        _settle(_user);

        uint256 curEpoch = _epochOf();
        uint256 compDays = uint256(_epochs) * uint256(TERM_DAYS);
        uint256 newAnchorDay = _today() + compDays;
        uint256 anchorEpoch = (newAnchorDay - uint256(DEPLOY_DAY)) / uint256(TERM_DAYS);

        // Update bucket entries for all non-burn taps: exit now, re-enter after comp
        bytes32[] storage uTaps = _userTaps[_user];
        for (uint256 i; i < uTaps.length; i++) {
            bytes32 tapMid = uTaps[i];
            Tap storage tap = _taps[_user][tapMid];
            bool isBurn = _mandateId(address(0), tap.rate) == tapMid;
            if (isBurn) continue;

            _exits[tapMid][curEpoch + 1]++;
            tap.entryEpoch = uint32(anchorEpoch + 1);
            _entries[tapMid][anchorEpoch + 1]++;
        }

        // Move anchor forward (freezes balance for all mandates)
        _anchor[_user] = uint32(newAnchorDay);

        // Recompute exits with new anchor
        _recomputeAllExits(_user);

        emit Comped(_user, _mid, _epochs);
    }

    // ──────────────────────────────────────────────
    // Internal: Lazy Math
    // ──────────────────────────────────────────────

    /// @dev Current day index. Virtual so tests can override for time travel.
    function _today() internal view virtual returns (uint256) {
        return block.timestamp / _SECONDS_PER_DAY;
    }

    /// @dev Spendable balance: principal minus lazy consumed. O(1).
    function _balance(address _user) internal view returns (uint256) {
        Account storage a = _accounts[_user];
        if (a.outflow == 0) return uint256(a.principal);
        uint256 c = _consumed(_user);
        return uint256(a.principal) - c;
    }

    /// @dev Tokens consumed by mandates since last settlement. Capped at principal
    ///      (can't consume more than what's there). Always: consumed + balance = principal.
    function _consumed(address _user) internal view returns (uint256) {
        Account storage a = _accounts[_user];
        if (a.outflow == 0) return 0;
        uint256 elapsed = _periodsElapsed(_user);
        uint256 f = _funded(a);
        uint256 effective = elapsed < f ? elapsed : f;
        return effective * uint256(a.outflow);
    }

    /// @dev Full billing periods elapsed since the user's anchor. Returns 0 during
    ///      comp (anchor is in the future) and on the same day as last settlement.
    function _periodsElapsed(address _user) internal view returns (uint256) {
        uint32 anch = _anchor[_user];
        uint256 today = _today();
        if (today <= uint256(anch)) return 0;
        return (today - uint256(anch)) / uint256(TERM_DAYS);
    }

    /// @dev How many full periods the user's principal can cover at current outflow.
    ///      Integer division: dust below one period's outflow is not counted.
    function _funded(Account storage _a) internal view returns (uint256) {
        if (_a.outflow == 0) return 0;
        return uint256(_a.principal) / uint256(_a.outflow);
    }

    // ──────────────────────────────────────────────
    // Internal: Epoch helpers
    // ──────────────────────────────────────────────

    /// @dev Deterministic mandate identifier. Same beneficiary + same rate = same hash.
    function _mandateId(address _beneficiary, uint128 _rate) internal pure returns (bytes32) {
        return keccak256(abi.encode(_beneficiary, _rate));
    }

    /// @dev Current epoch index. Epochs are TERM_DAYS-wide windows anchored at DEPLOY_DAY.
    function _epochOf() internal view returns (uint256) {
        uint256 today = _today();
        if (today <= uint256(DEPLOY_DAY)) return 0;
        return (today - uint256(DEPLOY_DAY)) / uint256(TERM_DAYS);
    }

    /// @dev Convert a user's anchor to an epoch index. Used for exit
    ///      computation so exits are relative to billing start, not wall clock.
    function _anchorEpoch(address _user) internal view returns (uint256) {
        uint32 anch = _anchor[_user];
        if (uint256(anch) <= uint256(DEPLOY_DAY)) return 0;
        return (uint256(anch) - uint256(DEPLOY_DAY)) / uint256(TERM_DAYS);
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
    ///      Bucket entries/exits are left in place for lapsed taps so
    ///      beneficiaries can still harvest their earned income.
    ///
    ///      Principal is NOT modified here. Surviving taps consume from
    ///      principal via normal settlement in subsequent periods. Only
    ///      outflow is adjusted (lapsing taps removed). Exits are recomputed
    ///      so the new funded count (principal / reduced outflow) is reflected
    ///      in the bucket system.
    function _resolvePriority(address _user) internal {
        Account storage a = _accounts[_user];
        uint256 budget = uint256(a.principal);
        uint256 committed;
        bytes32[] storage taps = _userTaps[_user];

        uint256 i = 0;
        while (i < taps.length) {
            bytes32 mid = taps[i];
            Tap storage t = _taps[_user][mid];

            if (committed + uint256(t.rate) <= budget) {
                committed += uint256(t.rate);
                i++;
            } else {
                // Lapse — clean up tap but preserve bucket entries/exits
                bool isBurn = _mandateId(address(0), t.rate) == mid;
                a.outflow -= t.rate;
                if (isBurn) _burnOutflow[_user] -= t.rate;
                delete _taps[_user][mid];
                delete _mandateExitEpoch[_user][mid];

                for (uint256 j = i; j < taps.length - 1; j++) {
                    taps[j] = taps[j + 1];
                }
                taps.pop();

                emit Revoked(_user, mid, uint32(_today()));
            }
        }

        // Recompute exits for surviving taps (outflow changed → funded changed)
        _recomputeAllExits(_user);

        if (taps.length == 0) {
            _notifyListener(_user, false);
        }
    }

    // ──────────────────────────────────────────────
    // Internal: Bucket Management
    // ──────────────────────────────────────────────

    /// @dev Update bucket exit epochs for all non-burn taps. Called after any
    ///      change to principal or outflow. Exit = anchorEpoch + 1 + funded.
    ///      Since all taps share principal/outflow, exit is the same for all.
    function _recomputeAllExits(address _user) internal {
        Account storage a = _accounts[_user];
        bytes32[] storage taps = _userTaps[_user];
        uint256 baseEpoch = _anchorEpoch(_user);
        uint256 sharedFunded = _funded(a);
        uint256 newExit = baseEpoch + 1 + sharedFunded;

        for (uint256 i; i < taps.length; i++) {
            bytes32 mid = taps[i];
            bool isBurn = _mandateId(address(0), _taps[_user][mid].rate) == mid;
            if (isBurn) continue;

            uint32 oldExit = _mandateExitEpoch[_user][mid];

            if (uint256(oldExit) != newExit) {
                if (oldExit > 0) _exits[mid][uint256(oldExit)]--;
                _exits[mid][newExit]++;
                _mandateExitEpoch[_user][mid] = uint32(newExit);
            }
        }
    }

    /// @dev Remove a mandateId from the user's tap list. O(n) shift to preserve
    ///      priority ordering (first-tapped = first-paid).
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

    // ──────────────────────────────────────────────
    // Internal: Listener
    // ──────────────────────────────────────────────

    /// @dev Set the schedule listener (receives callbacks on tap/revoke/lapse).
    function _setListener(address _listener) internal {
        scheduleListener = _listener;
        emit ListenerSet(_listener);
    }

    /// @dev Best-effort callback to the listener. Silently swallows reverts so
    ///      a broken listener can't block core operations.
    function _notifyListener(address _user, bool _active) internal {
        address listener = scheduleListener;
        if (listener == address(0)) return;
        try IScheduleListener(listener).onScheduleUpdate(address(this), _user, _active) {} catch {}
    }
}
