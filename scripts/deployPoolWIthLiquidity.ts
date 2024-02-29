import { ethers, network } from "hardhat";
import { Contract } from "ethers";
import { Token } from "@uniswap/sdk-core";
import { Pool, Position, nearestUsableTick, TickMath } from "@uniswap/v3-sdk";

import UniswapV3Factory from '@uniswap/v3-core/artifacts/contracts/UniswapV3Factory.sol/UniswapV3Factory.json'
import UniswapV3Pool from '@uniswap/v3-core/artifacts/contracts/UniswapV3Pool.sol/UniswapV3Pool.json'
import NonfungiblePositionManager from '@uniswap/v3-periphery/artifacts/contracts/NonfungiblePositionManager.sol/NonfungiblePositionManager.json'
import { abi as ERC20ABI } from '../artifacts/contracts/Token.sol/Token.json';
import * as Univ3Addresses from "../state.json"
import { encodePriceSqrt } from "../src/util/sqrtPrice";

async function getPoolData(poolContract: Contract) {
  const [tickSpacing, fee, liquidity, slot0] = await Promise.all([
    poolContract.tickSpacing(),
    poolContract.fee(),
    poolContract.liquidity(),
    poolContract.slot0(),
  ])

  return {
    tickSpacing: tickSpacing,
    fee: fee,
    liquidity: liquidity,
    sqrtPriceX96: slot0[0],
    tick: slot0[1],
  }
}

async function main() {
  if (network.name !== "arbitrumSepolia") {
    console.warn("This script is only for arbitrum sepolia netework");
    return;
  }

  const [signer] = await ethers.getSigners();

  // ================= Deploy Weth/Usdc pool =================== //
  const wethAddress = "0x0133Ff8B0eA9f22e510ff3A8B245aa863b2Eb13F";
  const usdcAddress = "0x1CE4B22e19FC264F526D12e471312bAb49348Ea5";
  const wethContract = new Contract(wethAddress, ERC20ABI, signer);
  const usdcContract = new Contract(usdcAddress, ERC20ABI, signer);

  const feeTier = 500;
  const price = encodePriceSqrt(2000, 1);

  const factory = new Contract(Univ3Addresses.v3CoreFactoryAddress, UniswapV3Factory.abi, signer);
  const positionManager = new Contract(Univ3Addresses.nonfungibleTokenPositionManagerAddress, NonfungiblePositionManager.abi, signer);
  // await (await positionManager.createAndInitializePoolIfNecessary(wethAddress, usdcAddress, feeTier, price, { gasLimit: 5000000 })).wait();

  const poolAddress = await factory.getPool(wethAddress, usdcAddress, feeTier);
  console.log("======= SqrtPrice96 =======", price);
  console.log("======= Pool Address =======", poolAddress);


  // ================= Add Liquidity =================== //
  const poolContract = new ethers.Contract(poolAddress, UniswapV3Pool.abi, signer);
  const LIQUIDITY = ethers.parseEther('0.00000001');
  const DEADLINE = Math.floor(Date.now() / 1000) + (60 * 10);

  const WethToken = new Token(network.config.chainId!, wethAddress, 18, "WETH", "Wrapped Ether");
  const UsdcToken = new Token(network.config.chainId!, usdcAddress, 6, "USDC", "USD Coin");

  const poolData = await getPoolData(poolContract);
  console.log(poolData)
  /*
  {
    tickSpacing: 10n,
    fee: 500n,
    liquidity: 0n,
    sqrtPriceX96: 3543191142285914205922034323214n,
    tick: 76012n
  }
  */

  const pool = new Pool(WethToken, UsdcToken, Number(poolData.fee), poolData.sqrtPriceX96.toString(), poolData.liquidity.toString(), Number(poolData.tick));
  const tickLower = nearestUsableTick(Number(poolData.tick), Number(poolData.tickSpacing)) - Number(poolData.tickSpacing) * 100;
  const tickUpper = nearestUsableTick(Number(poolData.tick), Number(poolData.tickSpacing)) + Number(poolData.tickSpacing) * 100;
  const position = new Position({
    pool,
    liquidity: LIQUIDITY.toString(),
    tickLower,
    tickUpper
  });

  // await wethContract.approve(positionManager.target, ethers.parseEther('9999999'));
  // await usdcContract.approve(positionManager.target, ethers.parseEther('9999999'));

  const { amount0: amount0Desired, amount1: amount1Desired } = position.mintAmounts;
  console.log(await wethContract.balanceOf(signer.address), await usdcContract.balanceOf(signer.address))
  console.log(amount0Desired.toString(), amount1Desired.toString());return;
  const tx = await positionManager.mint({
    token0: wethAddress,
    token1: usdcAddress,
    fee: poolData.fee,
    tickLower,
    tickUpper,
    amount0Desired: amount0Desired.toString(),
    amount1Desired: amount1Desired.toString(),
    amount0Min: 0,
    amount1Min: 0,
    recipient: signer.address,
    deadline: DEADLINE
  },
  {
    gasLimit: '1000000'
  });
  await tx.wait();

  console.log('DONE!');
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
