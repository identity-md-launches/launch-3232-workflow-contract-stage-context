// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "../test/vendor/forge-std/src/Script.sol";
import {LpDesk} from "../src/LpDesk.sol";
import {LpGovernor} from "../src/modules/LpGovernor.sol";
import {PriceGuard} from "../src/modules/PriceGuard.sol";
import {VenueV3} from "../src/modules/VenueV3.sol";
import {VenueV4} from "../src/modules/VenueV4.sol";

/// @notice Deploys every LpDesk module after the launch: deployModule(kind, creationCode) for LpGovernor, PriceGuard,
/// VenueV3 and VenueV4, skipping the ones already deployed. Anyone may run it; the modules land at the addresses LpDesk
/// predicted at launch. Verification input per module: the source file under src/modules/, compiler 0.8.26, the
/// foundry.toml settings (via_ir, optimizer runs 1, evm cancun, bytecode_hash none), no constructor arguments.
contract DeployModules is Script {
    /// @dev The launch's LpDesk address: pass it as LP_DESK in the environment when broadcasting.
    function run() external {
        address lpDesk = vm.envAddress("LP_DESK");
        vm.startBroadcast();
        deployAll(LpDesk(lpDesk));
        vm.stopBroadcast();
    }

    function deployAll(LpDesk desk) public returns (address[4] memory modules) {
        modules[0] = _deploy(desk, LpDesk.ModuleKind.LpGovernor, type(LpGovernor).creationCode);
        modules[1] = _deploy(desk, LpDesk.ModuleKind.PriceGuard, type(PriceGuard).creationCode);
        modules[2] = _deploy(desk, LpDesk.ModuleKind.VenueV3, type(VenueV3).creationCode);
        modules[3] = _deploy(desk, LpDesk.ModuleKind.VenueV4, type(VenueV4).creationCode);
    }

    function _deploy(LpDesk desk, LpDesk.ModuleKind kind, bytes memory code) private returns (address module) {
        module = desk.moduleAddress(kind);
        if (module.code.length == 0) desk.deployModule(kind, code);
    }
}
