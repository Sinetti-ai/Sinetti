import { expect } from "chai";
import { Interface } from "ethers";

import {
  arbitrationCaseHash,
  assertCaseMatchesDeal,
  assertCaseMatchesProposal,
  prepareOfficerOverturn,
  type ArbitrationCase
} from "../src/arbitrator";
import { CONSOLE_ARBITRATOR_ABI } from "../src/dealLifecycle";

const caseFile: ArbitrationCase = {
  version: "sinetti-arbitration-case/0.1",
  chain_id: "31337",
  escrow: "0x0000000000000000000000000000000000000001",
  arbitrator: "0x0000000000000000000000000000000000000002",
  deal_id: "7",
  terms_hash: `0x${"11".repeat(32)}`,
  evidence_hash: `0x${"22".repeat(32)}`,
  proposed_outcome: "refund",
  rationale: "The committed artifact fails the signed acceptance schema.",
  decided_at: "2026-09-01T00:00:00Z"
};

describe("arbitration operator records", function () {
  it("produces stable case hashes and officer-wallet calldata", function () {
    expect(arbitrationCaseHash(caseFile)).to.match(/^0x[0-9a-f]{64}$/);
    const prepared = prepareOfficerOverturn(caseFile);
    expect(prepared.to).to.equal(caseFile.arbitrator);
    const decoded = new Interface(CONSOLE_ARBITRATOR_ABI).decodeFunctionData(
      "overturn",
      prepared.data
    );
    expect(decoded[0]).to.equal(7n);
    expect(decoded[1]).to.equal(2n);
  });

  it("rejects blank rationale and non-RFC decision timestamps", function () {
    expect(() => arbitrationCaseHash({ ...caseFile, rationale: "   " })).to.throw(/rationale/);
    expect(() =>
      arbitrationCaseHash({ ...caseFile, decided_at: "September 1, 2026" })
    ).to.throw(/RFC 3339/);
  });

  it("binds push to the standing proposal and a closed override window", function () {
    const proposedAt = BigInt(Math.floor(Date.parse(caseFile.decided_at) / 1_000) + 10);
    const proposal = { outcome: 2n, proposedAt, pushed: false };
    expect(() => assertCaseMatchesProposal(caseFile, proposal, proposedAt + 300n, 300n)).not.to.throw();
    expect(() => assertCaseMatchesProposal(caseFile, { ...proposal, outcome: 1n }, proposedAt + 300n, 300n)).to.throw(/standing/);
    expect(() => assertCaseMatchesProposal(caseFile, proposal, proposedAt + 299n, 300n)).to.throw(/still open/);
    expect(() => assertCaseMatchesProposal(caseFile, { ...proposal, pushed: true }, proposedAt + 300n, 300n)).to.throw(/already/);
  });

  it("binds a decision to the RPC chain and exact disputed deal", function () {
    const deal = {
      arbitrator: caseFile.arbitrator,
      termsHash: caseFile.terms_hash,
      evidenceHash: caseFile.evidence_hash,
      state: 4n
    };
    expect(() => assertCaseMatchesDeal(caseFile, deal, 31337n)).not.to.throw();
    expect(() => assertCaseMatchesDeal(caseFile, { ...deal, state: 3n }, 31337n)).to.throw(
      /not disputed/
    );
    expect(() => assertCaseMatchesDeal(caseFile, deal, 11155111n)).to.throw(/chain_id/);
    expect(() =>
      assertCaseMatchesDeal(
        caseFile,
        { ...deal, evidenceHash: `0x${"33".repeat(32)}` },
        31337n
      )
    ).to.throw(/evidence_hash/);
  });
});
