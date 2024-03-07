// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

interface IExternalCallee {
    function externalCall(address sender, uint128[] calldata amounts, uint256 lpTokens, bytes calldata data) external;
}
