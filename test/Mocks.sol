// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    IERC20,
    LaunchPosition,
    Artifact,
    PoolKey,
    IOFTAdapter,
    INonfungiblePositionManager
} from "../src/interfaces/IExternal.sol";
import {PoolMath} from "../src/libraries/PoolMath.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LpDesk} from "../src/LpDesk.sol";
import {FirmVault} from "../src/FirmVault.sol";
import {GenesisSplitter} from "../src/GenesisSplitter.sol";
import {FirmAddresses} from "../src/FirmAddresses.sol";

/// @notice Plain ERC-20 standing in for IMD / WETH in unit tests.
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockLaunchFees {
    uint24 public poolFee = 12500;

    function setPoolFee(uint24 f) external {
        poolFee = f;
    }
}

contract MockRegistry {
    mapping(uint64 => Artifact[]) private _arts;

    function add(uint64 n, bytes32 kind, bytes32 name, address addr) external {
        _arts[n].push(Artifact({kind: kind, name: name, addr: addr}));
    }

    function artifactsOf(uint64 n) external view returns (Artifact[] memory) {
        return _arts[n];
    }
}

/// @notice Mirrors the live ProjectFactory's surface this launch reads: deploys the token and the three contracts in one
/// call (as launch() does), records positionOf and the registry artifacts, and lets the requester change the fee recipient.
contract MockFactory {
    MockLaunchFees public immutable feesContract = new MockLaunchFees();
    MockRegistry public immutable registryContract = new MockRegistry();
    address public poolHookAddr;
    address public immutable deployer = msg.sender;
    mapping(uint64 => LaunchPosition) private _pos;
    uint64 public nextLaunch = 1;

    error NotRequester();

    constructor(address hook) {
        poolHookAddr = hook;
    }

    function fees() external view returns (address) {
        return address(feesContract);
    }

    function registry() external view returns (address) {
        return address(registryContract);
    }

    function poolHook() external view returns (address) {
        return poolHookAddr;
    }

    function setPoolHook(address h) external {
        poolHookAddr = h;
    }

    function positionOf(uint64 n) external view returns (LaunchPosition memory) {
        return _pos[n];
    }

    function setRequester(uint64 n, address requester) external {
        if (msg.sender != _pos[n].requester) revert NotRequester();
        _pos[n].requester = requester;
    }

    /// @dev The launch: token, LpDesk (with Burner), FirmVault, GenesisSplitter; supply split 10% swarm (held here as
    /// the distributor stand-in), 30% pool stand-in (kept here), 60% to the requester.
    function launch(address requester, uint24 fee, address pairedCurrency)
        external
        returns (uint64 n, address token, address desk, address vault, address splitter)
    {
        n = nextLaunch++;
        LaunchToken t = new LaunchToken();
        token = address(t);
        LpDesk d = new LpDesk(token, FirmAddresses.DEV_WALLET, requester);
        desk = address(d);
        vault = address(new FirmVault(requester, desk));
        splitter = address(new GenesisSplitter(desk, FirmAddresses.DEV_WALLET));
        (address c0, address c1) = token < pairedCurrency ? (token, pairedCurrency) : (pairedCurrency, token);
        _pos[n] = LaunchPosition({
            key: PoolKey({currency0: c0, currency1: c1, fee: fee, tickSpacing: 60, hooks: poolHookAddr}),
            tickLower: -887220,
            tickUpper: 887220,
            requester: requester
        });
        registryContract.add(n, "token", "LaunchToken", token);
        registryContract.add(n, "contract", "LpDesk", desk);
        registryContract.add(n, "contract", "FirmVault", vault);
        registryContract.add(n, "contract", "GenesisSplitter", splitter);
        require(t.transfer(requester, 600_000_000e18));
    }

    /// @dev Test helper standing in for the factory's pool seeding: moves the 30% pool share to `to`.
    function releasePoolShare(address token, address to) external {
        require(IERC20(token).transfer(to, 300_000_000e18));
    }
}

/// @notice An OFT adapter that locks the token in itself, as LayerZero's OFTAdapter does.
contract MockOFTAdapter is IOFTAdapter {
    address public immutable token;
    SendParam public last;

    constructor(address t) {
        token = t;
    }

    function send(SendParam calldata p, MessagingFee calldata, address) external payable {
        require(IERC20(token).transferFrom(msg.sender, address(this), p.amountLD));
        last = p;
    }
}

/// @notice The attacker adapter of audit finding 4cd6b95d: token() lies right, send() steals.
contract EvilAdapter is IOFTAdapter {
    address public immutable token;
    address public immutable thief;

    constructor(address t, address thief_) {
        token = t;
        thief = thief_;
    }

    function send(SendParam calldata p, MessagingFee calldata, address) external payable {
        require(IERC20(token).transferFrom(msg.sender, thief, p.amountLD));
    }
}

/// @notice A contract pretending to be a V3 position manager (audit finding 4cd6b95d, AddVenue).
contract FakeVenue {
    address public immutable factory;
    address public immutable WETH9;

    constructor(address f, address w) {
        factory = f;
        WETH9 = w;
    }
}

interface IV3SwapCallbackLike {
    function uniswapV3SwapCallback(int256, int256, bytes calldata) external;
}

/// @notice A V3-shaped pool whose in-range liquidity runs out: like UniswapV3Pool.swap it stops at the price limit
/// with input left over, consuming only 60% of an exact input, and asks the callback to pay only what it consumed
/// (finding cfbdc8d3). Its price is fixed at 1:1.
contract ThinPool {
    address public token0;
    address public token1;

    constructor(address t0, address t1) {
        token0 = t0;
        token1 = t1;
    }

    function slot0() external pure returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (79228162514264337593543950336, 0, 0, 0, 0, 0, true);
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        int256 consumed = amountSpecified * 6 / 10;
        int256 out = -consumed / 2;
        (amount0, amount1) = zeroForOne ? (consumed, out) : (out, consumed);
        address tokenIn = zeroForOne ? token0 : token1;
        address tokenOut = zeroForOne ? token1 : token0;
        uint256 before = IERC20(tokenIn).balanceOf(address(this));
        IERC20(tokenOut).transfer(recipient, uint256(-out));
        IV3SwapCallbackLike(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        require(IERC20(tokenIn).balanceOf(address(this)) - before >= uint256(consumed), "unpaid");
    }
}

/// @notice A V3-shaped position manager and factory in one, with one ThinPool, carrying enough of the v3 surface for
/// LpDesk to open, poke, collect, top up, move and buy back offline. Meant to be etched at a listed venue address and
/// then init()ed. Liquidity is PoolMath's at 1:1 for the deposited amounts; principal is returned pro rata.
contract MockV3Manager {
    struct Pos {
        address token0;
        address token1;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 principal0;
        uint256 principal1;
        uint256 owed0;
        uint256 owed1;
    }

    uint160 constant ONE = 79228162514264337593543950336;
    address public pool;
    uint256 public nextId;
    mapping(uint256 => Pos) public pos;

    function init(address p) external {
        pool = p;
        nextId = 1;
    }

    function factory() external view returns (address) {
        return address(this);
    }

    function WETH9() external pure returns (address) {
        return FirmAddresses.WETH;
    }

    function getPool(address, address, uint24) external view returns (address) {
        return pool;
    }

    function feeAmountTickSpacing(uint24) external pure returns (int24) {
        return 60;
    }

    function setApprovalForAll(address, bool) external {}

    function createAndInitializePoolIfNecessary(address, address, uint24, uint160) external view returns (address) {
        return pool;
    }

    /// @dev Test helper: books `f0`/`f1` as fees owed to the position (the tokens must be sent here first).
    function addFees(uint256 tokenId, uint256 f0, uint256 f1) external {
        pos[tokenId].owed0 += f0;
        pos[tokenId].owed1 += f1;
    }

    function _liq(int24 lo, int24 hi, uint256 a0, uint256 a1) private pure returns (uint128) {
        uint160 sa = PoolMath.getSqrtRatioAtTick(lo);
        uint160 sb = PoolMath.getSqrtRatioAtTick(hi);
        return PoolMath.liquidityFromAmount0(ONE, sa, sb, a0) + PoolMath.liquidityFromAmount1(ONE, sa, sb, a1);
    }

    function mint(INonfungiblePositionManager.MintParams calldata p)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 a0, uint256 a1)
    {
        tokenId = nextId++;
        a0 = p.amount0Desired;
        a1 = p.amount1Desired;
        if (a0 > 0) require(IERC20(p.token0).transferFrom(msg.sender, address(this), a0));
        if (a1 > 0) require(IERC20(p.token1).transferFrom(msg.sender, address(this), a1));
        liquidity = _liq(p.tickLower, p.tickUpper, a0, a1);
        pos[tokenId] = Pos(p.token0, p.token1, p.tickLower, p.tickUpper, liquidity, a0, a1, 0, 0);
    }

    function increaseLiquidity(INonfungiblePositionManager.IncreaseLiquidityParams calldata p)
        external
        returns (uint128 liquidity, uint256 a0, uint256 a1)
    {
        Pos storage s = pos[p.tokenId];
        a0 = p.amount0Desired;
        a1 = p.amount1Desired;
        if (a0 > 0) require(IERC20(s.token0).transferFrom(msg.sender, address(this), a0));
        if (a1 > 0) require(IERC20(s.token1).transferFrom(msg.sender, address(this), a1));
        liquidity = _liq(s.tickLower, s.tickUpper, a0, a1);
        s.liquidity += liquidity;
        s.principal0 += a0;
        s.principal1 += a1;
    }

    function decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams calldata p)
        external
        returns (uint256 a0, uint256 a1)
    {
        Pos storage s = pos[p.tokenId];
        require(s.liquidity >= p.liquidity, "liquidity");
        a0 = s.principal0 * p.liquidity / s.liquidity;
        a1 = s.principal1 * p.liquidity / s.liquidity;
        s.liquidity -= p.liquidity;
        s.principal0 -= a0;
        s.principal1 -= a1;
        s.owed0 += a0;
        s.owed1 += a1;
    }

    function collect(INonfungiblePositionManager.CollectParams calldata p) external returns (uint256 c0, uint256 c1) {
        Pos storage s = pos[p.tokenId];
        c0 = s.owed0;
        c1 = s.owed1;
        s.owed0 = 0;
        s.owed1 = 0;
        if (c0 > 0) require(IERC20(s.token0).transfer(p.recipient, c0));
        if (c1 > 0) require(IERC20(s.token1).transfer(p.recipient, c1));
    }

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96,
            address,
            address,
            address,
            uint24,
            int24,
            int24,
            uint128 liquidity,
            uint256,
            uint256,
            uint128,
            uint128
        )
    {
        liquidity = pos[tokenId].liquidity;
    }
}

/// @notice A contract posing as a v4 PoolManager (finding 55ef5a4b): calls VenueV4.unlockCallback directly.
contract FakePoolManager {
    function attack(address venue, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = venue.call(abi.encodeWithSignature("unlockCallback(bytes)", data));
        require(ok, string(ret));
        return ret;
    }
}
