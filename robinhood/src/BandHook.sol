// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {IPriceSource} from "./interfaces/IPriceSource.sol";

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @notice Oracle-guarded band market maker for Uniswap v4.
///
/// The hook owns two tick positions per pool: a core band around a reference price
/// and a wide static backstop. Liquidity placement never sets the pool price; the
/// oracle is used only to (a) drive a dynamic fee that rises when the pool price
/// diverges from the reference, (b) gate re-centering so a manipulated pool price
/// cannot drag the band, and (c) pick the new center. Anyone can call recenter();
/// it only executes when the configured conditions hold. Third-party LPs join the
/// pool through the ordinary PositionManager and are unaffected except for paying
/// and earning the same dynamic fee.
///
/// Supports native ETH as currency0. Funding and withdrawal are owner-only.
contract BandHook is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;
    using SafeCast for uint256;
    using SafeCast for int256;

    // ---------- types

    struct PoolConfig {
        IPriceSource source;
        uint24 feeFloor; // ppm
        uint24 feeCap; // ppm
        uint32 feeSlopePpm; // ppm of extra fee per 100% pool-vs-oracle divergence
        uint32 staleAfter; // seconds; older source => floor fee, recenter disabled
        int24 halfBandTicks; // core band half-width
        int24 backstopHalfTicks; // 0 = no backstop
        uint16 backstopBps; // share of funded amounts placed in the backstop
        int24 triggerTicks; // recenter when |oracleTick - coreCenter| > trigger
        int24 guardTicks; // refuse recenter when |poolTick - oracleTick| > guard
        bool enabled;
    }

    struct Pos {
        int24 lower;
        int24 upper;
        int24 center; // the reference tick this band was quoted around
        uint128 liquidity;
    }

    enum Action {
        FUND,
        RECENTER,
        WITHDRAW
    }

    // ---------- state

    IPoolManager public immutable manager;
    address public owner;
    address public pendingOwner;

    mapping(PoolId => PoolConfig) public config;
    mapping(PoolId => PoolKey) internal keys;
    mapping(PoolId => Pos) public core;
    mapping(PoolId => Pos) public backstop;

    // ln(1.0001) * 1e18
    int256 internal constant LN_TICK = 99995000333308;
    bytes32 internal constant CORE_SALT = bytes32(0);
    bytes32 internal constant BACKSTOP_SALT = bytes32(uint256(1));
    // hard cap on asymmetric extension of the core band, in half-band multiples
    int24 internal constant MAX_EXTENSION_MULT = 4;

    event Configured(PoolId indexed id);
    event Funded(PoolId indexed id, uint256 amount0, uint256 amount1);
    event Recentered(PoolId indexed id, int24 oracleTick, int24 lower, int24 upper, uint128 liquidity);
    event Withdrawn(PoolId indexed id, uint256 amount0, uint256 amount1);

    error NotOwner();
    error NotManager();
    error NotEnabled();
    error AlreadyConfigured();
    error StaleOracle();
    error DriftBelowTrigger();
    error GuardTripped();
    error BadConfig();
    error BadValue();
    error NativeTransferFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(IPoolManager _manager, address _owner) {
        manager = _manager;
        owner = _owner;
    }

    /// @dev native ETH arrives from PoolManager.take and owner funding
    receive() external payable {}

    // ---------- ownership

    function transferOwnership(address to) external onlyOwner {
        pendingOwner = to;
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    // ---------- configuration

    function configure(PoolKey calldata key, PoolConfig calldata cfg) external onlyOwner {
        PoolId id = key.toId();
        if (address(config[id].source) != address(0)) revert AlreadyConfigured();
        _validate(cfg);
        if (address(key.hooks) != address(this) || !key.fee.isDynamicFee()) revert BadConfig();
        config[id] = cfg;
        keys[id] = key;
        emit Configured(id);
    }

    /// @notice Tune parameters on a live pool. The price source is intentionally
    /// not updatable; a bad source means a new pool.
    function setParams(PoolId id, PoolConfig calldata cfg) external onlyOwner {
        PoolConfig storage c = config[id];
        if (address(c.source) == address(0)) revert NotEnabled();
        if (address(cfg.source) != address(c.source)) revert BadConfig();
        _validate(cfg);
        config[id] = cfg;
        emit Configured(id);
    }

    function _validate(PoolConfig calldata cfg) internal pure {
        if (address(cfg.source) == address(0)) revert BadConfig();
        if (cfg.feeFloor > cfg.feeCap || cfg.feeCap >= LPFeeLibrary.OVERRIDE_FEE_FLAG) revert BadConfig();
        if (cfg.halfBandTicks <= 0 || cfg.triggerTicks <= 0 || cfg.guardTicks <= 0) revert BadConfig();
        if (cfg.backstopBps > 10_000) revert BadConfig();
        if (cfg.backstopHalfTicks != 0 && cfg.backstopHalfTicks < cfg.halfBandTicks) revert BadConfig();
    }

    // ---------- hook callbacks (only the two flagged ones are ever called)

    function afterInitialize(address, PoolKey calldata key, uint160, int24) external returns (bytes4) {
        if (msg.sender != address(manager)) revert NotManager();
        PoolConfig storage cfg = config[key.toId()];
        // pool may be initialized before configure(); syncFee() covers that path
        if (address(cfg.source) != address(0)) manager.updateDynamicLPFee(key, cfg.feeFloor);
        return IHooks.afterInitialize.selector;
    }

    /// @notice Set the resting fee to the floor for a pool configured after initialization.
    function syncFee(PoolId id) external {
        PoolConfig storage cfg = config[id];
        if (address(cfg.source) == address(0)) revert NotEnabled();
        manager.updateDynamicLPFee(keys[id], cfg.feeFloor);
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (msg.sender != address(manager)) revert NotManager();
        PoolId id = key.toId();
        PoolConfig storage cfg = config[id];
        uint24 fee = cfg.feeFloor;
        (int24 oracleTick, bool fresh) = _oracleTick(cfg);
        if (fresh) {
            (, int24 poolTick,,) = manager.getSlot0(id);
            uint256 dTicks = _absDiff(poolTick, oracleTick);
            // 1 tick ~ 0.01% divergence; slope is ppm per 100%
            uint256 add = dTicks * cfg.feeSlopePpm / 10_000;
            uint256 f = uint256(cfg.feeFloor) + add;
            fee = f >= cfg.feeCap ? cfg.feeCap : uint24(f);
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    // ---------- funding / recentering / withdrawal

    /// @notice Pull tokens from the owner and mint backstop + core around the oracle price.
    /// If currency0 is native ETH, amount0 must be sent as msg.value.
    function fund(PoolId id, uint256 amount0, uint256 amount1) external payable onlyOwner {
        PoolConfig storage cfg = config[id];
        if (!cfg.enabled) revert NotEnabled();
        PoolKey memory key = keys[id];
        if (key.currency0.isAddressZero()) {
            if (msg.value != amount0) revert BadValue();
        } else {
            if (msg.value != 0) revert BadValue();
            IERC20Minimal(Currency.unwrap(key.currency0)).transferFrom(msg.sender, address(this), amount0);
        }
        IERC20Minimal(Currency.unwrap(key.currency1)).transferFrom(msg.sender, address(this), amount1);
        manager.unlock(abi.encode(Action.FUND, id));
        emit Funded(id, amount0, amount1);
    }

    /// @notice Permissionless. Executes only when the oracle is fresh, the drift from
    /// the current core center exceeds the trigger, and the pool price agrees with
    /// the oracle within the guard.
    function recenter(PoolId id) external {
        PoolConfig storage cfg = config[id];
        if (!cfg.enabled) revert NotEnabled();
        (int24 oracleTick, bool fresh) = _oracleTick(cfg);
        if (!fresh) revert StaleOracle();
        Pos storage c = core[id];
        if (c.liquidity != 0 && _absDiff(oracleTick, c.center) <= uint256(int256(cfg.triggerTicks))) {
            revert DriftBelowTrigger();
        }
        (, int24 poolTick,,) = manager.getSlot0(id);
        if (_absDiff(poolTick, oracleTick) > uint256(int256(cfg.guardTicks))) revert GuardTripped();
        manager.unlock(abi.encode(Action.RECENTER, id));
    }

    /// @notice Burn everything and send all balances of both tokens to the owner.
    function withdraw(PoolId id) external onlyOwner {
        manager.unlock(abi.encode(Action.WITHDRAW, id));
        PoolKey memory key = keys[id];
        uint256 b0 = _idle(key.currency0);
        uint256 b1 = _idle(key.currency1);
        if (b0 > 0) _push(key.currency0, owner, b0);
        if (b1 > 0) _push(key.currency1, owner, b1);
        emit Withdrawn(id, b0, b1);
    }

    // ---------- unlock callback

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotManager();
        (Action action, PoolId id) = abi.decode(data, (Action, PoolId));
        PoolKey memory key = keys[id];
        PoolConfig storage cfg = config[id];

        if (action == Action.WITHDRAW) {
            _burn(key, core[id], CORE_SALT);
            _burn(key, backstop[id], BACKSTOP_SALT);
            delete core[id];
            delete backstop[id];
        } else {
            (int24 oracleTick, bool fresh) = _oracleTick(cfg);
            (, int24 poolTick,,) = manager.getSlot0(id);
            int24 center = fresh ? oracleTick : poolTick;

            if (action == Action.FUND && cfg.backstopHalfTicks != 0 && backstop[id].liquidity == 0) {
                // carve out the backstop share first, wide and symmetric
                (uint256 i0, uint256 i1) = (_available(key.currency0), _available(key.currency1));
                uint256 b0 = i0 * cfg.backstopBps / 10_000;
                uint256 b1 = i1 * cfg.backstopBps / 10_000;
                backstop[id] =
                    _mintFitted(key, center, cfg.backstopHalfTicks, cfg.backstopHalfTicks, b0, b1, BACKSTOP_SALT);
            }
            if (action == Action.RECENTER) {
                _burn(key, core[id], CORE_SALT);
                delete core[id];
            }
            (uint256 a0, uint256 a1) = (_available(key.currency0), _available(key.currency1));
            core[id] = _mintFitted(
                key, center, cfg.halfBandTicks, cfg.halfBandTicks * MAX_EXTENSION_MULT, a0, a1, CORE_SALT
            );
            Pos storage c = core[id];
            emit Recentered(id, center, c.lower, c.upper, c.liquidity);
        }
        _settleAll(key);
        return "";
    }

    // ---------- internals

    function _oracleTick(PoolConfig storage cfg) internal view returns (int24 tick, bool fresh) {
        (uint256 p, uint256 updatedAt) = cfg.source.priceX18();
        if (p == 0 || block.timestamp > updatedAt + cfg.staleAfter) return (0, false);
        tick = _tickFromPriceX18(p);
        fresh = true;
    }

    /// @dev tick = ln(price) / ln(1.0001); wad-based natural log.
    function _tickFromPriceX18(uint256 priceX18) internal pure returns (int24) {
        int256 t = _lnWad(int256(priceX18)) / LN_TICK;
        if (t > TickMath.MAX_TICK) t = TickMath.MAX_TICK;
        if (t < TickMath.MIN_TICK) t = TickMath.MIN_TICK;
        return int24(t);
    }

    function _absDiff(int24 a, int24 b) internal pure returns (uint256) {
        int256 d = int256(a) - int256(b);
        return uint256(d < 0 ? -d : d);
    }

    function _idle(Currency c) internal view returns (uint256) {
        if (c.isAddressZero()) return address(this).balance;
        return IERC20Minimal(Currency.unwrap(c)).balanceOf(address(this));
    }

    function _push(Currency c, address to, uint256 amount) internal {
        if (c.isAddressZero()) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            IERC20Minimal(Currency.unwrap(c)).transfer(to, amount);
        }
    }

    /// @dev Spendable amount mid-unlock: idle balance adjusted by the transient
    /// delta (positive after a burn credits us, negative after a pending mint).
    function _available(Currency c) internal view returns (uint256) {
        int256 total = int256(_idle(c)) + manager.currencyDelta(address(this), c);
        return total > 0 ? uint256(total) : 0;
    }

    function _burn(PoolKey memory key, Pos memory p, bytes32 salt) internal {
        if (p.liquidity == 0) return;
        manager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: p.lower,
                tickUpper: p.upper,
                liquidityDelta: -int256(uint256(p.liquidity)),
                salt: salt
            }),
            ""
        );
    }

    struct BandSpec {
        int24 center;
        int24 half;
        int24 maxHalf;
        int24 spacing;
    }

    /// @dev Mint a band of half-width `half` around `center`, extending one side up to
    /// `maxHalf` to absorb surplus inventory of the other token. No swaps; whatever
    /// still does not fit stays idle in the hook until the next recenter.
    function _mintFitted(
        PoolKey memory key,
        int24 center,
        int24 half,
        int24 maxHalf,
        uint256 a0,
        uint256 a1,
        bytes32 salt
    ) internal returns (Pos memory p) {
        if (a0 == 0 && a1 == 0) return p;
        BandSpec memory s = BandSpec({center: center, half: half, maxHalf: maxHalf, spacing: key.tickSpacing});
        (uint160 sqrtP,,,) = manager.getSlot0(key.toId());
        (int24 lo, int24 hi, uint128 liq) = _computeBand(s, sqrtP, a0, a1);
        if (liq == 0) return p;
        manager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: lo,
                tickUpper: hi,
                liquidityDelta: int256(uint256(liq)),
                salt: salt
            }),
            ""
        );
        p = Pos({lower: lo, upper: hi, center: center, liquidity: liq});
    }

    function _computeBand(BandSpec memory s, uint160 sqrtP, uint256 a0, uint256 a1)
        internal
        pure
        returns (int24 lo, int24 hi, uint128 liq)
    {
        lo = _floorTick(s.center - s.half, s.spacing);
        hi = _ceilTick(s.center + s.half, s.spacing);
        uint160 sqrtLo = TickMath.getSqrtPriceAtTick(lo);
        uint160 sqrtHi = TickMath.getSqrtPriceAtTick(hi);
        if (sqrtP > sqrtLo && sqrtP < sqrtHi) {
            (lo, hi) = _fitBounds(sqrtP, lo, hi, s, a0, a1);
            if (lo >= hi) {
                lo = _floorTick(s.center - s.half, s.spacing);
                hi = _ceilTick(s.center + s.half, s.spacing);
            }
            sqrtLo = TickMath.getSqrtPriceAtTick(lo);
            sqrtHi = TickMath.getSqrtPriceAtTick(hi);
        }
        int24 minT = TickMath.minUsableTick(s.spacing);
        int24 maxT = TickMath.maxUsableTick(s.spacing);
        if (lo < minT) lo = minT;
        if (hi > maxT) hi = maxT;
        liq = LiquidityAmounts.getLiquidityForAmounts(sqrtP, sqrtLo, sqrtHi, a0, a1);
    }

    /// @dev extend one side of [lo,hi] so the surplus token is absorbed at the
    /// liquidity implied by the scarce token; capped at center±maxHalf.
    function _fitBounds(uint160 sqrtP, int24 lo, int24 hi, BandSpec memory s, uint256 a0, uint256 a1)
        internal
        pure
        returns (int24, int24)
    {
        uint128 l0 = LiquidityAmounts.getLiquidityForAmount0(sqrtP, TickMath.getSqrtPriceAtTick(hi), a0);
        uint128 l1 = LiquidityAmounts.getLiquidityForAmount1(TickMath.getSqrtPriceAtTick(lo), sqrtP, a1);
        if (l0 <= l1) {
            if (l0 > 0) lo = _extendLower(sqrtP, l0, a1, s.center, s.maxHalf, s.spacing);
        } else {
            hi = _extendUpper(sqrtP, l1, a0, s.center, s.maxHalf, s.spacing);
        }
        return (lo, hi);
    }

    function _extendLower(uint160 sqrtP, uint128 liq, uint256 a1, int24 center, int24 maxHalf, int24 spacing)
        internal
        pure
        returns (int24 lo)
    {
        uint256 sqrtLoNew = uint256(sqrtP) - FullMath.mulDiv(a1, FixedPoint96.Q96, liq);
        int24 loNew = sqrtLoNew <= TickMath.MIN_SQRT_PRICE
            ? TickMath.MIN_TICK
            : TickMath.getTickAtSqrtPrice(uint160(sqrtLoNew));
        lo = _ceilTick(loNew, spacing); // ceil: never require more token1 than held
        int24 floorLo = _ceilTick(center - maxHalf, spacing);
        if (lo < floorLo) lo = floorLo;
    }

    function _extendUpper(uint160 sqrtP, uint128 liq, uint256 a0, int24 center, int24 maxHalf, int24 spacing)
        internal
        pure
        returns (int24 hi)
    {
        uint256 num = uint256(liq) * FixedPoint96.Q96;
        uint256 sub = FullMath.mulDiv(a0, sqrtP, 1);
        int24 hiNew;
        if (num <= sub) {
            hiNew = center + maxHalf;
        } else {
            uint256 den = num - sub;
            uint256 sqrtHiNew = FullMath.mulDiv(num, sqrtP, den);
            hiNew = sqrtHiNew > TickMath.MAX_SQRT_PRICE
                ? TickMath.MAX_TICK
                : TickMath.getTickAtSqrtPrice(uint160(sqrtHiNew));
        }
        hi = _floorTick(hiNew, spacing); // floor: never require more token0 than held
        int24 capHi = _floorTick(center + maxHalf, spacing);
        if (hi > capHi) hi = capHi;
    }

    function _settleAll(PoolKey memory key) internal {
        _settleOne(key.currency0);
        _settleOne(key.currency1);
    }

    function _settleOne(Currency c) internal {
        int256 delta = manager.currencyDelta(address(this), c);
        if (delta < 0) {
            if (c.isAddressZero()) {
                manager.settle{value: uint256(-delta)}();
            } else {
                manager.sync(c);
                IERC20Minimal(Currency.unwrap(c)).transfer(address(manager), uint256(-delta));
                manager.settle();
            }
        } else if (delta > 0) {
            manager.take(c, address(this), uint256(delta));
        }
    }

    function _floorTick(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 r = tick % spacing;
        if (r < 0) r += spacing;
        return tick - r;
    }

    function _ceilTick(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 f = _floorTick(tick, spacing);
        return f == tick ? tick : f + spacing;
    }

    // solmate lnWad, inlined to avoid a lib dependency mismatch
    function _lnWad(int256 x) internal pure returns (int256 r) {
        require(x > 0);
        assembly {
            r := shl(7, lt(0xffffffffffffffffffffffffffffffff, x))
            r := or(r, shl(6, lt(0xffffffffffffffff, shr(r, x))))
            r := or(r, shl(5, lt(0xffffffff, shr(r, x))))
            r := or(r, shl(4, lt(0xffff, shr(r, x))))
            r := or(r, shl(3, lt(0xff, shr(r, x))))
            r := or(r, shl(2, lt(0xf, shr(r, x))))
            r := or(r, shl(1, lt(0x3, shr(r, x))))
            r := or(r, lt(0x1, shr(r, x)))
        }
        int256 k = r - 96;
        x <<= uint256(159 - k);
        x = int256(uint256(x) >> 159);
        int256 p = x + 3273285459638523848632254066296;
        p = ((p * x) >> 96) + 24828157081833163892658089445524;
        p = ((p * x) >> 96) + 43456485725739037958740375743393;
        p = ((p * x) >> 96) - 11111509109440967052023855526967;
        p = ((p * x) >> 96) - 45023709667254063763336534515857;
        p = ((p * x) >> 96) - 14706773417378608786704636184526;
        p = p * x - (795164235651350426258249787498 << 96);
        int256 q = x + 5573035233440673466300451813936;
        q = ((q * x) >> 96) + 71694874799317883764090561454958;
        q = ((q * x) >> 96) + 283447036172924575727196451306956;
        q = ((q * x) >> 96) + 401686690394027663651624208769553;
        q = ((q * x) >> 96) + 204048457590392012362485061816622;
        q = ((q * x) >> 96) + 31853899698501571402653359427138;
        q = ((q * x) >> 96) + 909429971244387300277376558375;
        assembly {
            r := sdiv(p, q)
        }
        r *= 1677202110996718588342820967067443963516166;
        r += 16597577552685614221487285958193947469193820559219878177908093499208371 * k;
        r += 600920179829731861736702779321621459595472258049074101567377883020018308;
        r >>= 174;
    }
}
