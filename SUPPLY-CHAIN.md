# Supply chain

This repository keeps its dependency surface reviewable and treats dependency
changes as release changes. This review covers the initial public-release tree
and includes the advisory remediation described below; it was performed on 2
September 2026. Before publication, the same checks must run against the exact
commit being published. This is evidence about one reviewed tree, not a claim
that future installs are safe.

## What ships and what builds

The contract source has one direct runtime dependency:

| Dependency | Purpose | Pin |
|---|---|---|
| `@openzeppelin/contracts` | ERC-20, signature, and contract security primitives | exact `5.0.2` |

The manifest classifies the JavaScript and TypeScript toolchain as
`devDependencies` because the package is private and is not published to npm.
That label does not mean the entire tree is test-only: Ethers, Ajv,
TypeScript/`ts-node`, and their transitives are executed when an operator runs
the reference verifier or arbitration commands. Hardhat, its toolbox, Chai, and
the type packages support compilation and testing.

The supported runtime is Node 22, and the direct `@types/node` development
dependency is aligned to that major version. Some tools may retain their own
nested Node type version according to their published dependency ranges.

The current lockfile contains 579 package entries. Every resolved tarball has an
integrity hash and every resolved source uses `https://registry.npmjs.org/`; there
are no Git, file, or arbitrary URL package sources.

## Installation scripts

Three locked transitive packages declare installation scripts:

| Package | Version | Why present |
|---|---:|---|
| `fsevents` | `2.3.3` | Optional filesystem events support on macOS |
| `keccak` | `3.0.4` | Native hashing dependency in the Ethereum toolchain |
| `secp256k1` | `4.0.4` | Native elliptic-curve dependency in the Ethereum toolchain |

`scripts/check-dependencies.mjs` pins this allowlist by package and version. A new
or changed installation script fails CI until it is reviewed here.

## Reviewed advisory remediation

Release preparation identified transitive `fast-uri@3.1.3` inside affected
ranges for published high-severity URI parsing advisories. The manifest now
overrides Ajv's compatible range to `fast-uri@3.1.7`, and the lockfile records
that repaired version. The tarball URL and integrity value must still be
exercised by `npm ci`, and the full test suite and live advisory check must pass
on the exact release commit before publication.

- [GHSA-qw65-cvwx-89v3](https://github.com/fastify/fast-uri/security/advisories/GHSA-qw65-cvwx-89v3)
- [GHSA-58mr-gqgx-xq4g](https://github.com/fastify/fast-uri/security/advisories/GHSA-58mr-gqgx-xq4g)

The repository CI runs `npm audit --package-lock-only --audit-level=high`. This
queries the registry's current advisory database and is therefore time-sensitive;
the result must be read from the run for the exact release commit.

## License review

Lockfile metadata is predominantly MIT, ISC, BSD, Apache-2.0, and similarly
permissive licensing. The metadata also contains one LGPL-3.0 package
(`web3-utils@1.10.4`), one Python-2.0 package (`argparse@2.0.1`), and seven
packages with no license field in the lockfile. The manifest labels these as
development dependencies, but that classification does not by itself establish
whether a package is executed by an operator or distributed in a particular
artifact. Upstream license files require review before packaging or
redistributing a JavaScript tool bundle. Lockfile metadata is an inventory aid,
not a substitute for reading the packages' license texts.

## Enforced controls

- `package-lock.json` is committed; CI installs with `npm ci`.
- `scripts/check-dependencies.mjs` rejects missing integrity hashes, non-registry
  package sources, and unreviewed installation scripts.
- CI checks current high-severity npm advisories from the lockfile.
- GitHub Actions are pinned by commit SHA; the Foundry toolchain, Python runtime,
  and top-level Slither version are pinned.
- The publication check rejects local paths and private-workspace references.
- Gitleaks is downloaded at a fixed version and verified by SHA-256 before use.

Dependency changes must include the regenerated lockfile, an update to this record
when the reviewed surface changes, and passing contract, client, example, schema,
static-analysis, publication, and advisory checks.

This inventory and the deterministic policy script cover the npm lockfile.
Slither runs in its own job with a read-only GitHub token, no persisted checkout
credential, an exact Python runtime, and an exact top-level Slither version. The
job is not sandboxed from its checkout or network. Its transitive Python
dependencies are not currently locked with hashes, so the complete CI toolchain
is not fully reproducible. Foundry, Python, GitHub Actions, and PyPI packages
remain upstream executable inputs despite their version or commit pins.

## Limits

Integrity hashes detect changed downloads; they do not prove that an upstream
package is trustworthy. Advisory databases cover disclosed vulnerabilities, not
unknown defects or malicious maintainers. CI pinning and review reduce risk but do
not replace minimizing dependencies or reviewing code that handles keys, evidence,
signatures, and transactions.
