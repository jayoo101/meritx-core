/**
 * set-operator.js — Must be run with the TREASURY wallet's private key.
 *
 * Usage:
 *   1. In .env, set PRIVATE_KEY to the treasury wallet's private key
 *   2. npx hardhat run scripts/set-operator.js --network baseMainnet
 */
const hre = require("hardhat");

async function main() {
  const [signer] = await hre.ethers.getSigners();
  console.log("Caller:", signer.address);

  const factoryAddress = process.env.FACTORY_ADDRESS;
  const operatorAddress = process.env.OPERATOR_ADDRESS;

  if (!factoryAddress) throw new Error("Set FACTORY_ADDRESS in .env");
  if (!operatorAddress) throw new Error("Set OPERATOR_ADDRESS in .env");

  const factory = await hre.ethers.getContractAt("MeritXFactory", factoryAddress, signer);

  const treasury = await factory.platformTreasury();
  console.log("On-chain treasury:", treasury);

  if (signer.address.toLowerCase() !== treasury.toLowerCase()) {
    throw new Error(
      `Signer ${signer.address} is NOT the treasury (${treasury}). ` +
      "Switch PRIVATE_KEY in .env to the treasury wallet."
    );
  }

  const currentOp = await factory.operator();
  console.log("Current operator:", currentOp);
  console.log("Setting operator to:", operatorAddress);

  const tx = await factory.setOperator(operatorAddress);
  await tx.wait();

  const newOp = await factory.operator();
  console.log("\n✅ Operator updated:", newOp);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
