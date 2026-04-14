const hre = require("hardhat");
const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  
  const FACTORY_ADDRESS = "0x2E4A18520E1Ca4B002977E0f1f14202B9043FbD1";
  const factory = await ethers.getContractAt("MeritXFactory", FACTORY_ADDRESS);

  console.log("====================================================");
  console.log("  MeritX v6.0 Solo Stress Test (Base Sepolia)");
  console.log(`  Deployer account: ${deployer.address}`);
  console.log("====================================================\n");

  let projectAddress;

  // --- Test A: Verify project launch ---
  console.log("[Test A] Verifying project launch logic...");
  try {
    console.log("  Simulating via staticCall...");
    projectAddress = await factory.launchNewProject.staticCall(
      "StressTest_Solo",
      "SOLO",
      { value: ethers.parseEther("0") } 
    );
    console.log(`  Predicted address: ${projectAddress}`);

    console.log("  Submitting on-chain transaction...");
    const launchTx = await factory.launchNewProject(
      "StressTest_Solo",
      "SOLO",
      { value: ethers.parseEther("0") } 
    );
    await launchTx.wait();
    console.log(`  [OK] Project launched. Contract address: ${projectAddress}`);
  } catch (err) {
    console.error("\n  [FAIL] Test A:", err.reason || err.message);
    return;
  }

  const project = await ethers.getContractAt("MeritXFund", projectAddress);

  // --- Phase 1: Verify normal contribution (0.05 ETH) ---
  console.log("\n[Phase 1] Verifying normal contribution (0.05 ETH)...");
  try {
    const investTx = await project.contribute({ value: ethers.parseEther("0.05") });
    await investTx.wait();
    
    const total = await project.totalRaised();
    console.log(`  [OK] Contribution successful. Total raised: ${ethers.formatEther(total)} ETH`);
  } catch (err) {
    console.log("  [FAIL] Normal contribution failed:", err.reason || err.message);
    return;
  }

  // --- Phase 2: Verify 0.06 ETH per-wallet cap enforcement ---
  console.log("\n[Phase 2] Verifying 0.06 ETH per-wallet cap defense...");
  try {
    console.log("  Attempting additional 0.02 ETH (total would reach 0.07 ETH)...");
    const tx = await project.contribute({ value: ethers.parseEther("0.02") });
    await tx.wait();
    
    console.log("  [FAIL] CRITICAL: Cap defense breached! Contract allowed over-allocation.");
  } catch (error) {
    console.log("  [OK] Defense active. Contract rejected the over-limit transaction.");
    console.log(`  Revert reason: ${error.reason || "Reverted (check contract error message)"}`);
  }

  console.log("\n  v6.0 Solo stress test complete.");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
