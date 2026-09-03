import { Interface, getAddress } from "ethers";

import { canonicalJson, sha256Hex, toBytes32 } from "./evidenceManifest";
import { CONSOLE_ARBITRATOR_ABI, outcomeFromName } from "./dealLifecycle";

const RFC3339_TIMESTAMP =
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/;

export type ArbitrationCase = {
  version: "sinetti-arbitration-case/0.1";
  chain_id: string;
  escrow: string;
  arbitrator: string;
  deal_id: string;
  terms_hash: string;
  evidence_hash: string;
  proposed_outcome: "release" | "refund";
  rationale: string;
  decided_at: string;
};

export function validateArbitrationCase(caseFile: ArbitrationCase): void {
  if (caseFile.version !== "sinetti-arbitration-case/0.1") {
    throw new Error("unsupported arbitration case version");
  }
  if (!/^\d+$/.test(caseFile.chain_id) || !/^\d+$/.test(caseFile.deal_id)) {
    throw new Error("chain_id and deal_id must be unsigned base-10 integers");
  }
  getAddress(caseFile.escrow);
  getAddress(caseFile.arbitrator);
  if (!/^0x[0-9a-fA-F]{64}$/.test(caseFile.terms_hash)) {
    throw new Error("terms_hash must be bytes32");
  }
  if (!/^0x[0-9a-fA-F]{64}$/.test(caseFile.evidence_hash)) {
    throw new Error("evidence_hash must be bytes32");
  }
  outcomeFromName(caseFile.proposed_outcome);
  if (!caseFile.rationale.trim()) throw new Error("rationale must not be empty");
  if (
    !RFC3339_TIMESTAMP.test(caseFile.decided_at) ||
    !Number.isFinite(Date.parse(caseFile.decided_at))
  ) {
    throw new Error("decided_at must be an RFC 3339 timestamp");
  }
}

export function arbitrationCaseHash(caseFile: ArbitrationCase): string {
  validateArbitrationCase(caseFile);
  return toBytes32(sha256Hex(canonicalJson(caseFile)));
}

export function assertCaseMatchesDeal(
  caseFile: ArbitrationCase,
  deal: { arbitrator: string; termsHash: string; evidenceHash: string; state: bigint | number },
  chainId: bigint
): void {
  validateArbitrationCase(caseFile);
  if (BigInt(caseFile.chain_id) !== chainId) throw new Error("case chain_id does not match RPC");
  if (Number(deal.state) !== 4) throw new Error("deal is not disputed");
  if (getAddress(deal.arbitrator) !== getAddress(caseFile.arbitrator)) {
    throw new Error("case arbitrator does not match the deal");
  }
  if (deal.termsHash.toLowerCase() !== caseFile.terms_hash.toLowerCase()) {
    throw new Error("case terms_hash does not match the deal");
  }
  if (deal.evidenceHash.toLowerCase() !== caseFile.evidence_hash.toLowerCase()) {
    throw new Error("case evidence_hash does not match the deal");
  }
}

export function assertCaseMatchesProposal(
  caseFile: ArbitrationCase,
  proposal: { outcome: bigint | number; proposedAt: bigint | number; pushed: boolean },
  now: bigint,
  overrideWindow: bigint
): void {
  validateArbitrationCase(caseFile);
  const proposedAt = BigInt(proposal.proposedAt);
  if (proposedAt === 0n) throw new Error("no ruling has been proposed for this deal");
  if (proposal.pushed) throw new Error("the standing ruling has already been pushed");
  if (Number(proposal.outcome) !== outcomeFromName(caseFile.proposed_outcome)) {
    throw new Error("case proposed_outcome does not match the standing on-chain proposal");
  }
  const decidedAt = BigInt(Math.floor(Date.parse(caseFile.decided_at) / 1_000));
  if (decidedAt > proposedAt) {
    throw new Error("case decided_at is later than the on-chain proposal");
  }
  if (now < proposedAt + overrideWindow) {
    throw new Error("the officer override window is still open");
  }
}

export function prepareOfficerOverturn(caseFile: ArbitrationCase): {
  to: string;
  data: string;
  caseHash: string;
} {
  validateArbitrationCase(caseFile);
  const iface = new Interface(CONSOLE_ARBITRATOR_ABI);
  return {
    to: getAddress(caseFile.arbitrator),
    data: iface.encodeFunctionData("overturn", [
      BigInt(caseFile.deal_id),
      outcomeFromName(caseFile.proposed_outcome)
    ]),
    caseHash: arbitrationCaseHash(caseFile)
  };
}
