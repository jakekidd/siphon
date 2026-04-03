# Siphon

Recurring payments without recurring transactions. Two products, one mandate model.

## Products

**SiphonToken** (`src/token/`): ERC20 where `balanceOf` decays via mandates. Zero gas per payment period. Payments are computed, not transacted. For protocol tokens and closed ecosystems.

**SiphonWallet** (`src/wallet/`): Smart wallet where mandates are warrants authorizing payees to collect from any ERC20. Real transfers on collect. For end users paying in existing tokens (USDC, etc.).

| | SiphonToken | SiphonWallet |
|---|---|---|
| Works with | Custom token (extends SiphonToken) | Any ERC20 |
| Payment model | Lazy: balanceOf decreases automatically | Pull: payee calls collect() |
| Gas per period | Zero (computed in balanceOf) | One transfer per collection |
| Tx visibility | No Transfer event until settle/harvest | Real Transfer on every payment |
| Transfer restrictions | Optional (_beforeTransfer hook) | None (standard wallet) |
| Insolvency | Priority-based lapse | Partial payment; payee's loss |
| Best for | Protocol tokens, batch harvest at scale | End users, any-token payments |

---

## SiphonToken

ERC20 with autopay. Your token balance decays over time; no transactions required.

### What is this

SiphonToken is an ERC20 where `balanceOf` is a mathematical function of time, not a stored value (it references a stored principal and calculates what's been consumed by active autopayments whenever it's read). There are no transactions for recurring payments. The balance just ticks down at period boundaries, automatically, forever, until the **mandate** is revoked or funds run out.

It works like a bank account. You hold tokens. A service provider sets up a **mandate** to draw from your balance on a schedule. You authorized it. The payments happen. If you run out of funds, the mandate lapses. If you want to stop, you revoke it. Multiple mandates can run simultaneously from one balance; first-authorized gets priority when funds are low.

The same balance also supports one-time deductions via **spend**: marketplace purchases, usage charges, fees. Mandates and spend draw from the same principal and compose naturally. A recurring base subscription and on-demand usage charges can run simultaneously on one balance (see `ServiceCredit` example).

This isn't a protocol you deposit into. The token IS the protocol. Recurring payments are a native property of the token itself.

### Glossary

| Term | Definition |
|---|---|
| **Mandate** | Recurring payment agreement. `mandateId = keccak256(beneficiary, rate)`. |
| **Tap** | Active mandate instance on a user. Beneficiary creates via `tap()`. |
| **Outflow** | Sum of all active tap rates. Enables O(1) `balanceOf`. |
| **Anchor** | Day index of last settlement. Periods elapsed = `(today - anchor) / TERM_DAYS`. |
| **Entry/Exit** | Bucket system for harvest. Entry on tap, exit when funds will run out. |
| **Comp** | Beneficiary pauses billing N terms. Balance freezes, resumes automatically. |
| **Spend** | One-time deduction from a user's balance. Marketplace purchases, usage charges, fees. |
| **Priority** | On lapse, first-tapped = first-paid. Lower-priority mandates lapse first. |
| **Settlement** | Lazy: `balanceOf` is always current (O(1) math). Storage updates only on interaction. |

See NatSpec on `tap()`, `harvest()`, `comp()`, `revoke()`, and `authorize()` for detailed mechanics.

### Configuration

Three immutables set at construction. Choose wisely; they're permanent.

**`TERM_DAYS`** is the billing interval in days. Every mandate on this token uses the same interval; 30 for monthly, 7 for weekly. If you need both, deploy separate tokens. This constraint keeps `balanceOf` O(1); without it, mandates with different intervals can't share a combined outflow.

**`MAX_TAPS`** is the maximum simultaneous mandates per user. 32 is a generous default. If you need more, you might have a subscription problem. The real reason for the cap: operations that touch all of a user's mandates (deposit, spend, transfer) are O(n) in active taps. An unbounded array would mean unbounded gas.

**`GENESIS_DAY`** anchors epoch boundaries. Pass 0 to use the deployment day. Pass a specific day index to align epochs with an external system.

```solidity
// monthly billing; up to 32 mandates per user; epoch anchor = deploy day
constructor() SiphonToken(0, 30, 32) {}
```

### Mandate lifecycle

```
1. User:        token.authorize(mandateId, 1)
2. Beneficiary: token.tap(user, rate)
   ; checks authorization, consumes one
   ; deducts first-term payment, transfers to beneficiary
   ; writes entry at next epoch, computes exit epoch
3. Each term:   Nothing happens. This is perfectly normal.
                (Well, something did happen; the user's balance decreased.
                 But naturally, automatically, silently.
                 No transaction, no event, no gas. Just math and time.)
4. Beneficiary: token.harvest(beneficiary, rate, maxEpochs)
   ; walks epochs, counts active subscribers, collects income
5. Comp:        token.comp(user, rate, epochs)     [optional]
   ; beneficiary pauses billing for N terms; balance freezes
   ; billing resumes automatically; no re-auth needed
6. Lapse:       funds exhausted; mandate cleared on next interaction
7. Renewal:     user re-authorizes, beneficiary re-taps
```

### Implementing a service

The token contract is the bank. Your contract is the service. Here's the pattern using `StreamingSubscription` (see `src/token/example/StreamingSubscription.sol` for the full source):

```solidity
contract StreamingSubscription {
    SiphonToken public token;

    struct Plan {
        string name;
        uint128 rate;
        bool active;
    }

    mapping(uint256 => Plan) public plans;
    mapping(address => uint256) public userPlan;

    // Admin creates a plan
    function createPlan(string calldata _name, uint128 _rate) external returns (uint256 id);

    // User subscribes (must have called token.authorize(mandateId, 1) first)
    function subscribe(uint256 _planId) external {
        Plan storage plan = plans[_planId];
        userPlan[msg.sender] = _planId;
        token.tap(msg.sender, plan.rate); // this contract is the beneficiary
    }

    // Check access
    function hasAccess(address _user) external view returns (bool) {
        bytes32 mid = token.mandateId(address(this), plans[userPlan[_user]].rate);
        return token.isTapActive(_user, mid);
    }

    // Collect revenue
    function collect(uint256 _planId, uint256 _maxEpochs) external {
        token.harvest(address(this), plans[_planId].rate, _maxEpochs);
    }
}
```

The key pattern: the service contract IS the beneficiary (`msg.sender` on `tap()` and the address in `harvest()`). The user authorizes the mandateId which locks in both the beneficiary address and the rate. The service wraps mandates with its own product logic (plans, access gating, upgrades) without the token knowing or caring what the service does.

### Transfer restrictions

Transfers are open by default. Override `_beforeTransfer` to add restrictions:

```solidity
// Only whitelisted agents can initiate transfers (exchange regulation)
function _beforeTransfer(address, address, uint256) internal view override {
    if (!transferAgent[msg.sender]) revert NonTransferable();
}
```

### Reading state

```solidity
token.balanceOf(user)                    // spendable balance (accounts for all mandates)
token.getAccount(user)                   // (principal, outflow, anchor)
token.getUserTaps(user)                  // active mandate IDs (ordered by priority)
token.getTap(user, mid)                  // (rate, entryEpoch, exitEpoch)
token.isActive(user)                     // any mandate active and funded?
token.isTapActive(user, mid)             // specific mandate active?
token.funded(user)                       // full terms user can fund
token.expiryDay(user)                    // day when funds run out
token.isComped(user)                     // billing paused?
token.mandateId(beneficiary, rate)       // compute a mandateId
token.getCheckpoint(mid)                 // (lastEpoch, subscriberCount)
token.currentEpoch()                     // current epoch index
token.totalSupply()                      // totalMinted - totalBurned - totalSpent
```

### Use cases and examples

See `src/token/example/README.md` for a detailed walkthrough organized by pattern (payments vs burns, one-to-many vs many-to-one, admin vs user-authorized, etc.).

**Subscriptions** (`src/token/example/StreamingSubscription.sol`). Plans, subscribe, upgrade/downgrade, comp, access gating, revenue collection.

**Payroll** (`src/token/example/Payroll.sol`). One payer, many beneficiaries. Priority on lapse. Listener.

**Rent** (`src/token/example/RentalAgreement.sol`). Many payers, one beneficiary. Shared mandateId. One harvest collects all.

**Timeshare** (`src/token/example/Timeshare.sol`). Pooled escrow, rotating access, seasonal renewal.

**Decay** (`src/token/example/DecayToken.sol`). Burn mandates. Deflationary. Balance decays to zero.

**Vesting** (`src/token/example/Vesting.sol`). Token streaming. Sablier/Drips pattern as native mandates.

**Service credits** (`src/token/example/ServiceCredit.sol`). Base subscription (mandate) + usage charges (spend).

### Tradeoffs

**No on-chain transaction for payments.** Block explorers won't show a transfer event when a monthly payment "goes through." The `Settled` event fires when someone interacts with the user's account, but that could be days after the actual payment boundary. The payments are real; they're just computed, not transacted.

**Floating supply.** Between settlement and harvest, tokens exist in `totalSupply` that aren't in anyone's `balanceOf`. The user's balance already decreased (lazy math), but the beneficiary hasn't harvested yet. Correct accounting, just unfamiliar.

**What IS visible.** `balanceOf` is always accurate. `isActive` and `isTapActive` give real-time status. `Tapped`, `Revoked`, `Settled`, and `Harvested` events provide a full audit trail.

---

## SiphonWallet

Smart wallet with mandate-based recurring payments. Works with any ERC20.

### What is this

SiphonWallet is a smart wallet that holds ERC20 tokens and supports mandates. A mandate is a warrant: it authorizes a payee to collect a fixed amount of a specific token on a recurring schedule. The payee calls `collect()` to pull owed tokens. No lazy balance tricks: token balances are pristine until a real transfer fires on collection.

### Mandate lifecycle

```
1. Owner:  wallet.grant(payee, token, rate, cadence, maxPeriods)
   ; creates a mandate; first collection available after one full period
2. Time passes. Debt accumulates (capped by maxPeriods if set).
3. Anyone: wallet.collect(mandateId)
   ; computes periods owed since last collection
   ; transfers min(owed, balance) to payee
   ; lastCollected advances by exact period multiples
4. Owner:  wallet.cancel(mandateId)
   ; deactivates; no further collection
5. Owner:  wallet.execute(to, value, data)
   ; arbitrary calls: transfers, approvals, DeFi, anything
```

### Design decisions

**No lazy balanceOf.** The underlying token's `balanceOf` is untouched until `collect()` fires a real ERC20 transfer. Every payment is a visible on-chain transaction.

**No transfer restrictions.** The wallet owner can freely spend all tokens. If they drain the wallet before the payee collects, that's the payee's problem. Mandates are warrants, not locks.

**Debt stacking.** If the payee doesn't collect for 3 months, they can collect all 3 months in one call. `maxPeriods` caps this: set it to 1 and the payee must collect every period or the debt stops growing.

**Period carry-over.** `lastCollected` advances by exact period multiples, not to today. 45 days on a 30-day cadence = 1 period collected, 15 days carry over. The partial period counts toward the next collection.

**Permissionless collect.** Anyone can call `collect()`. Tokens always go to the payee. This allows keepers, crons, or the payee themselves to trigger collection.

### Reading state

```solidity
wallet.debt(id)            // current owed amount (0 if cancelled)
wallet.mandateInfo(id)     // full Mandate struct
wallet.mandateCount()      // total mandates (including cancelled)
```

### Factory

`SiphonFactory` deploys wallet instances and maintains a registry.

```solidity
factory.createWallet()              // deploy a wallet for msg.sender
factory.wallets(owner)              // look up wallet address
```

---

## Prior Art: ERC-1337

Siphon shares the spirit of [ERC-1337](https://eips.ethereum.org/EIPS/eip-1337) (Subscriptions on the Blockchain, Gitcoin/ERC-948 working group) but diverges in implementation.

**ERC-1337** uses signed meta-transactions stored off-chain and replayed by relayers each period. Each payment is a `transferFrom()` that costs gas. Requires relayer infrastructure and ERC20 allowance management.

**SiphonToken** eliminates transactions entirely. Payments are computed as a mathematical function of time within `balanceOf`. Zero gas per payment period. The tradeoff: requires a custom token; can't pay with existing ERC20s like USDC. The payee collects via `harvest()` which batch-processes all subscribers in O(epochs), not O(subscribers).

**SiphonWallet** is closer to ERC-1337's authorize-then-collect model, but: mandates are stored on-chain (not as signed meta-txs), debt stacking with configurable caps replaces the all-or-nothing replay model, no relayer is needed (payee calls `collect()` directly), and the wallet is a general-purpose smart account with `execute()` for arbitrary operations beyond payments.

## Build

```bash
forge build
forge test -vvv
```

281 tests: token mechanics, 8 example contracts, wallet mandates, factory.

## License

MIT
