# Runnable local examples

These examples exercise unaudited contracts with ephemeral local accounts and
test tokens. Do not use them with real funds.

Install dependencies and run the happy path:

```bash
npm ci
npm run example
```

The script starts Hardhat's in-process chain, deploys `TestEUR`,
`SinettiEscrowV04`, and `MockManualArbitrator`, then opens, funds, delivers,
verifies, accepts, settles, and withdraws one deal. It requires no RPC URL,
private key, faucet, hosted verifier, or arbitration service.

Two focused variants use the same local environment:

```bash
npm run example:dispute
npm run example:timeout
```

- `dispute.ts` shows a buyer challenge and a refund ruling from the reference
  manual arbitrator.
- `timeout-refund.ts` shows the no-verdict timeout path.

All delivery examples hash the synthetic bytes in `examples/delivery/` through
`src/evidenceManifest.ts` and compare the fresh digest with the value recorded on
chain. See [delivery evidence](../docs/evidence.md) for the format and limits.

There is no supported public-testnet example in this repository.
