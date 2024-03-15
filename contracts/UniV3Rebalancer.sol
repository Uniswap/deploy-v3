// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";

import "./interfaces/IExternalCallee.sol";
import "./interfaces/IWETH9.sol";
import "./interfaces/ISwapRouter.sol";

import "./libraries/Path.sol";
import "./libraries/PoolAddress.sol";
import "./libraries/CallbackValidation.sol";
import "./libraries/TickMath.sol";
import "forge-std/Test.sol";

contract UniV3Rebalancer is IExternalCallee, ISwapRouter {
    using Path for bytes;

    struct RebalanceData {
        address[] tokens;
        int256[] deltas;
        uint256[] amountsLimit;
        uint24 poolFee;
        uint160 sqrtPriceLimit;
        uint256 deadline;
        uint256 tokenId;
        bytes path;
    }

    event ExternalRebalanceSingleSwap(
        address indexed sender,
        address indexed caller,
        uint256 indexed tokenId,
        address tokenIn,
        address tokenOut,
        uint24 poolFee,
        uint256 amountIn,
        uint256 amountOut,
        bool isBuy
    );

    event ExternalRebalanceSwap(
        address indexed sender,
        address indexed caller,
        uint256 indexed tokenId,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bool isBuy
    );

    address public immutable uniFactory;
    address public immutable WETH9;

    uint256 private constant DEFAULT_AMOUNT_IN_CACHED = type(uint256).max;

    /// @dev Transient storage variable used for returning the computed amount in for an exact output swap.
    uint256 private amountInCached = DEFAULT_AMOUNT_IN_CACHED;

    constructor(address _uniFactory, address _WETH9) {
        uniFactory = _uniFactory;
        WETH9 = _WETH9;
    }

    function getPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) private view returns (IUniswapV3Pool) {
        return IUniswapV3Pool(PoolAddress.computeAddress(uniFactory, PoolAddress.getPoolKey(tokenA, tokenB, fee)));
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata _data
    ) external override {
        require(amount0Delta > 0 || amount1Delta > 0); // swaps entirely within 0-liquidity regions are not supported
        SwapCallbackData memory data = abi.decode(_data, (SwapCallbackData));
        (address tokenIn, address tokenOut, uint24 fee) = data.path.decodeFirstPool();
        CallbackValidation.verifyCallback(uniFactory, tokenIn, tokenOut, fee);

        (bool isExactInput, uint256 amountToPay) =
            amount0Delta > 0
                ? (tokenIn < tokenOut, uint256(amount0Delta))
                : (tokenOut < tokenIn, uint256(amount1Delta));

        if (isExactInput) {
            pay(tokenIn, data.payer, msg.sender, amountToPay);
        } else {
            // either initiate the next swap or pay
            if (data.path.hasMultiplePools()) {
                data.path = data.path.skipToken();
                exactOutputInternal(amountToPay, address(this), 0, data);
                // exactOutputInternal(amountToPay, msg.sender, 0, data);
            } else {
                amountInCached = amountToPay;
                tokenIn = tokenOut; // swap in/out because exact output swaps are reversed
                pay(tokenIn, data.payer, msg.sender, amountToPay);
            }
        }
    }

    /// @inheritdoc ISwapRouter
    function exactInputSingle(ExactInputSingleParams memory params)
        public
        payable
        override
        returns (uint256 amountOut)
    {
        require(block.timestamp <= params.deadline, "Transaction too old");
        amountOut = exactInputInternal(
            params.amountIn,
            params.recipient,
            params.sqrtPriceLimitX96,
            SwapCallbackData({path: abi.encodePacked(params.tokenIn, params.fee, params.tokenOut), payer: address(this)})
        );
        require(amountOut >= params.amountOutMinimum, "Too little received");
    }

    /// @inheritdoc ISwapRouter
    function exactInput(ExactInputParams memory params)
        public
        payable
        override
        returns (uint256 amountOut)
    {
        require(block.timestamp <= params.deadline, "Transaction too old");
        address payer = address(this);
        console.log("Exact Input");
        while (true) {
            bool hasMultiplePools = params.path.hasMultiplePools();

            // the outputs of prior swaps become the inputs to subsequent ones
            params.amountIn = exactInputInternal(
                params.amountIn,
                hasMultiplePools ? address(this) : params.recipient, // for intermediate swaps, this contract custodies
                0,
                SwapCallbackData({
                    path: params.path.getFirstPool(), // only the first pool in the path is necessary
                    payer: payer
                })
            );

            // decide whether to continue or terminate
            if (hasMultiplePools) {
                params.path = params.path.skipToken();
            } else {
                amountOut = params.amountIn;
                break;
            }
        }

        require(amountOut >= params.amountOutMinimum, "Too little received");
    }

    /// @inheritdoc ISwapRouter
    function exactOutputSingle(ExactOutputSingleParams memory params)
        public
        payable
        override
        returns (uint256 amountIn)
    {
        require(block.timestamp <= params.deadline, "Transaction too old");
        // avoid an SLOAD by using the swap return data
        amountIn = exactOutputInternal(
            params.amountOut,
            params.recipient,
            params.sqrtPriceLimitX96,
            SwapCallbackData({path: abi.encodePacked(params.tokenOut, params.fee, params.tokenIn), payer: address(this)})
        );

        require(amountIn <= params.amountInMaximum, "Too much requested");
        // has to be reset even though we don't use it in the single hop case
        amountInCached = DEFAULT_AMOUNT_IN_CACHED;
    }

    /// @inheritdoc ISwapRouter
    function exactOutput(ExactOutputParams memory params)
        public
        payable
        override
        returns (uint256 amountIn)
    {
        require(block.timestamp <= params.deadline, "Transaction too old");
        // it's okay that the payer is fixed to msg.sender here, as they're only paying for the "final" exact output
        // swap, which happens first, and subsequent swaps are paid for within nested callback frames
        console.log("Exact Output");
        exactOutputInternal(
            params.amountOut,
            params.recipient,
            0,
            SwapCallbackData({path: params.path, payer: address(this)})
        );

        amountIn = amountInCached;
        require(amountIn <= params.amountInMaximum, "Too much requested");
        amountInCached = DEFAULT_AMOUNT_IN_CACHED;
    }

    function externalCall(
        address sender,
        uint128[] calldata amounts,
        uint256 lpTokens,
        bytes calldata _data
    ) external {
        require(lpTokens == 0, "UniV3Rebalancer: Invalid deposit");

        RebalanceData memory data = abi.decode(_data, (RebalanceData));
        int256[] memory deltas = data.deltas;

        require(IERC20(data.tokens[0]).balanceOf(address(this)) >= uint256(amounts[0]), "UniV3Rebalancer: Invalid token amount");
        require(IERC20(data.tokens[1]).balanceOf(address(this)) >= uint256(amounts[1]), "UniV3Rebalancer: Invalid token amount");
        require((deltas[0] * deltas[1] == 0) && (deltas[0] + deltas[1] != 0), "UniV3Rebalancer: Invalid deltas");

        address caller = msg.sender;

        if (deltas[0] > 0 || deltas[1] > 0) {
            uint256 activeIndex = deltas[0] > 0 ? 0 : 1;

            if (data.path.length == 0) {
                ISwapRouter.ExactOutputSingleParams memory params = ISwapRouter.ExactOutputSingleParams({
                    tokenIn: data.tokens[1 - activeIndex],
                    tokenOut: data.tokens[activeIndex],
                    fee: data.poolFee,
                    recipient: address(this),
                    deadline: data.deadline,
                    amountOut: uint256(deltas[activeIndex]),
                    amountInMaximum: data.amountsLimit[1 - activeIndex],
                    sqrtPriceLimitX96: data.sqrtPriceLimit
                });
                uint256 amountIn = exactOutputSingle(params);

                emit ExternalRebalanceSingleSwap(sender, caller, data.tokenId, params.tokenIn, params.tokenOut, params.fee, amountIn, params.amountOut, true);
            } else {
                ISwapRouter.ExactOutputParams memory params =
                    ISwapRouter.ExactOutputParams({
                        path: data.path,
                        recipient: address(this),
                        deadline: block.timestamp,
                        amountOut: uint256(deltas[activeIndex]),
                        amountInMaximum: data.amountsLimit[1 - activeIndex]
                    });

                // Executes the swap, returning the amountIn actually spent.
                uint256 amountIn = exactOutput(params);
                emit ExternalRebalanceSwap(sender, caller, data.tokenId, data.tokens[1 - activeIndex], data.tokens[activeIndex], amountIn, params.amountOut, true);
            }
        } else if (deltas[0] < 0 || deltas[1] < 0) {
            uint256 activeIndex = deltas[0] < 0 ? 0 : 1;

            if (data.path.length == 0) {
                ExactInputSingleParams memory params = ExactInputSingleParams({
                    tokenIn: data.tokens[activeIndex],
                    tokenOut: data.tokens[1 - activeIndex],
                    fee: data.poolFee,
                    recipient: address(this),
                    deadline: data.deadline,
                    amountIn: uint256(-deltas[activeIndex]),
                    amountOutMinimum: data.amountsLimit[1 - activeIndex],
                    sqrtPriceLimitX96: data.sqrtPriceLimit
                });
                uint256 amountOut = exactInputSingle(params);

                emit ExternalRebalanceSingleSwap(sender, caller, data.tokenId, params.tokenIn, params.tokenOut, params.fee, params.amountIn, amountOut, false);
            } else {
                ISwapRouter.ExactInputParams memory params =
                    ISwapRouter.ExactInputParams({
                        path: data.path,
                        recipient: address(this),
                        deadline: block.timestamp,
                        amountIn: uint256(-deltas[activeIndex]),
                        amountOutMinimum: data.amountsLimit[1 - activeIndex]
                    });

                // Executes the swap.
                uint256 amountOut = exactInput(params);
                emit ExternalRebalanceSwap(sender, caller, data.tokenId, data.tokens[activeIndex], data.tokens[1 - activeIndex], params.amountIn, amountOut, true);
            }
        }

        for (uint256 i = 0; i < data.tokens.length; i ++) {
            uint256 balance = IERC20(data.tokens[i]).balanceOf(address(this));
            if (balance > 0) {
                TransferHelper.safeTransfer(data.tokens[i], caller, balance);
            }
        }
    }

    /// @dev Performs a single exact input swap
    function exactInputInternal(
        uint256 amountIn,
        address recipient,
        uint160 sqrtPriceLimitX96,
        SwapCallbackData memory data
    ) private returns (uint256 amountOut) {
        require(amountOut < 2**255, "Invalid amount");
        // allow swapping to the router address with address 0
        if (recipient == address(0)) recipient = address(this);

        (address tokenIn, address tokenOut, uint24 fee) = data.path.decodeFirstPool();

        bool zeroForOne = tokenIn < tokenOut;

        (int256 amount0, int256 amount1) =
            getPool(tokenIn, tokenOut, fee).swap(
                recipient,
                zeroForOne,
                int256(amountIn),
                sqrtPriceLimitX96 == 0
                    ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                    : sqrtPriceLimitX96,
                abi.encode(data)
            );

        return uint256(-(zeroForOne ? amount1 : amount0));
    }

    /// @dev Performs a single exact output swap
    function exactOutputInternal(
        uint256 amountOut,
        address recipient,
        uint160 sqrtPriceLimitX96,
        SwapCallbackData memory data
    ) private returns (uint256 amountIn) {
        require(amountOut < 2**255, "Invalid amount");
        // allow swapping to the router address with address 0
        if (recipient == address(0)) recipient = address(this);

        (address tokenOut, address tokenIn, uint24 fee) = data.path.decodeFirstPool();

        bool zeroForOne = tokenIn < tokenOut;
        console.log("************", recipient);
        (int256 amount0Delta, int256 amount1Delta) =
            getPool(tokenIn, tokenOut, fee).swap(
                recipient,
                zeroForOne,
                -int256(amountOut),
                sqrtPriceLimitX96 == 0
                    ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                    : sqrtPriceLimitX96,
                abi.encode(data)
            );
        console.log("=============");
        uint256 amountOutReceived;
        (amountIn, amountOutReceived) = zeroForOne
            ? (uint256(amount0Delta), uint256(-amount1Delta))
            : (uint256(amount1Delta), uint256(-amount0Delta));
        // it's technically possible to not receive the full output amount,
        // so if no price limit has been specified, require this possibility away
        if (sqrtPriceLimitX96 == 0) require(amountOutReceived == amountOut);
    }

    function pay(
        address token,
        address payer,
        address recipient,
        uint256 value
    ) internal {
        if (token == WETH9 && address(this).balance >= value) {
            // pay with WETH9
            IWETH9(WETH9).deposit{value: value}(); // wrap only what is needed to pay
            IWETH9(WETH9).transfer(recipient, value);
        } else if (payer == address(this)) {
            // pay with tokens already in the contract (for the exact input multihop case)
            TransferHelper.safeTransfer(token, recipient, value);
        } else {
            // pull payment
            TransferHelper.safeTransferFrom(token, payer, recipient, value);
        }
    }
}