const hre = require("hardhat");

// ╔══════════════════════════════════════════════════════════════════╗
// ║                       CONFIGURATION (REQUIRED)                   ║
// ╚══════════════════════════════════════════════════════════════════╝

const FUND_ADDRESS  = "0xAABEfD377AD01401e2b58442AfbE3d45d125f01F";
const TOKEN_ADDRESS = "0x755972826FbF87a1B0868F46941ac9Cee3479Eda";

// Optional: execute a buy-swap to pump price before triggering inflation
const DO_PRE_SWAP   = false;
const SWAP_ETH      = "0.001";      // ETH amount to buy tokens with (price pump)

// Base Sepolia — Uniswap V3 canonical addresses
const WETH_ADDRESS     = "0x4200000000000000000000000000000000000006";
const SWAP_ROUTER      = "0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4";
const FEE_TIER         = 3000;

// ─────────────────────────────────────────────────────────────────

const FUND_ABI = [
  "function mintInflation() external",
  "function getTWAP() external view returns (int24)",
  "function calculateTargetSupply(int24 tick) external view returns (uint256)",
  "function currentState() external view returns (uint8)",
  "function isFinalized() external view returns (bool)",
  "function totalRaised() external view returns (uint256)",
  "function uniswapPool() external view returns (address)",
  "function initialTick() external view returns (int24)",
  "function lastMintTime() external view returns (uint256)",
  "function poolCreationTime() external view returns (uint256)",
  "function projectToken() external view returns (address)",
  "function projectOwner() external view returns (address)",
  "function lpTokenId() external view returns (uint256)",
  "function weth() external view returns (address)",
];

const ERC20_ABI = [
  "function balanceOf(address) external view returns (uint256)",
  "function symbol() external view returns (string)",
  "function decimals() external view returns (uint8)",
  "function totalSupply() external view returns (uint256)",
];

const POOL_ABI = [
  "function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16 observationIndex, uint16 observationCardinality, uint16 observationCardinalityNext, uint8 feeProtocol, bool unlocked)",
  "function liquidity() external view returns (uint128)",
  "function token0() external view returns (address)",
  "function token1() external view returns (address)",
];

const WETH_ABI = [
  "function deposit() external payable",
  "function approve(address, uint256) external returns (bool)",
  "function balanceOf(address) external view returns (uint256)",
];

const ROUTER_ABI = [
  `function exactInputSingle((
      address tokenIn, address tokenOut, uint24 fee,
      address recipient, uint256 amountIn,
      uint256 amountOutMinimum, uint160 sqrtPriceLimitX96
  )) external payable returns (uint256 amountOut)`,
];

const STATE_NAMES     = ["Funding", "Failed", "Success_Isolated", "Ready_For_DEX"];
const MINT_COOLDOWN   = 60;          // 1 minute (test config)
const CALLER_REWARD   = 10n;         // 10 BPS = 0.1%
const MIN_LIQUIDITY   = 10n ** 18n;
const INITIAL_SUPPLY  = 40_950_000n * 10n ** 18n;

async function main() {
  const [signer] = await hre.ethers.getSigners();

  console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
  console.log("  MeritX PoP (Proof-of-Price) Inflation Test — Base Sepolia");
  console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
  console.log("Caller :", signer.address);

  if (FUND_ADDRESS.startsWith("0x0"))  throw new Error("Please set FUND_ADDRESS at the top of this script");
  if (TOKEN_ADDRESS.startsWith("0x0")) throw new Error("Please set TOKEN_ADDRESS at the top of this script");

  const fund  = new hre.ethers.Contract(FUND_ADDRESS, FUND_ABI, signer);
  const token = new hre.ethers.Contract(TOKEN_ADDRESS, ERC20_ABI, signer);
  const fmt   = (v, d = 18n) => hre.ethers.formatUnits(v, d);

  // ═══════════════════════════════════════════════════════════
  //  STEP 1: Read contract state & token sort order
  // ═══════════════════════════════════════════════════════════
  console.log("\n[1/6] Reading contract state ...");

  const [stateRaw, finalized, poolAddr, initTick, lastMint, poolTime, ownerAddr, onChainToken, wethAddr] =
    await Promise.all([
      fund.currentState(),
      fund.isFinalized(),
      fund.uniswapPool(),
      fund.initialTick(),
      fund.lastMintTime(),
      fund.poolCreationTime(),
      fund.projectOwner(),
      fund.projectToken(),
      fund.weth(),
    ]);

  const symbol   = await token.symbol();
  const decimals = await token.decimals();

  // Determine whether AgentToken is token0 or token1 in the Uniswap pool
  const tokenIsToken0 = onChainToken.toLowerCase() < wethAddr.toLowerCase();

  console.log("  State         :", STATE_NAMES[Number(stateRaw)] || `Unknown(${stateRaw})`);
  console.log("  isFinalized   :", finalized);
  console.log("  uniswapPool   :", poolAddr);
  console.log("  initialTick   :", Number(initTick));
  console.log("  poolCreatedAt :", new Date(Number(poolTime) * 1000).toISOString());
  console.log("  lastMintTime  :", new Date(Number(lastMint) * 1000).toISOString());
  console.log("  projectOwner  :", ownerAddr);
  console.log("  projectToken  :", onChainToken);
  console.log("  WETH          :", wethAddr);
  console.log("  Token sort    :", tokenIsToken0 ? "token0 (AgentToken) / token1 (WETH)" : "token0 (WETH) / token1 (AgentToken)");
  console.log("  Price axis    :", tokenIsToken0 ? "price up = tick increases" : "price up = tick decreases");

  if (!finalized) {
    console.error("\n  Contract not finalized. Cannot call mintInflation().");
    return;
  }
  if (poolAddr === hre.ethers.ZeroAddress) {
    console.error("\n  Uniswap pool not created yet.");
    return;
  }

  // ═══════════════════════════════════════════════════════════
  //  STEP 2: Read pool live state
  // ═══════════════════════════════════════════════════════════
  console.log("\n[2/6] Reading Uniswap V3 pool state ...");

  const pool = new hre.ethers.Contract(poolAddr, POOL_ABI, signer);
  const [slot0, liq] = await Promise.all([pool.slot0(), pool.liquidity()]);

  const currentTick = Number(slot0[1]);
  const sqrtPrice   = slot0[0];

  // Direction-aware tick delta
  const rawDelta   = currentTick - Number(initTick);
  const priceDelta = tokenIsToken0 ? rawDelta : -rawDelta;

  console.log("  Current tick    :", currentTick);
  console.log("  Initial tick    :", Number(initTick));
  console.log("  Raw tick delta  :", rawDelta, rawDelta > 0 ? "(tick up)" : "(tick down)");
  console.log("  Price tick delta:", priceDelta, priceDelta > 0 ? "Price UP" : "Price NOT up");
  console.log("  sqrtPriceX96    :", sqrtPrice.toString());
  console.log("  liquidity       :", liq.toString());

  if (liq < MIN_LIQUIDITY) {
    console.error(`\n  Pool liquidity (${liq}) < MIN_LIQUIDITY (${MIN_LIQUIDITY}). mintInflation will revert.`);
    return;
  }
  console.log("  Liquidity check : OK");

  // ═══════════════════════════════════════════════════════════
  //  STEP 3: Cooldown check
  // ═══════════════════════════════════════════════════════════
  console.log("\n[3/6] Checking cooldown ...");

  const now = Math.floor(Date.now() / 1000);
  const nextMintAt = Number(lastMint) + MINT_COOLDOWN;
  const remaining  = nextMintAt - now;

  console.log("  Current time    :", new Date(now * 1000).toISOString());
  console.log("  Next mint after :", new Date(nextMintAt * 1000).toISOString());

  if (remaining > 0) {
    console.log(`\n  Cooldown active. ${remaining}s remaining (${(remaining / 60).toFixed(1)} min)`);
    console.log("  On local Hardhat you can fast-forward:");
    console.log('     const { time } = require("@nomicfoundation/hardhat-network-helpers");');
    console.log(`     await time.increase(${remaining + 10});`);
    console.log("\n  On Base Sepolia testnet, wait for cooldown to expire and re-run.");
    return;
  }
  console.log("  Cooldown passed. Ready to mint!");

  // ═══════════════════════════════════════════════════════════
  //  STEP 4 (Optional): Pre-swap to pump price
  // ═══════════════════════════════════════════════════════════
  if (DO_PRE_SWAP) {
    console.log(`\n[4/6] Pre-swap to pump price (${SWAP_ETH} ETH -> ${symbol}) ...`);

    const weth   = new hre.ethers.Contract(WETH_ADDRESS, WETH_ABI, signer);
    const router = new hre.ethers.Contract(SWAP_ROUTER, ROUTER_ABI, signer);
    const amt    = hre.ethers.parseEther(SWAP_ETH);

    const wrapTx = await weth.deposit({ value: amt });
    await wrapTx.wait();
    console.log("  WETH deposit  :", wrapTx.hash);

    const appTx = await weth.approve(SWAP_ROUTER, amt);
    await appTx.wait();

    const swapTx = await router.exactInputSingle({
      tokenIn: WETH_ADDRESS, tokenOut: TOKEN_ADDRESS, fee: FEE_TIER,
      recipient: signer.address, amountIn: amt,
      amountOutMinimum: 0n, sqrtPriceLimitX96: 0n,
    });
    const swapRc = await swapTx.wait();
    console.log("  Swap tx       :", swapTx.hash);
    console.log("  Gas used      :", swapRc.gasUsed.toString());

    const newSlot0 = await pool.slot0();
    const newTick = Number(newSlot0[1]);
    const newRawDelta = newTick - Number(initTick);
    const newPriceDelta = tokenIsToken0 ? newRawDelta : -newRawDelta;
    console.log("  Post-swap tick:", newTick, `(price delta = ${newPriceDelta > 0 ? "+" : ""}${newPriceDelta})`);
  } else {
    console.log("\n[4/6] Skipping pre-swap (DO_PRE_SWAP = false)");
    if (priceDelta <= 0) {
      console.log("  Price has not increased. mintInflation will revert with \"!inf\".");
      console.log("     -> Run testSwap.js to buy tokens first, or set DO_PRE_SWAP = true.");
    }
  }

  // ═══════════════════════════════════════════════════════════
  //  STEP 5: Calculate mintable amount & forecast
  // ═══════════════════════════════════════════════════════════
  console.log("\n[5/6] Computing inflation target ...");

  let twapTick;
  try {
    twapTick = await fund.getTWAP();
  } catch (e) {
    console.error("  getTWAP() reverted:", e.reason || e.message);
    console.log("     TWAP observation window may be too short (pool just created). Retry later.");
    return;
  }

  const twapNum = Number(twapTick);
  const twapRawDelta   = twapNum - Number(initTick);
  const twapPriceDelta = tokenIsToken0 ? twapRawDelta : -twapRawDelta;

  console.log("  TWAP tick         :", twapNum);
  console.log("  initialTick       :", Number(initTick));
  console.log("  TWAP raw delta    :", twapRawDelta);
  console.log("  TWAP price delta  :", twapPriceDelta, twapPriceDelta > 0 ? "Price UP" : "Price NOT up");
  console.log("  Token sort        :", tokenIsToken0 ? "token0 (tick up = price up)" : "token1 (tick down = price up)");

  // Call contract's calculateTargetSupply (direction logic already handled on-chain)
  const targetSupply  = await fund.calculateTargetSupply(twapTick);
  const currentSupply = await token.totalSupply();
  const delta         = targetSupply > currentSupply ? targetSupply - currentSupply : 0n;

  console.log("  Target supply     :", fmt(targetSupply), symbol);
  console.log("  Current supply    :", fmt(currentSupply), symbol);
  console.log("  Mintable amount   :", fmt(delta), symbol);

  if (delta === 0n) {
    console.log("\n  Target supply <= current supply. Nothing to mint.");
    if (twapPriceDelta <= 0) {
      console.log("  Reason: TWAP price has not exceeded initial price.");
      console.log("  Action: Buy tokens via testSwap.js to pump price, wait for TWAP to update, retry.");
    } else {
      console.log("  Reason: TWAP reflects a gain but target supply is insufficient (small gain or already minted).");
    }
    console.log("  TWAP window is 30 minutes; new prices need time to propagate.");
    return;
  }

  const callerReward = (delta * CALLER_REWARD) / 10_000n;
  const ownerShare   = delta - callerReward;

  console.log("\n  Estimated distribution:");
  console.log(`  -> Owner  (${ownerAddr.slice(0, 10)}...): ${fmt(ownerShare)} ${symbol} (99.9%)`);
  console.log(`  -> Caller (${signer.address.slice(0, 10)}...): ${fmt(callerReward)} ${symbol} (0.1%)`);

  // ═══════════════════════════════════════════════════════════
  //  STEP 6: Execute mintInflation()
  // ═══════════════════════════════════════════════════════════
  console.log("\n[6/6] Executing mintInflation() ...");

  const callerBalBefore = await token.balanceOf(signer.address);
  const ownerBalBefore  = await token.balanceOf(ownerAddr);
  const supplyBefore    = currentSupply;

  console.log("  Caller bal before :", fmt(callerBalBefore), symbol);
  console.log("  Owner bal before  :", fmt(ownerBalBefore), symbol);
  console.log("  totalSupply before:", fmt(supplyBefore), symbol);

  let tx, receipt;
  try {
    tx = await fund.mintInflation();
    console.log("  Tx hash           :", tx.hash);
    console.log("  Waiting for confirmation ...");
    receipt = await tx.wait();
  } catch (e) {
    const reason = e.reason || e.message || String(e);
    console.error("\n  mintInflation() reverted:", reason);

    if (reason.includes("!cd")) {
      console.log("     Reason: Cooldown not elapsed. Wait and retry.");
    } else if (reason.includes("!inf")) {
      console.log("     Reason: Target supply <= current (price not up or TWAP lagging).");
      console.log("     Current TWAP price delta:", twapPriceDelta, "(must be > 0)");
      console.log("     Action: Buy tokens to pump price, wait for TWAP update, retry.");
    } else if (reason.includes("!low-liq")) {
      console.log("     Reason: Pool liquidity below safety threshold.");
    } else if (reason.includes("!fin")) {
      console.log("     Reason: Contract not yet finalized.");
    } else if (reason.includes("OLD") || reason.includes("!pool")) {
      console.log("     Reason: TWAP observation window insufficient. Wait a few minutes.");
    }
    return;
  }

  console.log("  Confirmed!");
  console.log("  Block             :", receipt.blockNumber);
  console.log("  Gas used          :", receipt.gasUsed.toString());

  // ─── Verify results ───
  const callerBalAfter = await token.balanceOf(signer.address);
  const ownerBalAfter  = await token.balanceOf(ownerAddr);
  const supplyAfter    = await token.totalSupply();

  const callerGot  = callerBalAfter - callerBalBefore;
  const ownerGot   = ownerBalAfter - ownerBalBefore;
  const supplyDiff = supplyAfter - supplyBefore;

  console.log("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
  console.log("  PoP inflation mint successful!");
  console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
  console.log(`  Total minted      : ${fmt(supplyDiff)} ${symbol}`);
  console.log(`  Caller reward     : ${fmt(callerGot)} ${symbol}  (actual ${supplyDiff > 0n ? (Number(callerGot * 10000n / supplyDiff) / 100).toFixed(2) : "0"}%)`);
  console.log(`  Owner share       : ${fmt(ownerGot)} ${symbol}`);
  console.log(`  totalSupply after : ${fmt(supplyAfter)} ${symbol}`);
  console.log(`  Inflation rate    : +${supplyBefore > 0n ? (Number(supplyDiff * 1_000_000n / supplyBefore) / 10000).toFixed(6) : "0"}%`);
  console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");

  const nextCd = Math.floor(Date.now() / 1000) + MINT_COOLDOWN;
  console.log(`\n  Next eligible call: ${new Date(nextCd * 1000).toISOString()}`);
  console.log("  Re-run this script to trigger subsequent inflations (price must remain above initial).");
}

// ─────────────────────────────────────────────────────────────────
// About tick direction & token sort order:
//
// Uniswap V3 tick definition: price = 1.0001^tick, price = token1/token0
//
// Case A: AgentToken is token0, WETH is token1
//   price = WETH/AgentToken (how much WETH per 1 AgentToken)
//   Buying AgentToken -> AgentToken appreciates -> price rises -> tick rises
//   Therefore: price up = tick - initialTick > 0
//
// Case B: WETH is token0, AgentToken is token1 (common case)
//   price = AgentToken/WETH (how many AgentTokens per 1 WETH)
//   Buying AgentToken -> AgentToken appreciates -> fewer tokens per WETH
//   -> price falls -> tick falls
//   Therefore: price up = initialTick - tick > 0
//
// The contract's calculateTargetSupply() handles both cases dynamically.
// ─────────────────────────────────────────────────────────────────

main().catch((err) => {
  console.error("\nPoP Claim failed:", err.message || err);
  process.exitCode = 1;
});
