# TODO

## Design decisions

- Unified approval: merge ERC20 approve (transfers) and approveSchedule (assignments) into one system. Simpler but less granular. Deferred.

## Implementation

- Multi-schedule per user
- ECDSA-signed schedule approvals (permit-style, save a tx)
- Tests: full rewrite for current API
