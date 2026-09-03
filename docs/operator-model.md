# Operator model

Sinetti expects to operate the first verifier and arbitrator instances. These
are cold-start defaults, not protocol privileges.

Each deal signs its verifier address and arbitrator contract. A compatible third
party can run the published software and be selected in a later deal.

## Public operator surface

- `scripts/verify.ts` validates a pushed artifact and optionally submits the
  chain-bound verdict.
- `scripts/arbitrate.ts` proposes, prepares officer-wallet calldata, overturns,
  or permissionlessly pushes a ruling.

## Instance-private state

Operators supply keys and RPC credentials through their own secret manager.
Private evidence, case records, databases, host inventory, alerts, backups, and
incident records remain outside Git. None may change verification or arbitration
semantics.

Verifier, agent, officer, and relayer keys should be distinct. The
officer path can be prepared as unsigned calldata so a wallet or hardware signer
does not expose its key to the service host. A public deployment must separately
review role separation and configure enough ruling time for the complete
proposal, override, and push ladder. `ConsoleArbitrator` rejects a proposal
unless at least its full human-review window and one-hour relay buffer remain;
deployments should allow additional operational margin.
