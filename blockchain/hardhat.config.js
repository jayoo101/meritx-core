require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config({ path: __dirname + '/.env' });

const raw = (process.env.PRIVATE_KEY || '').replace(/^["']|["']$/g, '').trim();
const hex = raw.replace(/^0x/, '');
if (raw && hex.length !== 64) {
  console.warn(`\n⚠️  PRIVATE_KEY is ${hex.length} hex chars (expected 64). Deployment will fail.\n`);
}
const validPk = hex.length === 64 && /^[0-9a-fA-F]{64}$/.test(hex) ? [`0x${hex}`] : [];

module.exports = {
  solidity: {
    version: "0.8.20",
    settings: {
      optimizer: { enabled: true, runs: 1 },
      viaIR: true,
      evmVersion: "shanghai",
    },
  },
  networks: {
    hardhat: {},
    baseSepolia: {
      // Prefer .env value; fallback to public RPC
      url: process.env.BASE_SEPOLIA_RPC || "https://base-sepolia-rpc.publicnode.com",
      chainId: 84532,
      accounts: validPk,
      timeout: 100000, // Extended timeout for Base Sepolia
    },
    baseMainnet: {
      url: process.env.BASE_MAINNET_RPC || "https://mainnet.base.org",
      chainId: 8453,
      accounts: validPk,
    },
  },
  etherscan: {
    apiKey: process.env.BASESCAN_API_KEY || '',
  },
  mocha: {
    timeout: 120000,
  },
};