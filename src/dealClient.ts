import { Contract, TypedDataEncoder, formatUnits, parseUnits } from "ethers";
import type { BigNumberish, Provider, Signer } from "ethers";

import {
  SELLER_ACCEPTANCE_TYPES,
  buildSellerAcceptanceDomain
} from "./sellerAcceptance";
import type { SellerAcceptanceTerms } from "./sellerAcceptance";

/**
 * The escrow calls this client needs, written out by hand so `src/` ships without
 * hardhat or typechain. A hand-written ABI is a second copy of the contract's
 * interface, so `test/DealClient.openDeal.test.ts` checks every fragment here
 * against the compiled artifact rather than trusting it.
 */
export const ESCROW_ABI = [
  "function openDeal((address buyer,address seller,address verifier,address arbitrator,address token,uint256 amount,uint256 bond,uint256 challengerBond,bytes32 termsHash,bytes32 buyerIdentityRef,bytes32 sellerIdentityRef,bytes32 verifierIdentityRef,bytes32 arbitratorIdentityRef,uint64 duration,uint64 challengeWindow,uint64 rulingWindow,uint64 openBy,bytes32 salt,string metaEvidenceURI) terms, bytes sellerSignature) returns (uint256 dealId)",
  "function postBond(uint256 dealId)",
  "function consumedAcceptance(bytes32 digest) view returns (bool)",
  "function submitDelivery(uint256 dealId, bytes32 evidenceHash)",
  "function recordVerification(uint256 dealId, uint8 rawVerdict)",
  "function accept(uint256 dealId)",
  "function challenge(uint256 dealId)",
  "function submitEvidence(uint256 dealId, string evidence)",
  "function submitRuling(uint256 dealId, uint8 rawOutcome)",
  "function finalize(uint256 dealId)",
  "function claimTimeout(uint256 dealId)",
  "function cancelMutually((uint256 dealId,address signer,uint32 revision,bytes32 nonce,uint64 issuedAt,uint64 expiry) offer, bytes signature)",
  "function revokeAcceptance((address buyer,address seller,address verifier,address arbitrator,address token,uint256 amount,uint256 bond,uint256 challengerBond,bytes32 termsHash,bytes32 buyerIdentityRef,bytes32 sellerIdentityRef,bytes32 verifierIdentityRef,bytes32 arbitratorIdentityRef,uint64 duration,uint64 challengeWindow,uint64 rulingWindow,uint64 openBy,bytes32 salt,string metaEvidenceURI) terms)",
  "function withdraw(address token)",
  "function withdraw(address token, uint256 amount)",
  "function withdrawable(address token, address party) view returns (uint256)",
  "function getDeal(uint256 dealId) view returns ((address buyer,address seller,address verifier,address arbitrator,address token,uint256 amount,uint256 bond,uint256 challengerBond,bytes32 termsHash,bytes32 buyerIdentityRef,bytes32 sellerIdentityRef,bytes32 verifierIdentityRef,bytes32 arbitratorIdentityRef,bytes32 evidenceHash,uint64 deadline,uint64 challengeWindow,uint64 rulingWindow,uint32 revision,uint64 verifiedAt,uint8 state,uint8 verdict,bool bondPosted))",
  "function disputes(uint256 dealId) view returns (address challenger, uint64 rulingDeadline)",
  "function tokenAccounting(address token) view returns (uint256 liabilities, uint256 actualBalance)",
  "function challengeEndsAt(uint256 dealId) view returns (uint64)",
  "event DealOpened(uint256 indexed dealId,address indexed buyer,address indexed seller,address verifier,address arbitrator,address token,uint256 amount,uint256 bond,uint256 challengerBond,bytes32 termsHash,bytes32 buyerIdentityRef,bytes32 sellerIdentityRef,bytes32 verifierIdentityRef,bytes32 arbitratorIdentityRef,uint64 deadline,uint64 challengeWindow,uint64 rulingWindow)",
  "event BondPosted(uint256 indexed dealId, uint256 bond)"
];

/** The settlement-token calls this client needs. */
export const ERC20_ABI = [
  "function approve(address spender, uint256 value) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function balanceOf(address account) view returns (uint256)",
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)"
];

/**
 * Mirrors SinettiEscrowV04.State, Verdict, and Outcome positionally.
 *
 * `test/ContractMirrors.test.ts` checks completeness and order against the
 * contract source.
 */
export const STATE = {
  None: 0,
  Funded: 1,
  Delivered: 2,
  Verified: 3,
  Disputed: 4,
  Released: 5,
  Refunded: 6,
  Cancelled: 7
} as const;

export const VERDICT = {
  None: 0,
  Pass: 1,
  Fail: 2,
  Inconclusive: 3
} as const;

export const OUTCOME = {
  None: 0,
  Release: 1,
  Refund: 2
} as const;

/**
 * Reads a display amount ("250", "250.5") into base units.
 *
 * The token's own decimals decide the scale, never an assumption: tEUR has 6, and
 * the instinctive 18 is wrong by a factor of a trillion. Excess precision is a
 * hard error rather than a silent truncation — quietly dropping a digit off a
 * settlement amount is worse than refusing it.
 */
export function parseTokenAmount(text: string, decimals: number, symbol: string): bigint {
  const trimmed = text.trim();
  if (trimmed === "") {
    throw new Error(`expected an amount in ${symbol}, got an empty value`);
  }
  if (trimmed.startsWith("-")) {
    throw new Error(`amount ${trimmed} is negative; amounts must be positive`);
  }
  if (!/^\d+(\.\d+)?$/.test(trimmed)) {
    throw new Error(
      `"${trimmed}" is not an amount. Give it in ${symbol} as a plain decimal, ` +
        'for example "250" or "250.50".'
    );
  }

  const [, fraction = ""] = trimmed.split(".");
  if (fraction.length > decimals) {
    throw new Error(
      `${trimmed} ${symbol} is finer than ${symbol} can represent: it has ` +
        `${decimals} decimal place(s), so ${fraction.length} were given and ` +
        `${fraction.length - decimals} would be silently dropped.`
    );
  }

  return parseUnits(trimmed, decimals);
}

/** Names a state value, so a status view shows "Funded" and not "1". */
export function stateName(value: BigNumberish): string {
  const numeric = Number(value.toString());
  const match = Object.entries(STATE).find(([, state]) => state === numeric);
  return match ? match[0] : `Unknown(${numeric})`;
}

function requireProvider(signer: Signer, role: string): Provider {
  if (!signer.provider) {
    throw new Error(`the ${role} signer is not connected to a provider`);
  }
  return signer.provider;
}

/**
 * Renders a base-unit amount the way a person reads it: "250 tEUR", not
 * "250000000" and not "250.0". Diagnostics that report base units make the reader
 * do decimal arithmetic at exactly the moment something is already wrong.
 */
export function formatTokenAmount(value: bigint, decimals: number, symbol: string): string {
  const text = formatUnits(value, decimals);
  const trimmed = text.includes(".") ? text.replace(/\.?0+$/, "") : text;
  return `${trimmed === "" ? "0" : trimmed} ${symbol}`;
}

/**
 * Checks the balance and sets the exact allowance the escrow will pull.
 *
 * Two failures this avoids. A missing approval is the most common reason an open
 * reverts; approving MaxUint256 to make that go away leaves a standing allowance
 * on a live escrow that outlives the deal it was for. So: approve the amount,
 * nothing more.
 */
export async function prepareTransfer(params: {
  tokenAddress: string;
  spender: string;
  owner: Signer;
  amount: bigint;
  role: string;
}): Promise<void> {
  const { tokenAddress, spender, owner, amount, role } = params;
  const token = new Contract(tokenAddress, ERC20_ABI, owner);
  const ownerAddress = await owner.getAddress();

  const [balance, decimals, symbol] = await Promise.all([
    token.balanceOf(ownerAddress) as Promise<bigint>,
    token.decimals() as Promise<bigint>,
    token.symbol() as Promise<string>
  ]);
  const places = Number(decimals);

  if (balance < amount) {
    throw new Error(
      `${role} ${ownerAddress} holds ${formatTokenAmount(balance, places, symbol)} ` +
        `but needs ${formatTokenAmount(amount, places, symbol)} for this deal. ` +
        `Short by ${formatTokenAmount(amount - balance, places, symbol)}.`
    );
  }

  const allowance = (await token.allowance(ownerAddress, spender)) as bigint;
  if (allowance !== amount) {
    await (await token.approve(spender, amount)).wait();
  }
}

/**
 * Refuses an acceptance the escrow has already spent.
 *
 * Re-running an open is the easy mistake: the signed file is still on disk after
 * it worked. The escrow does reject the replay, but as AcceptanceAlreadyConsumed
 * after the buyer's approval has already cost gas — and that name does not tell
 * anyone the deal they wanted already exists.
 */
async function assertAcceptanceUnconsumed(
  escrow: Contract,
  escrowAddress: string,
  buyerSigner: Signer,
  terms: SellerAcceptanceTerms
): Promise<void> {
  const domain = await buildSellerAcceptanceDomain(
    escrowAddress,
    buyerSigner.provider as Provider
  );
  const digest = TypedDataEncoder.hash(domain, SELLER_ACCEPTANCE_TYPES, terms);

  if (await escrow.consumedAcceptance(digest)) {
    throw new Error(
      "this acceptance has already been opened — the escrow has consumed it " +
        `(digest ${digest}). Each signature opens exactly one deal. Look up the deal ` +
        "it opened rather than opening another, or have the seller sign a new one."
    );
  }
}

export type OpenDealParams = {
  escrowAddress: string;
  buyerSigner: Signer;
  terms: SellerAcceptanceTerms;
  signature: string;
};

export type OpenDealResult = {
  /** Assigned by the escrow and read back from DealOpened, never counted here. */
  dealId: bigint;
  txHash: string;
  blockNumber: number;
  gasUsed: bigint;
};

/**
 * Funds a deal the seller has already consented to.
 *
 * The buyer's tokens move during this call, so the balance is checked and the
 * allowance set first: a revert here costs gas and reports the failure from
 * inside ERC20, where it cannot say who was short or by how much.
 */
export async function openDeal(params: OpenDealParams): Promise<OpenDealResult> {
  const { escrowAddress, buyerSigner, terms, signature } = params;
  requireProvider(buyerSigner, "buyer");

  // Checked before any token movement. The escrow catches this too, with a bare
  // NotBuyer() revert that names neither address -- and only after the approve has
  // already cost gas.
  const buyerAddress = await buyerSigner.getAddress();
  if (buyerAddress.toLowerCase() !== terms.buyer.toLowerCase()) {
    throw new Error(
      `signer ${buyerAddress} is not the buyer named in these terms (${terms.buyer}). ` +
        "Check which role's key is loaded before opening."
    );
  }

  const escrow = new Contract(escrowAddress, ESCROW_ABI, buyerSigner);
  await assertAcceptanceUnconsumed(escrow, escrowAddress, buyerSigner, terms);

  await prepareTransfer({
    tokenAddress: terms.token,
    spender: escrowAddress,
    owner: buyerSigner,
    amount: BigInt(terms.amount.toString()),
    role: "buyer"
  });

  const tx = await escrow.openDeal(terms, signature);
  const receipt = await tx.wait();
  if (!receipt) {
    throw new Error(`openDeal transaction ${tx.hash} produced no receipt`);
  }

  return {
    dealId: dealIdFromReceipt(escrow, receipt, tx.hash),
    txHash: tx.hash,
    blockNumber: receipt.blockNumber,
    gasUsed: receipt.gasUsed
  };
}

type ReceiptLike = {
  blockNumber: number;
  gasUsed: bigint;
  logs: ReadonlyArray<{ topics: ReadonlyArray<string>; data: string }>;
};

/**
 * Reads the escrow's own dealId out of the receipt.
 *
 * Inferring it from a local counter is correct until anyone else opens a deal
 * against the same escrow, which on a shared testnet address is routine. The
 * cost of guessing is silent: every later call addresses the wrong deal.
 */
function dealIdFromReceipt(escrow: Contract, receipt: ReceiptLike, txHash: string): bigint {
  for (const log of receipt.logs) {
    const parsed = escrow.interface.parseLog({
      topics: [...log.topics],
      data: log.data
    });
    if (parsed?.name === "DealOpened") {
      return parsed.args.dealId as bigint;
    }
  }

  throw new Error(
    `openDeal transaction ${txHash} emitted no DealOpened event, so the escrow ` +
      "assigned no dealId this client can read. The escrow at this address is not the " +
      "contract this client was built against."
  );
}

export type PostBondParams = {
  escrowAddress: string;
  sellerSigner: Signer;
  dealId: BigNumberish;
  token: string;
  bond: BigNumberish;
};

export type PostBondResult = {
  txHash: string;
  blockNumber: number;
  gasUsed: bigint;
  /** The escrow's state after the bond lands, as a STATE value. */
  state: number;
};

/** Posts the seller's bond against an already-funded deal. */
export async function postBond(params: PostBondParams): Promise<PostBondResult> {
  const { escrowAddress, sellerSigner, dealId, token, bond } = params;
  requireProvider(sellerSigner, "seller");

  await prepareTransfer({
    tokenAddress: token,
    spender: escrowAddress,
    owner: sellerSigner,
    amount: BigInt(bond.toString()),
    role: "seller"
  });

  const escrow = new Contract(escrowAddress, ESCROW_ABI, sellerSigner);
  const tx = await escrow.postBond(dealId);
  const receipt = await tx.wait();
  if (!receipt) {
    throw new Error(`postBond transaction ${tx.hash} produced no receipt`);
  }

  return {
    txHash: tx.hash,
    blockNumber: receipt.blockNumber,
    gasUsed: receipt.gasUsed,
    state: Number((await escrow.getDeal(dealId)).state)
  };
}
