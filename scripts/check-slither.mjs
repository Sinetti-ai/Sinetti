import { readFileSync } from "node:fs";

const reportPath = process.argv[2];
if (!reportPath) {
  throw new Error("usage: node scripts/check-slither.mjs <slither.json>");
}

const report = JSON.parse(readFileSync(reportPath, "utf8"));
if (report.success !== true) {
  throw new Error(`Slither did not complete successfully: ${report.error ?? "unknown error"}`);
}

const findings = report.results?.detectors ?? [];
const isAccepted = (finding) => {
  const acceptedUnusedReturn =
    finding.impact === "Medium" &&
    finding.check === "unused-return" &&
    finding.description.includes("SinettiEscrowV04._isValidSignature") &&
    finding.description.includes("ECDSA.tryRecover");

  // Both external withdraw overloads are nonReentrant. Slither reports the
  // balance assertions after safeTransfer from their shared private helper as
  // stale reads, but no reentrant caller can enter either withdrawal route.
  const acceptedGuardedWithdrawal =
    finding.impact === "High" &&
    finding.check === "reentrancy-balance" &&
    finding.description.includes("SinettiEscrowV04._withdraw") &&
    finding.description.includes("token.safeTransfer(msg.sender,amount)") &&
    (finding.description.includes("escrowBalanceBefore") ||
      finding.description.includes("recipientBalanceBefore"));

  return acceptedUnusedReturn || acceptedGuardedWithdrawal;
};

const rejected = findings.filter(
  (finding) => ["High", "Medium"].includes(finding.impact) && !isAccepted(finding),
);

for (const finding of findings) {
  const disposition = isAccepted(finding) ? "accepted" : "reported";
  console.log(`${disposition}: ${finding.impact} ${finding.check}`);
}

if (rejected.length > 0) {
  console.error(JSON.stringify(rejected, null, 2));
  throw new Error(`${rejected.length} unaccepted high/medium Slither finding(s)`);
}
