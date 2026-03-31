# TODO

## Design decisions

- Unified approval: merge ERC20 approve (transfers) and authorize (mandates) into one system. Simpler but less granular. Deferred.

## Implementation

- ECDSA-signed mandate authorizations (permit-style, save a tx). Eliminates the two-tx authorize-then-subscribe dance. Every example using public tap() requires this.
- Internal `_isTapActive` helper. Currently only exposed as external view; inheriting contracts (ServiceCredit) must duplicate the logic to avoid external self-calls.
- Fix `tap` variable shadowing warning in `_comp` (line 707: local `Tap storage tap` shadows the public `tap()` function)
- Delist method for beneficiaries (deactivate a mandate they no longer offer)

## Backlog

- Per-second streaming (Superfluid-style) alongside period-based mandates. Technically possible: add streamRate to Account, compute streamConsumed = elapsed_seconds * ratePerSecond in _balance alongside periodConsumed. But doubles the surface area; two systems competing for same principal creates priority questions. Also: balanceOf updating per-second breaks most frontend/wallet refresh assumptions. Period-based (monthly) fits the natural refresh cadence of wallets and explorers. Streaming micropayments may be fundamentally better as a deposit-into-separate-contract model (like Superfluid) rather than native to the token. Still worth exploring as a future extension; the math is compatible even if the UX is different.
- Mandate fulfillment cap: optional total amount (default 0 = unlimited) after which the mandate auto-terminates. Enables buy-now-pay-later / installment patterns: tap(user, rate) with a cap of N means the mandate runs until rate * periods >= N, then self-revokes. The cap would live on the Tap struct (e.g. `uint128 cap`). On settlement, if cumulative paid >= cap, the mandate is complete rather than lapsed. Distinct from lapse (ran out of funds) since the user fulfilled the obligation. Would need a new event (Fulfilled vs Revoked vs Lapsed) and possibly an IMandateListener callback. Example: BNPL contract where a merchant taps the buyer at rate=100/mo with cap=600; after 6 months the mandate completes automatically.
- Burn-only variant contract (strip beneficiary/bucket machinery, ~40% smaller)
- Abstract base + interface reorganization (shared base for burn-only and full variants)
