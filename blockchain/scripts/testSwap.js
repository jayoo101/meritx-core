const hre = require("hardhat");

// ╔══════════════════════════════════════════════════════════════╗
// ║                    CONFIGURATION (PRE-FILLED)                ║
// ╚══════════════════════════════════════════════════════════════╝

const TOKEN_ADDRESS       = "0x755972826FbF87a1B0868F46941ac9Cee3479Eda"; // SSS token address
const FUND_ADDRESS        = "0xAABEfD377AD01401e2b58442AfbE3d45d125f01F"; // Not called by script; for reference only

// Base Sepolia — Uniswap V3 canonical addresses
const SWAP_ROUTER         = "0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4";
const WETH_ADDRESS        = "0x4200000000000000000000000000000000000006";
const FEE_TIER            = 3000;   // 0.3% — must match pool fee tier

const SWAP_AMOUNT_ETH     = "0.005"; // ETH amount to swap for tokens

// ─────────────────────────────────────────────────────────────

const WETH_ABI = [
  "function deposit() external payable",
  "function approve(address spender, uint256 amount) external returns (bool)",
  "function balanceOf(address account) external view returns (uint256)",
];

// SwapRouter02 on Base Sepolia (no deadline in struct)
const ROUTER_ABI = [
  `function exactInputSingle((
      address tokenIn,
      address tokenOut,
      uint24 fee,
      address recipient,
      uint256 amountIn,
      uint256 amountOutMinimum,
      uint160 sqrtPriceLimitX96
  )) external payable returns (uint256 amountOut)`,
];

const ERC20_ABI = [
  "function balanceOf(address account) external view returns (uint256)",
  "function symbol() external view returns (string)",
  "function decimals() external view returns (uint8)",
];

async function main() {
  const [signer] = await hre.ethers.getSigners();
  console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
  console.log("  MeritX Swap Test — Base Sepolia");
  console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
  console.log("Wallet  :", signer.address);

  if (TOKEN_ADDRESS.startsWith("0x0")) {
    throw new Error("Please set TOKEN_ADDRESS at the top of this script");
  }

  const weth   = new hre.ethers.Contract(WETH_ADDRESS, WETH_ABI, signer);
  const router = new hre.ethers.Contract(SWAP_ROUTER, ROUTER_ABI, signer);
  const token  = new hre.ethers.Contract(TOKEN_ADDRESS, ERC20_ABI, signer);

  const symbol   = await token.symbol();
  const decimals = await token.decimals();
  const amountIn = hre.ethers.parseEther(SWAP_AMOUNT_ETH);

  console.log(`\n[1/4] Wrapping ${SWAP_AMOUNT_ETH} ETH -> WETH ...`);
  const wrapTx = await weth.deposit({ value: amountIn });
  await wrapTx.wait();
  console.log("  Done. WETH deposit tx:", wrapTx.hash);

  const wethBal = await weth.balanceOf(signer.address);
  console.log("  WETH balance:", hre.ethers.formatEther(wethBal));

  console.log("\n[2/4] Approving SwapRouter to spend WETH ...");
  const approveTx = await weth.approve(SWAP_ROUTER, amountIn);
  await approveTx.wait();
  console.log("  Done. Approve tx:", approveTx.hash);

  const tokenBalBefore = await token.balanceOf(signer.address);
  console.log(`\n[3/4] Pre-swap ${symbol} balance:`, hre.ethers.formatUnits(tokenBalBefore, decimals));

  console.log(`\n[4/4] Executing swap: ${SWAP_AMOUNT_ETH} WETH -> ${symbol} ...`);
  console.log("  Pool fee tier:", FEE_TIER);
  console.log("  tokenIn  (WETH) :", WETH_ADDRESS);
  console.log("  tokenOut (Token):", TOKEN_ADDRESS);

  const swapTx = await router.exactInputSingle({
    tokenIn:           WETH_ADDRESS,
    tokenOut:          TOKEN_ADDRESS,
    fee:               FEE_TIER,
    recipient:         signer.address,
    amountIn:          amountIn,
    amountOutMinimum:  0n,          // No slippage guard for testing
    sqrtPriceLimitX96: 0n,
  });

  const receipt = await swapTx.wait();
  console.log("\n  Swap tx hash    :", swapTx.hash);
  console.log("  Block number    :", receipt.blockNumber);
  console.log("  Gas used        :", receipt.gasUsed.toString());

  const tokenBalAfter = await token.balanceOf(signer.address);
  const received = tokenBalAfter - tokenBalBefore;

  console.log("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
  console.log(`  Successfully purchased ${symbol}!`);
  console.log(`  Spent   : ${SWAP_AMOUNT_ETH} ETH`);
  console.log(`  Received: ${hre.ethers.formatUnits(received, decimals)} ${symbol}`);
  console.log(`  Total   : ${hre.ethers.formatUnits(tokenBalAfter, decimals)} ${symbol}`);
  console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
}

main().catch((err) => {
  console.error("\nSwap failed:", err.message || err);
  process.exitCode = 1;
});
