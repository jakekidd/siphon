// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IMandateListener} from "./interfaces/IMandateListener.sol";

/**
 * @title SiphonToken — ERC20 with mandate-based autopay
 * @author Ubitel
 *
 * @notice Abstract ERC20 where balanceOf decays over time via concurrent
 *         payment mandates. Implementations provide name/symbol/decimals,
 *         access control, and mint/spend entry points.
 *
 * @dev Storage layout (14 declared state variables, base slots 0-13).
 *      Inheritors should start their own state at slot 14+.
 *      Mappings reserve a base slot for the hash seed; actual data lives at keccak256(key, slot).
 *
 *       Slot | Variable              | Type
 *       -----+-----------------------+--------------------------------------
 *        0   | _accounts             | mapping(address => Account)
 *        1   | _anchor               | mapping(address => uint32)
 *        2   | _allowances           | mapping(address => mapping => uint256)
 *        3   | totalMinted           | uint256
 *        4   | totalBurned           | uint256
 *        5   | totalSpent            | uint256
 *        6   | _authorizations       | mapping(address => mapping => uint256)
 *        7   | _checkpoints          | mapping(bytes32 => Checkpoint)
 *        8   | _entries              | mapping(bytes32 => mapping => uint256)
 *        9   | _exits                | mapping(bytes32 => mapping => uint256)
 *       10   | _userTaps             | mapping(address => bytes32[])
 *       11   | _taps                 | mapping(address => mapping => Tap)
 *       12   | _burnOutflow          | mapping(address => uint128)
 *       13   | mandateListener       | address
 */
abstract contract SiphonToken is IERC20, IERC20Metadata {
    // ──────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────

    /// @notice Balance too low for the requested operation.
    error InsufficientBalance();
    /// @notice ERC20 allowance too low for transferFrom.
    error InsufficientAllowance();
    /// @notice ERC20: transfer to the zero address.
    error ERC20InvalidReceiver(address receiver);
    /// @notice ERC20: transfer from the zero address.
    error ERC20InvalidSender(address sender);
    /// @notice Beneficiary cannot equal the user (self-tap).
    error InvalidBeneficiary();
    /// @notice Rate is zero, or mandate already exists on this user.
    error InvalidMandate();
    /// @notice No authorization remaining for this mandate.
    error NotApproved();
    /// @notice Caller is not permitted for this operation.
    error Unauthorized();
    /// @notice User already has MAX_TAPS active mandates.
    error MaxTaps();
    /// @notice No active tap found for the given mandateId.
    error TapNotFound();
    /// @notice User is already in a comp period (anchor in the future).
    error AlreadyComped();

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    /// @notice A mandate was activated on a user. Immediate first-term payment deducted.
    event Tapped(address indexed user, bytes32 indexed mandateId, address beneficiary, uint128 rate);
    /// @notice A mandate was terminated (user- or beneficiary-initiated, or lapse).
    event Revoked(address indexed user, bytes32 indexed mandateId, uint32 day);
    /// @notice Lazy settlement materialized: consumed tokens deducted from principal.
    event Settled(address indexed user, uint256 amount);
    /// @notice Mandate authorization set or updated.
    event Authorized(address indexed user, bytes32 indexed mandateId, uint256 count);
    /// @notice Tokens burned via _spend (marketplace purchases, fees, etc.).
    event Spent(address indexed user, uint256 amount);
    /// @notice Beneficiary collected income from the bucket system.
    event Harvested(address indexed beneficiary, bytes32 indexed mandateId, uint256 amount, uint256 epochs);
    /// @notice Billing paused for N terms on a user.
    event Comped(address indexed user, bytes32 indexed mandateId, uint16 epochs);
    /// @notice Mandate listener address updated.
    event ListenerSet(address listener);

    // ──────────────────────────────────────────────
    // Structs
    // ──────────────────────────────────────────────

    /// @dev Per-user account. Packed into 1 storage slot (256 bits).
    ///      principal: stored token balance (before lazy deductions).
    ///      outflow: sum of all active tap rates. balanceOf = principal - consumed(outflow).
    struct Account {
        uint128 principal;
        uint128 outflow;
    }

    /// @dev Per-user per-mandate tap record. Packed into 1 storage slot (192/256 bits).
    ///      rate: tokens per term paid to the beneficiary.
    ///      entryEpoch: epoch when this tap entered the bucket system.
    ///      exitEpoch: projected epoch when funds run out (updated on principal/outflow changes).
    struct Tap {
        uint128 rate;
        uint32 entryEpoch;
        uint32 exitEpoch;
    }

    /// @dev Harvest checkpoint per mandateId. Packed into 1 storage slot (256 bits).
    ///      lastEpoch: last epoch processed by harvest().
    ///      count: running number of active subscribers at lastEpoch.
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

    uint32 public immutable GENESIS_DAY;
    uint16 public immutable TERM_DAYS;
    uint8 public immutable MAX_TAPS;

    // ──────────────────────────────────────────────
    // State (slots 0-13)
    // ──────────────────────────────────────────────

    /// @notice Per-user account: principal balance and aggregate outflow rate.
    /// @dev Slot 0.
    mapping(address => Account) internal _accounts;

    /// @notice Per-user billing anchor (day index). Periods elapsed = (today - anchor) / TERM_DAYS.
    /// @dev Slot 1. Shared across all mandates. Reset on settle, tap, revoke. Moved forward on comp.
    mapping(address => uint32) internal _anchor;

    /// @notice ERC20 allowances.
    /// @dev Slot 2.
    mapping(address => mapping(address => uint256)) internal _allowances;

    /// @notice Cumulative tokens ever minted.
    /// @dev Slot 3. totalSupply = totalMinted - totalBurned - totalSpent.
    uint256 public totalMinted;

    /// @notice Cumulative tokens destroyed by burn mandates (beneficiary = address(0)).
    /// @dev Slot 4.
    uint256 public totalBurned;

    /// @notice Cumulative tokens removed via _spend (marketplace purchases, fees).
    /// @dev Slot 5.
    uint256 public totalSpent;

    /// @notice Per-user mandate authorizations. authorize(mid, count) sets; tap() decrements.
    /// @dev Slot 6. type(uint256).max = infinite (never decremented).
    mapping(address => mapping(bytes32 => uint256)) internal _authorizations;

    /// @notice Per-mandate harvest checkpoint: last epoch processed and running subscriber count.
    /// @dev Slot 7.
    mapping(bytes32 => Checkpoint) internal _checkpoints;

    /// @notice Bucket entries: _entries[mandateId][epoch] = number of users entering at that epoch.
    /// @dev Slot 8. Written on tap and comp re-entry. Deleted during harvest.
    mapping(bytes32 => mapping(uint256 => uint256)) internal _entries;

    /// @notice Bucket exits: _exits[mandateId][epoch] = number of users exiting at that epoch.
    /// @dev Slot 9. Recomputed on principal/outflow changes. Deleted during harvest.
    mapping(bytes32 => mapping(uint256 => uint256)) internal _exits;

    /// @notice Ordered list of active mandateIds per user. Index = priority (0 = highest).
    /// @dev Slot 10. Array order determines lapse priority: first-tapped = first-paid.
    mapping(address => bytes32[]) internal _userTaps;

    /// @notice Per-user per-mandate tap records.
    /// @dev Slot 11. Deleted on revoke/lapse (same mandateId can be re-tapped).
    mapping(address => mapping(bytes32 => Tap)) internal _taps;

    /// @notice Per-user burn outflow: subset of outflow from burn mandates (beneficiary = address(0)).
    /// @dev Slot 12. Tracked separately so _settle can attribute burns to totalBurned.
    mapping(address => uint128) internal _burnOutflow;

    /// @notice External contract notified on mandate state changes (tap, revoke, lapse).
    /// @dev Slot 13. Best-effort callback; reverts are silently swallowed.
    address public mandateListener;

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    constructor(uint32 _genesisDay, uint16 _termDays, uint8 _maxTaps) {
        GENESIS_DAY = _genesisDay == 0 ? uint32(block.timestamp / _SECONDS_PER_DAY) : _genesisDay;
        require(_termDays > 0, "term must be > 0");
        require(_maxTaps > 0, "max taps must be > 0");
        TERM_DAYS = _termDays;
        MAX_TAPS = _maxTaps;
    }

    // ──────────────────────────────────────────────
    // ERC20
    // ──────────────────────────────────────────────

    /// @notice Spendable balance after all active mandates. Computed lazily, always current.
    /// @dev O(1): principal - min(periodsElapsed, funded) * outflow. No iteration.
    function balanceOf(address _user) external view returns (uint256) {
        return _balance(_user);
    }

    /// @notice Total tokens in circulation. Stale between settlements — see Tradeoffs in README.
    /// @dev Does not reflect unsettled consumption or unharvested beneficiary income.
    function totalSupply() external view returns (uint256) {
        return totalMinted - totalBurned - totalSpent;
    }

    /// @notice ERC20 transfer. Settles both sides. Subject to _beforeTransfer hook.
    function transfer(address _to, uint256 _amount) external virtual returns (bool) {
        _transfer(msg.sender, _to, _amount);
        return true;
    }

    /// @notice ERC20 transferFrom. Settles both sides. Subject to _beforeTransfer hook.
    function transferFrom(address _from, address _to, uint256 _amount) external virtual returns (bool) {
        uint256 allowed = _allowances[_from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < _amount) revert InsufficientAllowance();
            _allowances[_from][msg.sender] = allowed - _amount;
        }
        _transfer(_from, _to, _amount);
        return true;
    }

    /// @notice ERC20 approve. Separate from mandate authorization (authorize()).
    function approve(address _spender, uint256 _amount) external virtual returns (bool) {
        _allowances[msg.sender][_spender] = _amount;
        emit Approval(msg.sender, _spender, _amount);
        return true;
    }

    /// @notice ERC20 allowance.
    function allowance(address _owner, address _spender) external view returns (uint256) {
        return _allowances[_owner][_spender];
    }

    // ──────────────────────────────────────────────
    // Authorization (mandate approval)
    // ──────────────────────────────────────────────

    /**
     * @notice Pre-authorize a mandate for tap(). Mirrors ERC20 approve/transferFrom.
     *
     *         Each tap() consumes one authorization. Set _count to type(uint256).max
     *         for infinite authorization (beneficiary can re-tap freely after revoke
     *         or lapse, enabling auto-renew flows).
     *
     *         The mandateId locks in both the beneficiary address and the rate.
     *         Changing either requires a new authorization.
     *
     * @param _mid    mandateId = keccak256(beneficiary, rate).
     * @param _count  Number of taps authorized. 0 = revoke authorization.
     */
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
    function getTap(address _user, bytes32 _mid) external view returns (uint128 rate, uint32 entryEpoch, uint32 exitEpoch) {
        Tap storage t = _taps[_user][_mid];
        return (t.rate, t.entryEpoch, t.exitEpoch);
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
        Account storage a = _accounts[_user];
        return _periodsElapsed(_user) <= _funded(a);
    }

    /// @notice Current day index (block.timestamp / 86400).
    function currentDay() external view returns (uint256) {
        return _today();
    }

    /// @notice Current epoch index ((today - GENESIS_DAY) / TERM_DAYS).
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

    /**
     * @notice Revoke a mandate. Immediate termination.
     *
     *         Callable by the user (revoking their own mandate) or the beneficiary
     *         (canceling service). Beneficiary identity is recovered from the
     *         mandateId hash: mandateId(msg.sender, rate) must equal _mid.
     *
     *         On revoke:
     *         - Outflow decreases; balance stops decaying for this mandate.
     *         - Bucket exit is moved to the current epoch (stops future harvest earnings).
     *         - Bucket entry is preserved so the beneficiary can still harvest historical epochs.
     *         - Tap is deleted: the same mandateId can be re-tapped later if re-authorized.
     *
     * @param _user  The user whose mandate is being revoked.
     * @param _mid   The mandateId to revoke.
     */
    function revoke(address _user, bytes32 _mid) external virtual {
        Tap storage t = _taps[_user][_mid];
        if (t.rate == 0) revert TapNotFound();
        if (msg.sender != _user) {
            if (_mandateId(msg.sender, t.rate) != _mid) revert Unauthorized();
        }
        _settle(_user);
        _revoke(_user, _mid);
    }

    // ──────────────────────────────────────────────
    // Public: Tap (beneficiary activates mandate for user)
    // ──────────────────────────────────────────────

    /**
     * @notice Tap a user: activate a mandate. msg.sender IS the beneficiary.
     *
     *         The beneficiary role is permissionless. Anyone can call tap() if
     *         the user authorized their mandateId. The user IS the gate. If your
     *         use case needs a beneficiary whitelist, override tap() in your
     *         implementation.
     *
     *         On tap:
     *         - One authorization is consumed (unless infinite).
     *         - Immediate first-term payment: _rate is deducted from the user and
     *           transferred to the beneficiary. User must have sufficient balance.
     *         - User's outflow increases by _rate; balance starts decaying each term.
     *         - Bucket entry is written at the next epoch for harvest accounting.
     *         - Exit epoch is computed from current funded periods.
     *
     *         Self-tap is forbidden (beneficiary != user). Duplicate mandateId
     *         on the same user reverts. Maximum MAX_TAPS concurrent mandates.
     *
     * @param _user  The user being tapped (payer).
     * @param _rate  Tokens per term. Determines mandateId = keccak256(msg.sender, _rate).
     */
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

    /**
     * @notice Harvest income for a mandate. Permissionless; tokens always go to
     *         the beneficiary regardless of caller.
     *
     *         Walks the bucket system epoch-by-epoch from the last checkpoint,
     *         tallying entries (new subscribers) and exits (lapsed/revoked),
     *         maintaining a running subscriber count. Each epoch's income =
     *         count * rate. Accumulated total is credited to the beneficiary's
     *         principal.
     *
     *         Cost scales linearly with neglect: monthly harvest = 1 epoch.
     *         Skip 6 months = 6 iterations. It never bricks. Use _maxEpochs
     *         to bound gas per call.
     *
     *         Multiple users sharing the same mandateId (same beneficiary + same
     *         rate) are harvested together in one call. This is the core
     *         scalability property: one harvest collects from all subscribers.
     *
     * @dev    Total is accumulated as uint256. Reverts if total exceeds uint128.max
     *         (requires extreme rate * epochs * subscribers). Harvest more
     *         frequently to stay under the cap.
     *
     * @param _beneficiary  The beneficiary address (combined with _rate to derive mandateId).
     * @param _rate         The mandate rate (combined with _beneficiary to derive mandateId).
     * @param _maxEpochs    Maximum epochs to process in this call (gas bound).
     */
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

    /**
     * @notice Comp a user: pause billing for N terms. Caller must be the
     *         mandate's beneficiary.
     *
     *         The user's balance freezes; no payments are deducted during the
     *         comp period. When it ends, billing resumes automatically. No
     *         re-authorization needed. This is how "3 months free" works.
     *
     *         Bucket entries/exits are updated: the user exits the bucket at
     *         the current epoch and re-enters after the comp period, so the
     *         beneficiary only earns for periods actually billed.
     *
     *         Cannot comp a user who is already comped (anchor in the future).
     *
     * @dev    IMPORTANT: Anchor is shared across all mandates. Comping via one
     *         mandate pauses ALL of the user's mandates. This is a known
     *         design tradeoff for O(1) balanceOf.
     *
     * @param _user    The user to comp.
     * @param _rate    Rate of the caller's mandate (to derive mandateId and verify caller).
     * @param _epochs  Number of terms to pause billing.
     */
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

    /// @dev Hook called before every ERC20 transfer. Override to add restrictions
    ///      (e.g. whitelist, pause, exchange regulation). Reverts block the transfer.
    ///      Default: no-op (open transfers). Not called by _mint, _spend, or _tap
    ///      (those manipulate principal directly).
    /// @param _from   Sender address.
    /// @param _to     Receiver address.
    /// @param _amount Transfer amount.
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

        uint128 rate = t.rate;
        Account storage a = _accounts[_user];
        a.outflow -= rate;
        bool isBurn = _mandateId(address(0), rate) == _mid;
        if (isBurn) _burnOutflow[_user] -= rate;
        _anchor[_user] = uint32(_today());

        // Move exit to current epoch (preserves entry for historical harvest)
        if (!isBurn) {
            uint32 oldExit = t.exitEpoch;
            if (oldExit > 0) _exits[_mid][uint256(oldExit)]--;
            _exits[_mid][_epochOf() + 1]++;
        }

        delete _taps[_user][_mid];
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
        if (_epochs == 0) revert InvalidMandate();
        if (_today() < uint256(_anchor[_user])) revert AlreadyComped();

        _settle(_user);

        uint256 curEpoch = _epochOf();
        uint256 compDays = uint256(_epochs) * uint256(TERM_DAYS);
        uint256 newAnchorDay = _today() + compDays;
        uint256 anchorEpoch = (newAnchorDay - uint256(GENESIS_DAY)) / uint256(TERM_DAYS);

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

    /// @dev Current epoch index. Epochs are TERM_DAYS-wide windows anchored at GENESIS_DAY.
    function _epochOf() internal view returns (uint256) {
        uint256 today = _today();
        if (today <= uint256(GENESIS_DAY)) return 0;
        return (today - uint256(GENESIS_DAY)) / uint256(TERM_DAYS);
    }

    /// @dev Convert a user's anchor to an epoch index. Used for exit
    ///      computation so exits are relative to billing start, not wall clock.
    function _anchorEpoch(address _user) internal view returns (uint256) {
        uint32 anch = _anchor[_user];
        if (uint256(anch) <= uint256(GENESIS_DAY)) return 0;
        return (uint256(anch) - uint256(GENESIS_DAY)) / uint256(TERM_DAYS);
    }

    // ──────────────────────────────────────────────
    // Internal: Settlement
    // ──────────────────────────────────────────────

    /**
     * @dev Settle: materialize lazy consumption into storage.
     *
     *      1. Compute periods elapsed since anchor and tokens consumed.
     *      2. Deduct consumed from principal. Attribute burn portion to totalBurned.
     *      3. Reset anchor to today (next settlement starts from here).
     *      4. If elapsed > funded (user ran out of money): resolve priority
     *         to determine which mandates survive and which lapse.
     *
     *      Idempotent within a term: if no full periods have elapsed since the
     *      last anchor, the function is a no-op. During comp (anchor in the future),
     *      periodsElapsed returns 0 so settle is also a no-op — the comp anchor
     *      is preserved until it naturally expires.
     *
     *      Called at the start of every mutation (_mint, _spend, _transfer, _tap,
     *      _revoke, _comp) to ensure principal is current before modification.
     */
    function _settle(address _user) internal {
        Account storage a = _accounts[_user];
        if (a.outflow == 0) return;

        uint256 elapsed = _periodsElapsed(_user);
        if (elapsed == 0) return;

        uint256 f = _funded(a);
        uint256 periods = elapsed < f ? elapsed : f;
        uint256 con = periods * uint256(a.outflow);

        if (con > 0) {
            a.principal -= uint128(con);
            uint128 burnRate = _burnOutflow[_user];
            if (burnRate > 0) {
                totalBurned += periods * uint256(burnRate);
            }
            emit Settled(_user, con);
        }

        _anchor[_user] = uint32(_today());

        if (elapsed > f) {
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
                bool isBurn = _mandateId(address(0), t.rate) == mid;
                a.outflow -= t.rate;
                if (isBurn) _burnOutflow[_user] -= t.rate;
                delete _taps[_user][mid];

                for (uint256 j = i; j < taps.length - 1; j++) {
                    taps[j] = taps[j + 1];
                }
                taps.pop();

                emit Revoked(_user, mid, uint32(_today()));
            }
        }

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
            Tap storage t = _taps[_user][mid];
            bool isBurn = _mandateId(address(0), t.rate) == mid;
            if (isBurn) continue;

            uint32 oldExit = t.exitEpoch;

            if (uint256(oldExit) != newExit) {
                if (oldExit > 0) _exits[mid][uint256(oldExit)]--;
                _exits[mid][newExit]++;
                t.exitEpoch = uint32(newExit);
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

    /// @dev Set the mandate listener (receives callbacks on tap/revoke/lapse).
    function _setListener(address _listener) internal {
        mandateListener = _listener;
        emit ListenerSet(_listener);
    }

    /// @dev Best-effort callback to the listener. Silently swallows reverts so
    ///      a broken listener can't block core operations.
    function _notifyListener(address _user, bool _active) internal {
        address listener = mandateListener;
        if (listener == address(0)) return;
        try IMandateListener(listener).onMandateUpdate(address(this), _user, _active) {} catch {}
    }
}
