# SiphonToken

ERC20 with autopay. Your token balance decays over time; no transactions required.

Think of it as money that automatically pays your bills for you, with itself.

## What is this

SiphonToken is an ERC20 where `balanceOf` is a mathematical function of time, not a stored value (it references a stored principal and calculates what's been consumed by active autopayments whenever it's read). There are no transactions for recurring payments. The balance just ticks down at period boundaries, automatically, forever, until the **mandate** is revoked or funds run out.

It works like a bank account. You hold tokens. A service provider sets up a **mandate** to draw from your balance on a schedule. You authorized it. The payments happen. If you run out of funds, the mandate lapses. If you want to stop, you revoke it. Multiple mandates can run simultaneously from one balance; first-authorized gets priority when funds are low.

The same balance also supports one-time deductions via **spend**: marketplace purchases, usage charges, fees. Mandates and spend draw from the same principal and compose naturally. A recurring base subscription and on-demand usage charges can run simultaneously on one balance (see `ServiceCredit` example).

This isn't a protocol you deposit into. The token IS the protocol. Recurring payments are a native property of the token itself.

## Glossary

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

## Configuration

Three immutables set at construction. Choose wisely; they're permanent.

**`TERM_DAYS`** is the billing interval in days. Every mandate on this token uses the same interval; 30 for monthly, 7 for weekly. If you need both, deploy separate tokens. This constraint keeps `balanceOf` O(1); without it, mandates with different intervals can't share a combined outflow.

**`MAX_TAPS`** is the maximum simultaneous mandates per user. 32 is a generous default. If you need more, you might have a subscription problem. The real reason for the cap: operations that touch all of a user's mandates (deposit, spend, transfer) are O(n) in active taps. An unbounded array would mean unbounded gas.

**`GENESIS_DAY`** anchors epoch boundaries. Pass 0 to use the deployment day. Pass a specific day index to align epochs with an external system.

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
5. Comp:        token.comp(user, rate, epochs)     [optional]
   ; beneficiary pauses billing for N terms; balance freezes
   ; billing resumes automatically; no re-auth needed
6. Lapse:       funds exhausted; mandate cleared on next interaction
7. Renewal:     user re-authorizes, beneficiary re-taps
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
        Plan storage newPlan = plans[_newPlanId];
        bytes32 oldMid = token.mandateId(address(this), oldPlan.rate);
        token.revoke(msg.sender, oldMid);     // revoke old
        token.tap(msg.sender, newPlan.rate);   // tap new
        userPlan[msg.sender] = _newPlanId;
    }

    // Gift 3 months free (billing pauses, resumes automatically)
    function comp(address _user, uint256 _planId, uint16 _months) external onlyOwner {
        Plan storage plan = plans[_planId];
        token.comp(_user, plan.rate, _months);
    }

    // Collect revenue
    function collect(uint256 _planId, uint256 _maxEpochs) external {
        token.harvest(address(this), plans[_planId].rate, _maxEpochs);
    }
}
```

The key pattern: the service contract IS the beneficiary (`msg.sender` on `tap()` and the address in `harvest()`). The user authorizes the mandateId which locks in both the beneficiary address and the rate. The service wraps mandates with its own product logic (plans, access gating, upgrades) without the token knowing or caring what the service does.

## Transfer restrictions

Transfers are open by default. Override `_beforeTransfer` to add restrictions:

```solidity
// Only whitelisted agents can initiate transfers (exchange regulation)
function _beforeTransfer(address, address, uint256) internal view override {
    if (!transferAgent[msg.sender]) revert NonTransferable();
}
```

This hooks into `_transfer`, which is called by `transfer()` and `transferFrom()`. Protocol internals (tap first-term, settle, harvest) manipulate principals directly and are unaffected. The hook only gates user-initiated ERC20 transfers.

## Reading state

```solidity
// user's spendable balance (accounts for all active mandates)
token.balanceOf(user)

// user's account: principal, total outflow rate, settlement anchor
(uint128 principal, uint128 outflow, uint32 anchor) = token.getAccount(user)

// list of active mandate IDs for a user (ordered by priority)
bytes32[] memory taps = token.getUserTaps(user)

// details of a specific tap
(uint128 rate, uint32 entryEpoch, uint32 exitEpoch) = token.getTap(user, mid)

// whether any mandate is active and funded
token.isActive(user)

// whether a specific mandate is active and funded
token.isTapActive(user, mid)

// how many full terms the user can fund
token.funded(user)

// day when funds will be fully consumed
token.expiryDay(user)

// whether user is in a comp period (billing paused)
token.isComped(user)

// compute a mandateId
token.mandateId(beneficiary, rate)

// beneficiary's harvest checkpoint
(uint32 lastEpoch, uint224 count) = token.getCheckpoint(mid)

// current epoch number
token.currentEpoch()

// supply accounting
token.totalSupply()    // totalMinted - totalBurned - totalSpent
token.totalMinted      // cumulative tokens ever minted
token.totalBurned      // cumulative tokens destroyed by burn mandates
token.totalSpent       // cumulative tokens removed via _spend
```

## Use cases and examples

See `src/example/README.md` for a detailed walkthrough organized by pattern (payments vs burns, one-to-many vs many-to-one, admin vs user-authorized, etc.).

**Subscriptions** (`src/example/StreamingSubscription.sol`). Plans with named tiers, subscribe, upgrade/downgrade (revoke + re-tap), comp (free months), access gating via `isTapActive`, revenue collection per plan. The flagship example; covers the full lifecycle.

**Payroll** (`src/example/Payroll.sol`). Employer holds tokens; employees are beneficiaries at different salary rates. The employer's balance decays as salaries are paid. Employees call `token.tap()` and `token.harvest()` directly. The Payroll contract is bookkeeping: roster management, views, lapse detection via `IMandateListener`. Shows the "one payer, many beneficiaries" pattern with priority (if the company runs low, hire order determines who gets paid first).

**Rent** (`src/example/RentalAgreement.sol`). One landlord, many tenants, same rent rate. All tenants share the same mandateId (same beneficiary contract + same rate = same hash), so one `harvest()` call collects everyone's rent. Includes security deposit handling, lease terms, delinquency detection, and tenant self-move-out.

**Timeshare** (`src/example/Timeshare.sol` + `TimeshareEscrow.sol`). Rotating payment responsibility among multiple users. Two-contract architecture: Timeshare (manager/beneficiary) deploys a TimeshareEscrow per agreement. Members deposit their share into the escrow each season; the escrow gets tapped and its balance drains at rate-per-term. Round-robin access rotation, seasonal renewal with automatic leftover refunds, comp (property maintenance), and funding reclaim with deadlines. Shows the "many payers, one pool, one beneficiary" pattern.

**Decay / burns** (`src/example/DecayToken.sol`). Deflationary token where holding costs something. Every holder gets a burn mandate (`beneficiary = address(0)`) on mint. Balance decays each term, reducing total supply. No beneficiary to harvest; the tokens just disappear. Shows `_tap` with burn mechanics, runway calculation, and admin exemption.

**Vesting** (`src/example/Vesting.sol`). Token streaming / grant vesting. Grantor holds tokens, creates streams for recipients. The Vesting contract is the beneficiary (intermediary); it harvests then forwards to recipients. Shows the Sablier/Drips pattern as native mandates. Priority means earlier grants vest first if the grantor underfunds.

**Service credits** (`src/example/ServiceCredit.sol`). Base subscription (mandate) + pay-per-use (spend) from one balance. Extends SiphonToken directly (IS the token). Shows how mandates and spend compose: both draw from the same principal, competing for the same pool.

## Tradeoffs

**No on-chain transaction for payments.** Block explorers won't show a transfer event when a monthly payment "goes through." The `Settled` event fires when someone interacts with the user's account, but that could be days after the actual payment boundary. The payments are real; they're just computed, not transacted.

**Floating supply.** Between settlement and harvest, tokens exist in `totalSupply` that aren't in anyone's `balanceOf`. The user's balance already decreased (lazy math), but the beneficiary hasn't harvested yet. Correct accounting, just unfamiliar. Explorers may show a discrepancy.

**What IS visible.** `balanceOf` is always accurate. `isActive` and `isTapActive` give real-time status. `Tapped`, `Revoked`, `Settled`, and `Harvested` events provide a full audit trail. The state is all there; it's just lazily computed rather than eagerly transacted.

## Build

```bash
forge build
forge test -vvv
```

218 tests covering core mechanics, example contracts, edge cases, and fuzz.

## License

MIT
