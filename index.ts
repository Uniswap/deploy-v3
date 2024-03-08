import { Command } from 'commander'
import { Wallet } from '@ethersproject/wallet'
import { JsonRpcProvider, TransactionReceipt } from '@ethersproject/providers'
import { AddressZero } from '@ethersproject/constants'
import { getAddress } from '@ethersproject/address'
import fs from 'fs'
import deploy from './src/deploy'
import { MigrationState, StepOutput } from './src/migrations'
import { asciiStringToBytes32 } from './src/util/asciiStringToBytes32'
import { version } from './package.json'

const program = new Command()

program
  .requiredOption('-pk, --private-key <string>', 'Private key used to deploy all contracts')
  .requiredOption('-j, --json-rpc <url>', 'JSON RPC URL where the program should be deployed')
  .requiredOption('-w9, --weth9-address <address>', 'Address of the WETH9 contract on this chain')
  .requiredOption('-ncl, --native-currency-label <string>', 'Native currency label, e.g. ETH')
  .requiredOption(
    '-o, --owner-address <address>',
    'Contract address that will own the deployed artifacts after the script runs',
  )
  .option('-s, --state <path>', 'Path to the JSON file containing the migrations state (optional)', './state.json')
  .option('-v2, --v2-core-factory-address <address>', 'The V2 core factory address used in the swap router (optional)')
  .option('-g, --gas-price <number>', 'The gas price to pay in GWEI for each transaction (optional)')
  .option('-c, --confirmations <number>', 'How many confirmations to wait for after each transaction (optional)', '2')

program.name('npx @uniswap/deploy-v3').version(version).action(action)

async function action(options: any) {
  if (!/^0x[a-zA-Z0-9]{64}$/.test(options.privateKey)) {
    console.error('Invalid private key!')
    process.exit(1)
  }

  let url: URL
  try {
    url = new URL(options.jsonRpc)
  } catch (error) {
    console.error('Invalid JSON RPC URL', (error as Error).message)
    process.exit(1)
  }

  let gasPrice: number | undefined
  try {
    gasPrice = options.gasPrice ? parseInt(options.gasPrice) : undefined
  } catch (error) {
    console.error('Failed to parse gas price', (error as Error).message)
    process.exit(1)
  }

  let confirmations: number
  try {
    confirmations = parseInt(options.confirmations)
  } catch (error) {
    console.error('Failed to parse confirmations', (error as Error).message)
    process.exit(1)
  }

  let nativeCurrencyLabelBytes: string
  try {
    nativeCurrencyLabelBytes = asciiStringToBytes32(options.nativeCurrencyLabel)
  } catch (error) {
    console.error('Invalid native currency label', (error as Error).message)
    process.exit(1)
  }

  let weth9Address: string
  try {
    weth9Address = getAddress(options.weth9Address)
  } catch (error) {
    console.error('Invalid WETH9 address', (error as Error).message)
    process.exit(1)
  }

  let v2CoreFactoryAddress: string
  if (typeof options.v2CoreFactoryAddress === 'undefined') {
    v2CoreFactoryAddress = AddressZero
  } else {
    try {
      v2CoreFactoryAddress = getAddress(options.v2CoreFactoryAddress)
    } catch (error) {
      console.error('Invalid V2 factory address', (error as Error).message)
      process.exit(1)
    }
  }

  let ownerAddress: string
  try {
    ownerAddress = getAddress(options.ownerAddress)
  } catch (error) {
    console.error('Invalid owner address', (error as Error).message)
    process.exit(1)
  }

  const wallet = new Wallet(options.privateKey, new JsonRpcProvider({ url: url.href }))

  let state: MigrationState
  if (fs.existsSync(options.state)) {
    try {
      state = JSON.parse(fs.readFileSync(options.state, { encoding: 'utf8' }))
    } catch (error) {
      console.error('Failed to load and parse migration state file', (error as Error).message)
      process.exit(1)
    }
  } else {
    state = {}
  }

  let finalState: MigrationState
  const onStateChange = async (newState: MigrationState): Promise<void> => {
    fs.writeFileSync(options.state, JSON.stringify(newState, null, 2))
    finalState = newState
  }

  async function run() {
    let step = 1
    const results: StepOutput[][] = []
    const generator = deploy({
      signer: wallet,
      gasPrice,
      nativeCurrencyLabelBytes,
      v2CoreFactoryAddress,
      ownerAddress,
      weth9Address,
      initialState: state,
      onStateChange,
    })

    for await (const result of generator) {
      console.log(`Step ${step++} complete`, result)
      results.push(result)

      // wait 15 minutes for any transactions sent in the step
      await Promise.all(
        result.map((stepResult): Promise<TransactionReceipt | true> => {
          if (stepResult.hash) {
            return wallet.provider.waitForTransaction(stepResult.hash, confirmations, /* 15 minutes */ 1000 * 60 * 15)
          } else {
            return Promise.resolve(true)
          }
        }),
      )
    }

    return results
  }

  run()
    .then((results) => {
      console.log('Deployment succeeded')
      console.log(JSON.stringify(results))
      console.log('Final state')
      console.log(JSON.stringify(finalState))
      process.exit(0)
    })
    .catch((error) => {
      console.error('Deployment failed', error)
      console.log('Final state')
      console.log(JSON.stringify(finalState))
      process.exit(1)
    })
}

program.parse(process.argv)
