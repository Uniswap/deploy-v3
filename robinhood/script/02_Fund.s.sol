// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Funds a configured pool. Approvals for ERC20 legs are handled here; the native
// leg (currency0 = 0x0) is sent as msg.value automatically.
//
//   set -a; source .env.eth-hollar; set +a
//   FUND_AMOUNT0=... FUND_AMOUNT1=... forge script script/02_Fund.s.sol --rpc-url robinhood --broadcast

import {Script, console2} from "forge-std/Script.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {BandHook} from "../src/BandHook.sol";

interface IERC20 {
    function approve(address, uint256) external returns (bool);
}

contract FundPool is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        BandHook hook = BandHook(payable(vm.envAddress("HOOK")));
        PoolId id = PoolId.wrap(vm.envBytes32("POOL_ID"));
        address c0 = vm.envAddress("CURRENCY0");
        address c1 = vm.envAddress("CURRENCY1");
        uint256 a0 = vm.envUint("FUND_AMOUNT0");
        uint256 a1 = vm.envUint("FUND_AMOUNT1");

        vm.startBroadcast(pk);
        if (c0 != address(0)) IERC20(c0).approve(address(hook), a0);
        IERC20(c1).approve(address(hook), a1);
        hook.fund{value: c0 == address(0) ? a0 : 0}(id, a0, a1);
        vm.stopBroadcast();

        (int24 cl, int24 cu, int24 cc, uint128 cliq) = hook.core(id);
        console2.log("core lower:", int256(cl));
        console2.log("core upper:", int256(cu));
        console2.log("core center:", int256(cc));
        console2.log("core liquidity:", uint256(cliq));
    }
}
