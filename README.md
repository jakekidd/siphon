# SiphonToken

ERC20 with autopay. Your token balance decays over time; no transactions required.

Think of it as money that automatically pays your bills for you, with itself.

## What is this

SiphonToken is an ERC20 where `balanceOf` is a mathematical function of time, not a stored value (it references a stored principal and calculates what's been consumed by active autopayments whenever it's read). There are no transactions for recurring payments. The balance just ticks down at period boundaries, automatically, forever, until the **mandate** is revoked or funds run out.

It works like a bank account. You hold tokens. A service provider sets up a **mandate** to draw from your balance on a schedule. You authorized it. The payments happen. If you run out of funds, the mandate lapses. If you want to stop, you revoke it. Multiple mandates can run simultaneously from one balance; first-authorized gets priority when funds are low.

This isn't a protocol you deposit into. The token IS the protocol. Recurring payments are a native property of the token itself.

## Siphonomics

**Mandate.** The recurring payment agreement; who gets paid, how much per term. Identified by `mandateId = keccak256(beneficiary, rate)`. The beneficiary creates mandates by **tapping** users who have pre-authorized them. Think of it as the bank's internal record of your autopay instruction.

**Tap.** The active instance of a mandate on a specific user. When a beneficiary taps a user, the user's balance starts draining at the mandate's rate. Multiple taps can be active simultaneously (up to `MAX_TAPS`), all drawing from one shared principal. The word works as both the noun (the user has 3 taps open) and the verb (the beneficiary taps the user).

**Outflow.** The sum of all active tap rates for a user. This is what makes `balanceOf` O(1); instead of iterating each tap, the contract computes `principal - min(periodsElapsed, principal / outflow) * outflow` in one shot.

**Lazy settlement.** Don't worry; SiphonToken isn't actually lazy. It's quite proactive. `balanceOf` computes the above formula every time it's called; always current, always accurate, zero gas spent on scheduled payments. Storage only updates when someone interacts with the contract; that's when `_settle` materializes the lazy math into storage. No keeper, no cron job, no gas for recurring payments.

**Authorization.** Users call `authorize(mandateId, count)` to pre-approve a mandate. Each `tap()` by the beneficiary consumes one authorization. Setting count to `type(uint256).max` means infinite; the beneficiary can re-tap freely after a lapse (useful for auto-renew flows where the user trusts the service). This mirrors ERC20's `approve` / `transferFrom` pattern but for recurring payments.

The beneficiary role is permissionless; anyone can call `tap()` if the user authorized their mandateId. The user IS the gate. If your use case needs a beneficiary whitelist, override `tap()` in your implementation.

**Entries and exits.** Beneficiaries need to collect income, but they don't know who their subscribers are on-chain. The contract solves this with shared count buckets per mandate: when a user is tapped, an **entry** is written at that epoch; when their funds will run out, an **exit** is written at that future epoch. The beneficiary calls `harvest()` which walks through epochs, tallies the running subscriber count, and multiplies by the rate. O(1) per user mutation; O(epochs) per harvest.

Harvest cost scales linearly with neglect. Monthly harvest = 1 epoch, trivial. Skip 6 months = 6 iterations. It never bricks. Anyone can call `harvest()` on any mandate; tokens always go to the beneficiary.

**Sponsorship.** Anyone can sponsor tokens for a specific user's specific mandate. Sponsored tokens are locked; they can't be transferred or withdrawn. They get consumed before the user's own principal. A sponsored mandate can survive past the point where the user's own balance runs out. This is how "3 months free" works without pausing or modifying the mandate.

**Priority.** When a user's balance can't cover all active mandates, they're resolved in tap order (first-tapped = first-paid). Higher-priority mandates survive; lower-priority ones lapse. Sponsored mandates can survive independently since they have their own funding.

## Configuration

Three immutables set at construction. Choose wisely; they're permanent.

**`TERM_DAYS`** is the billing interval in days. Every mandate on this token uses the same interval; 30 for monthly, 7 for weekly. If you need both, deploy separate tokens. This constraint keeps `balanceOf` O(1); without it, mandates with different intervals can't share a combined outflow.

**`MAX_TAPS`** is the maximum simultaneous mandates per user. 32 is a generous default. If you need more, you might have a subscription problem. The real reason for the cap: operations that touch all of a user's mandates (deposit, spend, transfer) are O(n) in active taps. An unbounded array would mean unbounded gas.

**`DEPLOY_DAY`** anchors epoch boundaries. Pass 0 to use the deployment day. Pass a specific day index to align epochs with an external system.

```solidity
// monthly billing; up to 32 mandates per user; epoch anchor = deploy day
constructor() SiphonToken(0, 30, 32) {}
```

## Mandate lifecycle

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
5. Lapse:       funds exhausted; mandate cleared on next interaction
6. Renewal:     user re-authorizes, beneficiary re-taps
```

## Implementing a service

The token contract is the bank. Your contract is the service. Here's the pattern using `StreamingSubscription` (see `src/example/StreamingSubscription.sol` for the full source):

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

    // Upgrade or downgrade: revoke old mandate, tap new one
    function changePlan(uint256 _newPlanId) external {
        Plan storage oldPlan = plans[userPlan[msg.sender]];
        bytes32 oldMid = token.mandateId(address(this), oldPlan.rate);
        token.revoke(msg.sender, oldMid);     // revoke old
        token.tap(msg.sender, newPlan.rate);   // tap new
        userPlan[msg.sender] = _newPlanId;
    }

    // Gift 3 months free
    function sponsorTrial(address _user, uint256 _planId, uint8 _months) external {
        Plan storage plan = plans[_planId];
        bytes32 mid = token.mandateId(address(this), plan.rate);
        token.sponsor(_user, mid, plan.rate * uint128(_months));
    }

    // Collect revenue
    function collect(uint256 _planId, uint256 _maxEpochs) external {
        token.harvest(address(this), plans[_planId].rate, _maxEpochs);
    }
}
```

The key pattern: the service contract IS the beneficiary (`msg.sender` on `tap()` and the address in `harvest()`). The user authorizes the mandateId which locks in both the beneficiary address and the rate. The service wraps mandates with its own product logic (plans, access gating, upgrades) without the token knowing or caring what the service does.

## Reading state

```solidity
// user's spendable balance (accounts for all active mandates)
token.balanceOf(user)

// user's account: principal, total outflow rate, settlement anchor
(uint128 principal, uint128 outflow, uint32 anchor) = token.getAccount(user)

// list of active mandate IDs for a user
bytes32[] memory taps = token.getUserTaps(user)

// details of a specific tap
(uint128 rate, uint32 entryEpoch, uint32 revokedAt, uint256 sponsored) = token.getTap(user, mid)

// whether any mandate is active
token.isActive(user)

// whether a specific mandate is active
token.isTapActive(user, mid)

// compute a mandateId
token.mandateId(beneficiary, rate)

// beneficiary's harvest checkpoint
(uint32 lastEpoch, uint224 count) = token.getCheckpoint(mid)

// current epoch number
token.currentEpoch()
```

## Use cases and examples

**Subscriptions** (`src/example/StreamingSubscription.sol`). Plans with named tiers, subscribe, upgrade/downgrade (revoke + re-tap), sponsored trials, access gating via `isTapActive`, revenue collection per plan. The flagship example; covers the full lifecycle.

**Payroll** (`src/example/Payroll.sol`). Employer holds tokens; employees are beneficiaries at different salary rates. The employer's balance decays as salaries are paid. Employees harvest their own pay. Shows the "one payer, many beneficiaries" pattern and priority (if the company runs low, hire order determines who gets paid first). Uses `IScheduleListener` to detect when payroll funds lapse.

**Rent** (`src/example/RentalAgreement.sol`). One landlord, many tenants, same rent rate. All tenants share the same mandateId (same beneficiary + same rate = same hash), so one `harvest()` call collects everyone's rent. Includes security deposit handling, lease terms, delinquency detection, and tenant self-move-out.

**Timeshare** (`src/example/Timeshare.sol`). Rotating payment responsibility among multiple users. Currently a design stub (constructor reverts); the naive manual-rotation approach needs a shared pool contract to properly handle asymmetric cost splitting and automated rotation. See the contract comments for the design options.

**Protocol burns.** A token where holding costs something. Burn mandates (`beneficiary = address(0)`) drain the balance into the void, reducing total supply. No beneficiary to harvest; the tokens just disappear. Use `_tap(user, address(0), rate)` internally.

## Tradeoffs

**No on-chain transaction for payments.** Block explorers won't show a transfer event when a monthly payment "goes through." The `Settled` event fires when someone interacts with the user's account, but that could be days after the actual payment boundary. The payments are real; they're just computed, not transacted.

**Floating supply.** Between settlement and harvest, tokens exist in `totalSupply` that aren't in anyone's `balanceOf`. The user's balance already decreased (lazy math), but the beneficiary hasn't harvested yet. Correct accounting, just unfamiliar. Explorers may show a discrepancy.

**What IS visible.** `balanceOf` is always accurate. `isActive` and `isTapActive` give real-time status. `Tapped`, `Revoked`, `Settled`, and `Harvested` events provide a full audit trail. The state is all there; it's just lazily computed rather than eagerly transacted.

## Build

```bash
forge build
forge test -vvv
```

142 tests covering core mechanics, example contracts, edge cases, and fuzz.

## License

MIT
