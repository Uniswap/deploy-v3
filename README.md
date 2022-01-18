# Deploy Uniswap V3 Script

This package includes a CLI script for deploying the latest Uniswap V3 smart contracts to any EVM (Ethereum Virtual Machine) compatible network.

## Usage

Get the arguments for running the latest version of the script via `npx @uniswap/deploy-v3 --help`.

As of `v1.0.1` the arguments are:

```text
> npx @uniswap/deploy-v3 --help
Usage: npx @uniswap/deploy-v3 [options]

Options:
Usage: npx @uniswap/deploy-v3 [options]

Options:
  -pk, --private-key <string>               Private key used to deploy all contracts
  -j, --json-rpc <url>                      JSON RPC URL where the program should be deployed
  -w9, --weth9-address <address>            Address of the WETH9 contract on this chain
  -ncl, --native-currency-label <string>    Native currency label, e.g. ETH
  -o, --owner-address <address>             Contract address that will own the deployed artifacts after the script runs
  -s, --state <path>                        Path to the JSON file containing the migrations state (optional) (default: "./
                                            state.json")
  -v2, --v2-core-factory-address <address/  The V2 core factory address used in the swap router (optional)
  -g, --gas-price <number>                  The gas price to pay in GWEI for each transaction (optional)
  -c, --confirmations <number>              How many confirmations to wait for after each transaction (optional) (default: "2")
  -V, --version                             output the version number
  -h, --help                                display help for command
```

This script runs a set of migrations, each migration deploying a contract or executing a transaction.

To use the script, you must fund an address, and pass the private key to the script so it can construct and broadcast
the deployment transactions. 

The block explorer verification process (e.g. Etherscan) is specific to the network. For the existing deployments,
we have used the `@nomiclabs/hardhat-etherscan` hardhat plugin in the individual repositories to verify the deployment addresses.

Note that in between deployment steps, the script waits for confirmations. By default, this is set to `2`. If the network
only mines blocks when the transactions is queued (e.g. a local testnet), you must set confirmations to `0`.

## Development

To run unit tests, run `yarn test`.

For testing the script, run `yarn start`.

To publish the script, first create a version: `npm version <version identifier>`, then publish via `npm publish`.
Don't forget to push your tagged commit!

## FAQs

### How much gas should I expect to use for full completion?

We estimate 30M - 40M gwei needed to run the full deploy script.

### When I run the script, it says "Contract was already deployed..."

Delete `state.json` before a fresh deploy. `state.json` tracks which steps have already occurred. If there are any entries, the deploy script will attempt to pick up from the last step in `state.json`. 

### Where can I see all the addresses where each contract is deployed?

Check out `state.json`. It'll show you the final deployed addresses.

### How long will the script take?

Depends on the confirmation times and gas parameter. There are a total of 14 individual deploys on chain.

### Where should I ask questions or report issues?

You can file them in `issues` on this repo and we'll try our best to respond.

