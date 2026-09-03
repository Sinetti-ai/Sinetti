# Deploying to Sepolia

## Prerequisites

Node 22 and this repo's dependencies installed (`npm install`). A funded
Sepolia account and its private key. A settlement token already deployed on
Sepolia, or one you deploy yourself first (any ERC20 works; the escrow only
stores its address and checks that it has bytecode).

## Environment

Copy `.env.example` to `.env` and fill in the values described there. The
variables are not auto-loaded by hardhat.config.ts, so export them to the
shell before running a script:

```
set -a
source .env
set +a
```

Every policy input is required and explicit, with one exception:
`TOKEN_MAX_AMOUNT` and `TOKEN_MAX_BOND` default to the maximum uint256 value
when left unset, meaning an uncapped deployment rather than a silent zero.
`PARTICIPANT_ALLOWLIST` and `ARBITRATOR_ALLOWLIST` default to empty, meaning
open enrollment: any address can act as a participant, and any contract with
bytecode can arbitrate a deal.

## Running the deploy

```
npm run deploy:sepolia
```

This runs `scripts/deploy.ts` against the `sepolia` network defined in
`hardhat.config.ts`. It deploys `SinettiEscrowV04` first, then
`ConsoleArbitrator` pointed at the escrow's address, and refuses to proceed
if the deployer equals the pauser, the arbitrator's agent key equals its
officer, or the officer equals the pauser. A single key controlling pause,
proposals, and overrides defeats the point of separating those roles, so the
script stops and prints which pairing collided rather than deploying anyway.

The script writes `deployments/sepolia.json` with both contract addresses,
transaction hashes, block numbers, the constructor arguments used, the
current commit hash, and a `verification` block with the exact `cast`
commands to reproduce the on-chain checks. It never writes
`DEPLOYER_PRIVATE_KEY` or any other private key to disk.

To try the flow without spending testnet ETH, run
`npm run deploy:local` instead, which points at Hardhat's in-process
network. The constructor only stores the token address and checks that it
has bytecode, so a local dry run needs a real deployed token; the repo's
`contracts/mocks/MockUSDC.sol` works for this.

## Verifying source on Etherscan

`hardhat.config.ts` already carries an `etherscan` block that reads
`ETHERSCAN_API_KEY`, because `@nomicfoundation/hardhat-toolbox` bundles the
Etherscan verify plugin; no extra dependency is needed for that path. This
repo also builds with Foundry, and Foundry's own verifier is the more direct
route since the contracts are compiled there too:

```
forge verify-contract <escrow-address> contracts/SinettiEscrowV04.sol:SinettiEscrowV04 \
  --chain sepolia --etherscan-api-key $ETHERSCAN_API_KEY

forge verify-contract <arbitrator-address> contracts/ConsoleArbitrator.sol:ConsoleArbitrator \
  --chain sepolia --etherscan-api-key $ETHERSCAN_API_KEY \
  --constructor-args $(cast abi-encode "constructor(address,address,address,uint64)" <escrow-address> <agentKey> <officer> <overrideWindowSeconds>)
```

The deploy script prints both commands with the real addresses filled in at
the end of a successful run.

## Running the synthetic lifecycles against a deployed contract

`examples/full-lifecycle.ts`, `examples/dispute.ts`, and
`examples/timeout-refund.ts` cannot be pointed at a network or an address
today. Each one calls `deployLocal()` from `examples/_local.ts`
unconditionally: that helper deploys its own fresh `SinettiEscrowV04`,
`TestEUR`, and `MockManualArbitrator` on whatever network the script runs
against, funds four Hardhat signer accounts from that network's own account
list, and returns a `LocalContext` built entirely around those addresses.
There is no `CONTRACT_ADDRESS` or `--network` branch in the examples
themselves; running `hardhat run examples/full-lifecycle.ts --network
sepolia` would deploy a brand-new escrow and token to Sepolia and run the
lifecycle against those fresh contracts. The addresses that `deploy.ts`
published would go untouched.

To run these lifecycles against the addresses in `deployments/sepolia.json`
without rewriting the examples, `_local.ts` would need a second path,
something like a `deployLocal()` variant that accepts an existing escrow
address, token address, and signer set instead of always deploying fresh
ones, plus funded Sepolia accounts standing in for the four local signers
(deployer, buyer, seller, verifier) with testnet ETH and the settlement
token. That is a real, separate piece of work; this deliverable does not
include it.
