# Deploy Uniswap V3 Script

This package includes a CLI script for deploying the latest Uniswap V3 smart contracts to any Ethereum compatible network.

## Usage

Get the arguments for running the latest version of the script via `npx @uniswap/deploy-v3 --help`:

```shell
moody@MacBook-Pro ~/I/uniswap> npx @uniswap/deploy-v3 --help
Usage: npx @uniswap/deploy-v3 [options]

Options:
  -pk, --private-key <string>               The private key used to deploy all contracts
  -j, --json-rpc <url>                      The JSON RPC URL where the program should be deployed
  -s, --state <path>                        Path to the JSON file containing the migrations state
  -w9, --weth9-address <address>            The address of the WETH9 contract to use
  -ncl, --native-currency-label <string>    The label of the native currency, e.g. ETH
  -v2, --v2-core-factory-address <address>  The V2 core factory address used in the swap router
  -o, --owner-address <address>             The address of the contract that will own the deployed artifacts after the
                                            migration runs
  -g, --gas-price <number>                  The gas price to pay in GWEI for each transaction
  -c, --confirmations <number>              How many confirmations to wait for after each transaction (default: "2")
  -V, --version                             output the version number
  -h, --help                                display help for command
```

The smart contract verification process is specific to the network. For existing deployments, we have used the
`@nomiclabs/hardhat-etherscan` hardhat plugin in the individual repositories to verify the deployment addresses.

Note that in between deployment steps, the script waits for confirmations. By default, this is set to `2`. If the network
only mines blocks when the transactions is queued (e.g. a local testnet), you must set confirmations to `0`.

## Development

To run unit tests, run `yarn test`.

For testing the script, run `yarn start`.

To publish the script, first create a version: `npm version <version identifier>`, then publish via `npm publish`.
Don't forget to push your tagged commit!
