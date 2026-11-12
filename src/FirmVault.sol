// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20, IPoolManager, PoolKey} from "./interfaces/IExternal.sol";
import {ILpDesk} from "./interfaces/ILpDesk.sol";
import {FirmAddresses} from "./FirmAddresses.sol";

/// @notice Receives the launch pool's 1% fee cut (plain transfers from the launch factory) once the project wallet
/// has made it the pool fee recipient. distribute(IMD) splits the undistributed IMD 25/25/25/25; distribute(NOTSTOCK)
/// sends everything to Burner. buyback(amount, minOut) by LpDesk's operator swaps bucket IMD for NOTSTOCK in the
/// registered pool and sends it to the dead address. No owner, no other withdrawal path.
contract FirmVault {
    address public immutable projectWallet;
    address public immutable lpDesk;
    IPoolManager public constant POOL_MANAGER = IPoolManager(FirmAddresses.UNI_V4_POOL_MANAGER);
    address public constant IMD = FirmAddresses.IMD;
    address public constant DEAD = FirmAddresses.DEAD;

    /// @notice IMD reserved for buybacks (25% of each distribute(IMD) plus LpDesk's IMD buyback share).
    uint256 public buybackBucket;

    event Distributed(address indexed token, uint256 amount);
    event BuybackCredited(uint256 amount);
    event Buyback(uint256 amountIn, uint256 notStockOut);

    error NotRegistered();
    error UnsupportedToken();
    error NotLpDesk();
    error NotOperator();
    error AboveBucket();
    error BelowMinOut();
    error NotPoolManager();

    constructor(address projectWallet_, address lpDesk_) {
        projectWallet = projectWallet_;
        lpDesk = lpDesk_;
    }

    /// @notice Splits the whole undistributed balance of `token`: IMD 25% bucket / 25% project wallet / 25% LpDesk
    /// top-up basket / 25% LpDesk free; NOTSTOCK 100% to Burner. Anyone may call; a repeat moves nothing.
    function distribute(address token) external {
        ILpDesk desk = ILpDesk(lpDesk);
        if (!desk.registered()) revert NotRegistered();
        address notStock = desk.notStock();
        if (token == notStock) {
            uint256 bal = IERC20(token).balanceOf(address(this));
            if (bal > 0) require(IERC20(token).transfer(desk.burner(), bal));
            emit Distributed(token, bal);
            return;
        }
        if (token != IMD) revert UnsupportedToken();
        uint256 undistributed = IERC20(IMD).balanceOf(address(this)) - buybackBucket;
        uint256 quarter = undistributed / 4;
        if (quarter == 0) {
            emit Distributed(token, 0);
            return;
        }
        // Up to 3 wei of rounding stay undistributed for the next call; nothing is lost or miscounted.
        buybackBucket += quarter;
        require(IERC20(IMD).transfer(projectWallet, quarter));
        require(IERC20(IMD).transfer(lpDesk, quarter * 2));
        desk.creditFromFirmVault(quarter, quarter);
        emit Distributed(token, quarter * 4);
    }

    /// @notice LpDesk's 25% IMD buyback share: LpDesk transfers the IMD first, then credits it here. Never split again.
    function creditBuyback(uint256 amount) external {
        if (msg.sender != lpDesk) revert NotLpDesk();
        buybackBucket += amount;
        if (IERC20(IMD).balanceOf(address(this)) < buybackBucket) revert AboveBucket();
        emit BuybackCredited(amount);
    }

    /// @notice Swaps `amount` of the buyback bucket's IMD for NOTSTOCK in the registered NOTSTOCK/IMD pool and sends
    /// all NOTSTOCK received to the dead address. Only LpDesk's current operator; minOut is manual slippage.
    function buyback(uint256 amount, uint256 minOut) external returns (uint256 out) {
        ILpDesk desk = ILpDesk(lpDesk);
        if (msg.sender != desk.operator()) revert NotOperator();
        if (amount > buybackBucket) revert AboveBucket();
        if (!desk.registered()) revert NotRegistered();
        buybackBucket -= amount;
        PoolKey memory key = desk.poolKey();
        bytes memory result = POOL_MANAGER.unlock(abi.encode(key, amount));
        out = abi.decode(result, (uint256));
        if (out < minOut) revert BelowMinOut();
        emit Buyback(amount, out);
    }

    /// @dev Inside POOL_MANAGER.unlock() made by buyback(): exact-input IMD -> NOTSTOCK, output taken to the dead address.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        (PoolKey memory key, uint256 amount) = abi.decode(data, (PoolKey, uint256));
        bool zeroForOne = key.currency0 == IMD;
        int256 delta = POOL_MANAGER.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341
            }),
            ""
        );
        // BalanceDelta packs amount0 in the upper 128 bits and amount1 in the lower 128 bits.
        int128 amount0 = int128(delta >> 128);
        int128 amount1 = int128(delta);
        int128 outSigned = zeroForOne ? amount1 : amount0;
        uint256 out = uint256(uint128(outSigned));
        POOL_MANAGER.sync(IMD);
        require(IERC20(IMD).transfer(address(POOL_MANAGER), amount));
        POOL_MANAGER.settle();
        address notStock = zeroForOne ? key.currency1 : key.currency0;
        if (out > 0) POOL_MANAGER.take(notStock, DEAD, out);
        return abi.encode(out);
    }
}
