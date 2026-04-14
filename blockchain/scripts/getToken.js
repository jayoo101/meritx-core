const hre = require("hardhat");

async function main() {
  const fundAddress = "0xAABEfD377AD01401e2b58442AfbE3d45d125f01F"; 
  
  const ABI = ["function projectToken() external view returns (address)"];
  
  const [signer] = await hre.ethers.getSigners();
  const fund = new hre.ethers.Contract(fundAddress, ABI, signer);
  
  console.log("Querying projectToken on Base Sepolia...");
  const tokenAddress = await fund.projectToken();
  
  console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
  console.log("Fund contract  :", fundAddress);
  console.log("Token contract :", tokenAddress);
  console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
}

main().catch((error) => {
  console.error("Query failed:", error);
  process.exitCode = 1;
});
