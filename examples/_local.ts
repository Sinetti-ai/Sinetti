import type {
  ContractTransactionReceipt,
  ContractTransactionResponse,
  LogDescription,
  Signer
} from "ethers";
import hre from "hardhat";
import path from "node:path";
import { canonicalJson, hashFile } from "../src/evidenceManifest";
import { signSellerAcceptance } from "../src/sellerAcceptance";
import { VERIFIER_VERSION, type AcceptanceCriteria } from "../src/verifier";
import { repoCommitHash, runtimeHash } from "./_evidence";

import type { MockManualArbitrator, SinettiEscrowV04, TestEUR } from "../typechain-types";

export const AMOUNT = hre.ethers.parseUnits("25", 6);
export const BOND = hre.ethers.parseUnits("5", 6);
export const CHALLENGER_BOND = hre.ethers.parseUnits("10", 6);

export function exampleCriteria(): AcceptanceCriteria {
  return {
    acceptance_criteria_id: "crit_example",
    acceptance_type: "schema_validity",
    verification_method: "deterministic",
    evidence_required: ["customer_export"],
    auto_release_threshold: "schema_valid",
    schema_or_test_ref: "schemas/customer-export.schema.json",
    artifact_path: "customer-export.json",
    schema_hash: hashFile(path.resolve(__dirname, "../schemas/customer-export.schema.json")),
    repo_commit_hash: repoCommitHash(),
    runtime_hash: runtimeHash(),
    verifier_version: VERIFIER_VERSION,
    created_at: "2026-01-01T00:00:00Z"
  };
}

export type LocalContext = {
  deployer: Signer;
  buyer: Signer;
  seller: Signer;
  verifier: Signer;
  buyerAddress: string;
  sellerAddress: string;
  verifierAddress: string;
  arbitratorAddress: string;
  tokenAddress: string;
  escrowAddress: string;
  token: TestEUR;
  escrow: SinettiEscrowV04;
  arbitrator: MockManualArbitrator;
  labels: Map<string, string>;
};

function shortAddress(address: string): string {
  return `${address.slice(0, 6)}...${address.slice(-4)}`;
}

function formatValue(context: LocalContext, name: string, type: string, value: unknown): string {
  if (type === "address" && typeof value === "string") {
    const label = context.labels.get(value.toLowerCase());
    return label ? `${label} (${shortAddress(value)})` : shortAddress(value);
  }
  if (type === "bytes32" && typeof value === "string") {
    try {
      return `"${hre.ethers.decodeBytes32String(value)}"`;
    } catch {
      return value;
    }
  }
  if (typeof value === "bigint") {
    if (["amount", "bond", "challengerBond", "sellerCredit", "buyerCredit", "value"].includes(name)) {
      return `${hre.ethers.formatUnits(value, 6)} tEUR`;
    }
    return value.toString();
  }
  return String(value);
}

function parseLog(
  context: LocalContext,
  log: ContractTransactionReceipt["logs"][number]
): LogDescription | null {
  try {
    if (log.address.toLowerCase() === context.escrowAddress.toLowerCase()) {
      return context.escrow.interface.parseLog(log);
    }
    if (log.address.toLowerCase() === context.tokenAddress.toLowerCase()) {
      return context.token.interface.parseLog(log);
    }
  } catch {
    return null;
  }
  return null;
}

export async function send(
  context: LocalContext,
  label: string,
  transactionPromise: Promise<ContractTransactionResponse>
): Promise<ContractTransactionReceipt> {
  const transaction = await transactionPromise;
  const receipt = await transaction.wait();
  if (!receipt) throw new Error(`Transaction ${transaction.hash} was not mined`);

  console.log(`\n${label}`);
  for (const event of receipt.logs.map((log) => parseLog(context, log)).filter(Boolean) as LogDescription[]) {
    const fields = event.fragment.inputs.map((input, index) =>
      `${input.name}=${formatValue(context, input.name, input.type, event.args[index])}`
    );
    console.log(`  ${event.name}(${fields.join(", ")})`);
  }
  return receipt;
}

export async function deployLocal(): Promise<LocalContext> {
  if (hre.network.name !== "hardhat") {
    throw new Error(`Local examples only run on the in-process Hardhat network, not ${hre.network.name}`);
  }

  const [deployer, buyer, seller, verifier] = await hre.ethers.getSigners();
  const [deployerAddress, buyerAddress, sellerAddress, verifierAddress] = await Promise.all([
    deployer.getAddress(),
    buyer.getAddress(),
    seller.getAddress(),
    verifier.getAddress()
  ]);

  const token = await (await hre.ethers.getContractFactory("TestEUR", deployer)).deploy();
  await token.waitForDeployment();
  const arbitrator = await (
    await hre.ethers.getContractFactory("MockManualArbitrator", deployer)
  ).deploy();
  await arbitrator.waitForDeployment();
  const escrow = await (await hre.ethers.getContractFactory("SinettiEscrowV04", deployer)).deploy(
    deployerAddress,
    [{
      token: await token.getAddress(),
      maxAmount: 1_000n * 10n ** 6n,
      maxBond: 500n * 10n ** 6n,
      minBondBps: 0,
      minChallengerBondBps: 0
    }],
    [],
    [],
    60,
    60
  );
  await escrow.waitForDeployment();

  const tokenAddress = await token.getAddress();
  const escrowAddress = await escrow.getAddress();
  const arbitratorAddress = await arbitrator.getAddress();
  const labels = new Map<string, string>([
    [deployerAddress.toLowerCase(), "deployer"],
    [buyerAddress.toLowerCase(), "buyer"],
    [sellerAddress.toLowerCase(), "seller"],
    [verifierAddress.toLowerCase(), "verifier"],
    [arbitratorAddress.toLowerCase(), "arbitrator"],
    [tokenAddress.toLowerCase(), "TestEUR"],
    [escrowAddress.toLowerCase(), "escrow"]
  ]);

  console.log("SinettiEscrowV04 local lifecycle");
  console.log("Network: hardhat (ephemeral, in-process, no keys or faucet required)");
  console.log(`TestEUR (tEUR): ${tokenAddress}`);
  console.log(`SinettiEscrowV04: ${escrowAddress}`);
  console.log(`MockManualArbitrator: ${arbitratorAddress}`);

  return {
    deployer,
    buyer,
    seller,
    verifier,
    buyerAddress,
    sellerAddress,
    verifierAddress,
    arbitratorAddress,
    tokenAddress,
    escrowAddress,
    token,
    escrow,
    arbitrator,
    labels
  };
}

export async function fundAndOpen(
  context: LocalContext,
  criteria: Record<string, unknown>,
  durationSeconds: bigint
): Promise<bigint> {
  await send(context, "Mint settlement tokens to buyer", context.token.mint(context.buyerAddress, AMOUNT));
  await send(context, "Mint bond tokens to seller", context.token.mint(context.sellerAddress, BOND));
  await send(
    context,
    "Buyer approves escrow principal",
    context.token.connect(context.buyer).approve(context.escrowAddress, AMOUNT)
  );

  const termsHash = hre.ethers.sha256(
    hre.ethers.toUtf8Bytes(canonicalJson(criteria))
  );
  const dealId = await context.escrow.nextDealId();
  const latestBlock = await hre.ethers.provider.getBlock("latest");
  if (!latestBlock) throw new Error("cannot read the local chain head");
  const { terms, signature } = await signSellerAcceptance({
    escrowAddress: context.escrowAddress,
    provider: hre.ethers.provider,
    sellerSigner: context.seller,
    buyer: context.buyerAddress,
    seller: context.sellerAddress,
    verifier: context.verifierAddress,
    arbitrator: context.arbitratorAddress,
    token: context.tokenAddress,
    amount: AMOUNT,
    bond: BOND,
    challengerBond: CHALLENGER_BOND,
    termsHash,
    duration: durationSeconds,
    openBy: BigInt(latestBlock.timestamp) + durationSeconds
  });
  await send(
    context,
    "Buyer opens and funds deal",
    context.escrow.connect(context.buyer).openDeal(terms, signature)
  );
  return dealId;
}

export async function postBond(context: LocalContext, dealId: bigint): Promise<void> {
  await send(
    context,
    "Seller approves bond",
    context.token.connect(context.seller).approve(context.escrowAddress, BOND)
  );
  await send(
    context,
    "Seller posts bond",
    context.escrow.connect(context.seller).postBond(dealId)
  );
}

export function assertEqual(actual: bigint, expected: bigint, message: string): void {
  if (actual !== expected) throw new Error(`${message}: expected ${expected}, got ${actual}`);
}
