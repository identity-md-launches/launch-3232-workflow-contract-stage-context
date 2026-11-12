// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "./vendor/forge-std/src/Test.sol";
import {MockERC20, MockFactory} from "./Mocks.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LpDesk} from "../src/LpDesk.sol";
import {FirmVault} from "../src/FirmVault.sol";
import {GenesisSplitter} from "../src/GenesisSplitter.sol";
import {Burner} from "../src/Burner.sol";
import {LpGovernor} from "../src/modules/LpGovernor.sol";
import {PriceGuard} from "../src/modules/PriceGuard.sol";
import {VenueV3} from "../src/modules/VenueV3.sol";
import {VenueV4} from "../src/modules/VenueV4.sol";
import {FirmAddresses} from "../src/FirmAddresses.sol";
import {IERC20} from "../src/interfaces/IExternal.sol";

/// @notice Shared setup: a launch through the mock factory (the live factory's read surface), every module deployed,
/// the 600,000,000 transfer, setRequester, registerNotStock and split.
abstract contract TestBase is Test {
    address constant PROJECT = FirmAddresses.PROJECT_WALLET;
    address constant DEV = FirmAddresses.DEV_WALLET;
    address constant DEAD = FirmAddresses.DEAD;
    address constant IMD = FirmAddresses.IMD;
    address constant WETH = FirmAddresses.WETH;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    MockFactory factory;
    uint64 launchNumber;
    LaunchToken token;
    LpDesk desk;
    FirmVault vault;
    GenesisSplitter splitter;
    Burner burner;
    LpGovernor gov;
    PriceGuard guard;
    VenueV3 v3;
    VenueV4 v4;

    function _launch(address hook) internal {
        factory = new MockFactory(hook);
        (uint64 n, address t, address d, address v, address s) = factory.launch(PROJECT, 12500, IMD);
        launchNumber = n;
        token = LaunchToken(t);
        desk = LpDesk(d);
        vault = FirmVault(v);
        splitter = GenesisSplitter(s);
        burner = Burner(desk.burner());
    }

    function _deployModules() internal {
        gov = LpGovernor(desk.deployModule(LpDesk.ModuleKind.LpGovernor, type(LpGovernor).creationCode));
        guard = PriceGuard(desk.deployModule(LpDesk.ModuleKind.PriceGuard, type(PriceGuard).creationCode));
        v3 = VenueV3(desk.deployModule(LpDesk.ModuleKind.VenueV3, type(VenueV3).creationCode));
        v4 = VenueV4(desk.deployModule(LpDesk.ModuleKind.VenueV4, type(VenueV4).creationCode));
    }

    function _fundAndRegister() internal {
        vm.startPrank(PROJECT);
        token.transfer(address(splitter), 600_000_000e18);
        factory.setRequester(launchNumber, address(vault));
        vm.stopPrank();
        guard.registerNotStock(launchNumber);
    }

    function _fullSetup(address hook) internal {
        _launch(hook);
        _deployModules();
        _fundAndRegister();
        splitter.split();
    }

    /// @dev Unit tests have no IMD at its fixed address: put a plain ERC-20 there.
    function _etchImd() internal {
        if (IMD.code.length == 0) {
            MockERC20 m = new MockERC20("Identity.md", "IMD", 18);
            vm.etch(IMD, address(m).code);
        }
    }

    function _give(address erc20, address to, uint256 amount) internal {
        if (block.chainid == 4663) deal(erc20, to, IERC20(erc20).balanceOf(to) + amount);
        else MockERC20(erc20).mint(to, amount);
    }
}
