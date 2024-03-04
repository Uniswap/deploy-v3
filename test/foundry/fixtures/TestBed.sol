// SPDX-License-Identifier: GPL-v3
pragma solidity ^0.8.0;

import "./UniswapSetup.sol";

contract TestBed is UniswapSetup {
    function initSetup() public {
        initTokens();
        initUniswap();
    }
}