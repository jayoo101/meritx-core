const hre = require("hardhat");

// ╔══════════════════════════════════════════════════════════════╗
// ║                    CONFIGURATION (REQUIRED)                  ║
// ╚══════════════════════════════════════════════════════════════╝

const FUND_ADDRESS  =  "0xAABEfD377AD01401e2b58442AfbE3d45d125f01F";
const TOKEN_ADDRESS = "0x755972826FbF87a1B0868F46941ac9Cee3479Eda";

// ─────────────────────────────────────────────────────────────

const FUND_ABI = [
  "function claimTokens() external",
  "function contributions(address) external view returns (uint256)",
  "function totalRaised() external view returns (uint256)",
  "function currentState() external view returns (uint8)",
  "function isFinalized() external view returns (bool)",
  "function projectToken() external view returns (address)",
  "function raiseEndTime() external view returns (uint256)",
];

const ERC20_ABI = [
  "function balanceOf(address) external view returns (uint256)",
  "function symbol() external view returns (string)",
  "function decimals() external view returns (uint8)",
  "function totalSupply() external view returns (uint256)",
];

const STATE_NAMES = ["Funding", "Failed", "Success_Isolated", "Ready_For_DEX"];
const RETAIL_POOL = 21_000_000n * 10n ** 18n; // 21M tokens (must match contract)

async function main() {
  const [signer] = await hre.ethers.getSigners();

  console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
  console.log("  MeritX Claim Test — Base Sepolia");
  console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
  console.log("Wallet :", signer.address);

  if (FUND_ADDRESS.startsWith("0x0")) {
    throw new Error("Please set FUND_ADDRESS at the top of this script");
  }
  if (TOKEN_ADDRESS.startsWith("0x0")) {
    throw new Error("Please set TOKEN_ADDRESS at the top of this script");
  }

  const fund  = new hre.ethers.Contract(FUND_ADDRESS, FUND_ABI, signer);
  const token = new hre.ethers.Contract(TOKEN_ADDRESS, ERC20_ABI, signer);

  const symbol   = await token.symbol();
  const decimals = await token.decimals();
  const fmt = (v) => hre.ethers.formatUnits(v, decimals);

  // ─── Step 1: Read contract state ───
  console.log("\n[1/5] Reading contract state ...");

  const stateRaw     = await fund.currentState();
  const stateName    = STATE_NAMES[Number(stateRaw)] || `Unknown(${stateRaw})`;
  const isFinalized  = await fund.isFinalized();
  const totalRaised  = await fund.totalRaised();
  const raiseEndTime = await fund.raiseEndTime();
  const onChainToken = await fund.projectToken();

  console.log("  Fund address :", FUND_ADDRESS);
  console.log("  State        :", stateName, `(enum=${stateRaw})`);
  console.log("  isFinalized  :", isFinalized);
  console.log("  totalRaised  :", hre.ethers.formatEther(totalRaised), "ETH");
  console.log("  raiseEndTime :", new Date(Number(raiseEndTime) * 1000).toISOString());
  console.log("  projectToken :", onChainToken);

  if (onChainToken.toLowerCase() !== TOKEN_ADDRESS.toLowerCase()) {
    console.warn("  TOKEN_ADDRESS does not match on-chain projectToken. Please verify.");
  }

  // ─── Step 2: Query claimable amount ───
  console.log("\n[2/5] Querying claimable amount ...");

  const contribution = await fund.contributions(signer.address);
  console.log("  My contribution :", hre.ethers.formatEther(contribution), "ETH");

  if (contribution === 0n) {
    console.log("\n  No contribution found (already claimed or never contributed).");
    console.log("  Aborting.");
    return;
  }

  const claimable = (contribution * RETAIL_POOL) / totalRaised;
  console.log("  Claimable tokens:", fmt(claimable), symbol);
  console.log("  Formula         : (myContrib * RETAIL_POOL) / totalRaised");
  console.log(`                  = (${hre.ethers.formatEther(contribution)} * 21,000,000) / ${hre.ethers.formatEther(totalRaised)}`);

  // ─── Step 3: Check prerequisites ───
  console.log("\n[3/5] Checking claim prerequisites ...");

  if (Number(stateRaw) !== 3) {
    console.error(`  State is "${stateName}", need "Ready_For_DEX" (3) to claim.`);
    if (Number(stateRaw) === 2) {
      console.log("     -> State is Success_Isolated. Call finalizeFunding() first.");
    } else if (Number(stateRaw) === 0) {
      console.log("     -> Still funding. Wait for raiseEndTime to expire.");
    } else if (Number(stateRaw) === 1) {
      console.log("     -> Funding failed. Call claimRefund() to withdraw.");
    }
    return;
  }
  console.log("  State is Ready_For_DEX. Claim allowed.");

  // ─── Step 4: Record pre-claim balance and execute ───
  console.log("\n[4/5] Executing claimTokens() ...");

  const balBefore = await token.balanceOf(signer.address);
  console.log("  Balance before:", fmt(balBefore), symbol);

  const tx = await fund.claimTokens();
  console.log("  Tx hash       :", tx.hash);
  console.log("  Waiting for confirmation ...");

  const receipt = await tx.wait();
  console.log("  Confirmed!");
  console.log("  Block         :", receipt.blockNumber);
  console.log("  Gas used      :", receipt.gasUsed.toString());

  // ─── Step 5: Verify result ───
  console.log("\n[5/5] Verifying claim result ...");

  const balAfter = await token.balanceOf(signer.address);
  const received = balAfter - balBefore;

  const contribAfter = await fund.contributions(signer.address);

  console.log("  Balance after :", fmt(balAfter), symbol);
  console.log("  Received      :", fmt(received), symbol);
  console.log("  Expected      :", fmt(claimable), symbol);
  console.log("  Contrib zeroed:", contribAfter === 0n ? "Yes" : "NO (ANOMALY!)");

  const diff = received > claimable ? received - claimable : claimable - received;
  if (diff <= 1n) {
    console.log("  Precision     : OK (delta <= 1 wei)");
  } else {
    console.warn(`  Precision     : DRIFT ${diff.toString()} wei`);
  }

  console.log("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
  console.log(`  Token claim successful!`);
  console.log(`  ${hre.ethers.formatEther(contribution)} ETH -> ${fmt(received)} ${symbol}`);
  console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
}

// ─────────────────────────────────────────────────────────────
// About Vesting:
//
// MeritXFund.claimTokens() is a one-time full release with no vesting.
// As long as currentState() == Ready_For_DEX, the user can claim
// their entire allocation.
//
// If linear vesting is introduced later, on local Hardhat you can:
//   const { time } = require("@nomicfoundation/hardhat-network-helpers");
//   await time.increase(86400 * 30); // fast-forward 30 days
//
// On testnet (Base Sepolia) there is no time acceleration; wait IRL.
// ─────────────────────────────────────────────────────────────

main().catch((err) => {
  console.error("\nClaim failed:", err.message || err);
  process.exitCode = 1;
});
