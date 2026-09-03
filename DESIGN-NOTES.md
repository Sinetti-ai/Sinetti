# Design notes

This document defines the boundary for the first public Sinetti release. It is a
protocol and reference-implementation repository.

## Roles and replaceability

Every deal names a verifier address and an arbitrator contract accepted in its
signed terms. Sinetti expects to run initial reference providers for cold start,
while publishing the code and operator interfaces needed for another party to
run compatible providers. A later deal may select different providers without
redeploying the escrow protocol.

The verifier evaluates committed acceptance criteria against committed evidence
and records `Pass`, `Fail`, or `Inconclusive`. A technical inability to perform a
check is not silently converted into seller failure. The reference verifier must
make its inputs, version, result, and reason reproducible.

The reference `ConsoleArbitrator` separates an operational proposal key from a
human officer who can overturn the proposal during a fixed review window. After
that window, pushing the standing ruling is permissionless. The contract name
does not mean that an autonomous agent decides disputes.

## Public and private boundary

Public:

- contracts, role logic, schemas, clients, fixtures, and tests;
- verifier evidence checks and chain-submission adapter;
- arbitrator proposal/review/push tools;
- protocol, integration, operator, threat-model, and security documentation.

Instance-private:

- signing keys, API and RPC credentials, private evidence and case records;
- live host names, alert destinations, backups, and access-control state; and
- incident records and abuse investigations that contain sensitive data.

Instance-private data must not hide verification, arbitration, or settlement
logic required to reproduce a public result. Reputation is outside this release.
Whether a future system stores reputation on-chain, derives it from events, or
combines both remains an open design question.

## Testnet evidence

A supported deployment must identify the exact source commit, chain, addresses,
constructor policy, source verification, and synthetic lifecycle transactions.
Private customer evidence and operator state are never documentation fixtures.

## Security posture

The current implementation has undergone maintainer self-review but no independent
audit. It is intended for synthetic local testing and future public-testnet
evaluation, not real funds. An independent audit remains a future release
condition for real-value use; static analysis and self-review are evidence, not
substitutes for that audit.
