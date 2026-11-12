// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20, IOFTAdapter, PoolKey} from "./interfaces/IExternal.sol";
import {
    ILpDesk,
    IPriceGuard,
    IVenueModule,
    IFirmVault,
    OpenParams,
    PosRef,
    Venue,
    VenueKind
} from "./interfaces/ILpDesk.sol";
import {PoolMath} from "./libraries/PoolMath.sol";
import {FirmAddresses} from "./FirmAddresses.sol";
import {Burner} from "./Burner.sol";

/// @notice The liquidity desk of SPEC.md section 2. Holds NOTSTOCK and every asset it receives from positions;
/// nothing ever leaves it except into a position on a listed venue, as the 25/25/25/25 fee split, by buyback or burn to
/// the dead address, or by an executed BridgeOut. Modules are created after launch by deployModule (CREATE2, fixed
/// code hashes). No owner beyond the operator's powers below.
contract LpDesk is ILpDesk {
    enum ModuleKind {
        LpGovernor,
        PriceGuard,
        VenueV3,
        VenueV4
    }

    struct Position {
        address positionManager;
        VenueKind kind;
        address asset;
        bool notStockIs0;
        uint24 fee;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint256 tokenId;
        bool open;
    }

    // Module creation code hashes, keccak256(type(Module).creationCode) of this build (checked by the bytecode test).
    bytes32 public constant LP_GOVERNOR_CODE_HASH = 0x950d93daedd06fac5d03b1811ffb9225e1fadbdf4923bd7d6b064e01ba1c0729;
    bytes32 public constant PRICE_GUARD_CODE_HASH = 0xf35f9b9e2d830f1ddff4e25aa6296ffbfd9234d46ccfe6a5d38e4ad870ab0bc8;
    bytes32 public constant VENUE_V3_CODE_HASH = 0xb0278c0b1e4a0a41235e60bb126e111586c6e9e44e4062db18edf60e47d47349;
    bytes32 public constant VENUE_V4_CODE_HASH = 0x91be9ed72e94f5da8f4f7155221beb8106829e93ff88ab06d54269e125e2994c;

    uint256 public constant BOOTSTRAP_DURATION = 604_800;
    address public constant DEAD = FirmAddresses.DEAD;
    address public constant IMD = FirmAddresses.IMD;

    address public immutable notStock;
    address public immutable projectWallet;
    address public immutable launchFactory;
    address public immutable burner;
    address public immutable governor;
    address public immutable priceGuard;
    address public immutable venueV3;
    address public immutable venueV4;

    address public operator;
    Position[] private _positions;
    mapping(address => uint256) public topUpBasket;
    mapping(address => uint256) public buybackBasket;
    mapping(address => mapping(address => bool)) private _nftApproved; // position manager => module

    event ModuleDeployed(ModuleKind kind, address module);
    event OperatorChanged(address indexed from, address indexed to);
    event PositionOpened(uint256 indexed id, address venue, address asset, uint256 tokenId, uint128 liquidity);
    event PositionChanged(uint256 indexed id, uint256 tokenId, int24 tickLower, int24 tickUpper);
    event PositionClosed(uint256 indexed id, uint256 amount0, uint256 amount1);
    event FeesSplit(uint256 indexed id, address token, uint256 amount);
    event ToppedUp(uint256 indexed id, uint256 amount, uint128 liquidity);
    event BuybackExecuted(uint256 indexed id, uint256 amountIn, uint256 notStockOut);
    event Burned(uint256 amount);
    event BridgedOut(address adapter, uint32 dstEid, address dstLpDesk, uint256 amount);
    event VaultCredit(uint256 topUp, uint256 free);

    error NotOperator();
    error NotGovernor();
    error NotFirmVault();
    error ModuleMissing();
    error WrongModuleCode();
    error ModuleExists();
    error NotRegistered();
    error BootstrapOver();
    error UnlistedAsset();
    error UnlistedVenue();
    error PriceMoved();
    error BelowMinimum();
    error AboveFreeBalance();
    error AboveBasket();
    error NeedsNotStock();
    error PositionNotOpen();
    error NotAnAssetOfThisPosition();
    error ImdNotBuyable();
    error BelowMinOut();
    error ZeroAddress();
    error PairMismatch();
    error BridgeMismatch();
    error BuybackMismatch();

    constructor(address token, address operator_, address projectWallet_) {
        if (token == address(0) || operator_ == address(0) || projectWallet_ == address(0)) revert ZeroAddress();
        notStock = token;
        operator = operator_;
        projectWallet = projectWallet_;
        launchFactory = msg.sender;
        burner = address(new Burner(address(this)));
        governor = _predict(ModuleKind.LpGovernor, LP_GOVERNOR_CODE_HASH);
        priceGuard = _predict(ModuleKind.PriceGuard, PRICE_GUARD_CODE_HASH);
        venueV3 = _predict(ModuleKind.VenueV3, VENUE_V3_CODE_HASH);
        venueV4 = _predict(ModuleKind.VenueV4, VENUE_V4_CODE_HASH);
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    modifier onlyGovernor() {
        if (msg.sender != governor || governor.code.length == 0) revert NotGovernor();
        _;
    }

    // ---------------------------------------------------------------- modules

    /// @notice Deploys a module by CREATE2 (salt = kind) from its exact creation code, once per kind, by anyone.
    function deployModule(ModuleKind kind, bytes memory creationCode) external returns (address module) {
        bytes32 expected = codeHashOf(kind);
        if (keccak256(creationCode) != expected) revert WrongModuleCode();
        address predicted = moduleAddress(kind);
        if (predicted.code.length != 0) revert ModuleExists();
        bytes32 salt = bytes32(uint256(kind));
        assembly ("memory-safe") {
            module := create2(0, add(creationCode, 32), mload(creationCode), salt)
        }
        if (module == address(0) || module != predicted) revert WrongModuleCode();
        emit ModuleDeployed(kind, module);
    }

    function codeHashOf(ModuleKind kind) public pure returns (bytes32) {
        if (kind == ModuleKind.LpGovernor) return LP_GOVERNOR_CODE_HASH;
        if (kind == ModuleKind.PriceGuard) return PRICE_GUARD_CODE_HASH;
        if (kind == ModuleKind.VenueV3) return VENUE_V3_CODE_HASH;
        return VENUE_V4_CODE_HASH;
    }

    function moduleAddress(ModuleKind kind) public view returns (address) {
        if (kind == ModuleKind.LpGovernor) return governor;
        if (kind == ModuleKind.PriceGuard) return priceGuard;
        if (kind == ModuleKind.VenueV3) return venueV3;
        return venueV4;
    }

    function moduleDeployed(ModuleKind kind) public view returns (bool) {
        return moduleAddress(kind).code.length != 0;
    }

    // ---------------------------------------------------------------- views

    function registered() public view returns (bool) {
        return priceGuard.code.length != 0 && IPriceGuard(priceGuard).registered();
    }

    function firmVault() public view returns (address) {
        return _guard().firmVault();
    }

    function poolKey() external view returns (PoolKey memory) {
        return _guard().poolKey();
    }

    /// @notice End of the 7-day bootstrap; 0 until NOTSTOCK is registered.
    function bootstrapEnd() public view returns (uint256) {
        if (!registered()) return 0;
        return IPriceGuard(priceGuard).registeredAt() + BOOTSTRAP_DURATION;
    }

    function freeBalance(address token) public view returns (uint256) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (token == notStock) return bal;
        return bal - topUpBasket[token] - buybackBasket[token];
    }

    function positionCount() external view returns (uint256) {
        return _positions.length;
    }

    function getPosition(uint256 id) external view returns (Position memory) {
        return _positions[id];
    }

    function positions() external view returns (Position[] memory) {
        return _positions;
    }

    /// @notice Current liquidity of a position as its venue reports it.
    function positionLiquidity(uint256 id) external view returns (uint128) {
        Position storage p = _positions[id];
        return IVenueModule(_moduleFor(p.kind)).liquidityOf(_ref(p));
    }

    // ---------------------------------------------------------------- operator: positions

    /// @notice Direct open during the bootstrap window only.
    function open(OpenParams calldata p) external onlyOperator returns (uint256 id) {
        uint256 end = bootstrapEnd();
        if (end == 0) revert NotRegistered();
        if (block.timestamp >= end) revert BootstrapOver();
        id = _open(p, false);
    }

    function openFromGovernor(OpenParams calldata p) external onlyGovernor returns (uint256 id) {
        id = _open(p, true);
    }

    /// @notice Collects the position's fees and splits them (SPEC.md section 2 collected fees).
    function collect(uint256 id) external onlyOperator {
        _collect(id);
    }

    /// @notice Collects and splits fees, withdraws everything (at least min0/min1) to the free balance, closes the record.
    function close(uint256 id, uint256 min0, uint256 min1) external onlyOperator {
        Position storage p = _positions[id];
        if (!p.open) revert PositionNotOpen();
        _collect(id);
        IVenueModule m = IVenueModule(_moduleFor(p.kind));
        uint128 liquidity = m.liquidityOf(_ref(p));
        uint256 a0;
        uint256 a1;
        if (liquidity > 0) (a0, a1) = m.decrease(_ref(p), liquidity, min0, min1);
        p.open = false;
        emit PositionClosed(id, a0, a1);
    }

    /// @notice Collects and splits fees, withdraws the whole position (at least min0/min1) and re-deposits it in
    /// [newLower, newUpper] of the same pool at the pool's current price; leftovers stay free.
    function shiftRange(uint256 id, int24 newLower, int24 newUpper, uint256 min0, uint256 min1) external onlyOperator {
        Position storage p = _positions[id];
        if (!p.open) revert PositionNotOpen();
        _collect(id);
        IVenueModule m = IVenueModule(_moduleFor(p.kind));
        uint128 liquidity = m.liquidityOf(_ref(p));
        (uint256 a0, uint256 a1) = m.decrease(_ref(p), liquidity, min0, min1);
        (bool exists, uint160 sqrtP,) = m.poolPrice(_ref(p));
        if (!exists) revert PriceMoved();
        p.tickLower = newLower;
        p.tickUpper = newUpper;
        _send(p.notStockIs0 ? notStock : p.asset, address(m), a0);
        _send(p.notStockIs0 ? p.asset : notStock, address(m), a1);
        (uint256 tokenId,,,) = m.mint(_ref(p), sqrtP, a0, a1);
        p.tokenId = tokenId;
        emit PositionChanged(id, tokenId, newLower, newUpper);
    }

    /// @notice Moves `liquidity` from one open position into another of the same pair: fees of the source are collected
    /// and split first, the withdrawn principal (at least min0/min1) is added to the destination; leftovers stay free.
    function moveLiquidity(uint256 fromId, uint256 toId, uint128 liquidity, uint256 min0, uint256 min1)
        external
        onlyOperator
    {
        Position storage a = _positions[fromId];
        Position storage b = _positions[toId];
        if (!a.open || !b.open) revert PositionNotOpen();
        if (a.asset != b.asset) revert PairMismatch();
        _collect(fromId);
        IVenueModule ma = IVenueModule(_moduleFor(a.kind));
        // the collect's 1-wei poke (V3/CL) leaves L-1: a request for the published figure moves the whole position
        uint128 have = ma.liquidityOf(_ref(a));
        if (liquidity > have) liquidity = have;
        (uint256 a0, uint256 a1) = ma.decrease(_ref(a), liquidity, min0, min1);
        // the destination's pending fees are collected and split first: v4 nets them against an increase otherwise
        if (toId != fromId) _collect(toId);
        IVenueModule mb = IVenueModule(_moduleFor(b.kind));
        _send(b.notStockIs0 ? notStock : b.asset, address(mb), a0);
        _send(b.notStockIs0 ? b.asset : notStock, address(mb), a1);
        (uint128 added,,) = mb.increase(_ref(b), a0, a1);
        emit ToppedUp(toId, 0, added);
    }

    /// @notice Adds up to `amount` of the position's asset from its top-up basket, never NOTSTOCK. The position's
    /// pending fees are collected and split first, so the top-up pays for all it adds (v4 would net them otherwise).
    function increaseLiquidity(uint256 id, uint256 amount, uint160 sqrtPriceX96, uint128 minLiquidity)
        external
        onlyOperator
    {
        Position storage p = _positions[id];
        if (!p.open) revert PositionNotOpen();
        _collect(id);
        if (amount > topUpBasket[p.asset]) revert AboveBasket();
        IVenueModule m = IVenueModule(_moduleFor(p.kind));
        (bool exists, uint160 sqrtP,) = m.poolPrice(_ref(p));
        if (!exists || !PoolMath.within0_5Percent(sqrtP, sqrtPriceX96)) revert PriceMoved();
        uint160 sa = PoolMath.getSqrtRatioAtTick(p.tickLower);
        uint160 sb = PoolMath.getSqrtRatioAtTick(p.tickUpper);
        uint128 expected = p.notStockIs0
            ? PoolMath.liquidityFromAmount1(sqrtPriceX96, sa, sb, amount)
            : PoolMath.liquidityFromAmount0(sqrtPriceX96, sa, sb, amount);
        if (expected == 0) revert NeedsNotStock();
        (uint256 n0, uint256 n1) = PoolMath.getAmountsForLiquidity(sqrtPriceX96, sa, sb, expected);
        if ((p.notStockIs0 ? n0 : n1) != 0) revert NeedsNotStock();
        if (minLiquidity < uint256(expected) * 995 / 1000) revert BelowMinimum();
        _send(p.asset, address(m), amount);
        (uint128 added, uint256 u0, uint256 u1) =
            m.increase(_ref(p), p.notStockIs0 ? 0 : amount, p.notStockIs0 ? amount : 0);
        if (added < minLiquidity) revert BelowMinimum();
        if ((p.notStockIs0 ? u0 : u1) != 0) revert NeedsNotStock();
        uint256 used = p.notStockIs0 ? u1 : u0;
        topUpBasket[p.asset] -= used;
        emit ToppedUp(id, used, added);
    }

    /// @notice Swaps `amount` of the position's asset from its buyback basket for NOTSTOCK in the position's own pool;
    /// all NOTSTOCK out goes to the dead address. IMD buybacks belong to FirmVault. When the pool's liquidity runs out
    /// before the whole amount is taken, the basket is debited only by what was swapped and the rest stays in it.
    function buyback(uint256 id, uint256 amount, uint256 minOut) external onlyOperator returns (uint256 out) {
        Position storage p = _positions[id];
        if (p.asset == IMD) revert ImdNotBuyable();
        if (amount > buybackBasket[p.asset]) revert AboveBasket();
        IVenueModule m = IVenueModule(_moduleFor(p.kind));
        uint256 before = IERC20(p.asset).balanceOf(address(this));
        _send(p.asset, address(m), amount);
        out = m.swapExactInToDead(_ref(p), p.asset, amount);
        // what the pool took is LpDesk's own balance change: the module returned the rest in the same call
        uint256 spent = before - IERC20(p.asset).balanceOf(address(this));
        if (spent > amount) revert BuybackMismatch();
        buybackBasket[p.asset] -= spent;
        if (out < minOut) revert BelowMinOut();
        emit BuybackExecuted(id, spent, out);
    }

    /// @notice Sends `amount` of free NOTSTOCK to the dead address.
    function burn(uint256 amount) external onlyOperator {
        if (amount > freeBalance(notStock)) revert AboveFreeBalance();
        _send(notStock, DEAD, amount);
        emit Burned(amount);
    }

    function setOperator(address newOperator) external onlyOperator {
        if (newOperator == address(0)) revert ZeroAddress();
        emit OperatorChanged(operator, newOperator);
        operator = newOperator;
    }

    // ---------------------------------------------------------------- FirmVault and governance entries

    function creditFromFirmVault(uint256 topUpAmount, uint256 freeAmount) external {
        if (msg.sender != firmVault()) revert NotFirmVault();
        topUpBasket[IMD] += topUpAmount;
        if (IERC20(IMD).balanceOf(address(this)) < topUpBasket[IMD] + buybackBasket[IMD]) revert AboveBasket();
        emit VaultCredit(topUpAmount, freeAmount);
    }

    function addAssetFromGovernor(address asset) external onlyGovernor {
        _guard().addAsset(asset);
    }

    function addVenueFromGovernor(address positionManager, VenueKind kind) external onlyGovernor {
        _guard().addVenue(positionManager, kind);
    }

    /// @notice Executed BridgeOut: exactly `amount` of free NOTSTOCK through the adapter to the recorded destination
    /// LpDesk, the native fee paid by the executor, approval reset to 0. The NOTSTOCK must land in the adapter
    /// (an OFT adapter locks it there); anything else reverts (audit finding 4cd6b95d).
    function bridgeOutFromGovernor(address adapter, uint32 dstEid, address dstLpDesk, uint256 amount, address refund)
        external
        payable
        onlyGovernor
    {
        if (amount > freeBalance(notStock)) revert AboveFreeBalance();
        uint256 before = IERC20(notStock).balanceOf(address(this));
        uint256 adapterBefore = IERC20(notStock).balanceOf(adapter);
        require(IERC20(notStock).approve(adapter, amount));
        IOFTAdapter(adapter).send{value: msg.value}(
            IOFTAdapter.SendParam({
                dstEid: dstEid,
                to: bytes32(uint256(uint160(dstLpDesk))),
                amountLD: amount,
                minAmountLD: amount,
                extraOptions: "",
                composeMsg: "",
                oftCmd: ""
            }),
            IOFTAdapter.MessagingFee({nativeFee: msg.value, lzTokenFee: 0}),
            refund
        );
        require(IERC20(notStock).approve(adapter, 0));
        if (before - IERC20(notStock).balanceOf(address(this)) != amount) revert BridgeMismatch();
        if (IERC20(notStock).balanceOf(adapter) - adapterBefore != amount) revert BridgeMismatch();
        emit BridgedOut(adapter, dstEid, dstLpDesk, amount);
    }

    // ---------------------------------------------------------------- internals

    function _open(OpenParams calldata p, bool fromGovernor) private returns (uint256 id) {
        IPriceGuard guard = _guard();
        if (!guard.isAsset(p.asset)) revert UnlistedAsset();
        (Venue memory v, bool listed) = guard.venueOf(p.venue);
        if (!listed) revert UnlistedVenue();
        IVenueModule m = IVenueModule(_moduleFor(v.kind));
        Position memory pos;
        pos.positionManager = p.venue;
        pos.kind = v.kind;
        pos.asset = p.asset;
        pos.notStockIs0 = notStock < p.asset;
        pos.fee = p.feeTier;
        pos.tickSpacing = p.tickSpacing;
        pos.tickLower = p.tickLower;
        pos.tickUpper = p.tickUpper;
        pos.open = true;
        PosRef memory r = _refMem(pos);

        (bool exists, uint160 sqrtP,) = m.poolPrice(r);
        if (exists && !PoolMath.within0_5Percent(sqrtP, p.sqrtPriceX96)) revert PriceMoved();

        (uint256 amt0, uint256 amt1) = _amountsAt(p, pos.notStockIs0);
        uint256 min0 = p.amount0Min;
        uint256 min1 = p.amount1Min;
        if (fromGovernor) {
            min0 = amt0 * 995 / 1000;
            min1 = amt1 * 995 / 1000;
        } else if (min0 < amt0 * 995 / 1000 || min1 < amt1 * 995 / 1000) {
            revert BelowMinimum();
        }
        address t0 = pos.notStockIs0 ? notStock : p.asset;
        address t1 = pos.notStockIs0 ? p.asset : notStock;
        if (amt0 > freeBalance(t0) || amt1 > freeBalance(t1)) revert AboveFreeBalance();

        _approveNft(p.venue, address(m));
        _send(t0, address(m), amt0);
        _send(t1, address(m), amt1);
        (uint256 tokenId, uint128 liquidity, uint256 used0, uint256 used1) = m.mint(r, p.sqrtPriceX96, amt0, amt1);
        if (used0 < min0 || used1 < min1) revert BelowMinimum();
        pos.tokenId = tokenId;
        id = _positions.length;
        _positions.push(pos);
        emit PositionOpened(id, p.venue, p.asset, tokenId, liquidity);
    }

    /// @dev The amounts the range takes at the given price for `amount` of NOTSTOCK (or of the asset when the range
    /// takes no NOTSTOCK), rounded up as the pool rounds.
    function _amountsAt(OpenParams calldata p, bool notStockIs0) private pure returns (uint256 amt0, uint256 amt1) {
        uint160 sa = PoolMath.getSqrtRatioAtTick(p.tickLower);
        uint160 sb = PoolMath.getSqrtRatioAtTick(p.tickUpper);
        uint128 liquidity = notStockIs0
            ? PoolMath.liquidityFromAmount0(p.sqrtPriceX96, sa, sb, p.amount)
            : PoolMath.liquidityFromAmount1(p.sqrtPriceX96, sa, sb, p.amount);
        if (liquidity == 0) {
            liquidity = notStockIs0
                ? PoolMath.liquidityFromAmount1(p.sqrtPriceX96, sa, sb, p.amount)
                : PoolMath.liquidityFromAmount0(p.sqrtPriceX96, sa, sb, p.amount);
        }
        if (liquidity == 0) revert BelowMinimum();
        (amt0, amt1) = PoolMath.getAmountsForLiquidity(p.sqrtPriceX96, sa, sb, liquidity);
    }

    function _collect(uint256 id) private {
        Position storage p = _positions[id];
        if (!p.open) revert PositionNotOpen();
        (uint256 f0, uint256 f1) = IVenueModule(_moduleFor(p.kind)).collectFees(_ref(p));
        _split(id, p.notStockIs0 ? notStock : p.asset, f0);
        _split(id, p.notStockIs0 ? p.asset : notStock, f1);
    }

    /// @dev Collected fees: NOTSTOCK 100% to Burner; any other token 25% buyback (IMD to FirmVault's bucket), 25%
    /// project wallet, 25% top-up basket, and the rest stays as free balance.
    function _split(uint256 id, address token, uint256 amount) private {
        if (amount == 0) return;
        if (token == notStock) {
            _send(token, burner, amount);
        } else {
            uint256 q = amount / 4;
            if (token == IMD) {
                address vault = firmVault();
                _send(token, vault, q);
                IFirmVault(vault).creditBuyback(q);
            } else {
                buybackBasket[token] += q;
            }
            _send(token, projectWallet, q);
            topUpBasket[token] += q;
        }
        emit FeesSplit(id, token, amount);
    }

    function _approveNft(address positionManager, address module) private {
        if (_nftApproved[positionManager][module]) return;
        _nftApproved[positionManager][module] = true;
        (bool ok,) = positionManager.call(abi.encodeWithSignature("setApprovalForAll(address,bool)", module, true));
        if (!ok) revert UnlistedVenue();
    }

    function _guard() private view returns (IPriceGuard) {
        if (priceGuard.code.length == 0) revert ModuleMissing();
        return IPriceGuard(priceGuard);
    }

    function _moduleFor(VenueKind kind) private view returns (address m) {
        m = kind == VenueKind.V4 ? venueV4 : venueV3;
        if (m.code.length == 0) revert ModuleMissing();
    }

    function _ref(Position storage p) private view returns (PosRef memory) {
        return _refMem(p);
    }

    function _refMem(Position memory p) private view returns (PosRef memory r) {
        r.positionManager = p.positionManager;
        r.kind = p.kind;
        r.token0 = p.notStockIs0 ? notStock : p.asset;
        r.token1 = p.notStockIs0 ? p.asset : notStock;
        r.fee = p.fee;
        r.tickSpacing = p.tickSpacing;
        r.tickLower = p.tickLower;
        r.tickUpper = p.tickUpper;
        r.tokenId = p.tokenId;
    }

    function _send(address token, address to, uint256 amount) private {
        if (amount > 0) require(IERC20(token).transfer(to, amount));
    }

    function _predict(ModuleKind kind, bytes32 codeHash) private view returns (address) {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(uint256(kind)), codeHash))))
        );
    }
}
