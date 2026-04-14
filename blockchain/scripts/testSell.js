const hre = require("hardhat");

// ╔══════════════════════════════════════════════════════════════╗
// ║                    CONFIGURATION (REQUIRED)                  ║
// ╚══════════════════════════════════════════════════════════════╝

const TOKEN_ADDRESS   = "0x755972826FbF87a1B0868F46941ac9Cee3479Eda";     // Agent Token (VVV / SSS etc.)

// Sell strategy — pick one:
// A) Fixed amount — set to "" to use percentage mode instead
const SELL_AMOUNT_ETH = "100000";
// B) Percentage mode — sell X% of holdings (0.1 = 10%, 0.5 = 50%, 1.0 = 100%)
const SELL_PERCENTAGE = 0.1;

// Base Sepolia Uniswap V3 (verified, matches Foundry fork test)
const WETH_ADDRESS    = "0x4200000000000000000000000000000000000006";
const SWAP_ROUTER     = "0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4";
const FEE_TIER        = 3000;  // 0.3% — must match MeritX pool fee tier

// ─────────────────────────────────────────────────────────────

const ERC20_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address, uint256) returns (bool)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
];

const WETH_ABI = [
  "function balanceOf(address) view returns (uint256)",
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

async function main() {
  const [signer] = await hre.ethers.getSigners();

  console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
  console.log("  MeritX Sell (Token -> WETH) - Base Sepolia");
  console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
  console.log("Wallet :", signer.address);

  if (TOKEN_ADDRESS.startsWith("0x0")) {
    throw new Error("Please set TOKEN_ADDRESS at the top of this script");
  }

  const token = new hre.ethers.Contract(TOKEN_ADDRESS, ERC20_ABI, signer);
  const weth  = new hre.ethers.Contract(WETH_ADDRESS, WETH_ABI, signer);

  const symbol   = await token.symbol();
  const decimals = await token.decimals();
  const fmt = (v) => hre.ethers.formatUnits(v, decimals);

  // ─── Step 1: Query balance & compute sell amount ───
  console.log(`\n[1/4] Querying ${symbol} balance ...`);

  const balance = await token.balanceOf(signer.address);
  console.log("  Holdings :", fmt(balance), symbol);

  if (balance === 0n) {
    console.error("  Balance is 0, nothing to sell.");
    return;
  }

  let sellAmount;
  if (SELL_AMOUNT_ETH && SELL_AMOUNT_ETH !== "") {
    sellAmount = hre.ethers.parseUnits(SELL_AMOUNT_ETH, decimals);
    console.log("  Mode     : Fixed amount");
  } else {
    sellAmount = (balance * BigInt(Math.floor(SELL_PERCENTAGE * 10000))) / 10000n;
    console.log(`  Mode     : Percentage (${(SELL_PERCENTAGE * 100).toFixed(1)}%)`);
  }

  if (sellAmount > balance) {
    console.error(`  Sell amount (${fmt(sellAmount)}) > holdings (${fmt(balance)})`);
    console.log("  Reduce SELL_AMOUNT_ETH or SELL_PERCENTAGE.");
    return;
  }
  if (sellAmount === 0n) {
    console.error("  Computed sell amount is 0.");
    return;
  }

  console.log("  Sell qty :", fmt(sellAmount), symbol);
  console.log("  % of bag :", ((Number(sellAmount) / Number(balance)) * 100).toFixed(2), "%");

  // ─── Step 2: Smart approval ───
  console.log(`\n[2/4] Checking allowance ...`);

  const currentAllowance = await token.allowance(signer.address, SWAP_ROUTER);
  console.log("  Allowance:", fmt(currentAllowance), symbol);

  if (currentAllowance >= sellAmount) {
    console.log("  Allowance sufficient, skipping approve.");
  } else {
    console.log("  Insufficient allowance, sending approve ...");
    const approveTx = await token.approve(SWAP_ROUTER, sellAmount);
    await approveTx.wait();
    console.log("  Approve tx:", approveTx.hash);
  }

  // ─── Step 3: Record pre-swap state ───
  console.log(`\n[3/4] Recording pre-swap state ...`);

  const wethBefore  = await weth.balanceOf(signer.address);
  const tokenBefore = balance;

  console.log("  WETH before  :", hre.ethers.formatEther(wethBefore));
  console.log("  Token before :", fmt(tokenBefore), symbol);

  // ─── Step 4: Execute sell ───
  console.log(`\n[4/4] Executing swap: ${fmt(sellAmount)} ${symbol} -> WETH ...`);
  console.log("  Router   :", SWAP_ROUTER);
  console.log("  Fee tier :", FEE_TIER);

  const router = new hre.ethers.Contract(SWAP_ROUTER, ROUTER_ABI, signer);

  try {
    const swapTx = await router.exactInputSingle({
      tokenIn:           TOKEN_ADDRESS,
      tokenOut:          WETH_ADDRESS,
      fee:               FEE_TIER,
      recipient:         signer.address,
      amountIn:          sellAmount,
      amountOutMinimum:  0n,
      sqrtPriceLimitX96: 0n,
    });

    console.log("  Tx hash  :", swapTx.hash);
    console.log("  Waiting for confirmation ...");

    const receipt = await swapTx.wait();
    console.log("  Confirmed!");
    console.log("  Block    :", receipt.blockNumber);
    console.log("  Gas used :", receipt.gasUsed.toString());

    const wethAfter  = await weth.balanceOf(signer.address);
    const tokenAfter = await token.balanceOf(signer.address);
    const wethGained = wethAfter - wethBefore;
    const tokenSold  = tokenBefore - tokenAfter;

    console.log("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    console.log("  Sell complete!");
    console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    console.log(`  Sold       : ${fmt(tokenSold)} ${symbol}`);
    console.log(`  Received   : ${hre.ethers.formatEther(wethGained)} WETH`);
    console.log(`  Remaining  : ${fmt(tokenAfter)} ${symbol}`);
    console.log(`  WETH total : ${hre.ethers.formatEther(wethAfter)} WETH`);

    if (tokenSold > 0n) {
      const pricePerToken = Number(wethGained) / Number(tokenSold);
      console.log(`  Avg price  : ${pricePerToken.toExponential(4)} WETH/${symbol}`);
    }
    console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");

  } catch (err) {
    const reason = err.reason || err.message || String(err);
    console.error("\n  Swap failed:", reason);

    if (reason.includes("STF")) {
      console.log("     STF = SwapRouter transferFrom failed.");
      console.log("     Possible cause: insufficient approval or token transfer restriction.");
    } else if (reason.includes("SPL")) {
      console.log("     SPL = sqrtPriceLimitX96 hit. Pool lacks sufficient liquidity for this trade.");
    }
  }
}

main().catch((err) => {
  console.error("\nScript failed:", err.message || err);
  process.exitCode = 1;
});
