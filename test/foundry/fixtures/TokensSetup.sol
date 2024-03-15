// SPDX-License-Identifier: GPL-v3
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../../contracts/Token.sol";

contract TokensSetup is Test {
    Token weth;
    Token usdc;
    Token usdt;

    function initTokens() public {
        weth = new Token("Wrapped ETH", "WETH", 18);
        usdc = new Token("USD Coin", "USDC", 6);
        usdt = new Token("Tether USD", "USDT", 6);

        if (weth > usdc) {
            (weth, usdc) = (usdc, weth);

            weth.setName("Wrapped ETH");
            weth.setSymbol("WETH");
            weth.setDecimals(18);

            usdc.setName("USD Coin");
            usdc.setSymbol("USDC");
            usdc.setDecimals(6);
        }

        if (weth > usdt) {
            (weth, usdt) = (usdt, weth);

            weth.setName("Wrapped ETH");
            weth.setSymbol("WETH");
            weth.setDecimals(18);

            usdt.setName("Tether USD");
            usdt.setSymbol("USDT");
            usdt.setDecimals(6);
        }
    }
}