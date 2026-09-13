// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {BandHook} from "../src/BandHook.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";
import {MockPriceSource} from "./mocks/MockPriceSource.sol";

contract BandHookTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager manager;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    MockERC20 t0;
    MockERC20 t1;
    MockPriceSource source;
    BandHook hook;
    PoolKey key;
    PoolId id;

    // AFTER_INITIALIZE (1<<12) | BEFORE_SWAP (1<<7)
    address constant HOOK_ADDR = address(uint160(0x1000000000000000000000000000000000001080));
    uint24 constant FLOOR = 3000; // 0.3%
    uint24 constant CAP = 20000; // 2%

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        source = new MockPriceSource(1e18); // price 1.0 => tick 0

        deployCodeTo("BandHook.sol:BandHook", abi.encode(manager, address(this)), HOOK_ADDR);
        hook = BandHook(payable(HOOK_ADDR));

        key = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(HOOK_ADDR)
        });
        id = key.toId();

        hook.configure(key, _cfg());
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        t0.mint(address(this), 1_000_000e18);
        t1.mint(address(this), 1_000_000e18);
        t0.approve(address(hook), type(uint256).max);
        t1.approve(address(hook), type(uint256).max);
        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);
        t0.approve(address(lpRouter), type(uint256).max);
        t1.approve(address(lpRouter), type(uint256).max);
    }

    function _cfg() internal view returns (BandHook.PoolConfig memory) {
        return BandHook.PoolConfig({
            source: IPriceSource(address(source)),
            feeFloor: FLOOR,
            feeCap: CAP,
            feeSlopePpm: 1_000_000, // +100% of divergence as fee: 1% div -> +1% fee
            staleAfter: 1 hours,
            halfBandTicks: 1000, // ~±10%
            backstopHalfTicks: 16000, // ~÷5..×5
            backstopBps: 3000,
            triggerTicks: 500, // ~5%
            guardTicks: 100, // ~1%
            enabled: true
        });
    }

    function _fund() internal {
        hook.fund(id, 100_000e18, 100_000e18);
    }

    function _swapFee(bool zeroForOne, int256 amt) internal returns (uint24 fee) {
        vm.recordLogs();
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amt,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            // Swap(id, sender, a0, a1, sqrtPrice, liquidity, tick, fee)
            if (logs[i].topics[0] == keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)")) {
                (,,,,, uint24 f) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return f;
            }
        }
        revert("no swap event");
    }

    // ---------- fee behavior

    function test_initialize_setsFloorFee() public view {
        (,,, uint24 lpFee) = manager.getSlot0(id);
        assertEq(lpFee, FLOOR);
    }

    function test_fee_atFloor_whenNoDivergence() public {
        _fund();
        uint24 fee = _swapFee(true, -1e18);
        assertEq(fee, FLOOR);
    }

    function test_fee_risesWithDivergence() public {
        _fund();
        // oracle says price is ~2% higher than pool: divergence ~200 ticks
        source.set(1.02e18, block.timestamp);
        uint24 fee = _swapFee(true, -1e18);
        // 200 ticks * 1e6 slope / 1e4 = 20000 -> capped at CAP
        assertEq(fee, CAP);
        // milder divergence ~0.5% -> ~ +50*100 = 5000 ppm over floor
        source.set(1.005e18, block.timestamp);
        fee = _swapFee(true, -1e18);
        assertGt(fee, FLOOR);
        assertLt(fee, CAP);
    }

    function test_fee_floorOnStaleOracle() public {
        _fund();
        source.set(1.05e18, block.timestamp);
        skip(2 hours); // beyond staleAfter
        uint24 fee = _swapFee(true, -1e18);
        assertEq(fee, FLOOR);
    }

    // ---------- funding & positions

    function test_fund_mintsCoreAndBackstop() public {
        _fund();
        (int24 cl, int24 cu,, uint128 cliq) = hook.core(id);
        (int24 bl, int24 bu,, uint128 bliq) = hook.backstop(id);
        assertGt(cliq, 0);
        assertGt(bliq, 0);
        // core centered on tick 0
        assertLe(cl, -900);
        assertGe(cu, 900);
        assertLt(bl, cl);
        assertGt(bu, cu);
        // funds actually left the test contract
        assertLt(t0.balanceOf(address(this)), 1_000_000e18);
    }

    function test_fund_notOwner_reverts() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(BandHook.NotOwner.selector);
        hook.fund(id, 1e18, 1e18);
    }

    // ---------- recentering

    function test_recenter_revertsBelowTrigger() public {
        _fund();
        source.set(1.01e18, block.timestamp); // ~100 ticks < 500 trigger
        vm.expectRevert(BandHook.DriftBelowTrigger.selector);
        hook.recenter(id);
    }

    function test_recenter_revertsOnGuard() public {
        _fund();
        // oracle jumps 6% but pool price still at 0 -> guard (100 ticks) trips
        source.set(1.06e18, block.timestamp);
        vm.expectRevert(BandHook.GuardTripped.selector);
        hook.recenter(id);
    }

    function test_recenter_revertsOnStale() public {
        _fund();
        source.set(1.06e18, block.timestamp);
        skip(2 hours);
        vm.expectRevert(BandHook.StaleOracle.selector);
        hook.recenter(id);
    }

    function test_recenter_happyPath() public {
        _fund();
        // market moves ~6%: arb pushes pool price up, oracle follows
        source.set(1.06e18, block.timestamp);
        _pushPoolToTick(582); // ln(1.06)/ln(1.0001) ~ 582
        (, int24 poolTick,,) = manager.getSlot0(id);
        assertApproxEqAbs(int256(poolTick), 582, 60);

        (int24 oldL, int24 oldU,,) = hook.core(id);
        hook.recenter(id); // called by anyone; use owner addr here but no permission needed
        (int24 nl, int24 nu, int24 nc, uint128 nliq) = hook.core(id);
        assertGt(nliq, 0);
        // quote center moved to the oracle tick; band covers it
        assertApproxEqAbs(int256(nc), 582, 60);
        assertLe(nl, nc);
        assertGe(nu, nc);
        assertTrue(nl != oldL || nu != oldU);
        assertLt(nl, nu);
        // trigger is measured from the stored center, so recentering is now settled
        vm.expectRevert(BandHook.DriftBelowTrigger.selector);
        hook.recenter(id);
    }

    function test_recenter_permissionless() public {
        _fund();
        source.set(1.06e18, block.timestamp);
        _pushPoolToTick(582);
        vm.prank(address(0xBEEF));
        hook.recenter(id);
    }

    // ---------- third-party LPs

    function test_thirdPartyLP_canJoin() public {
        _fund();
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -100, tickUpper: 100, liquidityDelta: 1e18, salt: 0}),
            ""
        );
        // and can swap against combined liquidity
        uint24 fee = _swapFee(true, -1e18);
        assertEq(fee, FLOOR);
    }

    // ---------- withdraw

    function test_withdraw_returnsFunds() public {
        _fund();
        uint256 before0 = t0.balanceOf(address(this));
        uint256 before1 = t1.balanceOf(address(this));
        hook.withdraw(id);
        assertGt(t0.balanceOf(address(this)), before0);
        assertGt(t1.balanceOf(address(this)), before1);
        (,,, uint128 cliq) = hook.core(id);
        (,,, uint128 bliq) = hook.backstop(id);
        assertEq(cliq, 0);
        assertEq(bliq, 0);
    }

    // ---------- helpers

    /// @dev swap until pool tick ~ target (coarse; relies on hook+test liquidity)
    function _pushPoolToTick(int24 target) internal {
        uint160 limit = TickMath.getSqrtPriceAtTick(target);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -500_000e18, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}
