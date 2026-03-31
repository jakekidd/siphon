// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {SiphonToken} from "../SiphonToken.sol";

/**
 * @title DecayToken: Deflationary token where holding costs something
 * @notice Demonstrates burn mandates (beneficiary = address(0)). Every holder
 *         gets a burn tap applied on mint. Their balance decays each term,
 *         reducing totalSupply. No beneficiary harvests; the tokens vanish.
 *
 *         Use cases: demurrage currencies, governance tokens that expire,
 *         protocol-native burns (e.g. gas credits that deplete).
 *
 * @dev Key differences from payment mandates:
 *      - beneficiary = address(0), so _tap skips bucket accounting
 *      - No harvest. Burns are tracked via totalBurned, not a checkpoint.
 *      - _tap is called internally (no authorization needed)
 *      - Users can top up (receive more tokens) to extend their runway
 *      - DECAY_RATE is immutable: all holders decay at the same rate.
 *        A mutable rate would create double-tap footguns when users minted
 *        before and after a rate change end up with two burn mandates.
 */
contract DecayToken is SiphonToken {
    address public owner;

    /// @notice Tokens burned per term per holder. Immutable: set at construction.
    uint128 public immutable DECAY_RATE;

    error NoDecayRate();

    modifier onlyOwner() { if (msg.sender != owner) revert Unauthorized(); _; }

    /// @param _termDays  Billing interval (e.g. 30 for monthly decay).
    /// @param _decayRate Tokens burned per term per holder. Must be > 0.
    constructor(uint16 _termDays, uint128 _decayRate) SiphonToken(0, _termDays, 32) {
        if (_decayRate == 0) revert NoDecayRate();
        owner = msg.sender;
        DECAY_RATE = _decayRate;
    }

    function name() external pure returns (string memory) { return "DecayToken"; }
    function symbol() external pure returns (string memory) { return "DECAY"; }
    function decimals() external pure returns (uint8) { return 18; }

    /// @notice Mint tokens to a user and apply the burn mandate. Balance starts
    ///         decaying immediately. If the user already has a burn tap,
    ///         just tops up their balance (extends runway).
    function mint(address _user, uint128 _amount) external onlyOwner {
        _mint(_user, _amount);

        // Apply burn tap if not already active
        bytes32 mid = _mandateId(address(0), DECAY_RATE);
        if (_taps[_user][mid].rate == 0) {
            _tap(_user, address(0), DECAY_RATE);
        }
    }

    /// @notice How many terms until a user's balance is fully burned.
    function runway(address _user) external view returns (uint256) {
        bytes32 mid = _mandateId(address(0), DECAY_RATE);
        if (_taps[_user][mid].rate == 0) return 0;
        return _funded(_accounts[_user]);
    }

    /// @notice Remove a user's burn mandate. Admin escape hatch.
    function exempt(address _user) external onlyOwner {
        bytes32 mid = _mandateId(address(0), DECAY_RATE);
        _revoke(_user, mid);
    }
}
