// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "./TestBase.sol";
import {DeployModules} from "../script/DeployModules.s.sol";
import {LpDesk} from "../src/LpDesk.sol";
import {FirmVault} from "../src/FirmVault.sol";
import {LpGovernor} from "../src/modules/LpGovernor.sol";
import {PriceGuard} from "../src/modules/PriceGuard.sol";
import {PoolMath} from "../src/libraries/PoolMath.sol";
import {OpenParams, PosRef, VenueKind, IVenueModule} from "../src/interfaces/ILpDesk.sol";
import {
    IERC20,
    IPoolManager,
    PoolKey,
    INonfungiblePositionManager,
    IV3PoolSwap,
    ICLFactory
} from "../src/interfaces/IExternal.sol";
import {FirmAddresses} from "../src/FirmAddresses.sol";

/// @notice An outside trader: swaps on V3/CL pools (paying in the callback) and on v4 pools (unlock), creates pools.
contract Trader {
    address private _pool;

    function swapV3(address pool, address tokenIn, bool zeroForOne, uint256 amountIn) external {
        _pool = pool;
        IV3PoolSwap(pool)
            .swap(
                address(this),
                zeroForOne,
                int256(amountIn),
                zeroForOne ? PoolMath.MIN_SQRT_RATIO + 1 : PoolMath.MAX_SQRT_RATIO - 1,
                abi.encode(tokenIn)
            );
        _pool = address(0);
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata data) external {
        require(msg.sender == _pool, "pool");
        address tokenIn = abi.decode(data, (address));
        IERC20(tokenIn).transfer(msg.sender, uint256(a0 > 0 ? a0 : a1));
    }

    function swapV4(IPoolManager pm, PoolKey memory key, address tokenIn, uint256 amountIn) external {
        pm.unlock(abi.encode(pm, key, tokenIn, amountIn));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (IPoolManager pm, PoolKey memory key, address tokenIn, uint256 amountIn) =
            abi.decode(data, (IPoolManager, PoolKey, address, uint256));
        require(msg.sender == address(pm), "pm");
        bool zeroForOne = tokenIn == key.currency0;
        int256 delta = pm.swap(
            key,
            IPoolManager.SwapParams(
                zeroForOne, -int256(amountIn), zeroForOne ? PoolMath.MIN_SQRT_RATIO + 1 : PoolMath.MAX_SQRT_RATIO - 1
            ),
            ""
        );
        uint256 out = uint256(uint128(zeroForOne ? int128(delta) : int128(delta >> 128)));
        pm.sync(tokenIn);
        IERC20(tokenIn).transfer(address(pm), amountIn);
        pm.settle();
        if (out > 0) pm.take(zeroForOne ? key.currency1 : key.currency0, address(this), out);
        return "";
    }
}

/// @notice Robinhood Chain fork tests (chain id 4663): every live venue of SPEC.md 2b plus the SushiSwap AddVenue case.
/// Skipped on any other chain, so `forge test` without --fork-url stays green offline.
contract ForkTest is TestBase {
    Trader trader;
    uint160 constant ONE = 79228162514264337593543950336; // 1:1

    modifier onFork() {
        if (block.chainid != 4663) {
            vm.skip(true);
        } else {
            _;
        }
    }

    function setUp() public {
        if (block.chainid != 4663) return;
        _launch(address(0));
        DeployModules deployer = new DeployModules();
        address[4] memory mods = deployer.deployAll(desk);
        gov = LpGovernor(mods[0]);
        guard = PriceGuard(mods[1]);
        _fundAndRegister();
        splitter.split();
        trader = new Trader();
        factory.releasePoolShare(address(token), address(trader));
        deal(WETH, address(desk), 1_000e18);
        deal(WETH, address(trader), 1_000e18);
        deal(IMD, address(trader), 1_000_000e18);
    }

    // ------------------------------------------------------------ helpers

    function _ref(uint256 id) internal view returns (PosRef memory r) {
        LpDesk.Position memory p = desk.getPosition(id);
        r.positionManager = p.positionManager;
        r.kind = p.kind;
        r.token0 = p.notStockIs0 ? address(token) : p.asset;
        r.token1 = p.notStockIs0 ? p.asset : address(token);
        r.fee = p.fee;
        r.tickSpacing = p.tickSpacing;
        r.tickLower = p.tickLower;
        r.tickUpper = p.tickUpper;
        r.tokenId = p.tokenId;
    }

    function _module(VenueKind kind) internal view returns (IVenueModule) {
        return IVenueModule(kind == VenueKind.V4 ? desk.venueV4() : desk.venueV3());
    }

    /// @dev Builds an open of `amount` NOTSTOCK (or asset when the range takes none) with 99.5% minimums.
    function _params(
        address asset,
        address venue,
        uint24 fee,
        int24 spacing,
        int24 lo,
        int24 hi,
        uint160 price,
        uint256 amount
    ) internal view returns (OpenParams memory p) {
        p = OpenParams(asset, venue, fee, spacing, lo, hi, price, amount, 0, 0);
        bool n0 = address(token) < asset;
        uint160 sa = PoolMath.getSqrtRatioAtTick(lo);
        uint160 sb = PoolMath.getSqrtRatioAtTick(hi);
        uint128 l = n0
            ? PoolMath.liquidityFromAmount0(price, sa, sb, amount)
            : PoolMath.liquidityFromAmount1(price, sa, sb, amount);
        if (l == 0) {
            l = n0
                ? PoolMath.liquidityFromAmount1(price, sa, sb, amount)
                : PoolMath.liquidityFromAmount0(price, sa, sb, amount);
        }
        (uint256 a0, uint256 a1) = PoolMath.getAmountsForLiquidity(price, sa, sb, l);
        p.amount0Min = a0 * 995 / 1000;
        p.amount1Min = a1 * 995 / 1000;
    }

    function _trade(uint256 id, uint256 amountAsset, uint256 amountNotStock) internal {
        PosRef memory r = _ref(id);
        LpDesk.Position memory p = desk.getPosition(id);
        if (r.kind == VenueKind.V4) {
            IPoolManager pm = IPoolManager(FirmAddresses.UNI_V4_POOL_MANAGER);
            PoolKey memory key = PoolKey(r.token0, r.token1, r.fee, r.tickSpacing, address(0));
            trader.swapV4(pm, key, p.asset, amountAsset);
            trader.swapV4(pm, key, address(token), amountNotStock);
        } else {
            address pool = _poolOf(r);
            trader.swapV3(pool, p.asset, p.asset == r.token0, amountAsset);
            trader.swapV3(pool, address(token), address(token) == r.token0, amountNotStock);
        }
    }

    function _poolOf(PosRef memory r) internal view returns (address) {
        address f = INonfungiblePositionManager(r.positionManager).factory();
        if (r.kind == VenueKind.CL) return ICLFactory(f).getPool(r.token0, r.token1, r.tickSpacing);
        (bool ok, bytes memory ret) =
            f.staticcall(abi.encodeWithSignature("getPool(address,address,uint24)", r.token0, r.token1, r.fee));
        require(ok);
        return abi.decode(ret, (address));
    }

    // ------------------------------------------------------------ the venue run

    function _runVenue(address pm, VenueKind kind, uint24 fee, int24 spacing) internal {
        bool n0 = address(token) < WETH;
        // 1. two-sided open at 1:1 creates the pool at exactly that price
        OpenParams memory p = _params(WETH, pm, fee, spacing, -spacing * 200, spacing * 200, ONE, 300e18);
        uint256 freeNotBefore = desk.freeBalance(address(token));
        vm.prank(DEV);
        uint256 id = desk.open(p);
        (bool exists, uint160 price,) = _module(kind).poolPrice(_ref(id));
        assertTrue(exists);
        assertEq(price, ONE, "pool created at the given price");
        assertLe(freeNotBefore - desk.freeBalance(address(token)), 300e18 + 1);
        assertGt(desk.positionLiquidity(id), 0);

        // 2. an outside trader generates fees both ways
        _trade(id, 1e18, 1e18);

        // 3. collect: WETH 25/25/25/25, NOTSTOCK 100% to Burner
        uint256 projBefore = IERC20(WETH).balanceOf(PROJECT);
        uint256 freeWethBefore = desk.freeBalance(WETH);
        uint256 burnerBefore = token.balanceOf(address(burner));
        uint256 deskWethBefore = IERC20(WETH).balanceOf(address(desk));
        vm.prank(DEV);
        desk.collect(id);
        uint256 projGain = IERC20(WETH).balanceOf(PROJECT) - projBefore;
        assertGt(projGain, 0, "weth fees collected");
        assertEq(desk.topUpBasket(WETH), projGain);
        assertEq(desk.buybackBasket(WETH), projGain);
        uint256 received = IERC20(WETH).balanceOf(address(desk)) - deskWethBefore + projGain;
        assertEq(desk.freeBalance(WETH) - freeWethBefore, received - 3 * projGain);
        assertGt(token.balanceOf(address(burner)) - burnerBefore, 0, "notstock fees to burner");

        // 4. asset-only position (range entirely on the WETH side) and a top-up from the basket
        (, uint160 cur, int24 tick) = _module(kind).poolPrice(_ref(id));
        int24 base = (tick / spacing) * spacing;
        OpenParams memory q = n0
            ? _params(WETH, pm, fee, spacing, base - spacing * 100, base - spacing, cur, 1e18)
            : _params(WETH, pm, fee, spacing, base + spacing * 2, base + spacing * 100, cur, 1e18);
        vm.prank(DEV);
        uint256 id2 = desk.open(q);
        uint256 topUp = desk.topUpBasket(WETH);
        uint160 sa = PoolMath.getSqrtRatioAtTick(q.tickLower);
        uint160 sb = PoolMath.getSqrtRatioAtTick(q.tickUpper);
        uint128 expectL =
            n0 ? PoolMath.liquidityFromAmount1(cur, sa, sb, topUp) : PoolMath.liquidityFromAmount0(cur, sa, sb, topUp);
        vm.expectRevert(LpDesk.AboveBasket.selector);
        vm.prank(DEV);
        desk.increaseLiquidity(id2, topUp + 1, cur, 0);
        vm.expectRevert(LpDesk.BelowMinimum.selector);
        vm.prank(DEV);
        desk.increaseLiquidity(id2, topUp, cur, expectL * 994 / 1000);
        vm.expectRevert(LpDesk.NotOperator.selector);
        desk.increaseLiquidity(id2, topUp, cur, expectL * 995 / 1000);
        // the two-sided position needs NOTSTOCK: top-up refuses it
        vm.expectRevert(LpDesk.NeedsNotStock.selector);
        vm.prank(DEV);
        desk.increaseLiquidity(id, topUp, cur, 0);
        uint256 notBefore = desk.freeBalance(address(token));
        uint128 liqBefore = desk.positionLiquidity(id2);
        vm.prank(DEV);
        desk.increaseLiquidity(id2, topUp, cur, expectL * 995 / 1000);
        assertEq(desk.freeBalance(address(token)), notBefore, "no NOTSTOCK taken");
        assertGe(desk.positionLiquidity(id2) - liqBefore, expectL * 995 / 1000);
        assertLt(desk.topUpBasket(WETH), topUp);
        assertEq(desk.topUpBasket(WETH), topUp - (topUp - desk.topUpBasket(WETH)));

        // 5. buyback from the WETH buyback basket in the position's own pool, output to the dead address
        uint256 bb = desk.buybackBasket(WETH);
        uint256 deadBefore = token.balanceOf(DEAD);
        vm.expectRevert(LpDesk.AboveBasket.selector);
        vm.prank(DEV);
        desk.buyback(id, bb + 1, 0);
        vm.expectRevert(LpDesk.BelowMinOut.selector);
        vm.prank(DEV);
        desk.buyback(id, bb, type(uint256).max);
        vm.expectRevert(LpDesk.NotOperator.selector);
        desk.buyback(id, bb, 0);
        vm.prank(DEV);
        uint256 out = desk.buyback(id, bb, 1);
        assertEq(desk.buybackBasket(WETH), 0);
        assertEq(token.balanceOf(DEAD) - deadBefore, out);
        assertGt(out, 0);

        // 6. shift range (fees collected first), then close with manual minimums
        vm.prank(DEV);
        desk.shiftRange(id, -spacing * 400, spacing * 400, 0, 0);
        assertEq(desk.getPosition(id).tickUpper, spacing * 400);
        assertGt(desk.positionLiquidity(id), 0);
        vm.expectRevert();
        vm.prank(DEV);
        desk.close(id, type(uint128).max, type(uint128).max);
        vm.expectRevert(LpDesk.NotOperator.selector);
        desk.close(id, 0, 0);
        uint256 freeBefore = desk.freeBalance(address(token));
        uint256 topBefore = desk.topUpBasket(WETH);
        uint256 bbBefore = desk.buybackBasket(WETH);
        uint256 projBefore2 = IERC20(WETH).balanceOf(PROJECT);
        vm.prank(DEV);
        desk.close(id, 0, 0);
        assertFalse(desk.getPosition(id).open);
        assertGt(desk.freeBalance(address(token)), freeBefore);
        // only the collected-fee split touches the baskets and the project wallet, in equal quarters
        uint256 feeQuarter = desk.topUpBasket(WETH) - topBefore;
        assertEq(desk.buybackBasket(WETH) - bbBefore, feeQuarter);
        assertEq(IERC20(WETH).balanceOf(PROJECT) - projBefore2, feeQuarter);
        vm.expectRevert(LpDesk.PositionNotOpen.selector);
        vm.prank(DEV);
        desk.close(id, 0, 0);
        // module holds nothing
        assertEq(IERC20(WETH).balanceOf(address(_module(kind))), 0);
        assertEq(token.balanceOf(address(_module(kind))), 0);
    }

    function test_uniswapV4Venue() public onFork {
        _runVenue(FirmAddresses.UNI_V4_POSITION_MANAGER, VenueKind.V4, 3000, 60);
    }

    function test_uniswapV3Venue() public onFork {
        _runVenue(FirmAddresses.UNI_V3_POSITION_MANAGER, VenueKind.V3, 3000, 60);
    }

    function test_aeroSlipstreamVenue() public onFork {
        _runVenue(FirmAddresses.AERO_CL_POSITION_MANAGER, VenueKind.CL, 0, 200);
    }

    /// @dev A pool created beforehand at a price more than 0.5% away makes the open revert; within 0.5% it opens.
    function test_openPriceCheckOnEveryVenue() public onFork {
        bool n0 = address(token) < WETH;
        (address a, address b) = n0 ? (address(token), WETH) : (WETH, address(token));
        uint160 far = uint160(uint256(ONE) * 1004 / 1000); // +0.8% price
        uint160 near = uint160(uint256(ONE) * 1001 / 1000); // +0.2% price
        // V3: the trader creates the 500 fee pool far away
        INonfungiblePositionManager(FirmAddresses.UNI_V3_POSITION_MANAGER)
            .createAndInitializePoolIfNecessary(a, b, 500, far);
        OpenParams memory p = _params(WETH, FirmAddresses.UNI_V3_POSITION_MANAGER, 500, 10, -1000, 1000, ONE, 100e18);
        vm.expectRevert(LpDesk.PriceMoved.selector);
        vm.prank(DEV);
        desk.open(p);
        p = _params(WETH, FirmAddresses.UNI_V3_POSITION_MANAGER, 500, 10, -1000, 1000, near, 100e18);
        vm.expectRevert(LpDesk.PriceMoved.selector);
        vm.prank(DEV);
        desk.open(p);
        p = _params(WETH, FirmAddresses.UNI_V3_POSITION_MANAGER, 500, 10, -1000, 1000, far, 100e18);
        vm.prank(DEV);
        desk.open(p);
        // V4: pool initialised far away by the trader
        IPoolManager(FirmAddresses.UNI_V4_POOL_MANAGER).initialize(PoolKey(a, b, 500, 10, address(0)), far);
        p = _params(WETH, FirmAddresses.UNI_V4_POSITION_MANAGER, 500, 10, -1000, 1000, ONE, 100e18);
        vm.expectRevert(LpDesk.PriceMoved.selector);
        vm.prank(DEV);
        desk.open(p);
        p = _params(WETH, FirmAddresses.UNI_V4_POSITION_MANAGER, 500, 10, -1000, 1000, far, 100e18);
        vm.prank(DEV);
        desk.open(p);
        // CL: pool created far away by the trader
        (bool ok,) = FirmAddresses.AERO_CL_FACTORY
            .call(abi.encodeWithSignature("createPool(address,address,int24,uint160)", a, b, int24(100), far));
        assertTrue(ok, "cl createPool");
        p = _params(WETH, FirmAddresses.AERO_CL_POSITION_MANAGER, 0, 100, -1000, 1000, ONE, 100e18);
        vm.expectRevert(LpDesk.PriceMoved.selector);
        vm.prank(DEV);
        desk.open(p);
        p = _params(WETH, FirmAddresses.AERO_CL_POSITION_MANAGER, 0, 100, -1000, 1000, far, 100e18);
        vm.prank(DEV);
        desk.open(p);
        // minimum below 99.5% reverts
        p = _params(WETH, FirmAddresses.AERO_CL_POSITION_MANAGER, 0, 100, -2000, 2000, far, 100e18);
        p.amount0Min = p.amount0Min * 99 / 100;
        vm.expectRevert(LpDesk.BelowMinimum.selector);
        vm.prank(DEV);
        desk.open(p);
        // amount above the free balance reverts
        p = _params(WETH, FirmAddresses.AERO_CL_POSITION_MANAGER, 0, 100, -2000, 2000, far, 600_000_000e18);
        vm.expectRevert(LpDesk.AboveFreeBalance.selector);
        vm.prank(DEV);
        desk.open(p);
    }

    /// @dev Single-sided NOTSTOCK above the current price: no swap, no asset taken.
    function test_singleSidedNotStockOpenTakesNoAsset() public onFork {
        bool n0 = address(token) < WETH;
        uint256 wethBefore = desk.freeBalance(WETH);
        OpenParams memory p = n0
            ? _params(WETH, FirmAddresses.UNI_V3_POSITION_MANAGER, 3000, 60, 600, 6000, ONE, 1_000e18)
            : _params(WETH, FirmAddresses.UNI_V3_POSITION_MANAGER, 3000, 60, -6000, -600, ONE, 1_000e18);
        vm.prank(DEV);
        desk.open(p);
        assertEq(desk.freeBalance(WETH), wethBefore);
        assertEq(desk.freeBalance(address(token)), 500_000_000e18 - 1_000e18);
    }

    /// @dev After the bootstrap only an executed OpenPosition opens.
    function test_governedOpenAfterBootstrap() public onFork {
        vm.prank(DEV);
        token.transfer(alice, 1_000e18);
        vm.startPrank(alice);
        token.approve(address(gov), 1_000e18);
        gov.stake(1_000e18);
        vm.stopPrank();
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(desk.bootstrapEnd());
        OpenParams memory p = _params(WETH, FirmAddresses.UNI_V3_POSITION_MANAGER, 3000, 60, -1200, 1200, ONE, 1_000e18);
        vm.expectRevert(LpDesk.BootstrapOver.selector);
        vm.prank(DEV);
        desk.open(p);
        vm.prank(DEV);
        uint256 id = gov.proposeOpenPosition(p);
        vm.prank(alice);
        gov.vote(id, true);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        gov.execute(id);
        assertEq(desk.positionCount(), 1);
        assertTrue(desk.getPosition(0).open);
        // the operator still closes after the bootstrap
        vm.prank(DEV);
        desk.close(0, 0, 0);
        assertFalse(desk.getPosition(0).open);
    }

    /// @dev FirmVault buyback in the registered NOTSTOCK/IMD pool (hookless on this fork, seeded through LpDesk).
    function test_firmVaultBuyback() public onFork {
        OpenParams memory p =
            _params(IMD, FirmAddresses.UNI_V4_POSITION_MANAGER, 12500, 60, -6000, 6000, ONE, 1_000_000e18);
        deal(IMD, address(desk), 2_000_000e18);
        vm.prank(DEV);
        desk.open(p);
        deal(IMD, address(vault), 400e18);
        vault.distribute(IMD);
        assertEq(vault.buybackBucket(), 100e18);
        uint256 deadBefore = token.balanceOf(DEAD);
        vm.expectRevert(FirmVault.BelowMinOut.selector);
        vm.prank(DEV);
        vault.buyback(50e18, type(uint256).max);
        vm.prank(DEV);
        uint256 out = vault.buyback(50e18, 1);
        assertEq(vault.buybackBucket(), 50e18);
        assertEq(token.balanceOf(DEAD) - deadBefore, out);
        assertGt(out, 0);
        // LpDesk's IMD fee share reaches the bucket after a trade
        trader.swapV4(
            IPoolManager(FirmAddresses.UNI_V4_POOL_MANAGER),
            PoolKey(
                address(token) < IMD ? address(token) : IMD,
                address(token) < IMD ? IMD : address(token),
                12500,
                60,
                address(0)
            ),
            IMD,
            1_000e18
        );
        uint256 bucketBefore = vault.buybackBucket();
        vm.prank(DEV);
        desk.collect(0);
        assertGt(vault.buybackBucket(), bucketBefore);
    }

    /// @dev SushiSwap v3 joins by AddVenue and works like the fixed list.
    function test_addVenueSushi() public onFork {
        vm.prank(DEV);
        token.transfer(alice, 1_000e18);
        vm.startPrank(alice);
        token.approve(address(gov), 1_000e18);
        gov.stake(1_000e18);
        vm.stopPrank();
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(alice);
        uint256 id = gov.proposeAddVenue(FirmAddresses.SUSHI_V3_POSITION_MANAGER, VenueKind.V3);
        vm.prank(alice);
        gov.vote(id, true);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        gov.execute(id);
        assertEq(guard.venues().length, 4);
        assertEq(guard.venues()[3].factory, FirmAddresses.SUSHI_V3_FACTORY);
        // bootstrap is over after 5 days? no: 7 days. Open directly.
        _runVenue(FirmAddresses.SUSHI_V3_POSITION_MANAGER, VenueKind.V3, 3000, 60);
    }

    /// @dev One listed stock token (balance by deal) pairs with NOTSTOCK and splits fees 25/25/25/25.
    function test_stockTokenPosition() public onFork {
        address stock = FirmAddresses.NVDA;
        deal(stock, address(desk), 1_000e18);
        deal(stock, address(trader), 1_000e18);
        bool n0 = address(token) < stock;
        OpenParams memory p =
            _params(stock, FirmAddresses.UNI_V3_POSITION_MANAGER, 3000, 60, -12000, 12000, ONE, 300e18);
        vm.prank(DEV);
        uint256 id = desk.open(p);
        PosRef memory r = _ref(id);
        address pool = _poolOf(r);
        trader.swapV3(pool, stock, stock == r.token0, 1e18);
        trader.swapV3(pool, address(token), address(token) == r.token0, 1e18);
        uint256 projBefore = IERC20(stock).balanceOf(PROJECT);
        vm.prank(DEV);
        desk.collect(id);
        uint256 q = IERC20(stock).balanceOf(PROJECT) - projBefore;
        assertGt(q, 0);
        assertEq(desk.topUpBasket(stock), q);
        assertEq(desk.buybackBasket(stock), q);
        n0;
        vm.prank(DEV);
        desk.close(id, 0, 0);
        assertFalse(desk.getPosition(id).open);
    }

    /// @dev Launch rehearsal through the factory stand-in: deploy gas, modules, 600M transfer, setRequester,
    /// registerNotStock, split, and the supply conservation of SPEC.md section 4.
    function test_launchRehearsalAccounting() public onFork {
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.balanceOf(address(desk)), 500_000_000e18);
        assertEq(token.balanceOf(DEV), 100_000_000e18);
        assertEq(token.balanceOf(address(splitter)), 0);
        assertEq(token.balanceOf(address(factory)) + token.balanceOf(address(trader)), 400_000_000e18); // 10% swarm + 30% pool
        assertEq(factory.positionOf(launchNumber).requester, address(vault));
        assertTrue(desk.registered());
        uint256 g = gasleft();
        new LpDesk(address(token), DEV, PROJECT);
        new FirmVault(PROJECT, address(desk));
        g = g - gasleft();
        assertLt(g, 16_777_216);
    }
}
