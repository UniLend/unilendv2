var HDWalletProvider = require("truffle-hdwallet-provider")
const MNEMONIC = process.env.MNEMONIC
const API_KEY = process.env.API_KEY
const ETHERSCAN_API_KEY = process.env.ETHERSCAN_API_KEY


module.exports = {
  // See <http://truffleframework.com/docs/advanced/configuration>
  // to customize your Truffle configuration!
  networks: {
    development: {
      quiet: true,
      host: "localhost",
      port: 8545,
      network_id: "*" // match any network
    },
    kovan: {
      provider: function() {
        return new HDWalletProvider(
          MNEMONIC,
          `https://kovan.infura.io/${API_KEY}`
        )
      },
      network_id: 42,
      gas: 8000000
    },
    ropsten: {
      provider: function() {
        return new HDWalletProvider(
          MNEMONIC,
          `https://ropsten.infura.io/v3/${API_KEY}`
        )
      },
      network_id: 3,
      gas: 7000000,
      gasPrice: 15000000000, // 15 gwei
      skipDryRun: true
    },
    mainnet: {
      provider: function() {
        return new HDWalletProvider(
          MNEMONIC,
          `https://mainnet.infura.io/v3/${API_KEY}`
        )
      },
      network_id: 1,
      gas: 7000000
    }
  },

  // Set default mocha options here, use special reporters etc.
  mocha: {
    // timeout: 100000
  },
  plugins: ['truffle-plugin-verify'],
  // Configure your compilers
  compilers: {
    solc: {
      version: "0.8.2", // Fetch exact version from solc-bin (default: truffle's version)
      docker: false, // Use "0.5.1" you've installed locally with docker (default: false)
      settings: {
        // See the solidity docs for advice about optimization and evmVersion
        optimizer: {
          enabled: true,
          runs: 200
        }
      }
    }
  },

  mocha: {
    reporter: "eth-gas-reporter",
    reporterOptions: {
      currency: "USD",
      gasPrice: 21,
      outputFile: "/dev/null",
      showTimeSpent: true
    }
  },
  verify: {
    preamble: 'UniLend Finance V2 Contract'
  },
  api_keys: {
    etherscan: ETHERSCAN_API_KEY
  }
}
