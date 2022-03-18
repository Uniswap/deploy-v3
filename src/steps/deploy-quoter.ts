import Quoter from '@uniswap/swap-router-contracts/artifacts/contracts/lens/Quoter.sol/Quoter.json'
import createDeployContractStep from './meta/createDeployContractStep'

export const DEPLOY_QUOTER = createDeployContractStep({
  key: 'quoterAddress',
  artifact: Quoter,
  computeArguments(state, config) {
    if (state.v3CoreFactoryAddress === undefined) {
      throw new Error('Missing V3 Core Factory')
    }
    return [state.v3CoreFactoryAddress, config.weth9Address]
  },
})
