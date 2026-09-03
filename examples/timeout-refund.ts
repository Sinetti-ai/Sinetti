import { time } from "@nomicfoundation/hardhat-network-helpers";

import { assertEqual, deployLocal, exampleCriteria, fundAndOpen, postBond, send } from "./_local";

const STATE_REFUNDED = 6n;

async function main(): Promise<void> {
  const context = await deployLocal();
  const criteria = exampleCriteria();
  const dealId = await fundAndOpen(context, criteria, 300n);
  await postBond(context, dealId);

  const deadline = (await context.escrow.getDeal(dealId)).deadline;
  await time.increaseTo(deadline + 1n);
  console.log("\nHardhat advances past the deadline without wall-clock waiting");
  await send(
    context,
    "Any account claims the timeout backstop",
    context.escrow.connect(context.deployer).claimTimeout(dealId)
  );
  await send(
    context,
    "Buyer withdraws refunded principal",
    context.escrow.connect(context.buyer)["withdraw(address)"](context.tokenAddress)
  );
  await send(
    context,
    "Seller withdraws returned bond",
    context.escrow.connect(context.seller)["withdraw(address)"](context.tokenAddress)
  );

  const deal = await context.escrow.getDeal(dealId);
  assertEqual(deal.state, STATE_REFUNDED, "deal state");
  assertEqual(await context.token.balanceOf(context.escrowAddress), 0n, "escrow balance");
  console.log(`\nSUCCESS: deal #${dealId} timed out; buyer principal and seller bond withdrawn.`);
}

main().catch((error: Error) => {
  console.error(error.message);
  process.exitCode = 1;
});
