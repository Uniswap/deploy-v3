// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPriceSource} from "../../src/interfaces/IPriceSource.sol";

contract MockPriceSource is IPriceSource {
    uint256 public price;
    uint256 public updatedAt;

    constructor(uint256 _price) {
        price = _price;
        updatedAt = block.timestamp;
    }

    function set(uint256 _price, uint256 _updatedAt) external {
        price = _price;
        updatedAt = _updatedAt;
    }

    function priceX18() external view returns (uint256, uint256) {
        return (price, updatedAt);
    }
}
