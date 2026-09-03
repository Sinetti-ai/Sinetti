import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";

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
  networks: { hardhat: {} },
  typechain: {
    outDir: "typechain-types",
    target: "ethers-v6"
  }
};

export default config;
