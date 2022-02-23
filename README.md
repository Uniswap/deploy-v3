# Deploy Uniswap V3 Script

This package includes a CLI script for deploying the latest Uniswap V3 smart contracts to any EVM (Ethereum Virtual Machine) compatible network.

## Licensing

Please note that Uniswap V3 is under [BUSL license](https://github.com/Uniswap/v3-core#licensing) until the Change Date, currently 2023-04-01. Exceptions to the license may be specified by Uniswap Governance via Additional Use Grants, which can, for example, allow V3 to be deployed on new chains. Please follow the [Uniswap Governance process](https://gov.uniswap.org/t/community-governance-process/7732) to request a DAO vote for exceptions to the license, or to move up the Change Date.

License changes must be enacted via the [ENS domain](https://ens.domains/) uniswap.eth, which is controlled by Uniswap Governance. This means (among other things) that Governance has the power to associate arbitrary text with any subdomain of the form X.uniswap.eth. Modifications of the Change Date should be specified at v3-core-license-date.uniswap.eth, and Additional Use Grants should be specified at v3-core-license-grants.uniswap.eth. The process for associating text with a subdomain is detailed below:

1. If the subdomain does not already exist (which can be [checked at this URL](https://app.ens.domains/name/uniswap.eth/subdomains)), the [`setSubnodeRecord`](https://docs.ens.domains/contract-api-reference/ens#set-subdomain-record) function of the ENS registry should be called with the following arguments:

- `node`: `namehash('uniswap.eth')` (`0xa2a03459171c76bff45817330c10ef9f8af07011a33005b73b50189bbc7e7132`)
- `label`: `keccak256('v3-core-license-date')` (`0xee55740591b0fd5d7a28a6edc49567f6ff3febbe942ec0e2fa49ee536595085b`) or `keccak256('v3-core-license-grants')` (`0x15ff9b5bd7642701a10e5ea8fb29c957ffda4854cd028e9f6218506e6b509af2`)
- `owner`: [`0x1a9C8182C09F50C8318d769245beA52c32BE35BC`](https://etherscan.io/address/0x1a9c8182c09f50c8318d769245bea52c32be35bc), the Uniswap Governance Timelock
- `resolver`: [`0x4976fb03c32e5b8cfe2b6ccb31c09ba78ebaba41`](https://etherscan.io/address/0x4976fb03c32e5b8cfe2b6ccb31c09ba78ebaba41), the public ENS resolver.
- `ttl`: `0`

2. Then, the [`setText`](https://docs.ens.domains/contract-api-reference/publicresolver#set-text-data) function of the public resolver should be called with the following arguments:

- `node`: `namehash('v3-core-license-date.uniswap.eth')` (`0x0505ec7822d61b4cfb294f137d1a7f0ceedf162f555a4bf2f4be58a07cf266c5`) or `namehash('v3-core-license-grants.uniswap.eth')` (`0xa35d592ec6e5289a387cba1d5f82be794f495bd5a361a1fb314687c6aefea1f4`)
- `key`: A suitable label, such as `notice`.
- `value`: The text of the change. Note that text may already be associated with the subdomain in question. If it does, it can be reviewed at the following URLs for either [v3-core-license-date](https://app.ens.domains/name/v3-core-license-date.uniswap.eth/details) or [v3-core-license-grants](https://app.ens.domains/name/v3-core-license-grants.uniswap.eth/details), and appended to as desired.

Note: [`setContentHash`](https://docs.ens.domains/contract-api-reference/publicresolver#set-content-hash) may also be used to associate text with a subdomain, but `setText` is presented above for simplicity.

These contract function calls should ultimately be encoded into a governance proposal, about which more details are available [here](https://docs.uniswap.org/protocol/concepts/governance/overview).

## Usage

This package vends a CLI for executing a deployment script that results in a full deployment of Uniswap Protocol v3.
Get the arguments for running the latest version of the script via `npx @uniswap/deploy-v3 --help`.

As of `v1.0.3` the arguments are:

```text
> npx @uniswap/deploy-v3 --help
Usage: npx @uniswap/deploy-v3 [options]

Options:
  -pk, --private-key <string>               Private key used to deploy all contracts
  -j, --json-rpc <url>                      JSON RPC URL where the program should be deployed
  -w9, --weth9-address <address>            Address of the WETH9 contract on this chain
  -ncl, --native-currency-label <string>    Native currency label, e.g. ETH
  -o, --owner-address <address>             Contract address that will own the deployed artifacts after the script runs
  -s, --state <path>                        Path to the JSON file containing the migrations state (optional) (default: "./state.json")
  -v2, --v2-core-factory-address <address>  The V2 core factory address used in the swap router (optional)
  -g, --gas-price <number>                  The gas price to pay in GWEI for each transaction (optional)
  -c, --confirmations <number>              How many confirmations to wait for after each transaction (optional) (default: "2")
  -V, --version                             output the version number
  -h, --help                                display help for command
```

The script runs a set of migrations, each migration deploying a contract or executing a transaction. Migration state is
saved in a JSON file at the supplied path (by default `./state.json`).

To use the script, you must fund an address, and pass the private key of that address to the script so that it can construct
and broadcast the deployment transactions.

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

We estimate 30M - 40M gas needed to run the full deploy script.

### When I run the script, it says "Contract was already deployed..."

Delete `state.json` before a fresh deploy. `state.json` tracks which steps have already occurred. If there are any entries, the deploy script will attempt to pick up from the last step in `state.json`.

### Where can I see all the addresses where each contract is deployed?

Check out `state.json`. It'll show you the final deployed addresses.

### How long will the script take?

Depends on the confirmation times and gas parameter. The deploy script sends up to a total of 14 transactions.

### Where should I ask questions or report issues?

You can file them in `issues` on this repo and we'll try our best to respond.
