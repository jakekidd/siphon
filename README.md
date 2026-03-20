# SiphonToken

ERC20 with scheduled payment deductions. Balance decays over time like a bank account with auto-pay.

## Overview

SiphonToken is an abstract Solidity contract that extends ERC20 with **period-based scheduled payments**. A user's `balanceOf` automatically decreases at period boundaries without any transaction -- the math is computed on-the-fly.

**Not streaming.** Siphoning is period-based (full period committed upfront), not per-second linear. This matches how real subscriptions work.

## Features

- **Auto-decaying balance**: `balanceOf` ticks down each period
- **Skip periods (prepaid)**: Periods where no balance is consumed
- **Lazy settlement**: No keeper or cron needed
- **Non-transferable by default**: Override for custom transfer logic
- **Schedule listener**: Optional callback on schedule state changes
- **Two storage slots per user**: Gas-efficient packed struct

## Usage

TODO: Full usage guide

```solidity
import {SiphonToken} from "siphon/SiphonToken.sol";

contract MyToken is SiphonToken {
    function _maxPrepaidPeriods() internal pure override returns (uint256) {
        return 12;
    }

    function name() external pure returns (string memory) { return "MyToken"; }
    function symbol() external pure returns (string memory) { return "MTK"; }
    function decimals() external pure returns (uint8) { return 18; }

    function mint(address user, uint128 amount) external onlyOwner {
        _mint(user, amount);
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
