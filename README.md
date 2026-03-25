# SiphonToken

ERC20 with autopay. Your token balance decays over time; no transactions required.

## What is this

SiphonToken is an ERC20 where `balanceOf` is a mathematical function of time, not a stored value (it references a stored principal amount and calculates what's been consumed by active autopayments when read). There are no transactions for recurring payments. The balance just ticks down at period boundaries, automatically, forever, until the mandate is revoked or funds run out.

It works like a bank account. You hold tokens. A service provider (Netflix, your landlord, a DAO) sets up a mandate to draw from your balance on a schedule. You authorized it. The payments happen. If you run out of funds, the mandate lapses. If you want to stop, you revoke it. Multiple mandates can run simultaneously from one balance; first-authorized gets priority when funds are low.

## Core concepts

**Mandates.** A mandate defines a recurring payment: who gets paid and how much per term. `mandateId = keccak256(beneficiary, rate)`. The beneficiary creates mandates by tapping users who have pre-authorized them. Think of it as the bank's record of your autopay instruction.

**Taps.** When a beneficiary activates a mandate for a user, that's a tap. The user's balance starts draining at the mandate's rate. Multiple taps can be active simultaneously (up to `MAX_TAPS`). Each tap has an entry epoch (when it started) and draws from the shared principal.

**Lazy settlement.** The contract never actually moves tokens on a schedule. Instead, `balanceOf` computes `principal - min(periodsElapsed, funded) * outflow` every time it's called. The `outflow` is the sum of all active mandate rates. Storage only changes when someone interacts with the contract (deposit, spend, transfer, tap, revoke); that's when `_settle` materializes the lazy math into storage.

Why this is the right approach: no keeper, no cron job, no gas spent on recurring payments. The math is O(1) regardless of how many periods have elapsed. The tradeoff is legibility (more on that below).

**Authorization model.** Users call `authorize(mandateId, count)` to pre-approve a mandate. Each `tap()` by the beneficiary consumes one authorization. Setting count to `type(uint256).max` means infinite; the beneficiary can re-tap freely after a lapse (useful for auto-renew flows where the user trusts the service).

This mirrors ERC20's `approve` / `transferFrom` pattern but for recurring payments instead of one-time transfers.

**Bucket system (entries and exits).** Beneficiaries need to collect income, but they don't know who their subscribers are on-chain. The contract solves this with shared count buckets per mandate: when a user is tapped, an entry is written at that epoch; when their funds will run out, an exit is written at that future epoch. The beneficiary calls `harvest()` which walks through epochs, tallies the running subscriber count, and multiplies by the rate. O(1) per user mutation; O(epochs) per harvest. The beneficiary never needs to enumerate subscribers.

**Sponsorship.** Anyone can sponsor tokens for a specific user's specific mandate. Sponsored tokens are locked; they can't be transferred or withdrawn. They get consumed before the user's own principal for that mandate. A sponsored mandate can survive past the point where the user's own balance runs out. This is how "3 months free" works without pausing or modifying the mandate itself.

**Priority.** When a user's balance can't cover all active mandates, they're resolved in tap order (first-tapped = first-paid). Higher-priority mandates survive; lower-priority ones lapse. Sponsored mandates can survive independently of priority since they have their own funding.

## Tradeoffs and limitations

**No on-chain transaction for payments.** Payments happen as a function of time, not as discrete transactions. Block explorers won't show a transfer event when your monthly payment "goes through." The `Settled` event fires when someone interacts with the user's account and the lazy math is materialized, but that could be days or weeks after the actual payment boundary.

**Floating supply.** Between settlement and harvest, there are tokens that exist in `totalSupply` but aren't in anyone's `balanceOf`. The user's balance already decreased (lazy math), but the beneficiary hasn't harvested yet. This is correct accounting; it's just not how most tokens behave. Explorers may show a discrepancy between `totalSupply` and the sum of all balances.

**Constant billing interval.** All mandates on a given deployment share the same `TERM_DAYS` (set at construction). You can't mix monthly and weekly billing on the same token. Deploy separate instances for different intervals.

**Max taps per user.** Bounded by `MAX_TAPS` (set at construction; default 16). Operations that touch all of a user's mandates (deposit, spend, transfer) are O(n) in active taps.

## Reading state

For wallets and frontends that need to display user state:

```solidity
// User's spendable balance (accounts for all active mandates)
token.balanceOf(user)

// User's account details
(uint128 principal, uint128 outflow, uint32 anchor) = token.getAccount(user)

// List of active mandate IDs for a user
bytes32[] memory taps = token.getUserTaps(user)

// Details of a specific tap
(uint128 rate, uint32 entryEpoch, uint32 revokedAt, uint256 sponsored) = token.getTap(user, mid)

// Whether any mandate is active for this user
token.isActive(user)

// Whether a specific mandate is active
token.isTapActive(user, mid)

// Current epoch number
token.currentEpoch()

// Beneficiary's collection checkpoint
(uint32 lastEpoch, uint224 count) = token.getCheckpoint(mid)
```

## Mandate lifecycle

```
1. User:        token.authorize(mandateId, 1)
2. Beneficiary: token.tap(user, rate)
   ; checks authorization, consumes one
   ; deducts first-term payment, transfers to beneficiary
   ; writes entry at next epoch, computes exit epoch
3. Each term:   user's balanceOf decreases by rate (no tx)
4. Beneficiary: token.harvest(beneficiary, rate, maxEpochs)
   ; walks epochs, counts active subscribers, collects income
5. Lapse:       funds exhausted; mandate cleared on next interaction
6. Renewal:     user re-authorizes, beneficiary re-taps
```

## Usage

```solidity
import {SiphonToken} from "siphon/SiphonToken.sol";

contract MyToken is SiphonToken {
    address public owner;

    // deployDay=0 (use current day), 30-day terms, max 16 taps per user
    constructor() SiphonToken(0, 30, 16) {
        owner = msg.sender;
    }

    function name() external pure returns (string memory) { return "MyToken"; }
    function symbol() external pure returns (string memory) { return "MTK"; }
    function decimals() external pure returns (uint8) { return 18; }

    function mint(address user, uint128 amount) external {
        require(msg.sender == owner);
        _mint(user, amount);
    }
}
```

The beneficiary flow (from a service contract like a subscription manager):

```solidity
contract SubscriptionManager {
    SiphonToken public token;
    uint128 public rate = 50 ether; // 50 tokens per term

    // User calls this after calling token.authorize(mandateId, 1)
    function subscribe(address user) external {
        token.tap(user, rate); // msg.sender (this contract) is the beneficiary
    }

    // Collect income across all subscribers
    function collect(uint256 maxEpochs) external {
        token.harvest(address(this), rate, maxEpochs);
    }

    // Check if a user's subscription is paid up
    function isSubscribed(address user) external view returns (bool) {
        bytes32 mid = token.mandateId(address(this), rate);
        return token.isTapActive(user, mid);
    }
}
```

See `src/example/SimpleSiphon.sol` for a complete implementation.

## Use cases

**Subscriptions.** Netflix-style recurring billing. User authorizes, service taps. The service checks `isTapActive` to gate access. Lapse means the subscription ended; user re-authorizes to restart.

**Rent.** Landlord deploys or uses a SiphonToken. Tenant authorizes a mandate for monthly rent. Landlord harvests. If tenant's balance runs low, the mandate lapses; the landlord sees it on-chain.

**Protocol burns.** A token where holding costs something. Burn mandates (beneficiary = address(0)) drain the balance into the void, reducing total supply. No beneficiary to collect; the tokens just disappear.

**B2B payouts.** Business-to-business recurring payments. A partner authorizes a mandate; the platform taps monthly. Clean audit trail via events.

**Sponsorship / "3 months free."** A service sponsors a user's mandate with tokens. The user's own balance isn't touched until the sponsorship runs out. Good for promotions, grants, onboarding credits.

## Build

```bash
forge build
forge test -vvv
```

## License

MIT
