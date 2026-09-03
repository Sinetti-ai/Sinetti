# Threat model

This is the minimum threat model for the unaudited implementation and future
public-testnet evaluation.

| Boundary | Main failure | Mitigation in this repository | Residual risk |
|---|---|---|---|
| Buyer/seller keys | Unauthorized terms or lifecycle action | Exact EIP-712 terms and role checks | Compromised wallets remain authoritative |
| Settlement token | Fee, rebase, callback, or balance mismatch | Policy caps and exact withdrawal accounting | Token behavior still requires review |
| Verifier | False or unavailable verdict | Per-deal selection, committed inputs, challenge window, `Inconclusive` | A dishonest verifier can force arbitration |
| Artifact intake | Traversal, substitution, resource exhaustion | Push model, root containment, complete per-file hashes, no URL fetch | Hosted upload limits and isolation remain operator duties |
| Arbitrator | Wrong proposal, officer compromise, stalled push | Deal binding, override window, separate officer, permissionless push, lapse fallback | Agent and officer collusion controls the ruling |
| Timing | Review ladder expires before push | Signed windows and documented operator constraint | Deployment configuration and congestion can still delay transactions |
| Operator host | Key or private evidence disclosure | Secrets excluded from Git; separate keys; unsigned officer calldata | Deployment-specific hardening is not supplied as a guarantee |

Pause blocks new deals only. It does not stop clocks or prevent already-open
deals from progressing. No private evidence should be placed on-chain; hashes
and transaction metadata are permanent and public.
