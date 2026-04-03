# TODO

## Token (src/token/)

### Implementation
- ECDSA-signed mandate authorizations (permit-style, save a tx). Eliminates the two-tx authorize-then-subscribe dance. Every example using public tap() requires this.
- Internal `_isTapActive` helper. Currently only exposed as external view; inheriting contracts (ServiceCredit) must duplicate the logic to avoid external self-calls.
- Fix `tap` variable shadowing warning in `_comp` (line 707: local `Tap storage tap` shadows the public `tap()` function)
- Delist method for beneficiaries (deactivate a mandate they no longer offer)

### Backlog
- Per-second streaming (Superfluid-style) alongside period-based mandates. Technically possible but doubles surface area and breaks frontend refresh assumptions. Deferred.
- Mandate fulfillment cap: optional total amount after which the mandate auto-terminates. Enables BNPL / installment patterns.
- Burn-only variant contract (strip beneficiary/bucket machinery, ~40% smaller)
- Abstract base + interface reorganization (shared base for burn-only and full variants)

### Design decisions
- Unified approval: merge ERC20 approve (transfers) and authorize (mandates) into one system. Simpler but less granular. Deferred.

## Wallet (src/wallet/)

### Implementation
- EIP-7702 compatibility (setCode delegate pattern for existing EOAs)
- Batch collect utility: contract or script that collects from N wallets in one tx
- Multicall support on SiphonWallet (batch grant/cancel/execute in one tx)
- CREATE2 deterministic deployment in SiphonFactory

### Backlog
- ERC-4337 (account abstraction) compatibility: validateUserOp, paymaster support
- Auto-pay hook: piggyback overdue mandate payments on user activity (execute() checks for due mandates before forwarding)
- Mandate transfer: allow payee to transfer their mandate to a new address
- Multi-owner / threshold support (multisig wallet variant)
