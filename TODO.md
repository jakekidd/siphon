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
- Burn-only variant contract (strip beneficiary/bucket machinery, ~40% smaller)
- Abstract base + interface reorganization (shared base for burn-only and full variants)
