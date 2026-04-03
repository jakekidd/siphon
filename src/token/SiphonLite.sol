// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IMandateListener} from "./interfaces/IMandateListener.sol";

// SiphonLite: stripped SiphonToken. Same lazy-balance model, O(1) mutations.
//
// Removed vs SiphonToken:
//   - Bucket system (entries/exits/checkpoints/harvest/_recomputeAllExits)
//   - Comp (service layer can revoke + delay + re-tap)
//   - Priority resolution (all-lapse-together on insolvency)
//   - _burnOutflow tracking (no burn mandates; use _spend for burns)
//   - Authorization counts (bool: yes or no)
//
// Added:
//   - claim(user, rate): beneficiary claims per-user, O(1)
//   - batchClaim(users, rate): convenience wrapper
//
// Every user mutation is O(1) in storage writes.
// Lapse is O(n_taps) but only fires once per insolvency event.

abstract contract SiphonLite is IERC20, IERC20Metadata {

    // ── Errors ──

    error InsufficientBalance();
    error InsufficientAllowance();
    error ERC20InvalidReceiver(address receiver);
    error ERC20InvalidSender(address sender);
    error InvalidBeneficiary();
    error InvalidMandate();
    error NotAuthorized();
    error Unauthorized();
    error MaxTaps();
    error TapNotFound();
    error NothingToClaim();

    // ── Events ──

    event Tapped(address indexed user, bytes32 indexed mandateId, address beneficiary, uint128 rate);
    event Revoked(address indexed user, bytes32 indexed mandateId, uint32 day);
    event Settled(address indexed user, uint256 amount);
    event Authorized(address indexed user, bytes32 indexed mandateId, bool status);
    event Spent(address indexed user, uint256 amount);
    event Claimed(address indexed beneficiary, bytes32 indexed mandateId, address indexed user, uint256 amount);
    event ListenerSet(address listener);

    // ── Structs ──

    // 1 slot: principal + outflow
    struct Account {
        uint128 principal;
        uint128 outflow;
    }

    // 1 slot: rate + claimedEpoch + endEpoch (192/256 bits)
    // rate > 0, endEpoch == ACTIVE: active tap
    // rate > 0, endEpoch < ACTIVE: ended (lapsed or revoked), still claimable
    // rate == 0: empty slot
    uint32 internal constant ACTIVE = type(uint32).max;

    struct Tap {
        uint128 rate;
        uint32 claimedEpoch;
        uint32 endEpoch;
    }

    // ── Constants ──

    uint256 internal constant _SECONDS_PER_DAY = 86_400;

    // ── Immutables ──

    uint32 public immutable GENESIS_DAY;
    uint16 public immutable TERM_DAYS;
    uint8 public immutable MAX_TAPS;

    // ── State ──

    mapping(address => Account) internal _accounts;           // slot 0
    mapping(address => uint32) internal _anchor;              // slot 1
    mapping(address => mapping(address => uint256)) internal _allowances; // slot 2
    uint256 public totalMinted;                               // slot 3
    uint256 public totalSpent;                                // slot 4
    mapping(address => mapping(bytes32 => bool)) internal _authorized;   // slot 5
    mapping(address => bytes32[]) internal _userTaps;         // slot 6
    mapping(address => mapping(bytes32 => Tap)) internal _taps;          // slot 7
    address public mandateListener;                           // slot 8

    // ── Constructor ──

    constructor(uint32 _genesisDay, uint16 _termDays, uint8 _maxTaps) {
        GENESIS_DAY = _genesisDay == 0 ? uint32(block.timestamp / _SECONDS_PER_DAY) : _genesisDay;
        require(_termDays > 0 && _maxTaps > 0);
        TERM_DAYS = _termDays;
        MAX_TAPS = _maxTaps;
    }

    // ══════════════════════════════════════════════
    //  ERC20
    // ══════════════════════════════════════════════

    function balanceOf(address _user) external view returns (uint256) {
        return _balance(_user);
    }

    function totalSupply() external view returns (uint256) {
        return totalMinted - totalSpent;
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

    // ══════════════════════════════════════════════
    //  Authorization (bool, not counted)
    // ══════════════════════════════════════════════

    function authorize(bytes32 _mid, bool _status) external {
        _authorized[msg.sender][_mid] = _status;
        emit Authorized(msg.sender, _mid, _status);
    }

    function authorization(address _user, bytes32 _mid) external view returns (bool) {
        return _authorized[_user][_mid];
    }

    // ══════════════════════════════════════════════
    //  Views
    // ══════════════════════════════════════════════

    function getAccount(address _user) external view returns (uint128 principal, uint128 outflow, uint32 anchor) {
        Account storage a = _accounts[_user];
        return (a.principal, a.outflow, _anchor[_user]);
    }

    function getTap(address _user, bytes32 _mid) external view returns (uint128 rate, uint32 claimedEpoch, uint32 endEpoch) {
        Tap storage t = _taps[_user][_mid];
        return (t.rate, t.claimedEpoch, t.endEpoch);
    }

    function getUserTaps(address _user) external view returns (bytes32[] memory) {
        return _userTaps[_user];
    }

    function consumed(address _user) external view returns (uint256) {
        return _consumed(_user);
    }

    function isActive(address _user) external view returns (bool) {
        Account storage a = _accounts[_user];
        return a.outflow > 0 && _funded(a) > 0;
    }

    function isTapActive(address _user, bytes32 _mid) external view returns (bool) {
        return _isTapActive(_user, _mid);
    }

    function currentDay() external view returns (uint256) { return _today(); }
    function currentEpoch() external view returns (uint256) { return _epochOf(); }

    function mandateId(address _beneficiary, uint128 _rate) external pure returns (bytes32) {
        return _mandateId(_beneficiary, _rate);
    }

    function funded(address _user) external view returns (uint256) {
        return _funded(_accounts[_user]);
    }

    function expiryDay(address _user) external view returns (uint256) {
        return uint256(_anchor[_user]) + _funded(_accounts[_user]) * uint256(TERM_DAYS);
    }

    // ══════════════════════════════════════════════
    //  Public: Settle
    // ══════════════════════════════════════════════

    function settle(address _user) external {
        _settle(_user);
    }

    // ══════════════════════════════════════════════
    //  Public: Revoke
    // ══════════════════════════════════════════════

    // User or beneficiary can revoke. Unclaimed epochs remain claimable via endEpoch.
    function revoke(address _user, bytes32 _mid) external virtual {
        Tap storage t = _taps[_user][_mid];
        if (t.rate == 0 || t.endEpoch != ACTIVE) revert TapNotFound();
        if (msg.sender != _user) {
            if (_mandateId(msg.sender, t.rate) != _mid) revert Unauthorized();
        }
        _settle(_user);
        _revoke(_user, _mid);
    }

    // ══════════════════════════════════════════════
    //  Public: Tap
    // ══════════════════════════════════════════════

    // Beneficiary activates mandate. User must have authorized.
    function tap(address _user, uint128 _rate) external virtual {
        bytes32 mid = _mandateId(msg.sender, _rate);
        if (!_authorized[_user][mid]) revert NotAuthorized();
        _tap(_user, msg.sender, _rate);
    }

    // ══════════════════════════════════════════════
    //  Public: Claim (replaces harvest)
    // ══════════════════════════════════════════════

    // Beneficiary claims owed tokens from a specific user. O(1).
    // Settles the user first, then computes epochs owed since last claim.
    function claim(address _user, uint128 _rate) external returns (uint256 owed) {
        bytes32 mid = _mandateId(msg.sender, _rate);
        owed = _claim(_user, mid, msg.sender);
    }

    // Batch claim across multiple users. Each claim is O(1).
    function batchClaim(address[] calldata _users, uint128 _rate) external returns (uint256 total) {
        bytes32 mid = _mandateId(msg.sender, _rate);
        for (uint256 i; i < _users.length; i++) {
            total += _claim(_users[i], mid, msg.sender);
        }
    }

    // ══════════════════════════════════════════════
    //  Internal: Mutations
    // ══════════════════════════════════════════════

    function _mint(address _user, uint128 _amount) internal {
        _settle(_user);
        _accounts[_user].principal += _amount;
        totalMinted += _amount;
        emit Transfer(address(0), _user, _amount);
    }

    function _spend(address _user, uint128 _amount) internal {
        _settle(_user);
        if (_balance(_user) < _amount) revert InsufficientBalance();
        _accounts[_user].principal -= _amount;
        totalSpent += _amount;
        emit Transfer(_user, address(0), _amount);
        emit Spent(_user, _amount);
    }

    function _transfer(address _from, address _to, uint256 _amount) internal {
        if (_from == address(0)) revert ERC20InvalidSender(address(0));
        if (_to == address(0)) revert ERC20InvalidReceiver(address(0));
        _beforeTransfer(_from, _to, _amount);
        _settle(_from);
        if (_balance(_from) < _amount) revert InsufficientBalance();
        _accounts[_from].principal -= uint128(_amount);
        _settle(_to);
        _accounts[_to].principal += uint128(_amount);
        emit Transfer(_from, _to, _amount);
    }

    function _beforeTransfer(address, address, uint256) internal virtual {}

    function _tap(address _user, address _beneficiary, uint128 _rate) internal {
        if (_rate == 0) revert InvalidMandate();
        if (_beneficiary == _user) revert InvalidBeneficiary();
        _settle(_user);

        Account storage a = _accounts[_user];
        bytes32 mid = _mandateId(_beneficiary, _rate);

        // Reject if active tap exists at this mid
        Tap storage existing = _taps[_user][mid];
        if (existing.rate > 0 && existing.endEpoch == ACTIVE) revert InvalidMandate();
        if (_userTaps[_user].length >= uint256(MAX_TAPS)) revert MaxTaps();

        // Immediate first-term payment
        if (_balance(_user) < _rate) revert InsufficientBalance();
        a.principal -= _rate;

        _settle(_beneficiary);
        _accounts[_beneficiary].principal += _rate;
        emit Transfer(_user, _beneficiary, _rate);

        // Update account
        a.outflow += _rate;
        _anchor[_user] = uint32(_today());

        // Write tap (overwrites ended tap at same mid if any)
        _taps[_user][mid] = Tap(_rate, uint32(_epochOf()), ACTIVE);
        _userTaps[_user].push(mid);

        emit Tapped(_user, mid, _beneficiary, _rate);
        _notifyListener(_user, true);
    }

    function _revoke(address _user, bytes32 _mid) internal {
        Tap storage t = _taps[_user][_mid];
        if (t.rate == 0 || t.endEpoch != ACTIVE) revert TapNotFound();

        _accounts[_user].outflow -= t.rate;
        _anchor[_user] = uint32(_today());

        // Mark ended, don't delete (preserves claimable epochs)
        t.endEpoch = uint32(_epochOf());

        // Swap-and-pop removal from userTaps, O(1)
        _removeFromUserTaps(_user, _mid);

        emit Revoked(_user, _mid, uint32(_today()));
        if (_userTaps[_user].length == 0) _notifyListener(_user, false);
    }

    function _claim(address _user, bytes32 _mid, address _beneficiary) internal returns (uint256 owed) {
        _settle(_user);

        Tap storage t = _taps[_user][_mid];
        if (t.rate == 0) revert TapNotFound();

        uint256 epoch = _epochOf();
        uint256 end = t.endEpoch != ACTIVE ? uint256(t.endEpoch) : epoch;
        if (end <= uint256(t.claimedEpoch)) return 0;

        uint256 epochs = end - uint256(t.claimedEpoch);
        owed = epochs * uint256(t.rate);

        t.claimedEpoch = uint32(end);

        // Materialize into beneficiary principal
        _accounts[_beneficiary].principal += uint128(owed);

        emit Claimed(_beneficiary, _mid, _user, owed);
    }

    // ══════════════════════════════════════════════
    //  Internal: Settlement
    // ══════════════════════════════════════════════

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
            emit Settled(_user, con);
        }

        // All-lapse: if underfunded, every tap ends
        // Must run BEFORE anchor update so _anchorEpoch reads the old value
        if (elapsed > f) {
            _lapseAll(_user, f);
        }

        _anchor[_user] = uint32(_today());
    }

    // O(n_taps), but only fires on insolvency
    function _lapseAll(address _user, uint256 _funded) internal {
        uint256 endEpoch = _anchorEpoch(_user) + _funded;
        bytes32[] storage taps = _userTaps[_user];

        for (uint256 i; i < taps.length; i++) {
            Tap storage t = _taps[_user][taps[i]];
            t.endEpoch = uint32(endEpoch);
            emit Revoked(_user, taps[i], uint32(_today()));
        }

        delete _userTaps[_user];
        _accounts[_user].outflow = 0;
        _notifyListener(_user, false);
    }

    // ══════════════════════════════════════════════
    //  Internal: Lazy math
    // ══════════════════════════════════════════════

    function _today() internal view virtual returns (uint256) {
        return block.timestamp / _SECONDS_PER_DAY;
    }

    function _balance(address _user) internal view returns (uint256) {
        Account storage a = _accounts[_user];
        if (a.outflow == 0) return uint256(a.principal);
        return uint256(a.principal) - _consumed(_user);
    }

    function _consumed(address _user) internal view returns (uint256) {
        Account storage a = _accounts[_user];
        if (a.outflow == 0) return 0;
        uint256 elapsed = _periodsElapsed(_user);
        uint256 f = _funded(a);
        return (elapsed < f ? elapsed : f) * uint256(a.outflow);
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

    function _isTapActive(address _user, bytes32 _mid) internal view returns (bool) {
        Tap storage t = _taps[_user][_mid];
        if (t.rate == 0 || t.endEpoch != ACTIVE) return false;
        return _periodsElapsed(_user) <= _funded(_accounts[_user]);
    }

    // ══════════════════════════════════════════════
    //  Internal: Epoch helpers
    // ══════════════════════════════════════════════

    function _mandateId(address _beneficiary, uint128 _rate) internal pure returns (bytes32) {
        return keccak256(abi.encode(_beneficiary, _rate));
    }

    function _epochOf() internal view returns (uint256) {
        uint256 today = _today();
        if (today <= uint256(GENESIS_DAY)) return 0;
        return (today - uint256(GENESIS_DAY)) / uint256(TERM_DAYS);
    }

    function _anchorEpoch(address _user) internal view returns (uint256) {
        uint32 anch = _anchor[_user];
        if (uint256(anch) <= uint256(GENESIS_DAY)) return 0;
        return (uint256(anch) - uint256(GENESIS_DAY)) / uint256(TERM_DAYS);
    }

    // ══════════════════════════════════════════════
    //  Internal: Array helpers
    // ══════════════════════════════════════════════

    // Swap-and-pop: O(1) removal, no priority ordering
    function _removeFromUserTaps(address _user, bytes32 _mid) internal {
        bytes32[] storage taps = _userTaps[_user];
        for (uint256 i; i < taps.length; i++) {
            if (taps[i] == _mid) {
                taps[i] = taps[taps.length - 1];
                taps.pop();
                return;
            }
        }
    }

    // ══════════════════════════════════════════════
    //  Internal: Listener
    // ══════════════════════════════════════════════

    function _setListener(address _listener) internal {
        mandateListener = _listener;
        emit ListenerSet(_listener);
    }

    function _notifyListener(address _user, bool _active) internal {
        address listener = mandateListener;
        if (listener == address(0)) return;
        try IMandateListener(listener).onMandateUpdate(address(this), _user, _active) {} catch {}
    }
}
