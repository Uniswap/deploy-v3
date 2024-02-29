// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract Token is ERC20 {
  constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}
}
