import { ethers, network } from 'hardhat'
import { Contract } from 'ethers'
import SwapRouter02 from '@uniswap/swap-router-contracts/artifacts/contracts/SwapRouter02.sol/SwapRouter02.json'

import * as Univ3Addresses from '../state.json'
import { abi as ERC20ABI } from '../artifacts/contracts/Token.sol/Token.json'

async function main() {
  if (network.name !== 'arbitrumSepolia') {
    console.warn('This script is only for arbitrum sepolia netework')
    return
  }

  const [signer] = await ethers.getSigners()

  const swapRouter = new ethers.Contract(Univ3Addresses.swapRouter02, SwapRouter02.abi, signer)
  const wethAddress = '0x0133Ff8B0eA9f22e510ff3A8B245aa863b2Eb13F'
  const usdcAddress = '0x1CE4B22e19FC264F526D12e471312bAb49348Ea5'
  const wethContract = new Contract(wethAddress, ERC20ABI, signer)
  const usdcContract = new Contract(usdcAddress, ERC20ABI, signer)

  await usdcContract.approve(Univ3Addresses.swapRouter02, ethers.MaxUint256);

  const params = {
    tokenIn: usdcAddress,
    tokenOut: wethAddress,
    fee: 10000,
    recipient: signer.address,
    deadline: Math.floor(Date.now() / 1000) + 60 * 10,
    amountOut: ethers.parseEther('0.1'),
    amountInMaximum: ethers.parseUnits('1000', 6),
    sqrtPriceLimitX96: 0
  }
  const tx = await swapRouter.exactOutputSingle(params);
  await tx.wait();
  console.log("DONE!");
}

main().catch((error) => {
  console.error(error)
  process.exitCode = 1
})
