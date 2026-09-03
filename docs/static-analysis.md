# Static analysis

CI runs Slither 0.11.6 against the Hardhat build of the deployable contracts.
High and medium findings fail the build except for these narrowly matched
accepted findings:

- OpenZeppelin `ECDSA.tryRecover` returns an optional error argument that
  `SinettiEscrowV04._isValidSignature` deliberately ignores after checking the
  recovered address and recovery status.
- Slither reports the post-transfer balance assertions in the shared private
  `_withdraw` helper as two `reentrancy-balance` findings. Both external
  withdrawal overloads are protected by `nonReentrant`, state and liabilities
  are reduced before transfer, and the malicious-token tests exercise the
  guard. The matcher is limited to that helper, transfer, and named balance
  reads.

Low and informational findings remain visible in the job output.

Mocks, dependencies, and Foundry test scaffolding are excluded from the scan.
An accepted finding is deliberately matched by detector, impact, function, and
call; changes to that finding or any new high/medium finding fail CI.
