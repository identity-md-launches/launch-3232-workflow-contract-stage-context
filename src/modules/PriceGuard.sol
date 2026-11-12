// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20, IProjectFactory, ILaunchRegistry, LaunchPosition, Artifact, PoolKey} from "../interfaces/IExternal.sol";
import {ILpDeskViews, IFirmVault, Venue, VenueKind} from "../interfaces/ILpDesk.sol";
import {FirmAddresses} from "../FirmAddresses.sol";

/// @notice LpDesk module (SPEC.md section 2b): the venue list, the asset list and NOTSTOCK registration.
/// Deployed by LpDesk.deployModule with CREATE2; no constructor argument; msg.sender is its LpDesk.
contract PriceGuard {
    address public immutable lpDesk;

    /// @notice The launch policy's pool fee (1.25%). Registration compares the pool with this constant and with the
    /// factory's poolHook(), never with the mutable LaunchFees.poolFee() (audit finding 6331aad7).
    uint24 public constant LAUNCH_POOL_FEE = 12500;
    uint256 public constant REGISTRATION_MIN_BALANCE = 600_000_000e18;
    address public constant WETH = FirmAddresses.WETH;

    Venue[] private _venues;
    mapping(address => uint256) private _venueIndex; // 1-based
    address[] private _assets;
    mapping(address => bool) public isAsset;

    bool public registered;
    uint256 public registeredAt;
    address public firmVault;
    uint64 public launchNumber;
    PoolKey private _poolKey;

    event VenueAdded(address indexed positionManager, VenueKind kind, address factory);
    event AssetAdded(address indexed asset);
    event NotStockRegistered(uint64 launchNumber, address firmVault, uint256 at);

    error NotLpDesk();
    error AlreadyRegistered();
    error WrongLaunchRecord();
    error WrongPool();
    error WrongToken();
    error SplitterUnderfunded();
    error WrongFeeRecipient();
    error ZeroAddress();
    error AlreadyListed();
    error NoCode();
    error NotAVenue();
    error NotStockIsNotAnAsset();

    constructor() {
        lpDesk = msg.sender;
        _pushVenue(FirmAddresses.UNI_V4_POSITION_MANAGER, VenueKind.V4, FirmAddresses.UNI_V4_POOL_MANAGER);
        _pushVenue(FirmAddresses.UNI_V3_POSITION_MANAGER, VenueKind.V3, FirmAddresses.UNI_V3_FACTORY);
        _pushVenue(FirmAddresses.AERO_CL_POSITION_MANAGER, VenueKind.CL, FirmAddresses.AERO_CL_FACTORY);
        _pushAsset(FirmAddresses.IMD);
        _pushAsset(FirmAddresses.WETH);
        _pushAsset(FirmAddresses.USDG);
        _pushAsset(FirmAddresses.CBBTC);
        _pushAsset(FirmAddresses.GOOGL);
        _pushAsset(FirmAddresses.SNDK);
        _pushAsset(FirmAddresses.NVDA);
        _pushAsset(FirmAddresses.META);
        _pushAsset(FirmAddresses.SPCX);
        _pushAsset(FirmAddresses.MSFT);
        _pushAsset(FirmAddresses.AAPL);
        _pushAsset(FirmAddresses.AMD);
        _pushAsset(FirmAddresses.PLTR);
    }

    // ---------------------------------------------------------------- views

    function venues() external view returns (Venue[] memory) {
        return _venues;
    }

    function assets() external view returns (address[] memory) {
        return _assets;
    }

    function venueOf(address positionManager) external view returns (Venue memory v, bool listed) {
        uint256 i = _venueIndex[positionManager];
        if (i == 0) return (v, false);
        return (_venues[i - 1], true);
    }

    function poolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    /// @notice Reverts unless `asset` may be added: not zero, not NOTSTOCK, not listed.
    function checkAsset(address asset) public view {
        if (asset == address(0)) revert ZeroAddress();
        if (asset == ILpDeskViews(lpDesk).notStock()) revert NotStockIsNotAnAsset();
        if (isAsset[asset]) revert AlreadyListed();
    }

    /// @notice Reverts unless `positionManager` may be added as `kind` (SPEC.md 2b AddVenue). Returns its factory.
    function checkVenue(address positionManager, VenueKind kind) public view returns (address factory) {
        if (positionManager == address(0)) revert ZeroAddress();
        if (_venueIndex[positionManager] != 0) revert AlreadyListed();
        if (positionManager.code.length == 0) revert NoCode();
        if (kind == VenueKind.V4) {
            factory = _staticAddress(positionManager, abi.encodeWithSignature("poolManager()"));
            if (factory.code.length == 0) revert NotAVenue();
        } else {
            factory = _staticAddress(positionManager, abi.encodeWithSignature("factory()"));
            if (factory.code.length == 0) revert NotAVenue();
            if (_staticAddress(positionManager, abi.encodeWithSignature("WETH9()")) != WETH) revert NotAVenue();
        }
    }

    // ---------------------------------------------------------------- governance entries (via LpDesk)

    function addAsset(address asset) external {
        if (msg.sender != lpDesk) revert NotLpDesk();
        checkAsset(asset);
        _pushAsset(asset);
    }

    function addVenue(address positionManager, VenueKind kind) external {
        if (msg.sender != lpDesk) revert NotLpDesk();
        address factory = checkVenue(positionManager, kind);
        _pushVenue(positionManager, kind, factory);
    }

    // ---------------------------------------------------------------- registration

    /// @notice Registers this launch's NOTSTOCK/IMD pool from the launch factory's own record, once, by anyone.
    function registerNotStock(uint64 launchNumber_) external {
        if (registered) revert AlreadyRegistered();
        ILpDeskViews desk = ILpDeskViews(lpDesk);
        IProjectFactory factory = IProjectFactory(desk.launchFactory());
        address token = desk.notStock();

        LaunchPosition memory pos = factory.positionOf(launchNumber_);
        bool tokenIs0 = pos.key.currency0 == token && pos.key.currency1 == FirmAddresses.IMD;
        bool tokenIs1 = pos.key.currency1 == token && pos.key.currency0 == FirmAddresses.IMD;
        if (!(tokenIs0 || tokenIs1)) revert WrongPool();
        if (pos.key.fee != LAUNCH_POOL_FEE) revert WrongPool();
        if (pos.key.hooks != factory.poolHook()) revert WrongPool();

        IERC20 t = IERC20(token);
        if (keccak256(bytes(t.name())) != keccak256("Not Firm")) revert WrongToken();
        if (keccak256(bytes(t.symbol())) != keccak256("NOTSTOCK")) revert WrongToken();
        if (t.totalSupply() != 1_000_000_000e18) revert WrongToken();

        Artifact[] memory arts = ILaunchRegistry(factory.registry()).artifactsOf(launchNumber_);
        address deskArtifact;
        address splitter;
        for (uint256 i; i < arts.length; ++i) {
            if (arts[i].name == bytes32("LpDesk")) deskArtifact = arts[i].addr;
            else if (arts[i].name == bytes32("GenesisSplitter")) splitter = arts[i].addr;
        }
        if (deskArtifact != lpDesk || splitter == address(0)) revert WrongLaunchRecord();
        if (t.balanceOf(splitter) < REGISTRATION_MIN_BALANCE) revert SplitterUnderfunded();

        address recipient = pos.requester;
        if (recipient.code.length == 0) revert WrongFeeRecipient();
        if (IFirmVault(recipient).lpDesk() != lpDesk) revert WrongFeeRecipient();

        registered = true;
        registeredAt = block.timestamp;
        firmVault = recipient;
        launchNumber = launchNumber_;
        _poolKey = pos.key;
        emit NotStockRegistered(launchNumber_, recipient, block.timestamp);
    }

    // ---------------------------------------------------------------- internals

    function _pushVenue(address pm, VenueKind kind, address factory) private {
        _venues.push(Venue({positionManager: pm, kind: kind, factory: factory}));
        _venueIndex[pm] = _venues.length;
        emit VenueAdded(pm, kind, factory);
    }

    function _pushAsset(address asset) private {
        _assets.push(asset);
        isAsset[asset] = true;
        emit AssetAdded(asset);
    }

    function _staticAddress(address target, bytes memory data) private view returns (address out) {
        (bool ok, bytes memory ret) = target.staticcall(data);
        if (!ok || ret.length < 32) revert NotAVenue();
        out = abi.decode(ret, (address));
    }
}
