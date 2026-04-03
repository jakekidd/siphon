// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Smart wallet with mandate-based recurring payments.
// Mandates are warrants: they authorize a payee to collect tokens on a schedule.
// Works with any ERC20. Every payment is a real transfer.
// No lazy balance tricks. No transfer restrictions. Insolvency = payee's problem.

contract SiphonWallet {
    using SafeERC20 for IERC20;

    // ── Errors ──

    error Unauthorized();
    error MandateNotActive();
    error InvalidMandate();
    error NothingOwed();
    error CallFailed();

    // ── Events ──

    event Granted(uint256 indexed id, address indexed payee, address indexed token, uint128 rate, uint32 cadence);
    event Cancelled(uint256 indexed id);
    event Collected(uint256 indexed id, address indexed payee, address indexed token, uint256 amount, uint256 periods);
    event Executed(address indexed to, uint256 value, bytes data);

    // ── Structs ──

    struct Mandate {
        address payee;
        address token;
        uint128 rate;           // amount per period
        uint32  cadence;        // period length in days
        uint32  lastCollected;  // day of last collection
        uint8   maxPeriods;     // debt cap (0 = unlimited)
        bool    active;
    }

    // ── Constants ──

    uint256 internal constant _SECONDS_PER_DAY = 86_400;

    // ── State ──

    address public immutable owner;
    Mandate[] internal _mandates;

    // ── Modifiers ──

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    // ── Constructor ──

    constructor(address _owner) {
        owner = _owner;
    }

    receive() external payable {}

    // ══════════════════════════════════════════════
    //  Owner operations
    // ══════════════════════════════════════════════

    // Create a mandate (warrant). Payee can start collecting after one full period.
    function grant(
        address _payee,
        address _token,
        uint128 _rate,
        uint32  _cadence,
        uint8   _maxPeriods
    ) external onlyOwner returns (uint256 id) {
        if (_rate == 0 || _cadence == 0 || _payee == address(0) || _payee == address(this))
            revert InvalidMandate();

        id = _mandates.length;
        _mandates.push(Mandate({
            payee: _payee,
            token: _token,
            rate: _rate,
            cadence: _cadence,
            lastCollected: uint32(_today()),
            maxPeriods: _maxPeriods,
            active: true
        }));

        emit Granted(id, _payee, _token, _rate, _cadence);
    }

    function cancel(uint256 _id) external onlyOwner {
        Mandate storage m = _mandates[_id];
        if (!m.active) revert MandateNotActive();
        m.active = false;
        emit Cancelled(_id);
    }

    // Arbitrary call. Transfer tokens, approve contracts, interact with DeFi.
    function execute(address _to, uint256 _value, bytes calldata _data) external onlyOwner returns (bytes memory) {
        (bool ok, bytes memory ret) = _to.call{value: _value}(_data);
        if (!ok) revert CallFailed();
        emit Executed(_to, _value, _data);
        return ret;
    }

    // ══════════════════════════════════════════════
    //  Permissionless operations
    // ══════════════════════════════════════════════

    // Collect owed tokens. Anyone can call; tokens always go to the payee.
    // lastCollected advances by exact period multiples (partial periods carry over).
    // On insolvency: transfers available balance, shortfall is payee's loss.
    function collect(uint256 _id) external returns (uint256 amount) {
        Mandate storage m = _mandates[_id];
        if (!m.active) revert MandateNotActive();

        uint256 elapsed = _today() - uint256(m.lastCollected);
        uint256 periods = elapsed / uint256(m.cadence);
        if (periods == 0) revert NothingOwed();

        if (m.maxPeriods > 0 && periods > uint256(m.maxPeriods))
            periods = uint256(m.maxPeriods);

        uint256 owed = periods * uint256(m.rate);
        uint256 bal = IERC20(m.token).balanceOf(address(this));
        amount = owed < bal ? owed : bal;

        m.lastCollected += uint32(periods * uint256(m.cadence));

        if (amount > 0) {
            IERC20(m.token).safeTransfer(m.payee, amount);
        }

        emit Collected(_id, m.payee, m.token, amount, periods);
    }

    // ══════════════════════════════════════════════
    //  Views
    // ══════════════════════════════════════════════

    function debt(uint256 _id) external view returns (uint256) {
        Mandate storage m = _mandates[_id];
        if (!m.active) return 0;

        uint256 elapsed = _today() - uint256(m.lastCollected);
        uint256 periods = elapsed / uint256(m.cadence);
        if (m.maxPeriods > 0 && periods > uint256(m.maxPeriods))
            periods = uint256(m.maxPeriods);

        return periods * uint256(m.rate);
    }

    function mandateInfo(uint256 _id) external view returns (Mandate memory) {
        return _mandates[_id];
    }

    function mandateCount() external view returns (uint256) {
        return _mandates.length;
    }

    // ── Internal ──

    function _today() internal view virtual returns (uint256) {
        return block.timestamp / _SECONDS_PER_DAY;
    }
}
