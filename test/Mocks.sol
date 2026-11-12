// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20, LaunchPosition, Artifact, PoolKey, IOFTAdapter} from "../src/interfaces/IExternal.sol";
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
