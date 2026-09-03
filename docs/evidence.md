# Delivery evidence

The escrow stores one opaque `bytes32` evidence hash. It does not fetch a file,
run acceptance checks, or decide whether a delivery is correct. The selected
verifier and, after a challenge, the selected arbitrator interpret the committed
evidence under the signed terms.

The local example builds an in-toto Statement v1-shaped document over the bytes
in `examples/delivery/`. Its subjects list every regular file and SHA-256 digest;
its predicate commits to the source revision, runtime fingerprint, and log hash.
The statement is serialized canonically and hashed with SHA-256.

Three checks define the reference behavior:

1. the statement's SHA-256 equals the `bytes32` submitted on chain;
2. every subject name and digest matches the delivered regular files, with
   symlinks and special files rejected; and
3. the committed revision, runtime, and log hashes match the execution the deal
   terms require.

Run the local examples to exercise the first two properties. To build a statement
for another synthetic delivery:

```bash
npm run evidence:hash -- \
  --deliverable ./out \
  --repo-commit "$(git rev-parse HEAD)" \
  --runtime package-lock.json \
  --logs ./out/test.log \
  --out statement.json
```

The command prints both bare hexadecimal and `0x`-prefixed forms. Keeping or
sharing evidence may expose its contents or metadata; only the hash belongs on
chain. This tooling is reference behavior, not a hosted verifier.
