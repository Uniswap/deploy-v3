// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Reference price for a v4 pool, oriented as the pool is: raw token1 units
/// per raw token0 unit, scaled by 1e18. Decimal adjustment between the two tokens
/// is the source's job, so the hook can compare directly against pool state.
interface IPriceSource {
    /// @return priceX18 raw token1 per raw token0, 1e18 fixed point
    /// @return updatedAt unix time of the oldest feed round backing this price
    function priceX18() external view returns (uint256 priceX18, uint256 updatedAt);
}
