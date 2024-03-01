// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "./interfaces/IExternalCallee.sol";

contract UniV3Rebalancer is IExternalCallee {
    struct RebalanceData {
        address[] tokens;
        int256[] deltas;
        uint256[] amountsLimit;
        uint24 poolFee;
        uint160 sqrtPriceLimit;
        uint256 deadline;
    }

    address public immutable swapRouter;

    constructor(address _swapRouter) {
        swapRouter = _swapRouter;
    }

    function externalCall(address sender, uint128[] calldata amounts, uint256 lpTokens, bytes calldata _data) external {
        require(lpTokens == 0, "UniV3Rebalancer: Invalid deposit");

        RebalanceData memory data = abi.decode(_data, (RebalanceData));
        int256[] memory deltas = data.deltas;

        require(IERC20(data.tokens[0]).balanceOf(address(this)) == uint256(amounts[0]), "UniV3Rebalancer: Invalid token amount");
        require(IERC20(data.tokens[1]).balanceOf(address(this)) == uint256(amounts[1]), "UniV3Rebalancer: Invalid token amount");
        require((deltas[0] * deltas[1] == 0) && (deltas[0] + deltas[1] != 0), "UniV3Rebalancer: Invalid deltas");

        if (deltas[0] > 0 || deltas[1] > 0) {
            uint256 activeIndex = deltas[0] > 0 ? 0 : 1;

            TransferHelper.safeApprove(data.tokens[1 - activeIndex], swapRouter, amounts[1 - activeIndex]);

            ISwapRouter.ExactOutputSingleParams memory params =
                ISwapRouter.ExactOutputSingleParams({
                    tokenIn: data.tokens[1 - activeIndex],
                    tokenOut: data.tokens[activeIndex],
                    fee: data.poolFee,
                    recipient: address(this),
                    deadline: data.deadline,
                    amountOut: uint256(deltas[activeIndex]),
                    amountInMaximum: data.amountsLimit[1 - activeIndex],
                    sqrtPriceLimitX96: data.sqrtPriceLimit
                });
            ISwapRouter(swapRouter).exactOutputSingle(params);

            require(
                IERC20(data.tokens[activeIndex]).balanceOf(address(this)) >=
                uint256(amounts[activeIndex]) + uint256(deltas[activeIndex]),
                "UniV3Rebalancer: Min Amount"
            );
        } else if (deltas[0] < 0 || deltas[1] < 0) {
            uint256 activeIndex = deltas[0] < 0 ? 0 : 1;

            TransferHelper.safeApprove(data.tokens[activeIndex], swapRouter, amounts[activeIndex]);

            ISwapRouter.ExactInputSingleParams memory params =
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: data.tokens[activeIndex],
                    tokenOut: data.tokens[1 - activeIndex],
                    fee: data.poolFee,
                    recipient: address(this),
                    deadline: data.deadline,
                    amountIn: uint256(-deltas[activeIndex]),
                    amountOutMinimum: data.amountsLimit[1 - activeIndex],
                    sqrtPriceLimitX96: data.sqrtPriceLimit
                });
            ISwapRouter(swapRouter).exactInputSingle(params);

            require(
                IERC20(data.tokens[1 - activeIndex]).balanceOf(address(this)) >=
                uint256(amounts[1 - activeIndex]) + data.amountsLimit[1 - activeIndex],
                "UniV3Rebalancer: Min Amount"
            );
        }

        address caller = msg.sender;
        for (uint256 i = 0; i < data.tokens.length; i ++) {
            uint256 balance = IERC20(data.tokens[i]).balanceOf(address(this));
            if (balance > 0) {
                TransferHelper.safeTransfer(data.tokens[0], caller, balance);
            }
        }
    }
}