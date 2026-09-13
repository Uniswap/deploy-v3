// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Deploys the pool's price source, configures the hook, and initializes the pool
// at the oracle price. Run once per pool with the pool's env section active:
//
//   set -a; source .env.eth-hollar; set +a
//   forge script script/01_SetupPool.s.sol --rpc-url robinhood --broadcast
//
// Caller must be the current hook owner.

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {BandHook} from "../src/BandHook.sol";
import {ChainlinkSource, IAggregatorV3} from "../src/sources/ChainlinkSource.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";

contract SetupPool is Script {
    using PoolIdLibrary for PoolKey;

    IPoolManager constant MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        BandHook hook = BandHook(payable(vm.envAddress("HOOK")));

        // pool identity
        address c0 = vm.envAddress("CURRENCY0"); // 0x0 for native ETH
        address c1 = vm.envAddress("CURRENCY1");
        require(c0 < c1, "currencies must be sorted (currency0 < currency1)");
        int24 spacing = int24(int256(vm.envInt("TICK_SPACING")));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: spacing,
            hooks: IHooks(address(hook))
        });

        vm.startBroadcast(pk);

        // price source: FEED prices FEED_BASE in the other token/USD-stable.
        // FEED_INVERT=true when the feed's base asset is the pool's currency1.
        // FEED_BASE_DECIMALS / FEED_QUOTE_DECIMALS are the token decimals of the
        // feed's base and quote as pool tokens (native ETH = 18).
        ChainlinkSource source = new ChainlinkSource(
            IAggregatorV3(vm.envAddress("FEED")),
            vm.envBool("FEED_INVERT"),
            uint8(vm.envUint("FEED_BASE_DECIMALS")),
            uint8(vm.envUint("FEED_QUOTE_DECIMALS"))
        );
        console2.log("source:", address(source));

        hook.configure(
            key,
            BandHook.PoolConfig({
                source: IPriceSource(address(source)),
                feeFloor: uint24(vm.envUint("FEE_FLOOR_PPM")),
                feeCap: uint24(vm.envUint("FEE_CAP_PPM")),
                feeSlopePpm: uint32(vm.envUint("FEE_SLOPE_PPM")),
                staleAfter: uint32(vm.envUint("STALE_AFTER_S")),
                halfBandTicks: int24(int256(vm.envInt("HALF_BAND_TICKS"))),
                backstopHalfTicks: int24(int256(vm.envInt("BACKSTOP_HALF_TICKS"))),
                backstopBps: uint16(vm.envUint("BACKSTOP_BPS")),
                triggerTicks: int24(int256(vm.envInt("TRIGGER_TICKS"))),
                guardTicks: int24(int256(vm.envInt("GUARD_TICKS"))),
                enabled: true
            })
        );

        (uint256 px, uint256 updatedAt) = source.priceX18();
        require(px > 0 && block.timestamp - updatedAt < vm.envUint("STALE_AFTER_S"), "oracle stale at init");
        uint160 sqrtPrice = _sqrtPriceX96(px);
        MANAGER.initialize(key, sqrtPrice);

        vm.stopBroadcast();

        console2.log("pool initialized at oracle priceX18:", px);
        console2.log("poolId:");
        console2.logBytes32(PoolId.unwrap(key.toId()));
    }

    function _sqrtPriceX96(uint256 priceX18) internal pure returns (uint160) {
        uint256 inner = priceX18 * (uint256(1) << 128) / 1e18;
        return uint160(_sqrt(inner) << 32);
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = (x + 1) / 2;
        while (y < z) {
            z = y;
            y = (x / y + y) / 2;
        }
    }
}
