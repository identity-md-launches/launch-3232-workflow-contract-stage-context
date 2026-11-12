// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    IERC20,
    INonfungiblePositionManager,
    ICLPositionManager,
    IUniswapV3Factory,
    ICLFactory,
    IV3PoolSwap
} from "../interfaces/IExternal.sol";
import {PosRef, VenueKind} from "../interfaces/ILpDesk.sol";
import {PoolMath} from "../libraries/PoolMath.sol";
import {FirmAddresses} from "../FirmAddresses.sol";

/// @notice LpDesk module for the V3 (Uniswap v3 interface) and CL (Aero Slipstream interface) venue kinds, one code
/// path with the two mint/positions shapes. Every state-changing function is LpDesk-only except the swap callbacks,
/// which answer only the pool this module is swapping in. Positions are minted to LpDesk; the module holds nothing
/// after any call.
contract VenueV3 {
    address public immutable lpDesk;
    address private _pendingPool;

    error NotLpDesk();
    error NoPool();
    error WrongCallback();
    error FeeTierDisabled();

    constructor() {
        lpDesk = msg.sender;
    }

    modifier onlyDesk() {
        if (msg.sender != lpDesk) revert NotLpDesk();
        _;
    }

    // ---------------------------------------------------------------- views

    function poolOf(PosRef calldata r) public view returns (address pool) {
        address factory = INonfungiblePositionManager(r.positionManager).factory();
        if (r.kind == VenueKind.CL) return ICLFactory(factory).getPool(r.token0, r.token1, r.tickSpacing);
        return IUniswapV3Factory(factory).getPool(r.token0, r.token1, r.fee);
    }

    function poolPrice(PosRef calldata r) external view returns (bool exists, uint160 sqrtPriceX96, int24 tick) {
        address pool = poolOf(r);
        if (pool == address(0)) return (false, 0, 0);
        (bool ok, bytes memory ret) = pool.staticcall(abi.encodeWithSignature("slot0()"));
        if (!ok || ret.length < 64) return (false, 0, 0);
        (sqrtPriceX96, tick) = abi.decode(ret, (uint160, int24));
        exists = sqrtPriceX96 != 0;
    }

    function liquidityOf(PosRef calldata r) external view returns (uint128 liquidity) {
        (,,,,,,, liquidity,,,,) = INonfungiblePositionManager(r.positionManager).positions(r.tokenId);
    }

    /// @notice Tick spacing of the position's pool: the factory's for the fee (V3) or the given one (CL).
    function tickSpacingOf(PosRef calldata r) public view returns (int24 spacing) {
        address factory = INonfungiblePositionManager(r.positionManager).factory();
        if (r.kind == VenueKind.CL) {
            if (ICLFactory(factory).tickSpacingToFee(r.tickSpacing) == 0) revert FeeTierDisabled();
            return r.tickSpacing;
        }
        spacing = IUniswapV3Factory(factory).feeAmountTickSpacing(r.fee);
        if (spacing == 0) revert FeeTierDisabled();
    }

    // ---------------------------------------------------------------- mint / increase

    function mint(PosRef calldata r, uint160 sqrtPriceX96, uint256 amt0, uint256 amt1)
        external
        onlyDesk
        returns (uint256 tokenId, uint128 liquidity, uint256 used0, uint256 used1)
    {
        tickSpacingOf(r);
        _approve(r.token0, r.positionManager, amt0);
        _approve(r.token1, r.positionManager, amt1);
        bool exists = poolOf(r) != address(0);
        if (r.kind == VenueKind.CL) {
            (tokenId, liquidity, used0, used1) = ICLPositionManager(r.positionManager)
                .mint(
                    ICLPositionManager.MintParams({
                        token0: r.token0,
                        token1: r.token1,
                        tickSpacing: r.tickSpacing,
                        tickLower: r.tickLower,
                        tickUpper: r.tickUpper,
                        amount0Desired: amt0,
                        amount1Desired: amt1,
                        amount0Min: 0,
                        amount1Min: 0,
                        recipient: lpDesk,
                        deadline: block.timestamp,
                        sqrtPriceX96: exists ? 0 : sqrtPriceX96
                    })
                );
        } else {
            if (!exists) {
                INonfungiblePositionManager(r.positionManager)
                    .createAndInitializePoolIfNecessary(r.token0, r.token1, r.fee, sqrtPriceX96);
            }
            (tokenId, liquidity, used0, used1) = INonfungiblePositionManager(r.positionManager)
                .mint(
                    INonfungiblePositionManager.MintParams({
                        token0: r.token0,
                        token1: r.token1,
                        fee: r.fee,
                        tickLower: r.tickLower,
                        tickUpper: r.tickUpper,
                        amount0Desired: amt0,
                        amount1Desired: amt1,
                        amount0Min: 0,
                        amount1Min: 0,
                        recipient: lpDesk,
                        deadline: block.timestamp
                    })
                );
        }
        _flush(r.token0, r.positionManager);
        _flush(r.token1, r.positionManager);
    }

    function increase(PosRef calldata r, uint256 amt0, uint256 amt1)
        external
        onlyDesk
        returns (uint128 liquidity, uint256 used0, uint256 used1)
    {
        _approve(r.token0, r.positionManager, amt0);
        _approve(r.token1, r.positionManager, amt1);
        (liquidity, used0, used1) = INonfungiblePositionManager(r.positionManager)
            .increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams({
                    tokenId: r.tokenId,
                    amount0Desired: amt0,
                    amount1Desired: amt1,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            );
        _flush(r.token0, r.positionManager);
        _flush(r.token1, r.positionManager);
    }

    // ---------------------------------------------------------------- collect / decrease

    /// @notice Collects the position's fees to LpDesk. A 1-wei liquidity poke updates the owed fees; the principal that
    /// poke returns (0 or 1 wei) is reported as principal, not fee.
    function collectFees(PosRef calldata r) external onlyDesk returns (uint256 fee0, uint256 fee1) {
        INonfungiblePositionManager pm = INonfungiblePositionManager(r.positionManager);
        (,,,,,,, uint128 liquidity,,,,) = pm.positions(r.tokenId);
        uint256 p0;
        uint256 p1;
        if (liquidity > 0) {
            (p0, p1) = pm.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: r.tokenId, liquidity: 1, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
                })
            );
        }
        (uint256 c0, uint256 c1) = pm.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: r.tokenId, recipient: lpDesk, amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );
        fee0 = c0 - p0;
        fee1 = c1 - p1;
    }

    /// @notice Withdraws `liquidity` (after collectFees in the same LpDesk call, so only principal is owed) to LpDesk.
    function decrease(PosRef calldata r, uint128 liquidity, uint256 min0, uint256 min1)
        external
        onlyDesk
        returns (uint256 amt0, uint256 amt1)
    {
        INonfungiblePositionManager pm = INonfungiblePositionManager(r.positionManager);
        pm.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: r.tokenId, liquidity: liquidity, amount0Min: min0, amount1Min: min1, deadline: block.timestamp
            })
        );
        (amt0, amt1) = pm.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: r.tokenId, recipient: lpDesk, amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );
    }

    // ---------------------------------------------------------------- swap (buyback)

    /// @notice Exact-input swap of `amountIn` of `tokenIn` (already transferred here by LpDesk) in the position's own
    /// pool; the output goes straight to the dead address.
    function swapExactInToDead(PosRef calldata r, address tokenIn, uint256 amountIn)
        external
        onlyDesk
        returns (uint256 out)
    {
        address pool = poolOf(r);
        if (pool == address(0)) revert NoPool();
        bool zeroForOne = tokenIn == r.token0;
        _pendingPool = pool;
        (int256 d0, int256 d1) = IV3PoolSwap(pool)
            .swap(
                FirmAddresses.DEAD,
                zeroForOne,
                int256(amountIn),
                zeroForOne ? PoolMath.MIN_SQRT_RATIO + 1 : PoolMath.MAX_SQRT_RATIO - 1,
                abi.encode(tokenIn)
            );
        _pendingPool = address(0);
        int256 outSigned = zeroForOne ? d1 : d0;
        out = outSigned < 0 ? uint256(-outSigned) : 0;
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        _pay(amount0Delta, amount1Delta, data);
    }

    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        _pay(amount0Delta, amount1Delta, data);
    }

    function _pay(int256 amount0Delta, int256 amount1Delta, bytes calldata data) private {
        if (msg.sender != _pendingPool || msg.sender == address(0)) revert WrongCallback();
        address tokenIn = abi.decode(data, (address));
        int256 owed = amount0Delta > 0 ? amount0Delta : amount1Delta;
        require(IERC20(tokenIn).transfer(msg.sender, uint256(owed)));
    }

    // ---------------------------------------------------------------- internals

    function _approve(address token, address spender, uint256 amount) private {
        if (amount > 0) require(IERC20(token).approve(spender, amount));
    }

    /// @dev Returns any unused balance to LpDesk and clears the approval.
    function _flush(address token, address spender) private {
        if (IERC20(token).allowance(address(this), spender) != 0) require(IERC20(token).approve(spender, 0));
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) require(IERC20(token).transfer(lpDesk, bal));
    }
}
