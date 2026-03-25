# SiphonToken

ERC20 with scheduled payment deductions. Balance decays over time like a bank account with auto-pay.

## Overview

SiphonToken is an abstract Solidity contract that extends ERC20 with **period-based scheduled payments**. A user's `balanceOf` automatically decreases at period boundaries without any transaction — the math is computed on-the-fly from five stored fields.

**Not streaming.** Siphoning is period-based (full period committed upfront), not per-second linear. This matches how real subscriptions work.

## Two paths

**Burn (to = address(0))** — consumed tokens leave the supply. Good for protocol fee sinks, deflationary mechanics.

**Beneficiary (to != address(0))** — consumed tokens flow to a payee. The beneficiary calls `collect()` to sweep income. Tracking uses shared count buckets (joinoffs + dropoffs per epoch), so user mutations are O(1) and collection is O(epochs).

## Key concepts

- **Lazy settlement**: `balanceOf` computed on-the-fly. No keeper, no cron. Storage only changes on interaction.
- **Only fully funded periods**: `consumed = min(periodsElapsed, principal / rate) * rate`. Partial-period remainders are never charged.
- **First payment at boundary**: No charge at schedule creation. First deduction at `anchor + interval`. For beneficiary schedules, the first term is paid immediately on assignment.
- **Schedule approval**: Users pre-approve schedules by ID (`approveSchedule(sid, count)`). Each `assign()` consumes one approval. `type(uint256).max` = infinite (beneficiary can reassign freely, e.g. auto-renew).
- **Lapse = done**: Running out of funds always clears the schedule. To resume, the user must re-approve and the beneficiary must re-assign.
- **Two storage slots per user**: Gas-efficient packed struct.

## Schedule lifecycle

```
1. User:    token.approveSchedule(scheduleId, 1)
2. Netflix: token.assign(user, treasury, rate, 30)
   -> checks approval, consumes it
   -> immediate first-term transfer to treasury
   -> sets schedule, writes joinoff + dropoff
3. Monthly: lazy consumed ticks down user balance
4. Netflix: token.collect(treasury, rate, 30, 12)
   -> walks epochs, multiplies running subscriber count by rate
5. Lapse or terminate: schedule cleared
6. Re-subscribe: approve again, assign again
```

## Usage

```solidity
import {SiphonToken} from "siphon/SiphonToken.sol";

contract MyToken is SiphonToken {
    constructor() SiphonToken(0) {} // 0 = use current day as epoch anchor

    function name() external pure returns (string memory) { return "MyToken"; }
    function symbol() external pure returns (string memory) { return "MTK"; }
    function decimals() external pure returns (uint8) { return 18; }

    function mint(address user, uint128 amount) external onlyOwner {
        _mint(user, amount);
    }

    // Burn-path schedule (no beneficiary)
    function setBurnSchedule(address user, uint128 rate, uint16 interval) external {
        _setSchedule(user, rate, interval);
    }

    // Beneficiary schedule (requires user's prior approveSchedule)
    function assignSchedule(address user, address to, uint128 rate, uint16 interval) external {
        _assign(user, to, rate, interval);
    }
}
```

See `src/example/SimpleSiphon.sol` for a complete implementation.

## Build

```bash
forge build
forge test -vvv
```

## License

MIT
