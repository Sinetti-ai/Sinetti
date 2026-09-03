import { Contract, ZeroHash } from "ethers";
import type { BigNumberish, Signer } from "ethers";

import {
  ESCROW_ABI,
  OUTCOME,
  STATE,
  VERDICT,
  prepareTransfer,
  stateName
} from "./dealClient";

export { OUTCOME, VERDICT } from "./dealClient";

export const CONSOLE_ARBITRATOR_ABI = [
  "function escrow() view returns (address)",
  "function propose(uint256 dealId, uint8 outcome)",
  "function overturn(uint256 dealId, uint8 outcome)",
  "function push(uint256 dealId)",
  "function proposals(uint256 dealId) view returns (uint8 outcome, uint64 proposedAt, bool pushed)",
  "function agentKey() view returns (address)",
  "function officer() view returns (address)",
  "function overrideWindow() view returns (uint64)"
];

const VERDICT_NAMES = ["pass", "fail", "inconclusive"] as const;
const OUTCOME_NAMES = ["release", "refund"] as const;

export type VerdictName = (typeof VERDICT_NAMES)[number];
export type OutcomeName = (typeof OUTCOME_NAMES)[number];

export function outcomeFromName(text: string): number {
  const name = text.trim().toLowerCase();
  if (!(OUTCOME_NAMES as readonly string[]).includes(name)) {
    throw new Error(
      `unknown outcome "${text}". An arbitrator outcome is one of: ` +
        `${OUTCOME_NAMES.join(", ")}.`
    );
  }
  return name === "release" ? OUTCOME.Release : OUTCOME.Refund;
}

export function outcomeName(outcome: number): string {
  if (outcome === OUTCOME.Release) return "release";
  if (outcome === OUTCOME.Refund) return "refund";
  return "nothing";
}

export function verdictFromName(text: string): number {
  const name = text.trim().toLowerCase();
  if (!(VERDICT_NAMES as readonly string[]).includes(name)) {
    throw new Error(
      `unknown verdict "${text}". The verifier records one of: ` +
        `${VERDICT_NAMES.join(", ")}.`
    );
  }
  return VERDICT[(name.charAt(0).toUpperCase() + name.slice(1)) as keyof typeof VERDICT];
}

export type LifecycleAction =
  | "deliver"
  | "verify"
  | "accept"
  | "challenge"
  | "propose"
  | "overturn"
  | "push"
  | "finalize"
  | "timeout";

type ActionRule = {
  allowed: number[];
  whose: string;
  hint?: string;
};

const ACTION_RULES: Record<LifecycleAction, ActionRule> = {
  deliver: { allowed: [STATE.Funded], whose: "seller" },
  verify: { allowed: [STATE.Delivered], whose: "verifier" },
  accept: { allowed: [STATE.Verified], whose: "buyer" },
  challenge: {
    allowed: [STATE.Verified],
    whose: "buyer against Pass, or seller against Fail/Inconclusive"
  },
  propose: { allowed: [STATE.Disputed], whose: "arbitrator agent" },
  overturn: { allowed: [STATE.Disputed], whose: "arbitrator officer" },
  push: { allowed: [STATE.Disputed], whose: "anyone" },
  finalize: {
    allowed: [STATE.Verified, STATE.Disputed],
    whose: "anyone",
    hint: "finalize waits for the challenge window or ruling deadline"
  },
  timeout: {
    allowed: [STATE.Funded, STATE.Delivered],
    whose: "anyone",
    hint: "claimTimeout waits for the deal deadline"
  }
};

export type ActionContext = { bond?: bigint };

export function assertActionAllowed(
  action: LifecycleAction,
  state: number,
  context: ActionContext = {}
): void {
  const rule = ACTION_RULES[action];
  if (rule.allowed.includes(state)) {
    if (action === "deliver" && (context.bond ?? 0n) > 0n) {
      // State.Funded does not encode bondPosted; the caller supplies the signed bond
      // only when it has not independently confirmed the bond is posted.
      throw new Error(
        "this deal requires a seller bond. Confirm it is posted before delivery."
      );
    }
    return;
  }

  const terminal = ([STATE.Released, STATE.Refunded, STATE.Cancelled] as number[]).includes(
    state
  );
  const hint = terminal
    ? "this deal is already settled"
    : rule.hint ?? `this is the ${rule.whose}'s move from ${rule.allowed.map(stateName).join(" or ")}`;
  throw new Error(`deal is in state ${stateName(state)}: ${hint}.`);
}

export type StepResult = {
  txHash: string;
  blockNumber: number;
  gasUsed: bigint;
  state: number;
};

async function currentDeal(escrow: Contract, dealId: BigNumberish): Promise<any> {
  return escrow.getDeal(dealId);
}

async function currentState(escrow: Contract, dealId: BigNumberish): Promise<number> {
  return Number((await currentDeal(escrow, dealId)).state);
}

async function send(
  escrow: Contract,
  call: () => Promise<{ hash: string; wait: () => Promise<unknown> }>,
  label: string,
  dealId: BigNumberish
): Promise<StepResult> {
  const tx = await call();
  const receipt = (await tx.wait()) as { blockNumber: number; gasUsed: bigint } | null;
  if (!receipt) throw new Error(`${label} transaction ${tx.hash} produced no receipt`);
  return {
    txHash: tx.hash,
    blockNumber: receipt.blockNumber,
    gasUsed: receipt.gasUsed,
    state: await currentState(escrow, dealId)
  };
}

export type SubmitDeliveryParams = {
  escrowAddress: string;
  sellerSigner: Signer;
  dealId: BigNumberish;
  evidenceHash: string;
  bond?: bigint;
};

export async function submitDelivery(params: SubmitDeliveryParams): Promise<StepResult> {
  const escrow = new Contract(params.escrowAddress, ESCROW_ABI, params.sellerSigner);
  const deal = await currentDeal(escrow, params.dealId);
  assertActionAllowed("deliver", Number(deal.state), {
    bond: deal.bondPosted ? 0n : (params.bond ?? BigInt(deal.bond))
  });
  if (params.evidenceHash === ZeroHash) {
    throw new Error("the evidence hash is empty, which the escrow rejects");
  }
  return send(
    escrow,
    () => escrow.submitDelivery(params.dealId, params.evidenceHash),
    "submitDelivery",
    params.dealId
  );
}

export type RecordVerificationParams = {
  escrowAddress: string;
  verifierSigner: Signer;
  dealId: BigNumberish;
  verdict: number;
};

export async function recordVerification(
  params: RecordVerificationParams
): Promise<StepResult> {
  const escrow = new Contract(params.escrowAddress, ESCROW_ABI, params.verifierSigner);
  assertActionAllowed("verify", await currentState(escrow, params.dealId));
  return send(
    escrow,
    () => escrow.recordVerification(params.dealId, params.verdict),
    "recordVerification",
    params.dealId
  );
}

export type WithdrawCreditParams = {
  escrowAddress: string;
  signer: Signer;
  tokenAddress: string;
};

export type WithdrawResult = {
  txHash: string;
  blockNumber: number;
  gasUsed: bigint;
  amount: bigint;
};

export async function withdrawCredit(params: WithdrawCreditParams): Promise<WithdrawResult> {
  const escrow = new Contract(params.escrowAddress, ESCROW_ABI, params.signer);
  const party = await params.signer.getAddress();
  const amount = (await escrow.withdrawable(params.tokenAddress, party)) as bigint;
  if (amount === 0n) {
    throw new Error(`nothing credited to ${party} for that token`);
  }
  const tx = await escrow["withdraw(address)"](params.tokenAddress);
  const receipt = (await tx.wait()) as { blockNumber: number; gasUsed: bigint } | null;
  if (!receipt) throw new Error(`withdraw transaction ${tx.hash} produced no receipt`);
  return { txHash: tx.hash, blockNumber: receipt.blockNumber, gasUsed: receipt.gasUsed, amount };
}

export type AcceptVerificationParams = {
  escrowAddress: string;
  buyerSigner: Signer;
  dealId: BigNumberish;
};

export async function acceptVerification(
  params: AcceptVerificationParams
): Promise<StepResult> {
  const escrow = new Contract(params.escrowAddress, ESCROW_ABI, params.buyerSigner);
  assertActionAllowed("accept", await currentState(escrow, params.dealId));
  return send(escrow, () => escrow.accept(params.dealId), "accept", params.dealId);
}

export type ChallengeVerdictParams = {
  escrowAddress: string;
  signer: Signer;
  dealId: BigNumberish;
};

export async function challengeVerdict(params: ChallengeVerdictParams): Promise<StepResult> {
  const escrow = new Contract(params.escrowAddress, ESCROW_ABI, params.signer);
  const deal = await currentDeal(escrow, params.dealId);
  assertActionAllowed("challenge", Number(deal.state));
  const signerAddress = (await params.signer.getAddress()).toLowerCase();
  const expected = Number(deal.verdict) === VERDICT.Pass ? deal.buyer : deal.seller;
  if (signerAddress !== String(expected).toLowerCase()) {
    const role = Number(deal.verdict) === VERDICT.Pass ? "buyer" : "seller";
    throw new Error(`this verdict can only be challenged by the ${role}`);
  }
  await prepareTransfer({
    tokenAddress: deal.token,
    spender: params.escrowAddress,
    owner: params.signer,
    amount: BigInt(deal.challengerBond),
    role: "challenger"
  });
  return send(escrow, () => escrow.challenge(params.dealId), "challenge", params.dealId);
}

export type ArbitratorStepParams = {
  escrowAddress: string;
  arbitratorAddress: string;
  signer: Signer;
  dealId: BigNumberish;
  outcome?: number;
};

async function arbitratorStep(
  action: "propose" | "overturn" | "push",
  params: ArbitratorStepParams
): Promise<StepResult> {
  const escrow = new Contract(params.escrowAddress, ESCROW_ABI, params.signer);
  assertActionAllowed(action, await currentState(escrow, params.dealId));
  const arbitrator = new Contract(
    params.arbitratorAddress,
    CONSOLE_ARBITRATOR_ABI,
    params.signer
  );
  if (action !== "push" && params.outcome !== OUTCOME.Release && params.outcome !== OUTCOME.Refund) {
    throw new Error("an arbitrator outcome must be release or refund");
  }
  return send(
    escrow,
    () =>
      action === "push"
        ? arbitrator.push(params.dealId)
        : arbitrator[action](params.dealId, params.outcome),
    action,
    params.dealId
  );
}

export function proposeRuling(params: ArbitratorStepParams): Promise<StepResult> {
  return arbitratorStep("propose", params);
}

export function overturnRuling(params: ArbitratorStepParams): Promise<StepResult> {
  return arbitratorStep("overturn", params);
}

export function pushRuling(params: ArbitratorStepParams): Promise<StepResult> {
  return arbitratorStep("push", params);
}

export type FinalizeDealParams = {
  escrowAddress: string;
  signer: Signer;
  dealId: BigNumberish;
};

export async function finalizeDeal(params: FinalizeDealParams): Promise<StepResult> {
  const escrow = new Contract(params.escrowAddress, ESCROW_ABI, params.signer);
  assertActionAllowed("finalize", await currentState(escrow, params.dealId));
  return send(escrow, () => escrow.finalize(params.dealId), "finalize", params.dealId);
}

export async function claimDealTimeout(params: FinalizeDealParams): Promise<StepResult> {
  const escrow = new Contract(params.escrowAddress, ESCROW_ABI, params.signer);
  assertActionAllowed("timeout", await currentState(escrow, params.dealId));
  return send(
    escrow,
    () => escrow.claimTimeout(params.dealId),
    "claimTimeout",
    params.dealId
  );
}
