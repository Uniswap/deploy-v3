// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Deploys BandHook via the canonical CREATE2 proxy at a salt-mined address whose
// low bits encode AFTER_INITIALIZE | BEFORE_SWAP (0x1080).
//
//   forge script script/00_DeployBandHook.s.sol --rpc-url robinhood --broadcast
//
// env: PRIVATE_KEY (deployer; becomes initial hook owner for setup, hand off with 03)

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BandHook} from "../src/BandHook.sol";
import {HookMiner} from "./HookMiner.sol";

contract DeployBandHook is Script {
    IPoolManager constant MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        bytes memory creationCode = abi.encodePacked(type(BandHook).creationCode, abi.encode(MANAGER, deployer));
        (address expected, bytes32 salt) = HookMiner.find(flags, creationCode);
        console2.log("mined hook address:", expected);
        console2.log("salt:", uint256(salt));

        vm.startBroadcast(pk);
        BandHook hook = new BandHook{salt: salt}(MANAGER, deployer);
        vm.stopBroadcast();

        require(address(hook) == expected, "address mismatch");
        console2.log("BandHook deployed:", address(hook));
        console2.log("owner (deployer, hand off via 03):", deployer);
    }
}
