// SPDX-License-Identifier: GPL-v3
pragma solidity ^0.8.0;

import "./fixtures/TestBed.sol";
import "../../contracts/UniV3Rebalancer.sol";

contract UniV3RebalanerFuzz is TestBed {
    UniV3Rebalancer rebalancer;

    function setUp() public {
        initSetup();
        rebalancer = new UniV3Rebalancer(address(swapRouter));
    }

    function testStates() public {
        assertGt(weth.balanceOf(address(wethUsdcPool)), 100 * 1e18);
        assertGt(usdc.balanceOf(address(wethUsdcPool)), 300000 * 1e6);
    }

    function testRebalance() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(usdc);
        int256[] memory deltas = new int256[](2);
        deltas[0] = 1e18;   // buy 1 WETH
        uint256[] memory amountsLimit = new uint256[](2);
        amountsLimit[1] = 3200e6;   // max spend 3200 usdc
        UniV3Rebalancer.RebalanceData memory data = UniV3Rebalancer.RebalanceData({
            tokens: tokens,
            deltas: deltas,
            amountsLimit: amountsLimit,
            poolFee: poolFee,
            sqrtPriceLimit: 0,
            deadline: type(uint256).max,
            tokenId: 100
        });
        usdc.mint(address(rebalancer), 5000);

        uint128[] memory amounts = new uint128[](2);
        amounts[1] = 5000 * 1e6;
        rebalancer.externalCall(vm.addr(1), amounts, 0, abi.encode(data));
    }
}