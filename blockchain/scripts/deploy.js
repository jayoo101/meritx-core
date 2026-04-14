const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  if (!deployer) {
    throw new Error(
      "No deployer signer found. Ensure PRIVATE_KEY is set in .env and the selected network has accounts configured."
    );
  }
  console.log("Deploying contracts with the account:", deployer.address);

  const backendSigner    = process.env.BACKEND_SIGNER_ADDRESS;
  const positionManager  = process.env.UNISWAP_POSITION_MANAGER;
  const wethAddress      = process.env.WETH_ADDRESS;
  const treasuryAddress  = process.env.PLATFORM_TREASURY;
  const emergencyAdmin   = process.env.EMERGENCY_ADMIN || '0x0000000000000000000000000000000000000000';
  const operatorAddress  = process.env.OPERATOR_ADDRESS || '0x0000000000000000000000000000000000000000';

  if (!backendSigner)   throw new Error("Set BACKEND_SIGNER_ADDRESS in .env");
  if (!positionManager) throw new Error("Set UNISWAP_POSITION_MANAGER in .env");
  if (!wethAddress)     throw new Error("Set WETH_ADDRESS in .env");
  if (!treasuryAddress) throw new Error("Set PLATFORM_TREASURY in .env");

  console.log("\nDeploying MeritX v8.1 (Mainnet Genesis)...");
  console.log("  Backend signer       :", backendSigner);
  console.log("  Position Manager     :", positionManager);
  console.log("  WETH                 :", wethAddress);
  console.log("  Platform Treasury    :", treasuryAddress);
  console.log("  Emergency Admin      :", emergencyAdmin);
  console.log("  Operator (hot-wallet):", operatorAddress);

  const MeritXFactory = await hre.ethers.getContractFactory("MeritXFactory", deployer);

  const factory = await MeritXFactory.deploy(
    backendSigner, positionManager, wethAddress, treasuryAddress, emergencyAdmin
  );
  await factory.waitForDeployment();

  const factoryAddress = await factory.getAddress();
  console.log("\n  ✅ MeritXFactory deployed:", factoryAddress);

  if (operatorAddress !== '0x0000000000000000000000000000000000000000') {
    if (deployer.address.toLowerCase() === treasuryAddress.toLowerCase()) {
      const tx = await factory.setOperator(operatorAddress);
      await tx.wait();
      console.log("  ✅ Operator set to:", operatorAddress);
    } else {
      console.log("  ⚠️  Deployer is not treasury — cannot call setOperator() here.");
      console.log("     Run: npx hardhat run scripts/set-operator.js --network baseMainnet");
    }
  } else {
    console.log("  ⚠️  No OPERATOR_ADDRESS set — skipping setOperator()");
  }

  console.log("\n--- Post-deploy checklist ---");
  console.log("1. Set NEXT_PUBLIC_FACTORY_ADDRESS=" + factoryAddress + " in frontend .env.local");
  console.log("2. Set NEXT_PUBLIC_SIGNER_ADDRESS=" + backendSigner + " in frontend .env.local");
  console.log("3. Set NEXT_PUBLIC_TREASURY_WALLET=" + treasuryAddress + " in frontend .env.local");
  console.log("4. Restart the Next.js dev server to pick up new env vars");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
