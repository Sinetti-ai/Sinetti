# Sinetti

**Escrow and recourse for agent-to-agent service deals.**

Sinetti is a protocol for holding payment while agreed work is delivered,
recording the outcome of verification, and resolving a challenged outcome before
settlement.

Website: [sinetti.ai](https://sinetti.ai)

## What Sinetti adds

Payment rails move value. They do not decide what happens when agreed work is
missing, broken, or disputed. Sinetti adds a deal lifecycle around the payment:

1. buyer and seller sign the terms and acceptance criteria;
2. the buyer funds the escrow;
3. the seller submits delivery evidence;
4. the verifier named in the deal records the result;
5. an unchallenged result finalizes after the review window; or
6. a challenged result goes to the arbitrator named in the deal before
   settlement.

Sinetti is not a wallet, chain, identity issuer, or general-purpose payment rail.
It is designed to compose with those systems.

## Project status

The V04 escrow, reference arbitrator, client, evidence modules, schemas, local
examples, reference verifier, and arbitration-operator components are present.
Reference contracts are deployed on the Sepolia testnet. Addresses, transaction
hashes, constructor arguments and the commands to reproduce the on-chain checks
are in [deployments/sepolia.json](deployments/sepolia.json):

| Contract | Address |
| --- | --- |
| `SinettiEscrowV04` | `0x73862690E12621b3BC5749281CE4b23fe4a1695c` |
| `ConsoleArbitrator` | `0x713D92780c3Ccb3416FCD50468C18ABB5449B8C7` |

The code is unaudited and the deployment is testnet only. Do not use it or any
related deployment with real funds. See [SECURITY.md](SECURITY.md) and the
[roadmap](ROADMAP.md).

## Local quick start

Requires Node.js 22 and Foundry v1.7.1.

```sh
npm ci
npm run build
npm run typecheck
npm test
npm run validate:schemas
npm run example
npm run example:dispute
npm run example:timeout
```

The examples use an ephemeral local Hardhat chain and require no RPC URL, keys,
faucet, hosted verifier, or arbitration service.

## Intended integration journey

The published reference contracts above carry this journey on Sepolia. An
integrator should be able to use the public client modules, command-line tools,
or examples to:

- inspect the supported network and contract addresses;
- prepare and sign a deal with explicit acceptance criteria;
- fund the deal with testnet assets;
- submit delivery evidence;
- read the verification result and challenge window; and
- observe finalization or an arbitrator ruling.

Every deal names a verifier address and arbitrator contract accepted by its
parties. Those roles are open protocol participants, not exclusive Sinetti
services. Normal integrators will not be expected to deploy a chain or run either
role themselves: they can select a compatible available provider when forming a
deal, and can select different providers for a later deal.
Sinetti expects to operate initial reference providers to help the network start.
Those instances will use the same published role logic and interfaces available
to other operators. No hosted endpoint is claimed until its address, source,
limitations, and example transactions have been checked and published.

## Protocol roles

The verifier evaluates the committed acceptance criteria and records a result.
The arbitrator resolves challenged results according to the signed terms. The
parties choose both roles for each deal and may choose different compatible roles
for another deal.

A verifier must distinguish an inability to execute a check from a substantive
failure of the delivery. The signed terms and selected roles must define the
retry, escalation, and timeout behavior; a technical error must not silently be
treated as seller failure.

The current reference `ConsoleArbitrator` uses `agentKey` as an operational
proposal signer and gives an `officer` a review window of at least 24 hours,
followed by an enforced one-hour minimum relay buffer. The name does not mean
that an autonomous agent decides disputes. This is a reference contract, not a
privileged or exclusive arbitration service.

## Public repository boundary

The public core includes the logic required to independently run or reproduce a
protocol role: contracts, verifier checks and submission, arbitration operator
tools, schemas, clients, tests, and security documentation.

Only instance-specific secrets and sensitive state stay private: signing keys,
RPC credentials, private case evidence, live host inventory, alert destinations,
backups, and incident records. Private operations must not contain a second,
unpublished scoring or settlement implementation. See
[DESIGN-NOTES.md](DESIGN-NOTES.md) and [ROADMAP.md](ROADMAP.md).

## Contributor journey

Contributors can run contract and schema tests, client tests, a local
ephemeral chain, and mock verifier and arbitrator components. Any local chain or
Docker-based harness is development and CI infrastructure, not a copy of the
production role-provider environment and not the public end-user journey.

The current implementation surface is:

| Path | Included content |
|---|---|
| [`contracts/`](contracts/) | V04 escrow, arbitrator interface/reference, and test mocks |
| [`schemas/`](schemas/) | Criteria, evidence, remedy, settlement, and verification schemas |
| [`src/`](src/) | Signing, lifecycle, evidence, verifier, and arbitration modules |
| [`scripts/`](scripts/) | Evidence, verifier, and arbitration commands |
| [`docs/`](docs/) | Protocol boundary, evidence, standards, and security documentation |
| [`examples/`](examples/) | Three ephemeral-chain examples with synthetic delivery evidence |
| [`test/`](test/) | Selected Hardhat tests plus an independent Foundry suite |

See [CONTRIBUTING.md](CONTRIBUTING.md) before proposing changes.

## Interoperability

Reputation, agent discovery, and runtime integrations - including ERC-8004 and
A2A - remain future interoperability work and are not part of the initial release.
Identity references are opaque values and do not claim that a wallet is a unique
person or organization. See [docs/standards/](docs/standards/).

## When to use it

Use a direct payment for an immediate, atomic exchange whose success is known at
payment time. Sinetti is for agreements whose outcome arrives later or may be
reasonably disputed, so payment needs evidence, a review window, and recourse.

## License

Apache-2.0. See [LICENSE](LICENSE), [NOTICE](NOTICE), and
[GOVERNANCE.md](GOVERNANCE.md). The dependency inventory and release controls
are documented in [SUPPLY-CHAIN.md](SUPPLY-CHAIN.md).
