# SiphonToken Examples

Eight contracts demonstrating how to build on SiphonToken. Each targets a different dimension of the mandate system. Read them in any order; the table below maps what you want to learn to which contract shows it.

## Dimensions

| What you want to learn | Contract | Pattern |
|---|---|---|
| Payments to a beneficiary | StreamingSubscription, RentalAgreement | Beneficiary collects via `harvest()` |
| Burn / demurrage | DecayToken | `beneficiary = address(0)`, tokens vanish |
| Token vesting / streaming | Vesting | Sablier-like streams as native mandates |
| Subscription + usage | ServiceCredit | Base fee (mandate) + overage (spend) |
| One payer, many beneficiaries | Payroll, Vesting | Employer/grantor balance decays across all streams |
| Many payers, one beneficiary | RentalAgreement | All tenants share one mandateId; one `harvest()` call |
| Many payers, pooled escrow | Timeshare + TimeshareEscrow | Members deposit into escrow; escrow gets tapped |
| Admin-controlled (`_tap`/`_revoke`) | SimpleSiphon, DecayToken, ServiceCredit | No user authorization; admin taps directly |
| User-authorized (`authorize`/`tap`) | StreamingSubscription, Vesting | User pre-authorizes; beneficiary calls `tap()` |
| Mandate + spend composition | ServiceCredit | Recurring base fee + one-time usage charges |
| Token IS the protocol | ServiceCredit, DecayToken | Contract extends SiphonToken (not wrapping) |
| Listener callbacks | Payroll | `IMandateListener` detects lapse |
| Comp (free periods) | StreamingSubscription, Timeshare | Billing pauses N terms, resumes automatically |
| Spend (one-time deduction) | SimpleSiphon | `_spend()` for marketplace-style purchases |
| Transfer restrictions | SimpleSiphon (base for override) | Override `_beforeTransfer` |

## StreamingSubscription

**File:** `StreamingSubscription.sol`

**Pattern:** Service contract IS the beneficiary. Users authorize, service taps.

This is the flagship example and the closest to a "hello world." A subscription service with named plans. Covers the full mandate lifecycle:

1. Admin creates plans (name + rate per term)
2. User calls `token.authorize(mandateId, 1)` off-chain
3. User calls `subscribe(planId)` which calls `token.tap(user, rate)`
4. Balance decays automatically each term. No transactions.
5. `hasAccess(user)` checks `isTapActive` for gating
6. Admin can `comp(user, planId, months)` for free periods
7. User can `cancel()` which revokes the mandate (or clears lapsed state)
8. User can `changePlan()` (revoke old + tap new, requires new authorization)
9. Anyone calls `collect(planId, maxEpochs)` to harvest revenue

**Key SiphonToken features used:** `authorize`, `tap`, `revoke`, `comp`, `harvest`, `isTapActive`, `mandateId`

**Lapse handling.** When a user runs out of funds, their mandate is deleted by SiphonToken's priority resolution. The contract handles this: `cancel()` checks `isTapActive` before calling `revoke()` (skips if already lapsed), and `subscribe()` detects stale subscriptions and allows re-subscribe.

**The pattern to internalize:** The service contract is the beneficiary (`msg.sender` on `tap()`). The mandateId locks in both the beneficiary address AND the rate. Changing either requires a new mandate. Always guard `revoke()` calls with `isTapActive` checks to handle lapse gracefully.

## Payroll

**File:** `Payroll.sol`

**Pattern:** One payer (employer), many beneficiaries (employees). Inverted flow.

Unlike subscriptions where users are payers, here the employer holds tokens and employees are beneficiaries. The employer's balance decays as all salaries are paid simultaneously.

The Payroll contract is bookkeeping only. The actual mandate operations happen on the token directly:

1. Payroll.hire() adds to roster
2. Employer calls `token.authorize(mandateId(employee, salary), max)`
3. Employee calls `token.tap(employer, salary)` to activate pay
4. Employee calls `token.harvest(employee, salary, epochs)` to collect
5. Employer calls `token.revoke(employer, mandateId)` to terminate

**Key SiphonToken features used:** `authorize`, `tap`, `harvest`, `revoke`, `isTapActive`, `IMandateListener`

**The pattern to internalize:** Priority determines who gets paid first when funds run low. First-tapped = highest priority. If the employer can only cover 3 of 5 salaries, the first 3 employees hired keep getting paid. Lower-priority employees' mandates lapse and the listener fires `PayrollLapsed`.

## RentalAgreement

**File:** `RentalAgreement.sol`

**Pattern:** Many payers (tenants), one beneficiary (landlord). Shared mandateId.

All tenants pay the same rent to the same beneficiary contract. Since `mandateId = keccak256(beneficiary, rate)`, all tenants share the same mandateId. One `harvest()` call collects rent from everyone.

1. Landlord calls `addTenant(tenant, endDay, deposit)` which taps the tenant
2. Tenant authorized the mandate beforehand
3. `collectRent(maxEpochs)` harvests all tenants at once
4. Tenant can `moveOut()` to stop paying (revokes mandate if active, no-op if lapsed)
5. Landlord calls `endLease()` to finalize and return deposit (handles both active and moved-out tenants)

Also demonstrates:
- Security deposits as separate token transfers (not mandate principal)
- Two-phase exit: `moveOut()` stops billing, `endLease()` returns deposit
- `checkDelinquencies()` iterating tenants to flag lapsed mandates
- Lease terms as wrapper state alongside mandate state

**The pattern to internalize:** Shared mandateIds are a scalability property. 1,000 tenants at the same rate = one harvest call. Different rates = different mandateIds = separate harvests.

## DecayToken

**File:** `DecayToken.sol`

**Pattern:** Burn mandates. No beneficiary. Tokens vanish.

A deflationary token where holding costs something. Every holder gets a burn tap (`beneficiary = address(0)`) applied on mint. Their balance decays each term, reducing `totalSupply`. No one harvests; the tokens just disappear.

1. `DECAY_RATE` set at construction (immutable: all holders decay at the same rate)
2. `mint(user, amount)` mints tokens AND applies burn tap if not present
3. Balance decays automatically. `runway(user)` shows terms remaining.
4. Additional mints extend runway (more principal, same burn rate)
5. `exempt(user)` removes the burn tap (admin escape hatch)

**Why immutable?** A mutable decay rate creates a double-tap footgun: a user minted at rate X, then minted again after rate changes to Y, would get two burn mandates draining at X + Y. Immutable rate avoids this entirely.

**Key SiphonToken features used:** `_tap` (internal, admin-controlled), `_revoke`, `_mint`, `_mandateId`, `_funded`, burn mechanics (`beneficiary = address(0)`, `totalBurned`)

**The pattern to internalize:** Burn mandates skip bucket accounting entirely. No entries, no exits, no harvest. The tokens are just gone. `totalBurned` tracks the cumulative amount. This is the simplest possible use of the mandate system.

**Use cases:** Demurrage currencies, governance tokens that expire, protocol-native gas credits, time-limited rewards.

## Vesting

**File:** `Vesting.sol`

**Pattern:** Token streaming / grant vesting via mandates. Sablier in 50 lines.

A grantor holds tokens and creates vesting streams for recipients. The Vesting contract IS the beneficiary (it calls `tap()`, making itself `msg.sender` to the token). Revenue is harvested into the contract, then forwarded to recipients.

1. Admin creates grants (recipient, rate per term, total terms)
2. Grantor calls `token.authorize(mandateId(address(vesting), rate), 1)`
3. Recipient calls `activate(grantId)` which taps the grantor
4. Grantor's balance decays as all streams drain simultaneously
5. Anyone calls `collect(grantId, maxEpochs)` to harvest and forward to recipient
6. Admin calls `revokeGrant()` to stop future vesting (already-collected tokens kept)
7. `isVesting(grantId)` checks stream status; `fundedTerms()` shows grantor runway

**Key SiphonToken features used:** `authorize`, `tap`, `harvest`, `revoke`, `isTapActive`, `mandateId`, `funded`, priority

**The pattern to internalize:** The contract that calls `tap()` IS the beneficiary. This means tokens flow to the contract first, then must be distributed. Different rates produce different mandateIds. If the grantor underfunds, earlier-activated grants get priority (first-tapped = first-paid).

**Limitation:** Multiple grants at the same rate share one mandateId. One harvest collects for all of them. For production, ensure unique rates or add internal accounting for shared harvests.

## ServiceCredit

**File:** `ServiceCredit.sol`

**Pattern:** Base subscription (mandate) + pay-per-use (spend) from one balance.

A service where users hold credit tokens. A recurring base fee drains via mandate; usage charges deduct on demand via spend. This is the natural composition of SiphonToken's two deduction mechanisms.

Unlike other examples that wrap an external SiphonToken, this contract extends SiphonToken directly (IS the token). This pattern makes sense when the service IS the credit system.

1. Admin creates tiers (name, base fee per term, usage rate per unit)
2. Admin mints credits to users
3. User calls `enroll(tierId)` to start base subscription (must authorize first)
4. Balance decays from base fee each term
5. Operator calls `chargeUsage(user, units)` for on-demand deductions via `_spend`
6. User calls `unenroll()` to stop base fee (handles lapsed state)
7. `collect(tierId, maxEpochs)` harvests base fee revenue

**Key SiphonToken features used:** `_tap`, `_spend`, `_revoke`, `_mint`, `authorize`, `harvest`, `isTapActive`, `_mandateId`

**The pattern to internalize:** Mandates and spend draw from the same principal. A usage charge reduces the balance, which reduces funded periods, which can cause the base subscription mandate to lapse sooner. The two mechanisms compose naturally but compete for the same pool.

## Timeshare + TimeshareEscrow

**Files:** `Timeshare.sol`, `TimeshareEscrow.sol`

**Pattern:** Many payers pool into one escrow; escrow is the payer; beneficiary is the Timeshare contract.

The most complex example. Shows how SiphonToken handles shared payment responsibility:

1. Admin creates an agreement with N members, a rate, and terms-per-season
2. Each member calls `fund()` to deposit their share into the escrow
3. When all members have funded, the escrow auto-activates (authorizes + gets tapped)
4. The escrow's balance decays at rate-per-term. Timeshare harvests the income.
5. Access rotates round-robin: `hasAccess()` = `termIndex % memberCount`
6. When the season ends (mandate lapsed or revoked), `renew()` refunds leftover and resets

Also demonstrates:
- Two-contract architecture (manager + per-agreement escrow)
- Funding deadlines with `reclaimFunding()` for failed activations
- Comp for property maintenance (billing pauses, access returns false)
- Seasonal renewal with automatic refunds

**The pattern to internalize:** From the beneficiary's perspective, a pool looks like a single payer. The escrow is just an address with a balance that decays. SiphonToken doesn't know or care that 5 people funded it.

## SimpleSiphon

**File:** `SimpleSiphon.sol`

**Pattern:** Admin-controlled reference implementation. No user-facing authorize flow.

The simplest possible SiphonToken: admin mints, a scheduler role taps/revokes/comps, a spender role does one-time deductions. No user authorization step (uses `_tap` directly). Good for protocols where the service controls everything.

Exposes all internal methods behind role checks:
- `mint` (owner) via `_mint`
- `tapUser` / `revokeUser` / `compUser` (scheduler) via `_tap` / `_revoke` / `_comp`
- `spend` (spender) via `_spend`
- `setListener` (owner) via `_setListener`

This is also the contract used by the test suite to exercise the full SiphonToken surface area.

## Integration checklist

When building on SiphonToken:

**Authorization.** If using the public `tap()` (not `_tap`), the user must call `token.authorize(mandateId, count)` before your contract calls `tap()`. The mandateId encodes both your contract's address and the rate. Changing either requires new authorization.

**Settlement.** `balanceOf` is always current (lazy math), but storage is stale until someone interacts with the user. If your logic depends on storage values (principal, outflow), call `settle(user)` first or use the view functions which account for lazy state.

**Harvest frequency.** Harvest cost scales linearly with neglect. Monthly harvest = 1 epoch to walk. Skip a year = 12 epochs. Use `_maxEpochs` to cap gas per call. Never bricks, just costs more gas if you wait.

**Comp side effects.** Comp moves the billing anchor forward for ALL mandates on the user, not just the one you're comping. This is a design tradeoff for O(1) `balanceOf`. If your users have mandates with other services, comp affects those too.

**Transfer hooks.** `_beforeTransfer` only fires on `transfer()` and `transferFrom()`. Internal operations (tap first-term payment, settle, harvest) bypass it. Don't rely on transfer hooks for accounting that needs to capture mandate flows.

**Lapse vs revoke.** Lapse: funds ran out, resolved on next interaction (settle/tap/spend/transfer). Revoke: explicit termination. Both delete the tap. Both preserve bucket entries for historical harvest. But lapse is lazy (might not be "detected" until later), while revoke is immediate.

**Guarding revoke calls.** Since lapse deletes the tap, calling `revoke()` on an already-lapsed mandate reverts with `TapNotFound`. Any wrapper that calls `revoke()` must check `isTapActive()` first. This is the most common footgun when building on SiphonToken. See `StreamingSubscription.cancel()` and `RentalAgreement.moveOut()` for the pattern.

**Re-tapping.** After revoke or lapse, the same mandateId can be re-tapped if the user re-authorizes. The tap record is deleted on revoke, not just marked inactive. This enables subscription renewal without changing the mandateId.

**Who is the beneficiary?** Whoever calls `tap()` is `msg.sender` to the token and becomes the beneficiary. If your contract calls `tap()`, your contract IS the beneficiary (not the end user). Tokens from `harvest()` go to your contract; you must forward them. See `Vesting.collect()` for this pattern. If you want the end user to be the beneficiary, they must call `tap()` directly on the token (Payroll pattern).

**Extending vs wrapping.** Most examples wrap an external SiphonToken. `ServiceCredit` and `DecayToken` extend SiphonToken directly (IS the token). Extending gives access to internal methods (`_tap`, `_spend`, `_mint`) without authorization overhead, but means one contract = one token. Wrapping keeps concerns separate and lets multiple services share one token.
