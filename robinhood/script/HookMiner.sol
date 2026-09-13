// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Mines a CREATE2 salt so the deployed hook address carries the
/// required permission flags in its low 14 bits.
library HookMiner {
    uint160 internal constant FLAG_MASK = 0x3FFF;
    // canonical deterministic-deployment-proxy used by `forge create2` / scripts
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function find(uint160 flags, bytes memory creationCodeWithArgs)
        internal
        view
        returns (address hookAddress, bytes32 salt)
    {
        bytes32 initHash = keccak256(creationCodeWithArgs);
        for (uint256 i = 0; i < 500_000; i++) {
            salt = bytes32(i);
            hookAddress = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, initHash))))
            );
            if (uint160(hookAddress) & FLAG_MASK == flags && hookAddress.code.length == 0) {
                return (hookAddress, salt);
            }
        }
        revert("HookMiner: no salt found");
    }
}
