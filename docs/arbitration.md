# Reference arbitration operator

`ConsoleArbitrator` separates four actions:

- the configured agent key proposes `Release` or `Refund` for a live disputed
  deal that names this arbitrator;
- the configured officer may overturn it while the override window is open;
- the configured officer may rule outright at any time, with or without a
  standing proposal, and the ruling lands on the escrow in the same
  transaction; and
- after the window, anyone may push the standing outcome to the escrow.

The override window is the time the officer is guaranteed before an unreviewed
proposal lands. It never holds up an officer who has reviewed: `rule` is the
reviewed path, `push` is the unreviewed one.

The contract requires the officer review window to be at least 24 hours and no
more than 30 days. A proposal is rejected unless the live ruling deadline still
leaves the complete review window plus a one-hour relay buffer for the standing
outcome to be pushed. Operators should configure more margin for congestion and
recovery rather than treating that enforced hour as a recommendation.

`scripts/arbitrate.ts` consumes a versioned case record bound to chain ID,
escrow, arbitrator, deal ID, terms hash, and evidence hash. Its networked actions
refuse a record that does not match the live disputed deal. The offline
`officer-calldata` action can only validate the record's shape before producing
unsigned calldata; the officer must compare that record with the live deal and
standing proposal in the signing wallet. No officer key is required on the
operator host. Before `push`, the command reads the standing proposal and
refuses a missing, already-pushed, outcome-mismatched, post-dated, or
still-overridable case. A valid push case therefore cannot be attached to a
different live proposal.

The case hash is an off-chain audit identifier. The current contract records the
outcome and transaction, not the rationale bytes. Operators must retain the case
record and transaction receipt together and disclose the record according to the
deal's evidence policy.

The escrow does not enforce `ARBITRATOR_MARKER()`. Integrators must inspect the
selected arbitrator's code and binding. Deal identity is `(escrow, dealId)`, not
`dealId` alone. If no ruling lands by the signed deadline, permissionless
`finalize()` executes the standing verifier verdict and returns the challenger
bond.
