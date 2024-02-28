import { ethers, network } from 'hardhat'
import { encodePriceSqrt } from '../src/util/sqrtPrice'
import UniswapV3Factory from '@uniswap/v3-core/artifacts/contracts/UniswapV3Factory.sol/UniswapV3Factory.json'
import NonfungiblePositionManager from '@uniswap/v3-periphery/artifacts/contracts/NonfungiblePositionManager.sol/NonfungiblePositionManager.json'
import * as Univ3Addresses from '../state.json'

async function main() {
  if (network.name !== 'arbitrumSepolia') {
    console.warn('This script is only for arbitrum sepolia netework')
    return
  }

  const [signer] = await ethers.getSigners()

  const wethAddress = '0x0133Ff8B0eA9f22e510ff3A8B245aa863b2Eb13F'
  const usdtAddress = '0x1Be207F7AE412c6Deb0505485a36BFBdBd921D89'
  const usdcAddress = '0x1CE4B22e19FC264F526D12e471312bAb49348Ea5'
  const feeTier = 3000
  const price = encodePriceSqrt(2000, 1)

  const factory = new ethers.Contract(Univ3Addresses.v3CoreFactoryAddress, UniswapV3Factory.abi, signer)
  const positionManager = new ethers.Contract(
    Univ3Addresses.nonfungibleTokenPositionManagerAddress,
    NonfungiblePositionManager.abi,
    signer,
  )
  await (
    await positionManager.createAndInitializePoolIfNecessary(wethAddress, usdcAddress, feeTier, price, {
      gasLimit: 5000000,
    })
  ).wait()

  const poolAddress = await factory.getPool(wethAddress, usdcAddress, feeTier)

  console.log('======= Pool Address =======', poolAddress)
}

main().catch((error) => {
  console.error(error)
  process.exitCode = 1
})
