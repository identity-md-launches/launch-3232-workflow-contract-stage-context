// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20, IPoolManager, IPositionManagerV4, PoolKey} from "../interfaces/IExternal.sol";
import {PosRef} from "../interfaces/ILpDesk.sol";
import {PoolMath} from "../libraries/PoolMath.sol";
import {FirmAddresses} from "../FirmAddresses.sol";

/// @notice LpDesk module for the V4 venue kind: Uniswap v4 PositionManager positions on hookless pools, minted to
/// LpDesk, settled from this module's balance (no Permit2), leftovers swept back to LpDesk. The buyback swap runs
/// through PoolManager.unlock with the output taken straight to the dead address.
contract VenueV4 {
    address public immutable lpDesk;
    /// @dev The PoolManager this module is inside an unlock of; unlockCallback answers only it (finding 55ef5a4b).
    address private _pendingPoolManager;

    // v4-periphery Actions
    uint8 private constant INCREASE_LIQUIDITY = 0x00;
    uint8 private constant DECREASE_LIQUIDITY = 0x01;
    uint8 private constant MINT_POSITION = 0x02;
    uint8 private constant SETTLE = 0x0b;
    uint8 private constant TAKE_PAIR = 0x11;
    uint8 private constant SWEEP = 0x14;

    error NotLpDesk();
    error NotPoolManager();
    error NoPool();

    constructor() {
        lpDesk = msg.sender;
    }

    modifier onlyDesk() {
        if (msg.sender != lpDesk) revert NotLpDesk();
        _;
    }

    // ---------------------------------------------------------------- views

    function keyOf(PosRef calldata r) public pure returns (PoolKey memory key) {
        key = PoolKey({
            currency0: r.token0, currency1: r.token1, fee: r.fee, tickSpacing: r.tickSpacing, hooks: address(0)
        });
    }

    function poolPrice(PosRef calldata r) external view returns (bool exists, uint160 sqrtPriceX96, int24 tick) {
        IPoolManager pm = IPoolManager(IPositionManagerV4(r.positionManager).poolManager());
        bytes32 slot = keccak256(abi.encode(keccak256(abi.encode(keyOf(r))), uint256(6)));
        uint256 word = uint256(pm.extsload(slot));
        sqrtPriceX96 = uint160(word);
        tick = int24(int256(word >> 160));
        exists = sqrtPriceX96 != 0;
    }

    function liquidityOf(PosRef calldata r) external view returns (uint128) {
        return IPositionManagerV4(r.positionManager).getPositionLiquidity(r.tokenId);
    }

    // ---------------------------------------------------------------- mint / increase

    function mint(PosRef calldata r, uint160 sqrtPriceX96, uint256 amt0, uint256 amt1)
        external
        onlyDesk
        returns (uint256 tokenId, uint128 liquidity, uint256 used0, uint256 used1)
    {
        IPositionManagerV4 posm = IPositionManagerV4(r.positionManager);
        IPoolManager pm = IPoolManager(posm.poolManager());
        PoolKey memory key = keyOf(r);
        uint160 current = _sqrtPrice(pm, key);
        if (current == 0) {
            pm.initialize(key, sqrtPriceX96);
            current = sqrtPriceX96;
        }
        liquidity = _fit(current, r.tickLower, r.tickUpper, amt0, amt1);
        tokenId = posm.nextTokenId();
        _send(r.token0, r.positionManager, amt0);
        _send(r.token1, r.positionManager, amt1);
        bytes memory actions = abi.encodePacked(MINT_POSITION, SETTLE, SETTLE, SWEEP, SWEEP);
        bytes[] memory params = new bytes[](5);
        params[0] = abi.encode(
            key, r.tickLower, r.tickUpper, uint256(liquidity), uint128(amt0), uint128(amt1), lpDesk, bytes("")
        );
        params[1] = abi.encode(r.token0, uint256(0), false);
        params[2] = abi.encode(r.token1, uint256(0), false);
        params[3] = abi.encode(r.token0, lpDesk);
        params[4] = abi.encode(r.token1, lpDesk);
        uint256 b0 = IERC20(r.token0).balanceOf(lpDesk);
        uint256 b1 = IERC20(r.token1).balanceOf(lpDesk);
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        used0 = amt0 - (IERC20(r.token0).balanceOf(lpDesk) - b0);
        used1 = amt1 - (IERC20(r.token1).balanceOf(lpDesk) - b1);
    }

    function increase(PosRef calldata r, uint256 amt0, uint256 amt1)
        external
        onlyDesk
        returns (uint128 liquidity, uint256 used0, uint256 used1)
    {
        IPositionManagerV4 posm = IPositionManagerV4(r.positionManager);
        IPoolManager pm = IPoolManager(posm.poolManager());
        uint160 current = _sqrtPrice(pm, keyOf(r));
        if (current == 0) revert NoPool();
        liquidity = _fit(current, r.tickLower, r.tickUpper, amt0, amt1);
        _send(r.token0, r.positionManager, amt0);
        _send(r.token1, r.positionManager, amt1);
        bytes memory actions = abi.encodePacked(INCREASE_LIQUIDITY, SETTLE, SETTLE, SWEEP, SWEEP);
        bytes[] memory params = new bytes[](5);
        params[0] = abi.encode(r.tokenId, uint256(liquidity), uint128(amt0), uint128(amt1), bytes(""));
        params[1] = abi.encode(r.token0, uint256(0), false);
        params[2] = abi.encode(r.token1, uint256(0), false);
        params[3] = abi.encode(r.token0, lpDesk);
        params[4] = abi.encode(r.token1, lpDesk);
        uint256 b0 = IERC20(r.token0).balanceOf(lpDesk);
        uint256 b1 = IERC20(r.token1).balanceOf(lpDesk);
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        used0 = amt0 - (IERC20(r.token0).balanceOf(lpDesk) - b0);
        used1 = amt1 - (IERC20(r.token1).balanceOf(lpDesk) - b1);
    }

    // ---------------------------------------------------------------- collect / decrease

    /// @notice Collects the position's fees to LpDesk by a zero-liquidity decrease. An empty position has nothing
    /// pending (v4 credits fees on every liquidity change) and the PoolManager refuses to poke it, so it is skipped
    /// (finding 0e020971).
    function collectFees(PosRef calldata r) external onlyDesk returns (uint256 fee0, uint256 fee1) {
        if (IPositionManagerV4(r.positionManager).getPositionLiquidity(r.tokenId) == 0) return (0, 0);
        (fee0, fee1) = _decrease(r, 0, 0, 0);
    }

    function decrease(PosRef calldata r, uint128 liquidity, uint256 min0, uint256 min1)
        external
        onlyDesk
        returns (uint256 amt0, uint256 amt1)
    {
        (amt0, amt1) = _decrease(r, liquidity, min0, min1);
    }

    function _decrease(PosRef calldata r, uint128 liquidity, uint256 min0, uint256 min1)
        private
        returns (uint256 amt0, uint256 amt1)
    {
        bytes memory actions = abi.encodePacked(DECREASE_LIQUIDITY, TAKE_PAIR);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(r.tokenId, uint256(liquidity), uint128(min0), uint128(min1), bytes(""));
        params[1] = abi.encode(r.token0, r.token1, lpDesk);
        uint256 b0 = IERC20(r.token0).balanceOf(lpDesk);
        uint256 b1 = IERC20(r.token1).balanceOf(lpDesk);
        IPositionManagerV4(r.positionManager).modifyLiquidities(abi.encode(actions, params), block.timestamp);
        amt0 = IERC20(r.token0).balanceOf(lpDesk) - b0;
        amt1 = IERC20(r.token1).balanceOf(lpDesk) - b1;
    }

    // ---------------------------------------------------------------- swap (buyback)

    /// @notice Exact-input swap of `amountIn` of `tokenIn` (already transferred here by LpDesk) in the position's own
    /// pool, output to the dead address. The pool takes less than amountIn only when its liquidity runs out before
    /// the price limit; the rest goes back to LpDesk in the same call.
    function swapExactInToDead(PosRef calldata r, address tokenIn, uint256 amountIn)
        external
        onlyDesk
        returns (uint256 out)
    {
        IPoolManager pm = IPoolManager(IPositionManagerV4(r.positionManager).poolManager());
        PoolKey memory key = keyOf(r);
        if (_sqrtPrice(pm, key) == 0) revert NoPool();
        _pendingPoolManager = address(pm);
        bytes memory result = pm.unlock(abi.encode(key, tokenIn, amountIn));
        _pendingPoolManager = address(0);
        out = abi.decode(result, (uint256));
        uint256 rest = IERC20(tokenIn).balanceOf(address(this));
        if (rest > 0) require(IERC20(tokenIn).transfer(lpDesk, rest));
    }

    /// @notice Answers only the PoolManager recorded by swapExactInToDead inside that call.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        IPoolManager pm = IPoolManager(_pendingPoolManager);
        if (msg.sender != address(pm) || address(pm) == address(0)) revert NotPoolManager();
        (PoolKey memory key, address tokenIn, uint256 amountIn) = abi.decode(data, (PoolKey, address, uint256));
        bool zeroForOne = tokenIn == key.currency0;
        int256 delta = pm.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? PoolMath.MIN_SQRT_RATIO + 1 : PoolMath.MAX_SQRT_RATIO - 1
            }),
            ""
        );
        int128 amount0 = int128(delta >> 128);
        int128 amount1 = int128(delta);
        uint256 out = uint256(uint128(zeroForOne ? amount1 : amount0));
        int128 inSigned = zeroForOne ? amount0 : amount1;
        uint256 spent = inSigned < 0 ? uint256(uint128(-inSigned)) : 0;
        if (spent > amountIn) revert NotPoolManager();
        if (spent > 0) {
            pm.sync(tokenIn);
            require(IERC20(tokenIn).transfer(address(pm), spent));
            pm.settle();
        }
        if (out > 0) pm.take(zeroForOne ? key.currency1 : key.currency0, FirmAddresses.DEAD, out);
        return abi.encode(out);
    }

    // ---------------------------------------------------------------- internals

    function _sqrtPrice(IPoolManager pm, PoolKey memory key) private view returns (uint160) {
        bytes32 slot = keccak256(abi.encode(keccak256(abi.encode(key)), uint256(6)));
        return uint160(uint256(pm.extsload(slot)));
    }

    /// @dev Largest liquidity whose rounded-up amounts at the current price fit within amt0/amt1.
    function _fit(uint160 current, int24 tl, int24 tu, uint256 amt0, uint256 amt1)
        private
        pure
        returns (uint128 liquidity)
    {
        uint160 sa = PoolMath.getSqrtRatioAtTick(tl);
        uint160 sb = PoolMath.getSqrtRatioAtTick(tu);
        uint128 l0 = amt0 > 0 ? PoolMath.liquidityFromAmount0(current, sa, sb, amt0) : 0;
        uint128 l1 = amt1 > 0 ? PoolMath.liquidityFromAmount1(current, sa, sb, amt1) : 0;
        if (current <= sa) liquidity = l0;
        else if (current >= sb) liquidity = l1;
        else liquidity = l0 < l1 ? l0 : l1;
        for (uint256 i; i < 4 && liquidity > 0; ++i) {
            (uint256 n0, uint256 n1) = PoolMath.getAmountsForLiquidity(current, sa, sb, liquidity);
            if (n0 <= amt0 && n1 <= amt1) break;
            liquidity -= 1;
        }
    }

    function _send(address token, address to, uint256 amount) private {
        if (amount > 0) require(IERC20(token).transfer(to, amount));
    }
}
