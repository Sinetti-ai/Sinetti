import { createHash } from "node:crypto";
import {
  lstatSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  symlinkSync,
  writeFileSync
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { expect } from "chai";

import {
  DELIVERY_PREDICATE_TYPE,
  DELIVERY_STATEMENT_TYPE,
  buildDeliveryStatement,
  buildSubject,
  compareSubjectNames,
  canonicalJson,
  deliveryStatementDigest,
  hashFile,
  toBytes32
} from "../src/evidenceManifest";

const HEX64 = /^[0-9a-f]{64}$/;

function statementOver(subject: ReturnType<typeof buildSubject>) {
  return buildDeliveryStatement({
    subject,
    repoCommitHash: "a".repeat(40),
    runtimeHash: "b".repeat(64),
    logsHash: "c".repeat(64)
  });
}

describe("delivery evidence manifest", function () {
  let temp: string;

  beforeEach(function () {
    temp = mkdtempSync(join(tmpdir(), "evidence-manifest-"));
  });

  afterEach(function () {
    rmSync(temp, { recursive: true, force: true });
  });

  describe("canonicalJson", function () {
    it("sorts object keys so key order cannot change the digest", function () {
      expect(canonicalJson({ b: "2", a: "1" })).to.equal('{"a":"1","b":"2"}');
      expect(canonicalJson({ a: "1", b: "2" })).to.equal(canonicalJson({ b: "2", a: "1" }));
    });

    it("emits no insignificant whitespace", function () {
      expect(canonicalJson({ a: ["1", "2"] })).to.equal('{"a":["1","2"]}');
    });

    it("preserves array order, which carries meaning", function () {
      expect(canonicalJson(["b", "a"])).to.equal('["b","a"]');
    });

    it("rejects numbers rather than guessing at RFC 8785 number rules", function () {
      expect(() => canonicalJson({ size: 1 })).to.throw(/numbers are rejected/);
    });
  });

  describe("buildSubject", function () {
    it("hashes each file's contents, never an archive of them", function () {
      writeFileSync(join(temp, "a.txt"), "alpha");
      const [subject] = buildSubject(join(temp, "a.txt"));
      expect(subject.name).to.equal("a.txt");
      expect(subject.digest.sha256).to.equal(
        createHash("sha256").update("alpha").digest("hex")
      );
    });

    it("walks a directory and names files relative to it, POSIX style", function () {
      mkdirSync(join(temp, "src"));
      writeFileSync(join(temp, "src", "fee.ts"), "export const fee = 1;");
      writeFileSync(join(temp, "README.md"), "# delivery");
      expect(buildSubject(temp).map((s) => s.name)).to.deep.equal(["README.md", "src/fee.ts"]);
    });

    it("sorts by name so two machines produce the same subject list", function () {
      for (const name of ["c.txt", "a.txt", "b.txt"]) writeFileSync(join(temp, name), name);
      expect(buildSubject(temp).map((s) => s.name)).to.deep.equal(["a.txt", "b.txt", "c.txt"]);
    });

    it("refuses an empty directory: there is nothing to commit to", function () {
      expect(() => buildSubject(temp)).to.throw(/nothing to deliver/);
    });
  });

  // A symlink hashes to whatever it resolves to on the machine doing the
  // hashing, and an archive of one carries a path rather than bytes. Before
  // this block the walk used statSync, which follows links, while the comment
  // above it claimed the opposite.
  // RFC 8785 preserves array order rather than imposing one, so this is the one
  // ordered thing inside the hashed statement whose order Sinetti chooses. A
  // producer in another language that disagrees computes a different
  // artifact_hash for a byte-identical delivery, and docs/evidence.md
  // invites exactly that producer.
  describe("subject order is UTF-8 bytes, not JavaScript's default", function () {
    // Supplementary plane (first surrogate U+D800-U+DBFF) against U+E000-U+FFFF
    // is the whole disagreement. Everything else sorts the same either way.
    const ASTRAL = "\u{1F600}.txt";
    const HIGH_BMP = "\uFF3F.txt";
    const ASCII = "cafe.txt";

    // Anchor. If these two names ever stop distinguishing the two orderings,
    // every assertion below passes without testing anything, and the reason is
    // in the test's own input rather than in the code under test.
    it("uses names the two orderings actually disagree about", function () {
      const utf16 = [ASCII, ASTRAL, HIGH_BMP].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
      const utf8 = [ASCII, ASTRAL, HIGH_BMP].sort(compareSubjectNames);
      expect(utf8, "the chosen names no longer distinguish the orderings").to.not.deep.equal(
        utf16
      );
      expect(utf16).to.deep.equal([ASCII, ASTRAL, HIGH_BMP]);
      expect(utf8).to.deep.equal([ASCII, HIGH_BMP, ASTRAL]);
    });

    it("walks a directory into UTF-8 byte order", function () {
      for (const name of [ASTRAL, HIGH_BMP, ASCII]) writeFileSync(join(temp, name), name);
      expect(buildSubject(temp).map((entry) => entry.name)).to.deep.equal([
        ASCII,
        HIGH_BMP,
        ASTRAL
      ]);
    });

    it("re-sorts a caller-supplied subject list the same way", function () {
      const supplied = [ASTRAL, HIGH_BMP, ASCII].map((name) => ({
        name,
        digest: { sha256: "a".repeat(64) }
      }));
      expect(statementOver(supplied).subject.map((entry) => entry.name)).to.deep.equal([
        ASCII,
        HIGH_BMP,
        ASTRAL
      ]);
    });

    it("agrees with the order another language's sort would produce", function () {
      // Node's Intl-free code-point iteration is what Python's sorted() and
      // Go's `<` both reproduce, because UTF-8 is order-preserving.
      const byCodePoint = [ASTRAL, HIGH_BMP, ASCII].sort((a, b) => {
        const left = [...a].map((c) => c.codePointAt(0) as number);
        const right = [...b].map((c) => c.codePointAt(0) as number);
        for (let i = 0; i < Math.min(left.length, right.length); i += 1) {
          if (left[i] !== right[i]) return left[i] - right[i];
        }
        return left.length - right.length;
      });
      expect([ASTRAL, HIGH_BMP, ASCII].sort(compareSubjectNames)).to.deep.equal(byCodePoint);
    });

    it("gives ASCII deliveries the order they already had", function () {
      for (const name of ["c.txt", "a.txt", "b.txt"]) writeFileSync(join(temp, name), name);
      expect(buildSubject(temp).map((entry) => entry.name)).to.deep.equal([
        "a.txt",
        "b.txt",
        "c.txt"
      ]);
    });
  });

  describe("buildSubject refuses symlinks inside the delivery", function () {
    /**
     * Anchor. Every assertion below is "this throws", and a filesystem that
     * cannot make a symlink at all (Windows without developer mode, some CI
     * images) would throw for an unrelated reason and look like a pass.
     */
    function linkTo(target: string, at: string): void {
      symlinkSync(target, at);
      expect(lstatSync(at).isSymbolicLink(), `${at} was not created as a symlink`).to.equal(
        true
      );
    }

    it("refuses a link to a file inside the root, naming the link and its target", function () {
      writeFileSync(join(temp, "real.txt"), "alpha");
      linkTo(join(temp, "real.txt"), join(temp, "alias.txt"));
      expect(() => buildSubject(temp)).to.throw(/alias\.txt is a symlink to .*real\.txt/);
    });

    it("refuses a link that escapes the delivery root", function () {
      const outside = mkdtempSync(join(tmpdir(), "evidence-manifest-outside-"));
      try {
        writeFileSync(join(outside, "secret.txt"), "not part of the delivery");
        writeFileSync(join(temp, "real.txt"), "alpha");
        linkTo(join(outside, "secret.txt"), join(temp, "escape.txt"));
        expect(() => buildSubject(temp)).to.throw(/escape\.txt is a symlink to/);
      } finally {
        rmSync(outside, { recursive: true, force: true });
      }
    });

    it("refuses a link to a directory", function () {
      mkdirSync(join(temp, "src"));
      writeFileSync(join(temp, "src", "fee.ts"), "export const fee = 1;");
      linkTo(join(temp, "src"), join(temp, "current"));
      expect(() => buildSubject(temp)).to.throw(/current is a symlink to/);
    });

    it("refuses a link nested below the root, naming its POSIX path", function () {
      mkdirSync(join(temp, "dist"));
      writeFileSync(join(temp, "dist", "app.js"), "1");
      linkTo(join(temp, "dist", "app.js"), join(temp, "dist", "app.latest.js"));
      expect(() => buildSubject(temp)).to.throw(/dist\/app\.latest\.js is a symlink/);
    });

    // The finding that started this: a delivery with no real bytes in it at all
    // used to produce the same digest as the delivery holding the real file.
    it("refuses a delivery whose only entry is a link, rather than hashing the target", function () {
      const source = mkdtempSync(join(tmpdir(), "evidence-manifest-source-"));
      try {
        writeFileSync(join(source, "report.txt"), "the actual delivered bytes");
        const real = mkdtempSync(join(tmpdir(), "evidence-manifest-real-"));
        writeFileSync(join(real, "report.txt"), "the actual delivered bytes");
        linkTo(join(source, "report.txt"), join(temp, "report.txt"));
        expect(buildSubject(real)).to.have.length(1);
        expect(() => buildSubject(temp)).to.throw(/report\.txt is a symlink to/);
        rmSync(real, { recursive: true, force: true });
      } finally {
        rmSync(source, { recursive: true, force: true });
      }
    });

    // 19 levels of two links each is 2^18 subjects from 4 KB on disk. No ELOOP
    // fires, because the shape is a directed graph rather than a cycle.
    it("refuses a symlink fan-out instead of expanding it", function () {
      let current = temp;
      for (let level = 0; level < 12; level += 1) {
        const next = join(current, "d");
        mkdirSync(next);
        writeFileSync(join(next, "leaf.txt"), String(level));
        linkTo(next, join(current, "a"));
        linkTo(next, join(current, "b"));
        current = next;
      }
      expect(() => buildSubject(temp)).to.throw(/is a symlink to/);
    });

    // The one link that is allowed. `--deliverable ./latest` where
    // `latest -> ./v1.2.3` is normal, the caller named it, and resolving it
    // once leaves no ambiguity below.
    it("resolves a symlinked delivery root and hashes the real directory", function () {
      const real = join(temp, "v1.2.3");
      mkdirSync(real);
      writeFileSync(join(real, "report.txt"), "alpha");
      const alias = join(temp, "latest");
      linkTo(real, alias);
      expect(buildSubject(alias)).to.deep.equal(buildSubject(real));
      expect(buildSubject(alias).map((entry) => entry.name)).to.deep.equal(["report.txt"]);
    });
  });

  describe("deliveryStatementDigest", function () {
    it("produces an in-toto Statement v1 shape", function () {
      writeFileSync(join(temp, "a.txt"), "alpha");
      const statement = statementOver(buildSubject(temp));
      expect(statement._type).to.equal(DELIVERY_STATEMENT_TYPE);
      expect(statement.predicateType).to.equal(DELIVERY_PREDICATE_TYPE);
    });

    it("is stable across runs over identical content", function () {
      writeFileSync(join(temp, "a.txt"), "alpha");
      writeFileSync(join(temp, "b.txt"), "beta");
      const first = deliveryStatementDigest(statementOver(buildSubject(temp)));

      const other = mkdtempSync(join(tmpdir(), "evidence-manifest-b-"));
      writeFileSync(join(other, "b.txt"), "beta");
      writeFileSync(join(other, "a.txt"), "alpha");
      const second = deliveryStatementDigest(statementOver(buildSubject(other)));
      rmSync(other, { recursive: true, force: true });

      expect(first).to.equal(second);
      expect(first).to.match(HEX64);
    });

    it("changes when any delivered byte changes", function () {
      writeFileSync(join(temp, "a.txt"), "alpha");
      const before = deliveryStatementDigest(statementOver(buildSubject(temp)));
      writeFileSync(join(temp, "a.txt"), "alphb");
      expect(deliveryStatementDigest(statementOver(buildSubject(temp)))).to.not.equal(before);
    });

    it("changes when a file is added, so a partial delivery cannot reuse a digest", function () {
      writeFileSync(join(temp, "a.txt"), "alpha");
      const before = deliveryStatementDigest(statementOver(buildSubject(temp)));
      writeFileSync(join(temp, "b.txt"), "beta");
      expect(deliveryStatementDigest(statementOver(buildSubject(temp)))).to.not.equal(before);
    });

    it("changes when the predicate changes, binding commit and runtime to the delivery", function () {
      writeFileSync(join(temp, "a.txt"), "alpha");
      const subject = buildSubject(temp);
      const base = deliveryStatementDigest(statementOver(subject));
      const moved = deliveryStatementDigest(
        buildDeliveryStatement({
          subject,
          repoCommitHash: "d".repeat(40),
          runtimeHash: "b".repeat(64),
          logsHash: "c".repeat(64)
        })
      );
      expect(moved).to.not.equal(base);
    });

    it("rejects a subject digest that is not SHA-256 hex", function () {
      expect(() =>
        buildDeliveryStatement({
          subject: [{ name: "a.txt", digest: { sha256: "not-a-hash" } }],
          repoCommitHash: "",
          runtimeHash: "",
          logsHash: ""
        })
      ).to.throw(/SHA-256/);
    });

    it("rejects a duplicated subject name", function () {
      const digest = createHash("sha256").update("x").digest("hex");
      expect(() =>
        buildDeliveryStatement({
          subject: [
            { name: "a.txt", digest: { sha256: digest } },
            { name: "a.txt", digest: { sha256: digest } }
          ],
          repoCommitHash: "",
          runtimeHash: "",
          logsHash: ""
        })
      ).to.throw(/duplicate subject name/);
    });
  });

  describe("toBytes32", function () {
    it("is the same 32 bytes the envelope carries, with the 0x the contract needs", function () {
      writeFileSync(join(temp, "a.txt"), "alpha");
      const digest = deliveryStatementDigest(statementOver(buildSubject(temp)));
      expect(toBytes32(digest)).to.equal(`0x${digest}`);
      expect(toBytes32(digest)).to.have.lengthOf(66);
    });

    it("refuses anything that is not a SHA-256 digest", function () {
      expect(() => toBytes32("0xdeadbeef")).to.throw(/SHA-256/);
    });
  });

  describe("hashFile", function () {
    it("matches sha256sum, so a seller needs no Sinetti tooling to check it", function () {
      writeFileSync(join(temp, "log.txt"), "3 passing\n");
      expect(hashFile(join(temp, "log.txt"))).to.equal(
        createHash("sha256").update("3 passing\n").digest("hex")
      );
    });
  });
});
