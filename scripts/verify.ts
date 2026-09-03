import { readFileSync } from "node:fs";

import { Contract, JsonRpcProvider, Wallet } from "ethers";

import { ESCROW_ABI, STATE } from "../src/dealClient";
import { recordVerification, verdictFromName } from "../src/dealLifecycle";
import { verifySchemaDelivery, type SchemaVerificationJob } from "../src/verifier";

function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required for on-chain submission`);
  return value;
}

async function main(): Promise<void> {
  const jobPath = process.argv[2];
  if (!jobPath) throw new Error("Usage: npm run verifier -- <job.json> [--submit]");
  const job = JSON.parse(readFileSync(jobPath, "utf8")) as SchemaVerificationJob;
  const shouldSubmit = process.argv.includes("--submit");
  let signer: Wallet | undefined;
  let escrowAddress: string | undefined;
  let dealId: string | undefined;
  if (shouldSubmit) {
    const provider = new JsonRpcProvider(required("VERIFIER_RPC_URL"));
    signer = new Wallet(required("VERIFIER_PRIVATE_KEY"), provider);
    escrowAddress = required("VERIFIER_ESCROW_ADDRESS");
    dealId = required("VERIFIER_DEAL_ID");
    const escrow = new Contract(escrowAddress, ESCROW_ABI, provider);
    const deal = await escrow.getDeal(dealId);
    if (Number(deal.state) !== STATE.Delivered) {
      throw new Error("the on-chain deal is not awaiting verification");
    }
    if (String(deal.verifier).toLowerCase() !== signer.address.toLowerCase()) {
      throw new Error("the configured signer is not the verifier named by the deal");
    }
    job.onChainEvidenceHash = String(deal.evidenceHash);
    job.onChainTermsHash = String(deal.termsHash);
  }

  const verification = verifySchemaDelivery(job);
  console.log(JSON.stringify(verification, null, 2));
  if (!shouldSubmit || !signer || !escrowAddress || !dealId) return;

  const submitted = await recordVerification({
    escrowAddress,
    verifierSigner: signer,
    dealId,
    verdict: verdictFromName(verification.result)
  });
  console.log(
    JSON.stringify(
      { submitted },
      (_, value) => (typeof value === "bigint" ? value.toString() : value),
      2
    )
  );
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
});
