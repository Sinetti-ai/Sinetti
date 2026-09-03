import { readFileSync } from "node:fs";

import { expect } from "chai";

import { OUTCOME, STATE, VERDICT } from "../src/dealClient";

const SOURCE = "contracts/SinettiEscrowV04.sol";

function solidityEnum(name: string): string[] {
  const source = readFileSync(SOURCE, "utf8");
  const match = new RegExp(`enum\\s+${name}\\s*\\{([^}]*)\\}`).exec(source);
  if (!match) throw new Error(`no enum ${name} in ${SOURCE}`);
  return match[1]
    .split(",")
    .map((entry) => entry.replace(/\/\/.*$/gm, "").trim())
    .filter(Boolean);
}

describe("hand-kept mirrors of SinettiEscrowV04 enums", function () {
  const cases: Array<{ name: string; mirror: Record<string, number> }> = [
    { name: "State", mirror: STATE },
    { name: "Verdict", mirror: VERDICT },
    { name: "Outcome", mirror: OUTCOME }
  ];

  for (const { name, mirror } of cases) {
    it(`mirrors every ${name} value, in order`, function () {
      const declared = solidityEnum(name);
      expect(Object.keys(mirror)).to.deep.equal(declared);
      declared.forEach((member, index) => {
        expect(mirror[member], `${name}.${member}`).to.equal(index);
      });
    });
  }
});
