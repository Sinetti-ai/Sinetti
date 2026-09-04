import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";

// No .env loader here: dotenv is not a dependency of this repo. Export
// variables to the shell before running (`set -a; source .env; set +a`),
// see docs/deploy.md.
const deployerPrivateKey = process.env.DEPLOYER_PRIVATE_KEY?.trim();

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.26",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200
      },
      evmVersion: "berlin"
    }
  },
  networks: {
    hardhat: {},
    sepolia: {
      url: process.env.SEPOLIA_RPC_URL || "https://ethereum-sepolia-rpc.publicnode.com",
      accounts: deployerPrivateKey ? [deployerPrivateKey] : [],
      chainId: 11155111
    }
  },
  // hardhat-toolbox already bundles @nomicfoundation/hardhat-verify; no new
  // dependency needed for Etherscan verification.
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY || ""
  },
  typechain: {
    outDir: "typechain-types",
    target: "ethers-v6"
  }
};

export default config;
