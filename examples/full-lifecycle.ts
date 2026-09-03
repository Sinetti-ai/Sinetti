import hre from "hardhat";

import { assertCommittedOnChain, describeDelivery, exampleDelivery } from "./_evidence";
import {
  AMOUNT,
  BOND,
  assertEqual,
  deployLocal,
  exampleCriteria,
  fundAndOpen,
  postBond,
  send
} from "./_local";

const STATE_RELEASED = 5n;

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
  await send(
    context,
    "Buyer accepts Pass; escrow credits seller",
    context.escrow.connect(context.buyer).accept(dealId)
  );
  await send(
    context,
    "Seller withdraws released principal and returned bond",
    context.escrow.connect(context.seller)["withdraw(address)"](context.tokenAddress)
  );

  const deal = await context.escrow.getDeal(dealId);
  const sellerBalance = await context.token.balanceOf(context.sellerAddress);
  const escrowBalance = await context.token.balanceOf(context.escrowAddress);
  assertEqual(deal.state, STATE_RELEASED, "deal state");
  assertEqual(sellerBalance, AMOUNT + BOND, "seller balance");
  assertEqual(escrowBalance, 0n, "escrow balance");

  console.log(`\nSUCCESS: deal #${dealId} paid ${hre.ethers.formatUnits(AMOUNT, 6)} tEUR to seller after withdrawal; bond withdrawn.`);
}

main().catch((error: Error) => {
  console.error(error.message);
  process.exitCode = 1;
});
