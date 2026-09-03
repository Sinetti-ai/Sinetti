# Roadmap

Sinetti is building an open protocol and open reference implementations for
verification and arbitration. Sinetti expects to operate the first public
instances of those roles so the network can start, but no deal is locked to a
Sinetti-operated provider.

## What “open core” means here

The core is every component needed to understand, reproduce, or independently
operate a protocol role:

- escrow and arbitration contracts;
- verification rules, evidence validation, and on-chain submission logic;
- arbitration proposal, review, and ruling submission logic;
- public schemas, clients, fixtures, and tests; and
- the security assumptions and operator interfaces for those components.

Private operations are not a second implementation of that logic. They are
instance-specific secrets and state: signing keys, RPC credentials, private case
material, alert destinations, host inventory, backups, and incident records.
Live service hosts, credentials, and machine configuration do not belong in this
repository. Public-testnet deployment tooling is a later reviewed release item.

## Initial public release

The first public release is complete when a clean clone provides:

- the V04 escrow and reference arbitrator with Hardhat and Foundry tests;
- a deterministic reference verifier with fixtures and optional on-chain
  submission;
- operator commands for proposing, reviewing, and pushing arbitration rulings;
- a complete local lifecycle covering verification, challenge, ruling,
  and settlement;
- an operator model, threat model, maintainer security assessment, and responsible
  disclosure route; and
- clean-clone, static-analysis, dependency, secret, and publication-safety checks,
  with the reviewed dependency surface recorded in
  [SUPPLY-CHAIN.md](SUPPLY-CHAIN.md).

Sinetti may be the initial verifier and arbitrator operator. That is a cold-start
responsibility, not a protocol privilege. Parties choose the verifier and
arbitrator in each signed deal, and anyone can run the published role software.

## Supported testnet

A supported testnet release requires a new deployment from the reviewed source.
The repository will publish its chain ID, addresses, constructor policy,
deployment commit, verified source, and synthetic example transactions.

## Release states

| State | What it proves |
|---|---|
| Source published | The reviewed code and documentation are publicly readable; no service claim follows. |
| Reference instance operated | Sinetti runs the published role code at a documented endpoint or address with instance-specific limits. |
| Supported testnet | Current-source contracts, role instances, configuration, and synthetic lifecycle receipts have been verified together. |
| Production or mainnet | A separate independent audit and operational review support real-value use. This is not scheduled by the initial release. |

## Next releases

- Add independently operated verifier and arbitrator compatibility fixtures.
- Add sandbox adapters for more deterministic task classes without changing the
  evidence commitment format.
- Publish provider discovery metadata and health semantics.
- Design reputation as a separate release. Evaluate on-chain state,
  event-derived records, and hybrid models—including identity binding, update
  and appeal authority, portability, privacy, gas, Sybil resistance, and
  upgradeability—before selecting an architecture.
- Commission an independent contract and service security review before any
  real-value deployment.

## Explicit non-claims

The initial release is unaudited and not production-safe. It does not include a
reputation score, reputation API, or claim that wallet history establishes a
unique or trustworthy participant.
