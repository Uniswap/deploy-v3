// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPriceSource} from "../interfaces/IPriceSource.sol";
import {IAggregatorV3} from "./ChainlinkSource.sol";

/// @notice Price from the ratio of two same-quote feeds (e.g. HDX/USD ÷ ETH/USD for
/// a WETH/HDX pool). token0's feed is the numerator. Staleness is the older of the two.
contract RatioSource is IPriceSource {
    IAggregatorV3 public immutable feedBase; // prices pool token0 in USD
    IAggregatorV3 public immutable feedQuote; // prices pool token1 in USD
    uint256 public immutable baseScale;
    uint256 public immutable quoteScale;
    uint256 public immutable decimalsScaleNum; // 10^(18+dec1)
    uint256 public immutable decimalsScaleDen; // 10^dec0

    constructor(IAggregatorV3 _feedBase, IAggregatorV3 _feedQuote, uint8 token0Decimals, uint8 token1Decimals) {
        feedBase = _feedBase;
        feedQuote = _feedQuote;
        baseScale = 10 ** _feedBase.decimals();
        quoteScale = 10 ** _feedQuote.decimals();
        decimalsScaleNum = 10 ** (18 + uint256(token1Decimals));
        decimalsScaleDen = 10 ** uint256(token0Decimals);
    }

    function priceX18() external view returns (uint256, uint256) {
        (, int256 aB,, uint256 uB,) = feedBase.latestRoundData();
        (, int256 aQ,, uint256 uQ,) = feedQuote.latestRoundData();
        if (aB <= 0 || aQ <= 0) return (0, 0);
        // human ratio = (aB/baseScale) / (aQ/quoteScale); raw-unit X18 applies token decimals
        uint256 p = uint256(aB) * quoteScale * decimalsScaleNum / (uint256(aQ) * baseScale) / decimalsScaleDen;
        return (p, uB < uQ ? uB : uQ);
    }
}
