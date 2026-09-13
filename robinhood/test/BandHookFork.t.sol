// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {BandHook} from "../src/BandHook.sol";
import {ChainlinkSource, IAggregatorV3} from "../src/sources/ChainlinkSource.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";

/// Runs against a fork of Robinhood Chain mainnet: real PoolManager, real
/// Chainlink ETH/USD feed, fresh mock HOLLAR + canonical WETH pair simulated
/// with two mocks (bridged HOLLAR does not exist yet).
contract BandHookForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager constant MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IAggregatorV3 constant ETH_USD = IAggregatorV3(0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9);

    address constant HOOK_ADDR = address(uint160(0x1000000000000000000000000000000000001080));

    BandHook hook;
    ChainlinkSource source;
    PoolSwapTest swapRouter;
    MockERC20 weth;
    MockERC20 hollar;
    PoolKey key;
    PoolId id;

    function setUp() public {
        vm.createSelectFork("robinhood");
        swapRouter = new PoolSwapTest(MANAGER);
        MockERC20 a = new MockERC20("Wrapped Ether", "WETH", 18);
        MockERC20 b = new MockERC20("Hollar", "HOLLAR", 18);
        (weth, hollar) = address(a) < address(b) ? (a, b) : (b, a);
        bool wethIs0 = address(weth) < address(hollar);

        // real feed; orient so the source prices pool token0 in token1
        source = new ChainlinkSource(ETH_USD, !wethIs0, 18, 18);

        deployCodeTo("BandHook.sol:BandHook", abi.encode(MANAGER, address(this)), HOOK_ADDR);
        hook = BandHook(payable(HOOK_ADDR));

        key = PoolKey({
            currency0: Currency.wrap(address(weth) < address(hollar) ? address(weth) : address(hollar)),
            currency1: Currency.wrap(address(weth) < address(hollar) ? address(hollar) : address(weth)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(HOOK_ADDR)
        });
        id = key.toId();

        hook.configure(
            key,
            BandHook.PoolConfig({
                source: IPriceSource(address(source)),
                feeFloor: 800, // 0.08%
                feeCap: 10000, // 1%
                feeSlopePpm: 1_000_000,
                staleAfter: 96 hours, // feed heartbeat is 24h + weekend pauses
                halfBandTicks: 700, // ~±7%
                backstopHalfTicks: 11000, // ~÷3..×3
                backstopBps: 3500,
                triggerTicks: 350, // ~3.5%
                guardTicks: 150,
                enabled: true
            })
        );

        // initialize the pool exactly at the oracle price
        (uint256 px,) = source.priceX18();
        MANAGER.initialize(key, _sqrtPriceX96(px));

        weth.mint(address(this), 1_000_000e18);
        hollar.mint(address(this), 10_000_000e18);
        weth.approve(address(hook), type(uint256).max);
        hollar.approve(address(hook), type(uint256).max);
        weth.approve(address(swapRouter), type(uint256).max);
        hollar.approve(address(swapRouter), type(uint256).max);
    }

    function test_fork_endToEnd() public {
        // fund: 100 WETH + matching HOLLAR at the oracle price
        (uint256 px,) = source.priceX18();
        bool wethIs0 = Currency.unwrap(key.currency0) == address(weth);
        uint256 amtW = 100e18;
        uint256 amtH = wethIs0 ? amtW * px / 1e18 : amtW * 1e18 / px;
        hook.fund(id, wethIs0 ? amtW : amtH, wethIs0 ? amtH : amtW);

        (,,, uint128 cliq) = hook.core(id);
        (,,, uint128 bliq) = hook.backstop(id);
        assertGt(cliq, 0);
        assertGt(bliq, 0);

        // swap against the real PoolManager
        uint256 gasBefore = gasleft();
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1e18,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        emit log_named_uint("swap gas", gasBefore - gasleft());

        // resting fee is the floor
        (,,, uint24 lpFee) = MANAGER.getSlot0(id);
        assertEq(lpFee, 800);
    }

    function test_fork_recenterGas() public {
        (uint256 px,) = source.priceX18();
        bool wethIs0 = Currency.unwrap(key.currency0) == address(weth);
        uint256 amtW = 100e18;
        uint256 amtH = wethIs0 ? amtW * px / 1e18 : amtW * 1e18 / px;
        hook.fund(id, wethIs0 ? amtW : amtH, wethIs0 ? amtH : amtW);

        // simulate a 4% market move: push the pool, then move the oracle by mocking
        (, int24 tick0,,) = MANAGER.getSlot0(id);
        int24 target = tick0 + (wethIs0 ? int24(400) : int24(-400));
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: !wethIs0,
                amountSpecified: -200_000e18,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(target)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        // mock the feed 4% higher so oracle agrees with the pushed pool
        (, int256 ans,,,) = ETH_USD.latestRoundData();
        vm.mockCall(
            address(ETH_USD),
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(uint80(1), ans * 104 / 100, block.timestamp, block.timestamp, uint80(1))
        );

        uint256 gasBefore = gasleft();
        hook.recenter(id);
        emit log_named_uint("recenter gas", gasBefore - gasleft());

        (,, int24 nc, uint128 nliq) = hook.core(id);
        assertGt(nliq, 0);
        (, int24 poolTick,,) = MANAGER.getSlot0(id);
        assertApproxEqAbs(int256(nc), int256(poolTick), 160);
    }

    /// @dev sqrtPriceX96 = sqrt(priceX18/1e18) * 2^96, exact to integer sqrt
    function _sqrtPriceX96(uint256 priceX18) internal pure returns (uint160) {
        // sqrt(priceX18 * 2^192 / 1e18) computed as sqrt(priceX18 * 2^128 / 1e18) << 32
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
