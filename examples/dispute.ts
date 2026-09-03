import hre from "hardhat";

import {
  assertCommittedOnChain,
  describeDelivery,
  exampleDelivery,
  tamperedDelivery
} from "./_evidence";
import {
  AMOUNT,
  BOND,
  CHALLENGER_BOND,
  assertEqual,
  deployLocal,
  exampleCriteria,
  fundAndOpen,
  postBond,
  send
} from "./_local";

const STATE_REFUNDED = 6n;
const OUTCOME_REFUND = 2n;

async function main(): Promise<void> {
  const context = await deployLocal();
  const criteria = exampleCriteria();
  const delivery = exampleDelivery();
  console.log("Seller hashes the delivery in examples/delivery/");
  console.log(describeDelivery(delivery));
  const dealId = await fundAndOpen(context, criteria, 3600n);
  await postBond(context, dealId);
  await send(
    context,
    "Seller submits delivery evidence",
    context.escrow.connect(context.seller).submitDelivery(
      dealId,
      delivery.evidenceHash
    )
  );
  console.log(
    `  read back from chain: ${await assertCommittedOnChain(context.escrow, dealId)}`
  );
  await send(
    context,
    "Verifier records Pass; buyer challenge window opens",
    context.escrow.connect(context.verifier).recordVerification(dealId, 1)
  );
  // Why the buyer challenges. The contract stored the seller's 32 bytes and will
  // never look at them again, so this comparison happens entirely off chain,
  // between whoever holds the files. It is only worth running because the stored
  // value commits to the delivered bytes: recomputing it over the copy the buyer
  // actually received either reproduces the on-chain value or does not.
  const received = tamperedDelivery(delivery);
  console.log("\nBuyer recomputes the digest over the copy it received");
  console.log(`  committed on chain: ${delivery.evidenceHash}`);
  console.log(`  buyer's copy:       ${received.evidenceHash}`);
  console.log(`  difference:         ${received.change}`);
  if (received.evidenceHash === delivery.evidenceHash) {
    throw new Error(
      "an edited artifact produced the committed digest, so the evidence hash " +
        "distinguishes nothing and this example is showing a check that cannot fail"
    );
  }

  await send(
    context,
    "Mint challenger-bond tokens to buyer",
    context.token.mint(context.buyerAddress, CHALLENGER_BOND)
  );
  await send(
    context,
    "Buyer approves challenger bond",
    context.token.connect(context.buyer).approve(context.escrowAddress, CHALLENGER_BOND)
  );
  await send(
    context,
    "Buyer challenges the Pass, posting the challenger bond",
    context.escrow.connect(context.buyer).challenge(dealId)
  );
  await send(
    context,
    "Arbitrator contract rules Refund; loser pays - seller bond slashed, challenger bond returned inside buyer credit",
    context.arbitrator.rule(context.escrowAddress, dealId, OUTCOME_REFUND)
  );
  await send(
    context,
    "Buyer withdraws principal, slashed bond, and returned challenger bond",
    context.escrow.connect(context.buyer)["withdraw(address)"](context.tokenAddress)
  );

  const deal = await context.escrow.getDeal(dealId);
  assertEqual(deal.state, STATE_REFUNDED, "deal state");
  assertEqual(
    await context.token.balanceOf(context.buyerAddress),
    AMOUNT + BOND + CHALLENGER_BOND,
    "buyer refund"
  );
  assertEqual(await context.token.balanceOf(context.escrowAddress), 0n, "escrow balance");
  console.log(`\nSUCCESS: deal #${dealId} refunded by arbitrator ruling after buyer challenge; seller bond slashed to buyer, challenger bond returned.`);
}

main().catch((error: Error) => {
  console.error(error.message);
  process.exitCode = 1;
});
