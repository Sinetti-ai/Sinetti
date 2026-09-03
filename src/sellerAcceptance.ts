import { Contract, hexlify, randomBytes } from "ethers";
import type {
  BigNumberish,
  Provider,
  Signer,
  TypedDataDomain,
  TypedDataField
} from "ethers";

/**
 * ERC-5267. The escrow declares its own EIP-712 signing domain, so a client can
 * read it instead of assuming one. Assuming is how earlier deployment drift stayed
 * hidden: a signature under domain version "1" against a contract signing
 * version "8" is well-formed, cheap to produce, and silently invalid.
 */
const EIP712_DOMAIN_ABI = [
  "function eip712Domain() view returns (bytes1 fields, string name, string version, uint256 chainId, address verifyingContract, bytes32 salt, uint256[] extensions)"
];

/** ERC-5267 `fields` bits, in the order the standard defines them. */
const DOMAIN_FIELD_BITS = {
  name: 0x01,
  version: 0x02,
  chainId: 0x04,
  verifyingContract: 0x08,
  salt: 0x10
} as const;

/** The only domain shape this client knows how to sign for. */
const SUPPORTED_FIELDS =
  DOMAIN_FIELD_BITS.name |
  DOMAIN_FIELD_BITS.version |
  DOMAIN_FIELD_BITS.chainId |
  DOMAIN_FIELD_BITS.verifyingContract;

const SUPPORTED_MEMBERS = ["name", "version", "chainId", "verifyingContract"] as const;
export const SIGNING_DOMAIN_NAME = "SinettiEscrow";
export const SIGNING_DOMAIN_VERSION = "8";

function toHexByte(value: number): string {
  return `0x${value.toString(16).padStart(2, "0")}`;
}

function withCause(error: Error, cause: unknown): Error {
  // The es2020 target predates Error's `cause` option, so attach it directly.
  (error as Error & { cause?: unknown }).cause = cause;
  return error;
}

/**
 * Turns a failed `eip712Domain()` call into a diagnosis, or hands the original
 * error back when there is no evidence for one.
 *
 * Classifying by error code is brittle, so this classifies by evidence instead:
 * ask the chain what is actually at the address. A dead endpoint cannot answer
 * that either, which is precisely what distinguishes a transport failure from a
 * contract that will not answer.
 */
async function explainDomainReadFailure(
  escrowAddress: string,
  provider: Provider,
  cause: unknown
): Promise<unknown> {
  let code: string;
  try {
    code = await provider.getCode(escrowAddress);
  } catch {
    // The provider cannot answer a basic question, so the fault is the transport,
    // not the contract. Reporting drift here sends the reader to Solidity that was
    // never wrong.
    return cause;
  }

  if (code !== "0x") {
    return withCause(
      new Error(
        `${escrowAddress} does not declare an EIP-712 domain (ERC-5267). ` +
          "A contract is deployed there, but it does not answer eip712Domain(). " +
          "It is either not a SinettiEscrowV04 instance, or it is an older deployment " +
          "than the source you are signing against — the deployed instance and this " +
          "contract have drifted. Check the address before signing anything."
      ),
      cause
    );
  }

  let where = "an unidentified chain";
  try {
    const network = await provider.getNetwork();
    const named = network.name && network.name !== "unknown" ? ` (${network.name})` : "";
    where = `chain ${network.chainId}${named}`;
  } catch {
    // Keep the generic phrasing; the address being empty is the point.
  }

  return withCause(
    new Error(
      `no contract at ${escrowAddress} on ${where}. Nothing is deployed at that ` +
        "address. Check the address, and check which network you are connected to — " +
        "an address deployed on one chain is empty on every other."
    ),
    cause
  );
}

export async function buildSellerAcceptanceDomain(
  escrowAddress: string,
  provider: Provider
): Promise<TypedDataDomain> {
  const escrow = new Contract(escrowAddress, EIP712_DOMAIN_ABI, provider);

  let declared;
  try {
    declared = await escrow.eip712Domain();
  } catch (cause) {
    throw await explainDomainReadFailure(escrowAddress, provider, cause);
  }

  const [fields, name, version, chainId, verifyingContract, , extensions] = declared;
  const bitmap = Number(BigInt(fields));

  // The `fields` bitmap says which domain members are actually in use. Reading the
  // four members this client understands and ignoring the bitmap would sign a
  // salted domain as though it had no salt: a different digest, silently invalid,
  // which is the failure this whole module exists to prevent.
  if (bitmap !== SUPPORTED_FIELDS || extensions.length > 0) {
    const missing = SUPPORTED_MEMBERS.filter(
      (member) => (bitmap & DOMAIN_FIELD_BITS[member]) === 0
    );
    const notes: string[] = [];
    if (missing.length > 0) notes.push(`it does not use ${missing.join(", ")}`);
    if ((bitmap & DOMAIN_FIELD_BITS.salt) !== 0) notes.push("it also uses salt");
    if (extensions.length > 0) {
      notes.push(`it declares ${extensions.length} domain extension(s)`);
    }

    throw new Error(
      `${escrowAddress} declares an EIP-712 domain this client cannot sign for: ` +
        `fields ${toHexByte(bitmap)}, expected ${toHexByte(SUPPORTED_FIELDS)} — ` +
        `${notes.join("; ")}. Signing anyway would produce a well-formed signature ` +
        "under the wrong domain, which the contract would reject without saying why."
    );
  }

  if (name !== SIGNING_DOMAIN_NAME || version !== SIGNING_DOMAIN_VERSION) {
    throw new Error(
      `${escrowAddress} declares EIP-712 domain ${JSON.stringify(name)} version ` +
        `${JSON.stringify(version)}, but this client requires ${JSON.stringify(
          SIGNING_DOMAIN_NAME
        )} version ${JSON.stringify(SIGNING_DOMAIN_VERSION)}. Signing anyway would ` +
        "produce a well-formed signature under the wrong domain, which the contract " +
        "would reject without saying why."
    );
  }

  const connectedChainId = (await provider.getNetwork()).chainId;
  if (BigInt(chainId) !== connectedChainId) {
    throw new Error(
      `${escrowAddress} declares EIP-712 domain chainId ${chainId}, but the connection ` +
        `is chain ${connectedChainId}. Signing anyway would produce a well-formed ` +
        "signature under the wrong domain, which the contract would reject without saying why."
    );
  }

  return { name, version, chainId, verifyingContract };
}

/** Must match SELLER_ACCEPTANCE_TYPEHASH in SinettiEscrowV04.sol, field for field. */
export const SELLER_ACCEPTANCE_TYPES: Record<string, TypedDataField[]> = {
  SellerAcceptance: [
    { name: "buyer", type: "address" },
    { name: "seller", type: "address" },
    { name: "verifier", type: "address" },
    { name: "arbitrator", type: "address" },
    { name: "token", type: "address" },
    { name: "amount", type: "uint256" },
    { name: "bond", type: "uint256" },
    { name: "challengerBond", type: "uint256" },
    { name: "termsHash", type: "bytes32" },
    { name: "buyerIdentityRef", type: "bytes32" },
    { name: "sellerIdentityRef", type: "bytes32" },
    { name: "verifierIdentityRef", type: "bytes32" },
    { name: "arbitratorIdentityRef", type: "bytes32" },
    { name: "duration", type: "uint64" },
    { name: "challengeWindow", type: "uint64" },
    { name: "rulingWindow", type: "uint64" },
    { name: "openBy", type: "uint64" },
    { name: "salt", type: "bytes32" },
    { name: "metaEvidenceURI", type: "string" }
  ]
};

/** SinettiEscrowV04 client defaults. */
export const DEFAULT_CHALLENGE_WINDOW = 3600n;
export const DEFAULT_RULING_WINDOW = 86400n;
export const ZERO_IDENTITY_REF = "0x" + "00".repeat(32);

export type SellerAcceptanceTerms = {
  buyer: string;
  seller: string;
  verifier: string;
  arbitrator: string;
  token: string;
  amount: BigNumberish;
  bond: BigNumberish;
  challengerBond: BigNumberish;
  termsHash: string;
  buyerIdentityRef: string;
  sellerIdentityRef: string;
  verifierIdentityRef: string;
  arbitratorIdentityRef: string;
  duration: BigNumberish;
  challengeWindow: BigNumberish;
  rulingWindow: BigNumberish;
  openBy: BigNumberish;
  salt: string;
  metaEvidenceURI: string;
};

export type SignSellerAcceptanceParams = {
  escrowAddress: string;
  provider: Provider;
  sellerSigner: Signer;
  buyer: string;
  seller: string;
  verifier: string;
  arbitrator: string;
  token: string;
  amount: BigNumberish;
  bond: BigNumberish;
  challengerBond: BigNumberish;
  termsHash: string;
  duration: BigNumberish;
  openBy: BigNumberish;
  challengeWindow?: BigNumberish;
  rulingWindow?: BigNumberish;
  buyerIdentityRef?: string;
  sellerIdentityRef?: string;
  verifierIdentityRef?: string;
  arbitratorIdentityRef?: string;
  metaEvidenceURI?: string;
  /** Override only for tests that need a reproducible digest. */
  salt?: string;
};

/**
 * Produces the seller's off-chain consent to one exact deal.
 *
 * Returns the signed struct alongside the signature so the caller submits the
 * same object it signed. Rebuilding the struct at the call site is the mistake
 * this shape exists to prevent: any field that differs changes the digest, and
 * openDeal reverts with InvalidSellerSignature rather than telling you which
 * field moved.
 */
export async function signSellerAcceptance(
  params: SignSellerAcceptanceParams
): Promise<{ terms: SellerAcceptanceTerms; signature: string; domain: TypedDataDomain }> {
  const domain = await buildSellerAcceptanceDomain(params.escrowAddress, params.provider);

  const terms: SellerAcceptanceTerms = {
    buyer: params.buyer,
    seller: params.seller,
    verifier: params.verifier,
    arbitrator: params.arbitrator,
    token: params.token,
    amount: params.amount,
    bond: params.bond,
    challengerBond: params.challengerBond,
    termsHash: params.termsHash,
    buyerIdentityRef: params.buyerIdentityRef ?? ZERO_IDENTITY_REF,
    sellerIdentityRef: params.sellerIdentityRef ?? ZERO_IDENTITY_REF,
    verifierIdentityRef: params.verifierIdentityRef ?? ZERO_IDENTITY_REF,
    arbitratorIdentityRef: params.arbitratorIdentityRef ?? ZERO_IDENTITY_REF,
    duration: params.duration,
    challengeWindow: params.challengeWindow ?? DEFAULT_CHALLENGE_WINDOW,
    rulingWindow: params.rulingWindow ?? DEFAULT_RULING_WINDOW,
    openBy: params.openBy,
    salt: params.salt ?? hexlify(randomBytes(32)),
    metaEvidenceURI: params.metaEvidenceURI ?? ""
  };

  const signature = await params.sellerSigner.signTypedData(
    domain,
    SELLER_ACCEPTANCE_TYPES,
    terms
  );

  return { terms, signature, domain };
}
