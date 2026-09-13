// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPriceSource} from "../interfaces/IPriceSource.sol";

interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Single Chainlink feed priced in a USD-stable quote token (e.g. WETH/HOLLAR
/// via the ETH/USD feed, treating HOLLAR as $1). `invert` flips the feed when the
/// feed's base asset is the pool's token1 rather than token0.
contract ChainlinkSource is IPriceSource {
    IAggregatorV3 public immutable feed;
    bool public immutable invert;
    /// @dev 10**(18 + quoteDecimals - baseDecimals) pre-invert; fixed at deploy
    uint256 public immutable scaleNum;
    uint256 public immutable feedScale;

    constructor(IAggregatorV3 _feed, bool _invert, uint8 baseTokenDecimals, uint8 quoteTokenDecimals) {
        feed = _feed;
        invert = _invert;
        feedScale = 10 ** _feed.decimals();
        // price of one raw base unit in raw quote units, X18:
        // human price * 10^quoteDec / 10^baseDec * 1e18
        scaleNum = 10 ** (18 + quoteTokenDecimals) / 10 ** baseTokenDecimals;
    }

    function priceX18() external view returns (uint256, uint256) {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0) return (0, 0);
        uint256 p = uint256(answer) * scaleNum / feedScale;
        if (invert) p = 1e36 / p;
        return (p, updatedAt);
    }
}
