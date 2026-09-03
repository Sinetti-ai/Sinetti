import { createHash } from "node:crypto";
import {
  lstatSync,
  readFileSync,
  readdirSync,
  readlinkSync,
  realpathSync,
  statSync
} from "node:fs";
import * as path from "node:path";

/**
 * Delivery evidence: what the seller commits to on chain.
 *
 * `submitDelivery(dealId, evidenceHash)` stores an opaque `bytes32`. The contract
 * never recomputes it and never compares it to anything, so the value is only
 * worth what the off-chain rule behind it is worth. Hashing a literal label such
 * as "delivery evidence" would commit to a description rather than a delivery.
 *
 * The shape here is copied from the in-toto Attestation Framework's Statement v1
 * — the same envelope Docker, npm, PyPI and Sigstore publish provenance in. It is
 * copied, not depended on: no in-toto package is installed, and nothing here
 * requires the seller to adopt in-toto tooling. Reusing the shape means an
 * arbitrator, auditor, or compatible verifier reads a structure that
 * already has published semantics.
 *
 * Two constraints drive the design and both are load-bearing:
 *
 * 1. **Never hash an archive.** A zip or tar of the same files differs run to run
 *    — entry order, mtimes and compression level all land in the bytes. A digest
 *    that changes when nothing changed cannot settle a dispute. The subject list
 *    is therefore per-file: each file carries its own digest, and the archive, if
 *    one is shipped at all, is only a transport.
 * 2. **Canonicalize before hashing.** Two parties serializing the same manifest
 *    must get the same bytes, or the digest proves nothing about agreement. See
 *    `canonicalJson`.
 *
 * The digest algorithm is SHA-256, for three reasons that all point the same way:
 * `sha256sum` ships on every platform a seller might build on, so producing
 * evidence needs no dependency; `docs/evidence.md` specifies SHA-256
 * for `logs_hash`, and a second algorithm for the artifact would make sellers run
 * two; and SHA-256 output is exactly 32 bytes, so it lands in the contract's
 * `bytes32` with no truncation and no loss.
 */

/** in-toto Statement v1. Copied shape — no in-toto dependency. */
export const DELIVERY_STATEMENT_TYPE = "https://in-toto.io/Statement/v1";

/** Sinetti's own predicate: the v0 `code_test_execution` delivery fields. */
export const DELIVERY_PREDICATE_TYPE = "https://sinetti.ai/Delivery/v0";

/** A delivered file and its digest. `name` is a deal-relative POSIX path. */
export type EvidenceSubject = {
  name: string;
  digest: { sha256: string };
};

/**
 * The fields `docs/evidence.md` checks but the envelope schema never had a
 * home for. `repo_commit_hash` and `runtime_hash` were described as living
 * "inside the artifact package", which left them outside every commitment; here
 * they are inside the hashed statement.
 */
export type DeliveryPredicate = {
  repo_commit_hash: string;
  runtime_hash: string;
  logs_hash: string;
};

export type DeliveryStatement = {
  _type: typeof DELIVERY_STATEMENT_TYPE;
  predicateType: typeof DELIVERY_PREDICATE_TYPE;
  subject: EvidenceSubject[];
  predicate: DeliveryPredicate;
};

const SHA256_HEX = /^[0-9a-f]{64}$/;

/**
 * Canonical JSON over the closed set of types a manifest may contain.
 *
 * RFC 8785 (JCS) is the reference, and this is deliberately a strict subset of
 * it: object keys sorted by UTF-16 code unit, no insignificant whitespace, and
 * `JSON.stringify`'s string escaping, which already matches JCS for the strings
 * a manifest holds. The hard part of RFC 8785 is number serialization, and this
 * function does not implement it — it *rejects* numbers instead.
 *
 * That refusal is the point. A manifest carries hex digests, paths and type
 * URIs, all strings; nothing in it needs a number. Rejecting rather than
 * half-implementing means this can never silently disagree with a full JCS
 * implementation on the one input class where the subset would be wrong. If a
 * numeric field is ever genuinely needed, adopt a real JCS library at that
 * point rather than extending this.
 */
export function canonicalJson(value: unknown): string {
  if (value === null) return "null";
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "string") return JSON.stringify(value);
  if (Array.isArray(value)) {
    return `[${value.map(canonicalJson).join(",")}]`;
  }
  if (typeof value === "object") {
    const entries = Object.entries(value as Record<string, unknown>)
      .filter(([, v]) => v !== undefined)
      // UTF-16 code unit, and deliberately NOT compareSubjectNames. RFC 8785
      // specifies this order for object keys; the subject array is Sinetti's
      // own choice and uses UTF-8 bytes. Two orders in one file is not a
      // mistake, and making them agree would break JCS conformance.
      .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
    return `{${entries.map(([k, v]) => `${JSON.stringify(k)}:${canonicalJson(v)}`).join(",")}}`;
  }
  throw new Error(
    `canonicalJson: unsupported value of type ${typeof value}. Only strings, ` +
      "booleans, null, arrays and plain objects may appear in a manifest; " +
      "numbers are rejected because RFC 8785 number canonicalization is not " +
      "implemented here."
  );
}

/** SHA-256 of arbitrary bytes, as bare lowercase hex (in-toto digest form). */
export function sha256Hex(bytes: Uint8Array | string): string {
  return createHash("sha256").update(bytes).digest("hex");
}

/** SHA-256 of a single file's contents. */
export function hashFile(filePath: string): string {
  return sha256Hex(readFileSync(filePath));
}

/**
 * Every regular file under `root`, depth-first, refusing symlinks.
 *
 * Directory order from the filesystem is not guaranteed, so the caller sorts.
 * An unsorted subject list would give the same delivery two different digests
 * on two machines.
 *
 * This used to say "symlinks not followed" while using `statSync`, which
 * follows them. It did, and three things broke:
 *
 *  - A delivery holding one symlink and no real file at all produced the
 *    byte-identical digest to the delivery holding the real file. Nothing
 *    downstream could tell the two apart.
 *  - Reproducibility, which is the property this whole module exists for. A
 *    link escaping the delivery root makes the digest a function of the
 *    *recomputing* machine's filesystem: the same archive, nothing edited,
 *    hashes differently elsewhere, or dies with a bare ENOENT naming a path
 *    the verifier has never heard of.
 *  - `docs/evidence.md` check 2, which no honest seller could then
 *    satisfy for that entry: an archived symlink carries a target path, not
 *    content bytes, so the file the verifier extracts cannot match the digest
 *    the statement committed to.
 *
 * Refusing rather than skipping is deliberate. A skipped link leaves the
 * subject list short, and a short subject list is the exact hole this module
 * was written to close: it fails check 2 later, somewhere less legible, having
 * looked fine here.
 *
 * The one symlink that is allowed is `target` itself, resolved once by
 * `buildSubject`. `--deliverable ./latest` where `latest -> ./v1.2.3` is a
 * normal thing to type, the caller named it explicitly, and the result is
 * unambiguous.
 */
function walkFiles(root: string, current = root, found: string[] = []): string[] {
  for (const entry of readdirSync(current)) {
    const full = path.join(current, entry);
    const stats = lstatSync(full);
    if (stats.isSymbolicLink()) {
      throw new Error(
        `${path.relative(root, full).split(path.sep).join("/")} is a symlink to ` +
          `${readlinkSync(full)}. A delivery commits to bytes, and a symlink is a ` +
          "path: it hashes to whatever the link resolves to on this machine, and " +
          "an archive of it carries no content for a verifier to check. Replace " +
          "it with the file it points at, or exclude it from the delivery."
      );
    }
    if (stats.isDirectory()) {
      walkFiles(root, full, found);
    } else if (stats.isFile()) {
      found.push(full);
    } else {
      // Sockets, fifos and devices. Skipping one would under-commit silently;
      // the delivery would carry a file the subject list does not name.
      throw new Error(
        `${path.relative(root, full).split(path.sep).join("/")} is not a regular ` +
          "file, so it has no contents to commit to. Exclude it from the delivery."
      );
    }
  }
  return found;
}

/**
 * Order two subject names by their UTF-8 bytes.
 *
 * JavaScript's `<` on strings compares UTF-16 code units, which is an order no
 * other common language reproduces by default. Python's `sorted`, Go's `<` and
 * Rust's `Ord` all give code-point or UTF-8-byte order, and those two agree with
 * each other because UTF-8 is order-preserving. They disagree with UTF-16
 * whenever a supplementary-plane character (an emoji, an astral CJK glyph, whose
 * first surrogate is U+D800-U+DBFF) is compared against one in U+E000-U+FFFF:
 *
 *   UTF-16 code unit : cafe.txt, U+1F600.txt, U+FF3F.txt
 *   UTF-8 byte       : cafe.txt, U+FF3F.txt, U+1F600.txt
 *
 * That matters here and nowhere else in this module, because `subject` is the
 * one ordered thing inside the hashed statement. RFC 8785 preserves array order
 * rather than imposing one, so two producers that disagree about the order
 * produce different `artifact_hash` values for byte-identical deliveries.
 *
 * `docs/evidence.md` promises the digest is reproducible "with no Sinetti
 * tooling", which is an invitation to write a producer in another language.
 * UTF-8 byte order is what those languages give for free, so it is the order the
 * schema names and the one implemented here. Reproduced before choosing it: the
 * same three files gave e1457dc8... from a JS producer and 15db280c... from a
 * Python one written from the schema alone.
 *
 * `Buffer.compare` is the byte comparison; nothing about it is locale-aware, and
 * that is deliberate. A locale-aware collation would make the digest depend on
 * the producer's environment.
 */
export function compareSubjectNames(a: string, b: string): number {
  return Buffer.compare(Buffer.from(a, "utf8"), Buffer.from(b, "utf8"));
}

/**
 * Build the subject list from a file or directory path.
 *
 * Names are POSIX-separated and relative to `root` so that the same delivery
 * hashes identically on Windows and on Unix, and so an absolute path from the
 * seller's machine never leaks into the commitment.
 */
export function buildSubject(target: string): EvidenceSubject[] {
  // Resolved once, here, so a symlinked delivery root is a convenience rather
  // than an ambiguity: everything below this point is a real path, and the walk
  // refuses every link it meets after it.
  const resolved = realpathSync(target);
  const stats = statSync(resolved);
  const files = stats.isDirectory() ? walkFiles(resolved) : [resolved];
  const root = stats.isDirectory() ? resolved : path.dirname(resolved);

  if (files.length === 0) {
    throw new Error(`no files found under ${target}; there is nothing to deliver`);
  }

  return files
    .map((file) => ({
      name: path.relative(root, file).split(path.sep).join("/"),
      digest: { sha256: hashFile(file) }
    }))
    .sort((a, b) => compareSubjectNames(a.name, b.name));
}

export function buildDeliveryStatement(params: {
  subject: EvidenceSubject[];
  repoCommitHash: string;
  runtimeHash: string;
  logsHash: string;
}): DeliveryStatement {
  if (params.subject.length === 0) {
    throw new Error("a delivery statement needs at least one subject file");
  }
  const names = params.subject.map((s) => s.name);
  const duplicate = names.find((name, index) => names.indexOf(name) !== index);
  if (duplicate) {
    throw new Error(`duplicate subject name ${duplicate}; each file appears once`);
  }
  for (const subject of params.subject) {
    if (!SHA256_HEX.test(subject.digest.sha256)) {
      throw new Error(
        `subject ${subject.name} carries ${subject.digest.sha256}, which is not ` +
          "64 lowercase hex characters of SHA-256"
      );
    }
  }

  return {
    _type: DELIVERY_STATEMENT_TYPE,
    predicateType: DELIVERY_PREDICATE_TYPE,
    subject: [...params.subject].sort((a, b) => compareSubjectNames(a.name, b.name)),
    predicate: {
      repo_commit_hash: params.repoCommitHash,
      runtime_hash: params.runtimeHash,
      logs_hash: params.logsHash
    }
  };
}

/**
 * The value that goes on chain, as bare hex.
 *
 * This is the envelope's `artifact_hash`. `docs/evidence.md` check 1 requires it
 * to equal the deal's on-chain `submitDelivery` hash.
 */
export function deliveryStatementDigest(statement: DeliveryStatement): string {
  return sha256Hex(canonicalJson(statement));
}

/**
 * The same 32 bytes in the form the contract takes.
 *
 * The envelope keeps bare hex because that is in-toto's digest convention;
 * `bytes32` needs the `0x`. Keeping the conversion in one function is what stops
 * the two representations drifting apart in callers.
 */
export function toBytes32(digestHex: string): string {
  if (!SHA256_HEX.test(digestHex)) {
    throw new Error(`${digestHex} is not 64 lowercase hex characters of SHA-256`);
  }
  return `0x${digestHex}`;
}
