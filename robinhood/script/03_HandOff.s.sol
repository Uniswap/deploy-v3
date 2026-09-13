// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Begins the 2-step ownership transfer of the hook to the final owner (multisig).
// The multisig must then call acceptOwnership() itself.
//
//   HOOK=0x... NEW_OWNER=0x... forge script script/03_HandOff.s.sol --rpc-url robinhood --broadcast

import {Script, console2} from "forge-std/Script.sol";
import {BandHook} from "../src/BandHook.sol";

contract HandOff is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        BandHook hook = BandHook(payable(vm.envAddress("HOOK")));
        address newOwner = vm.envAddress("NEW_OWNER");

        vm.startBroadcast(pk);
        hook.transferOwnership(newOwner);
        vm.stopBroadcast();

        console2.log("pending owner set:", newOwner);
        console2.log("ACTION REQUIRED: multisig must call acceptOwnership()");
    }
}
