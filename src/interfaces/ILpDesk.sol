// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "./IExternal.sol";

/// @notice Venue kinds of SPEC.md section 2b.
enum VenueKind {
    V4,
    V3,
    CL
}

/// @notice A venue: position manager, kind, and its factory (the PoolManager for V4).
struct Venue {
    address positionManager;
    VenueKind kind;
    address factory;
}

/// @notice Everything an open takes (SPEC.md section 2). feeTier is the pool fee for V3 and V4 and ignored for CL;
/// tickSpacing is the pool tick spacing for V4 and CL and ignored for V3 (its factory fixes it per fee).
struct OpenParams {
    address asset;
    address venue;
    uint24 feeTier;
    int24 tickSpacing;
    int24 tickLower;
    int24 tickUpper;
    uint160 sqrtPriceX96;
    uint256 amount;
    uint256 amount0Min;
    uint256 amount1Min;
}

/// @notice A position as a venue module needs to address it.
struct PosRef {
    address positionManager;
    VenueKind kind;
    address token0;
    address token1;
    uint24 fee;
    int24 tickSpacing;
    int24 tickLower;
    int24 tickUpper;
    uint256 tokenId;
}

/// @notice The views other contracts of this launch read from LpDesk.
interface ILpDeskViews {
    function notStock() external view returns (address);
    function operator() external view returns (address);
    function projectWallet() external view returns (address);
    function burner() external view returns (address);
    function launchFactory() external view returns (address);
    function governor() external view returns (address);
    function priceGuard() external view returns (address);
    function venueV3() external view returns (address);
    function venueV4() external view returns (address);
    function registered() external view returns (bool);
    function firmVault() external view returns (address);
    function poolKey() external view returns (PoolKey memory);
    function bootstrapEnd() external view returns (uint256);
    function freeBalance(address token) external view returns (uint256);
    function topUpBasket(address token) external view returns (uint256);
    function buybackBasket(address token) external view returns (uint256);
}

/// @notice What the modules and FirmVault call on LpDesk.
interface ILpDesk is ILpDeskViews {
    function creditFromFirmVault(uint256 topUpAmount, uint256 freeAmount) external;
    function openFromGovernor(OpenParams calldata p) external returns (uint256 positionId);
    function addAssetFromGovernor(address asset) external;
    function addVenueFromGovernor(address positionManager, VenueKind kind) external;
    function bridgeOutFromGovernor(address adapter, uint32 dstEid, address dstLpDesk, uint256 amount, address refund)
        external
        payable;
}

interface IPriceGuard {
    function registered() external view returns (bool);
    function registeredAt() external view returns (uint256);
    function firmVault() external view returns (address);
    function poolKey() external view returns (PoolKey memory);
    function isAsset(address asset) external view returns (bool);
    function venueOf(address positionManager) external view returns (Venue memory v, bool listed);
    function venues() external view returns (Venue[] memory);
    function assets() external view returns (address[] memory);
    function checkVenue(address positionManager, VenueKind kind) external view returns (address factory);
    function checkAsset(address asset) external view;
    function addAsset(address asset) external;
    function addVenue(address positionManager, VenueKind kind) external;
}

/// @notice A venue module. Tokens for mint/increase/swap are transferred to the module by LpDesk just before the
/// call; the module returns every unused or withdrawn amount to LpDesk (swap output to the dead address) in the same
/// call and holds nothing afterwards.
interface IVenueModule {
    function poolPrice(PosRef calldata r) external view returns (bool exists, uint160 sqrtPriceX96, int24 tick);
    function liquidityOf(PosRef calldata r) external view returns (uint128);
    function mint(PosRef calldata r, uint160 sqrtPriceX96, uint256 amt0, uint256 amt1)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 used0, uint256 used1);
    function increase(PosRef calldata r, uint256 amt0, uint256 amt1)
        external
        returns (uint128 liquidity, uint256 used0, uint256 used1);
    function collectFees(PosRef calldata r) external returns (uint256 fee0, uint256 fee1);
    function decrease(PosRef calldata r, uint128 liquidity, uint256 min0, uint256 min1)
        external
        returns (uint256 amt0, uint256 amt1);
    function swapExactInToDead(PosRef calldata r, address tokenIn, uint256 amountIn) external returns (uint256 out);
}

interface IFirmVault {
    function lpDesk() external view returns (address);
    function creditBuyback(uint256 amount) external;
}

interface IBurner {
    function burn() external;
}
