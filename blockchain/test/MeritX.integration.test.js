const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

/*
 * MeritX v7.0 — Full Lifecycle Integration Test (Mainnet Constants)
 *
 * Tests run against TESTNET fast-track constants:
 *   SOFT_CAP         = 0.01 ETH   (TODO: REVERT FOR MAINNET: 15 ETH)
 *   MAX_ALLOCATION   = 0.005 ETH  (TODO: REVERT FOR MAINNET: 0.15 ETH)
 *   RAISE_DURATION   = 5 minutes  (TODO: REVERT FOR MAINNET: 24 hours)
 *   GLOBAL_COOLDOWN  = 5 minutes  (TODO: REVERT FOR MAINNET: 48 hours)
 *   PRE_LAUNCH_NOTICE = 5 minutes (TODO: REVERT FOR MAINNET: 6 hours)
 *   LAUNCH_EXPIRATION = 10 minutes(TODO: REVERT FOR MAINNET: 24 hours)
 *   LISTING_FEE       = 0.001 ETH (TODO: REVERT FOR MAINNET: 0.01 ETH)
 */

// ---- Base Sepolia live addresses (available via fork) ----
const POSITION_MANAGER = "0x27F971cb582BF9E50F397e4d29a5C7A34f11faA2";
const WETH = "0x4200000000000000000000000000000000000006";

const BACKEND_SIGNER_PK =
  "0xbeefbeefbeefbeefbeefbeefbeefbeefbeefbeefbeefbeefbeefbeefbeefbeef";

const RAISE_SECS      = 5 * 60;       // matches contract RAISE_DURATION     (TODO: REVERT FOR MAINNET: 24h)
const PRE_LAUNCH_SECS = 1 * 60;       // matches contract PRE_LAUNCH_NOTICE  (TODO: REVERT FOR MAINNET: 6h)
const LAUNCH_EXP_SECS = 10 * 60;      // matches contract LAUNCH_EXPIRATION  (TODO: REVERT FOR MAINNET: 24h)
const COOLDOWN_SECS   = 5 * 60;       // matches contract GLOBAL_COOLDOWN    (TODO: REVERT FOR MAINNET: 48h)

// ---- Helpers ----

const SIG_TTL = 3600; // 1 hour — generous buffer for time-travel tests

async function signAllocation(wallet, userAddress, maxAlloc, nonce, deadline, fundAddress, chainId) {
  const hash = ethers.solidityPackedKeccak256(
    ["address", "uint256", "uint256", "uint256", "address", "uint256"],
    [userAddress, maxAlloc, nonce, deadline, fundAddress, chainId]
  );
  return wallet.signMessage(ethers.getBytes(hash));
}

async function futureDeadline() {
  return (await time.latest()) + SIG_TTL;
}

async function getLatestProject(factoryContract) {
  const count = await factoryContract.projectCount();
  return factoryContract.allDeployedProjects(count - 1n);
}

/**
 * Fill a fund to its SOFT_CAP by generating fresh wallets,
 * funding them from `funder`, and contributing MAX_ALLOCATION each.
 */
async function fillToSoftCap(fund, fundAddr, signerWallet, funder, chainId) {
  const softCap  = await fund.SOFT_CAP();
  const maxAlloc = await fund.MAX_ALLOCATION();
  let raised = await fund.totalRaised();

  while (raised < softCap) {
    const wallet = ethers.Wallet.createRandom().connect(ethers.provider);
    await funder.sendTransaction({
      to: wallet.address,
      value: maxAlloc + ethers.parseEther("0.01"),
    });

    const remaining = softCap - raised;
    const amount = remaining < maxAlloc ? remaining : maxAlloc;

    const nonce = await fund.nonces(wallet.address);
    const dl = await futureDeadline();
    const sig = await signAllocation(signerWallet, wallet.address, maxAlloc, nonce, dl, fundAddr, chainId);
    await fund.connect(wallet).contribute(maxAlloc, dl, sig, { value: amount });
    raised = await fund.totalRaised();
  }
}

// ---- Test Suite ----

describe("MeritX v7.0 — Full Lifecycle Integration (Mainnet Constants)", function () {
  let factory, fundAddr, fund, token;
  let deployer, user1, user2;
  let signerWallet;
  let chainId;

  const MAX_ALLOC = ethers.parseEther("0.15"); // matches contract MAX_ALLOCATION

  before(async function () {
    [deployer, user1, user2] = await ethers.getSigners();
    signerWallet = new ethers.Wallet(BACKEND_SIGNER_PK);

    const network = await ethers.provider.getNetwork();
    chainId = network.chainId;

    const Factory = await ethers.getContractFactory("MeritXFactory");
    factory = await Factory.deploy(
      signerWallet.address,
      POSITION_MANAGER,
      WETH,
      deployer.address,
      deployer.address   // emergencyAdmin = deployer for test convenience
    );
    await factory.waitForDeployment();
  });

  // ================================================================
  //  PHASE 1 — Project Launch
  // ================================================================
  describe("Phase 1 — Project Launch", function () {
    it("deploys a new MeritXFund + MeritXToken via Factory", async function () {
      const tx = await factory.launchNewProject("TestAgent", "TAGT", "ipfs://test", {
        value: ethers.parseEther("0.001"), // TODO: REVERT FOR MAINNET ("0.01")
      });
      await tx.wait();

      const count = await factory.projectCount();
      expect(count).to.equal(1n);
      fundAddr = await factory.allDeployedProjects(0);

      fund = await ethers.getContractAt("MeritXFund", fundAddr);
      const tokenAddr = await fund.projectToken();
      token = await ethers.getContractAt("MeritXToken", tokenAddr);

      expect(await token.name()).to.equal("TestAgent");
      expect(await token.symbol()).to.equal("TAGT");
      expect(await token.minter()).to.equal(fundAddr);
    });

    it("starts in Funding state (0)", async function () {
      expect(await fund.currentState()).to.equal(0);
    });

    it("records correct immutables", async function () {
      expect(await fund.platformTreasury()).to.equal(deployer.address);
      expect(await fund.backendSigner()).to.equal(signerWallet.address);
      expect(await fund.positionManager()).to.equal(POSITION_MANAGER);
      expect(await fund.weth()).to.equal(WETH);
    });

    it("verifies testnet constants", async function () {
      expect(await fund.SOFT_CAP()).to.equal(ethers.parseEther("0.01"));       // TODO: REVERT FOR MAINNET ("15")
      expect(await fund.MAX_ALLOCATION()).to.equal(ethers.parseEther("0.15"));
      expect(await fund.RAISE_DURATION()).to.equal(RAISE_SECS);
      expect(await fund.PRE_LAUNCH_NOTICE()).to.equal(PRE_LAUNCH_SECS);
      expect(await fund.LAUNCH_EXPIRATION()).to.equal(LAUNCH_EXP_SECS);
      expect(await factory.GLOBAL_COOLDOWN()).to.equal(COOLDOWN_SECS);
    });
  });

  // ================================================================
  //  PHASE 2 — PoHG Contribution
  // ================================================================
  describe("Phase 2 — PoHG Contribution", function () {
    it("accepts a valid signed contribution", async function () {
      const amt = ethers.parseEther("0.003"); // TODO: REVERT FOR MAINNET ("0.1")
      const nonce = await fund.nonces(user1.address);
      const dl = await futureDeadline();
      const sig = await signAllocation(signerWallet, user1.address, MAX_ALLOC, nonce, dl, fundAddr, chainId);

      await fund.connect(user1).contribute(MAX_ALLOC, dl, sig, { value: amt });

      expect(await fund.contributions(user1.address)).to.equal(amt);
      expect(await fund.totalRaised()).to.equal(amt);
    });

    it("rejects a forged signature", async function () {
      const fakeWallet = ethers.Wallet.createRandom();
      const nonce = await fund.nonces(user2.address);
      const dl = await futureDeadline();
      const sig = await signAllocation(fakeWallet, user2.address, MAX_ALLOC, nonce, dl, fundAddr, chainId);

      await expect(
        fund.connect(user2).contribute(MAX_ALLOC, dl, sig, { value: ethers.parseEther("0.003") }) // TODO: REVERT FOR MAINNET ("0.1")
      ).to.be.revertedWith("!sig");
    });

    it("rejects maxAlloc above MAX_ALLOCATION ceiling", async function () {
      const overAlloc = ethers.parseEther("0.3"); // exceeds 0.15 ETH MAX_ALLOCATION
      const nonce = await fund.nonces(user2.address);
      const dl = await futureDeadline();
      const sig = await signAllocation(signerWallet, user2.address, overAlloc, nonce, dl, fundAddr, chainId);

      await expect(
        fund.connect(user2).contribute(overAlloc, dl, sig, { value: ethers.parseEther("0.003") }) // TODO: REVERT FOR MAINNET ("0.1")
      ).to.be.revertedWith("!ceil");
    });

    it("enforces global cooldown on repeat contribution", async function () {
      // With GLOBAL_COOLDOWN (48h) > RAISE_DURATION (24h), a user can
      // only contribute once per project on mainnet.
      const nonce = await fund.nonces(user1.address);
      const dl = await futureDeadline();
      const sig = await signAllocation(signerWallet, user1.address, MAX_ALLOC, nonce, dl, fundAddr, chainId);

      await expect(
        fund.connect(user1).contribute(MAX_ALLOC, dl, sig, { value: ethers.parseEther("0.003") }) // TODO: REVERT FOR MAINNET ("0.05")
      ).to.be.revertedWith("!cd");
    });
  });

  // ================================================================
  //  PHASE 3 — Anti-Stealth Launch + Finalization
  // ================================================================
  describe("Phase 3 — Announcement + Time Travel + Finalization", function () {
    it("rejects finalization without announcement", async function () {
      await expect(fund.finalizeFunding()).to.be.revertedWith("!notice");
    });

    it("rejects announcement while still in raise period", async function () {
      await expect(fund.announceLaunch()).to.be.revertedWith("!raise");
    });

    it("fills soft cap with multiple contributors", async function () {
      this.timeout(120_000);
      await fillToSoftCap(fund, fundAddr, signerWallet, deployer, chainId);
      expect(await fund.totalRaised()).to.be.gte(ethers.parseEther("0.01")); // TODO: REVERT FOR MAINNET ("15")
    });

    it("transitions to Success_Isolated (2) after raise ends", async function () {
      await time.increase(RAISE_SECS + 1);
      expect(await fund.currentState()).to.equal(2);
    });

    it("rejects announcement from a non-owner", async function () {
      await expect(fund.connect(user1).announceLaunch()).to.be.revertedWith("!owner");
    });

    it("announces launch successfully", async function () {
      const tx = await fund.announceLaunch();
      await tx.wait();
      expect(await fund.launchAnnouncementTime()).to.be.greaterThan(0n);
    });

    it("rejects double announcement", async function () {
      await expect(fund.announceLaunch()).to.be.revertedWith("!ann");
    });

    it("rejects finalization during the 6-hour notice period", async function () {
      await expect(fund.finalizeFunding()).to.be.revertedWith("!notice");
    });

    it("rejects finalization from a non-owner (even after notice would elapse)", async function () {
      await expect(fund.connect(user1).finalizeFunding()).to.be.revertedWith("!owner");
    });

    it("advances past the 6-hour notice period", async function () {
      await time.increase(PRE_LAUNCH_SECS + 1);
    });

    it("finalizes and creates Uniswap V3 pool after notice ends", async function () {
      // Finalization calls real WETH + PositionManager — requires Hardhat forking mode
      const code = await ethers.provider.getCode(WETH);
      if (code === "0x") { this.skip(); return; }

      const tx = await fund.finalizeFunding();
      const receipt = await tx.wait();

      expect(await fund.isFinalized()).to.be.true;
      expect(await fund.currentState()).to.equal(3);

      console.log("      Gas used:", receipt.gasUsed.toString(), "units");
    });

    it("has a valid LP NFT token ID and pool address", async function () {
      const code = await ethers.provider.getCode(WETH);
      if (code === "0x") { this.skip(); return; }

      const lpId = await fund.lpTokenId();
      const pool = await fund.uniswapPool();
      const tick = await fund.initialTick();

      expect(lpId).to.be.greaterThan(0n);
      expect(pool).to.not.equal(ethers.ZeroAddress);

      console.log("      LP Token ID :", lpId.toString());
      console.log("      Uniswap Pool:", pool);
      console.log("      Initial tick :", tick.toString());
    });

    it("rejects double finalization", async function () {
      const code = await ethers.provider.getCode(WETH);
      if (code === "0x") { this.skip(); return; }

      await expect(fund.finalizeFunding()).to.be.revertedWith("!done");
    });
  });

  // ================================================================
  //  PHASE 4 — Post-Finalization Verification
  // ================================================================
  describe("Phase 4 — Post-Finalization Checks", function () {
    it("lets contributors claim their PoP tokens", async function () {
      const code = await ethers.provider.getCode(WETH);
      if (code === "0x") { this.skip(); return; }

      expect(await token.balanceOf(user1.address)).to.equal(0n);

      await fund.connect(user1).claimTokens();

      const bal = await token.balanceOf(user1.address);
      expect(bal).to.be.greaterThan(0n);
      console.log("      User1 claimed:", ethers.formatEther(bal), "tokens");
    });

    it("rejects double claim", async function () {
      const code = await ethers.provider.getCode(WETH);
      if (code === "0x") { this.skip(); return; }

      await expect(fund.connect(user1).claimTokens()).to.be.revertedWith("!contrib");
    });

    it("calculateTargetSupply(initialTick) returns INITIAL_SUPPLY", async function () {
      const tick = await fund.initialTick();
      const target = await fund.calculateTargetSupply(tick);
      expect(target).to.equal(await fund.INITIAL_SUPPLY());
    });

    it("allows treasury to collect trading fees", async function () {
      const code = await ethers.provider.getCode(WETH);
      if (code === "0x") { this.skip(); return; }

      await expect(fund.connect(deployer).collectTradingFees()).to.not.be.reverted;
    });

    it("rejects fee collection from non-treasury", async function () {
      await expect(fund.connect(user1).collectTradingFees()).to.be.revertedWith("!ac");
    });
  });

  // ================================================================
  //  PHASE 5 — Refund Path (separate project, soft cap NOT met)
  // ================================================================
  describe("Phase 5 — Refund Path", function () {
    let fund2Addr, fund2;
    const SMALL_AMT = ethers.parseEther("0.003"); // TODO: REVERT FOR MAINNET ("0.1")

    it("launches a second project", async function () {
      const tx = await factory.launchNewProject("FailAgent", "FAIL", "ipfs://test", {
        value: ethers.parseEther("0.001"), // TODO: REVERT FOR MAINNET ("0.01")
      });
      await tx.wait();

      fund2Addr = await getLatestProject(factory);
      fund2 = await ethers.getContractAt("MeritXFund", fund2Addr);
      expect(await fund2.currentState()).to.equal(0);
    });

    it("accepts a contribution below the soft cap", async function () {
      const nonce = await fund2.nonces(user2.address);
      const dl = await futureDeadline();
      const sig = await signAllocation(signerWallet, user2.address, MAX_ALLOC, nonce, dl, fund2Addr, chainId);

      await fund2.connect(user2).contribute(MAX_ALLOC, dl, sig, { value: SMALL_AMT });
      expect(await fund2.totalRaised()).to.equal(SMALL_AMT);
    });

    it("enters Failed state (1) after raise deadline", async function () {
      await time.increase(RAISE_SECS + 1);
      expect(await fund2.currentState()).to.equal(1);
    });

    it("rejects contributions after deadline", async function () {
      const nonce = await fund2.nonces(user1.address);
      const dl = await futureDeadline();
      const sig = await signAllocation(signerWallet, user1.address, MAX_ALLOC, nonce, dl, fund2Addr, chainId);

      await expect(
        fund2.connect(user1).contribute(MAX_ALLOC, dl, sig, { value: ethers.parseEther("0.003") }) // TODO: REVERT FOR MAINNET ("0.1")
      ).to.be.revertedWith("!time");
    });

    it("rejects finalization on a failed project (no announcement possible)", async function () {
      await expect(fund2.announceLaunch()).to.be.revertedWith("!cap");
      await expect(fund2.finalizeFunding()).to.be.revertedWith("!notice");
    });

    it("lets the contributor claim a full ETH refund", async function () {
      const balBefore = await ethers.provider.getBalance(user2.address);

      const tx = await fund2.connect(user2).claimRefund();
      const receipt = await tx.wait();
      const gasCost = receipt.gasUsed * receipt.gasPrice;

      const balAfter = await ethers.provider.getBalance(user2.address);
      expect(balAfter).to.equal(balBefore + SMALL_AMT - gasCost);
      expect(await fund2.contributions(user2.address)).to.equal(0n);
    });

    it("rejects double refund", async function () {
      await expect(fund2.connect(user2).claimRefund()).to.be.revertedWith("!funds");
    });
  });

  // ================================================================
  //  PHASE 6 — Launch Window (30-day deadline + expired refund)
  // ================================================================
  describe("Phase 6 — Launch Window & Expired Refund", function () {
    let fund3Addr, fund3;
    const CONTRIB = ethers.parseEther("0.003"); // TODO: REVERT FOR MAINNET ("0.1")

    it("launches a third project for deadline testing", async function () {
      const tx = await factory.launchNewProject("DeadlineAgent", "DEAD", "ipfs://test", {
        value: ethers.parseEther("0.001"), // TODO: REVERT FOR MAINNET ("0.01")
      });
      await tx.wait();

      fund3Addr = await getLatestProject(factory);
      fund3 = await ethers.getContractAt("MeritXFund", fund3Addr);
      expect(await fund3.currentState()).to.equal(0);
    });

    it("contributes and fills to soft cap", async function () {
      this.timeout(120_000);
      const nonce = await fund3.nonces(user1.address);
      const dl = await futureDeadline();
      const sig = await signAllocation(signerWallet, user1.address, MAX_ALLOC, nonce, dl, fund3Addr, chainId);
      await fund3.connect(user1).contribute(MAX_ALLOC, dl, sig, { value: CONTRIB });

      await fillToSoftCap(fund3, fund3Addr, signerWallet, deployer, chainId);
      expect(await fund3.totalRaised()).to.be.gte(ethers.parseEther("0.01")); // TODO: REVERT FOR MAINNET ("15")
    });

    it("rejects refund while the launch window is still open", async function () {
      await time.increase(RAISE_SECS + 1);
      expect(await fund3.currentState()).to.equal(2);
      await expect(fund3.connect(user1).claimRefund()).to.be.revertedWith("!rna");
    });

    it("announces launch, then lets the 30-day window expire", async function () {
      await fund3.announceLaunch();
      expect(await fund3.launchAnnouncementTime()).to.be.greaterThan(0n);
      await time.increase(30 * 24 * 60 * 60);
    });

    it("rejects finalization after the 30-day window expires", async function () {
      await expect(fund3.finalizeFunding()).to.be.revertedWith("!le");
    });

    it("lets contributor claim a refund on an expired successful project", async function () {
      const balBefore = await ethers.provider.getBalance(user1.address);

      const tx = await fund3.connect(user1).claimRefund();
      const receipt = await tx.wait();
      const gasCost = receipt.gasUsed * receipt.gasPrice;

      const balAfter = await ethers.provider.getBalance(user1.address);
      expect(balAfter).to.equal(balBefore + CONTRIB - gasCost);
      expect(await fund3.contributions(user1.address)).to.equal(0n);
    });

    it("rejects double refund on expired project", async function () {
      await expect(fund3.connect(user1).claimRefund()).to.be.revertedWith("!funds");
    });
  });

  // ================================================================
  //  PHASE 7 — 24h Launch Expiration (announce → notice → 24h expires)
  // ================================================================
  describe("Phase 7 — 24h Post-Notice Expiration & Refund", function () {
    let fund4Addr, fund4;
    const CONTRIB = ethers.parseEther("0.003"); // TODO: REVERT FOR MAINNET ("0.1")

    it("launches a fourth project for 24h expiration testing", async function () {
      const tx = await factory.launchNewProject("ExpireAgent", "EXPR", "ipfs://test", {
        value: ethers.parseEther("0.001"), // TODO: REVERT FOR MAINNET ("0.01")
      });
      await tx.wait();

      fund4Addr = await getLatestProject(factory);
      fund4 = await ethers.getContractAt("MeritXFund", fund4Addr);
      expect(await fund4.currentState()).to.equal(0);
    });

    it("contributes and fills to soft cap", async function () {
      this.timeout(120_000);
      const nonce = await fund4.nonces(user2.address);
      const dl = await futureDeadline();
      const sig = await signAllocation(signerWallet, user2.address, MAX_ALLOC, nonce, dl, fund4Addr, chainId);
      await fund4.connect(user2).contribute(MAX_ALLOC, dl, sig, { value: CONTRIB });

      await fillToSoftCap(fund4, fund4Addr, signerWallet, deployer, chainId);
      expect(await fund4.totalRaised()).to.be.gte(ethers.parseEther("0.01")); // TODO: REVERT FOR MAINNET ("15")
    });

    it("advances past raise end", async function () {
      await time.increase(RAISE_SECS + 1);
      expect(await fund4.currentState()).to.equal(2);
    });

    it("announces launch", async function () {
      await fund4.announceLaunch();
      expect(await fund4.launchAnnouncementTime()).to.be.greaterThan(0n);
    });

    it("rejects refund while notice + execution window is still active", async function () {
      await expect(fund4.connect(user2).claimRefund()).to.be.revertedWith("!rna");
    });

    it("advances past the 6-hour notice period", async function () {
      await time.increase(PRE_LAUNCH_SECS + 1);
    });

    it("still rejects refund within the 24h execution window", async function () {
      await expect(fund4.connect(user2).claimRefund()).to.be.revertedWith("!rna");
    });

    it("advances past the 24-hour execution window", async function () {
      await time.increase(LAUNCH_EXP_SECS);
    });

    it("rejects finalization after the 24h window expires", async function () {
      await expect(fund4.finalizeFunding()).to.be.revertedWith("!le");
    });

    it("allows refund after 24h post-notice window expires", async function () {
      const balBefore = await ethers.provider.getBalance(user2.address);

      const tx = await fund4.connect(user2).claimRefund();
      const receipt = await tx.wait();
      const gasCost = receipt.gasUsed * receipt.gasPrice;

      const balAfter = await ethers.provider.getBalance(user2.address);
      expect(balAfter).to.equal(balBefore + CONTRIB - gasCost);
      expect(await fund4.contributions(user2.address)).to.equal(0n);
    });

    it("rejects double refund", async function () {
      await expect(fund4.connect(user2).claimRefund()).to.be.revertedWith("!funds");
    });

    it("confirms LAUNCH_EXPIRATION constant is 10 minutes", async function () { // TODO: REVERT FOR MAINNET (24 hours)
      expect(await fund4.LAUNCH_EXPIRATION()).to.equal(10n * 60n); // TODO: REVERT FOR MAINNET (24n * 60n * 60n)
    });
  });
});
