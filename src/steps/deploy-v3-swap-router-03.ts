import SwapRouter03 from '@uniswap/v3-periphery/artifacts/contracts/SwapRouter.sol/SwapRouter.json'
import createDeployContractStep from './meta/createDeployContractStep'

export const DEPLOY_V3_SWAP_ROUTER_03 = createDeployContractStep({
  key: 'swapRouter03',
  artifact: SwapRouter03,
  computeArguments(state, config) {
    if (state.v3CoreFactoryAddress === undefined) {
      throw new Error('Missing V3 Core Factory')
    }

    return [
      state.v3CoreFactoryAddress,
      config.weth9Address,
    ]
  },
})
