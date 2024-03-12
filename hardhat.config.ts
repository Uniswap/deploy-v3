import dotenv from 'dotenv'

import { HardhatUserConfig } from 'hardhat/config'
import '@nomicfoundation/hardhat-toolbox'
import '@nomicfoundation/hardhat-foundry'

dotenv.config()

const config: HardhatUserConfig = {
  defaultNetwork: 'hardhat',
  solidity: {
    version: '0.8.21',
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
      evmVersion: 'paris',
    },
  },
  networks: {
    hardhat: {
      chainId: 31337,
      allowUnlimitedContractSize: true,
    },
    arbitrum: {
      url: `https://arb-mainnet.g.alchemy.com/v2/${process.env.ALCHEMY_ARBITRUM_API_KEY}`,
      accounts: {
        mnemonic: process.env.ARBITRUM_MNEMONIC || '',
      },
      chainId: 42161,
    },
    arbitrumSepolia: {
      url: `https://arb-sepolia.g.alchemy.com/v2/${process.env.ALCHEMY_ARBITRUM_SEPOLIA_API_KEY}`,
      accounts: {
        mnemonic: process.env.ARBITRUM_SEPOLIA_MNEMONIC || '',
      },
      chainId: 421614,
    },
  },
}

export default config
