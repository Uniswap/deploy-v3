// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {BandHook} from "../src/BandHook.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";
import {MockPriceSource} from "./mocks/MockPriceSource.sol";

/// Same hook, currency0 = native ETH (the production shape for ETH/HOLLAR, ETH/HDX).
contract BandHookNativeTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager manager;
    PoolSwapTest swapRouter;
    MockERC20 hollar;
    MockPriceSource source;
    BandHook hook;
    PoolKey key;
    PoolId id;

    address constant HOOK_ADDR = address(uint160(0x1000000000000000000000000000000000001080));

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        swapRouter = new PoolSwapTest(manager);
        hollar = new MockERC20("Hollar", "HOLLAR", 18);
        source = new MockPriceSource(2500e18); // 2500 HOLLAR per ETH => tick ~ ln(2500)/ln(1.0001)

        deployCodeTo("BandHook.sol:BandHook", abi.encode(manager, address(this)), HOOK_ADDR);
        hook = BandHook(payable(HOOK_ADDR));

        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(hollar)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(HOOK_ADDR)
        });
        id = key.toId();

        hook.configure(
            key,
            BandHook.PoolConfig({
                source: IPriceSource(address(source)),
                feeFloor: 800,
                feeCap: 10000,
                feeSlopePpm: 1_000_000,
                staleAfter: 1 hours,
                halfBandTicks: 700,
                backstopHalfTicks: 11000,
                backstopBps: 3500,
                triggerTicks: 350,
                guardTicks: 150,
                enabled: true
            })
        );
        // tick for price 2500e18: ln(2500)*1e18 / ln(1.0001)*1e18 ≈ 78244
        manager.initialize(key, TickMath.getSqrtPriceAtTick(78244));

        hollar.mint(address(this), 10_000_000e18);
        hollar.approve(address(hook), type(uint256).max);
        hollar.approve(address(swapRouter), type(uint256).max);
        vm.deal(address(this), 10_000 ether);
    }

    function _fund() internal {
        hook.fund{value: 100 ether}(id, 100 ether, 250_000e18);
    }

    function test_native_fund() public {
        uint256 ethBefore = address(this).balance;
        _fund();
        (,,, uint128 cliq) = hook.core(id);
        (,,, uint128 bliq) = hook.backstop(id);
        assertGt(cliq, 0);
        assertGt(bliq, 0);
        assertEq(ethBefore - address(this).balance, 100 ether);
        // hook holds only dust idle; capital is in the PoolManager
        assertLt(address(hook).balance, 5 ether);
    }

    function test_native_fund_wrongValue_reverts() public {
        vm.expectRevert(BandHook.BadValue.selector);
        hook.fund{value: 1 ether}(id, 2 ether, 1000e18);
    }

    function test_native_swap_atFloor() public {
        _fund();
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        (,,, uint24 lpFee) = manager.getSlot0(id);
        assertEq(lpFee, 800);
        // we received HOLLAR for the ETH
        assertGt(hollar.balanceOf(address(this)), 10_000_000e18 - 250_000e18);
    }

    function test_native_recenter() public {
        _fund();
        // market moves +4%: push pool up, oracle follows
        source.set(2600e18, block.timestamp); // +4% => +392 ticks
        uint256 hollarIn = 300_000e18;
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(hollarIn),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(78244 + 392)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.prank(address(0xBEEF));
        hook.recenter(id);
        (,, int24 nc, uint128 nliq) = hook.core(id);
        assertGt(nliq, 0);
        assertApproxEqAbs(int256(nc), 78244 + 392, 60);
    }

    function test_native_withdraw() public {
        _fund();
        uint256 ethBefore = address(this).balance;
        uint256 holBefore = hollar.balanceOf(address(this));
        hook.withdraw(id);
        // rounding dust aside, we get everything back
        assertApproxEqAbs(address(this).balance, ethBefore + 100 ether, 0.01 ether);
        assertApproxEqAbs(hollar.balanceOf(address(this)), holBefore + 250_000e18, 100e18);
        assertEq(address(hook).balance, 0);
    }

    receive() external payable {}
}
