// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "./TestBase.sol";
import {MockERC20, FakeVenue} from "./Mocks.sol";
import {IERC20, IPoolManager, PoolKey} from "../src/interfaces/IExternal.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LpDesk} from "../src/LpDesk.sol";
import {FirmVault} from "../src/FirmVault.sol";
import {GenesisSplitter} from "../src/GenesisSplitter.sol";
import {Burner} from "../src/Burner.sol";
import {LpGovernor} from "../src/modules/LpGovernor.sol";
import {PriceGuard} from "../src/modules/PriceGuard.sol";
import {PoolMath} from "../src/libraries/PoolMath.sol";
import {OpenParams, VenueKind} from "../src/interfaces/ILpDesk.sol";
import {FirmAddresses} from "../src/FirmAddresses.sol";

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/// @notice Stand-in for the v4 PoolManager at its fixed address: unlock -> callback, an exact-input swap at a set
/// rate, and sync/settle/take that must leave every delta at zero when unlock returns (as the real one requires).
contract MockPoolManager {
    uint256 public rate; // NOTSTOCK out per 1e18 IMD in
    address public inToken;
    address public outToken;
    uint256 public owedIn;
    uint256 public owedOut;
    address public synced;
    uint256 public syncedBal;
    bool public unlocked;

    function setRate(uint256 r) external {
        rate = r;
    }

    function unlock(bytes calldata data) external returns (bytes memory r) {
        unlocked = true;
        r = IUnlockCallback(msg.sender).unlockCallback(data);
        require(owedIn == 0 && owedOut == 0, "CurrencyNotSettled");
        unlocked = false;
    }

    function swap(PoolKey memory key, IPoolManager.SwapParams memory p, bytes calldata) external returns (int256) {
        require(unlocked, "locked");
        require(p.amountSpecified < 0, "exact input only");
        uint256 amtIn = uint256(-p.amountSpecified);
        uint256 out = amtIn * rate / 1e18;
        inToken = p.zeroForOne ? key.currency0 : key.currency1;
        outToken = p.zeroForOne ? key.currency1 : key.currency0;
        owedIn += amtIn;
        owedOut += out;
        int128 a0 = p.zeroForOne ? -int128(int256(amtIn)) : int128(int256(out));
        int128 a1 = p.zeroForOne ? int128(int256(out)) : -int128(int256(amtIn));
        return (int256(a0) << 128) | int256(uint256(uint128(a1)));
    }

    function sync(address c) external {
        synced = c;
        syncedBal = IERC20(c).balanceOf(address(this));
    }

    function settle() external payable returns (uint256 paid) {
        require(synced == inToken, "wrong settle");
        paid = IERC20(synced).balanceOf(address(this)) - syncedBal;
        owedIn -= paid;
    }

    function take(address c, address to, uint256 amount) external {
        require(c == outToken, "wrong take");
        owedOut -= amount;
        require(IERC20(c).transfer(to, amount));
    }
}

/// @dev External wrapper so reverts of internal library code can be expected.
contract PoolMathHarness {
    function sqrtAt(int24 t) external pure returns (uint160) {
        return PoolMath.getSqrtRatioAtTick(t);
    }

    function mulDiv(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return PoolMath.mulDiv(x, y, d);
    }

    function toUint128(uint256 x) external pure returns (uint128) {
        return PoolMath.toUint128(x);
    }
}

// =====================================================================================================================
// LaunchToken
// =====================================================================================================================

contract LaunchTokenEdgeTest is TestBase {
    LaunchToken t;

    function setUp() public {
        t = new LaunchToken();
    }

    function test_constantsAndMintToDeployer() public view {
        assertEq(t.name(), "Not Firm");
        assertEq(t.symbol(), "NOTSTOCK");
        assertEq(t.decimals(), 18);
        assertEq(t.totalSupply(), 1_000_000_000e18);
        assertEq(t.balanceOf(address(this)), 1_000_000_000e18);
    }

    function test_transferToZeroReverts() public {
        vm.expectRevert(LaunchToken.ZeroAddress.selector);
        t.transfer(address(0), 1);
        t.approve(alice, 10);
        vm.prank(alice);
        vm.expectRevert(LaunchToken.ZeroAddress.selector);
        t.transferFrom(address(this), address(0), 1);
    }

    function test_transferAboveBalanceReverts() public {
        vm.prank(alice);
        vm.expectRevert(LaunchToken.InsufficientBalance.selector);
        t.transfer(bob, 1);
        vm.expectRevert(LaunchToken.InsufficientBalance.selector);
        t.transfer(bob, 1_000_000_000e18 + 1);
    }

    function test_transferFromAllowanceEdges() public {
        // no allowance
        vm.prank(alice);
        vm.expectRevert(LaunchToken.InsufficientAllowance.selector);
        t.transferFrom(address(this), bob, 1);
        // allowance one short
        t.approve(alice, 99);
        vm.prank(alice);
        vm.expectRevert(LaunchToken.InsufficientAllowance.selector);
        t.transferFrom(address(this), bob, 100);
        // exact allowance is consumed to zero
        t.approve(alice, 100);
        vm.prank(alice);
        t.transferFrom(address(this), bob, 100);
        assertEq(t.allowance(address(this), alice), 0);
        assertEq(t.balanceOf(bob), 100);
        // allowance enough but balance not
        vm.prank(bob);
        t.approve(alice, type(uint256).max - 1);
        vm.prank(alice);
        vm.expectRevert(LaunchToken.InsufficientBalance.selector);
        t.transferFrom(bob, alice, 101);
        // infinite allowance is never decremented
        t.approve(alice, type(uint256).max);
        vm.prank(alice);
        t.transferFrom(address(this), bob, 5);
        assertEq(t.allowance(address(this), alice), type(uint256).max);
    }

    function test_selfTransferKeepsBalance() public {
        t.transfer(address(this), 123);
        assertEq(t.balanceOf(address(this)), 1_000_000_000e18);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_transferConserves(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != address(this));
        amount = bound(amount, 0, 1_000_000_000e18);
        t.transfer(to, amount);
        assertEq(t.balanceOf(to) + t.balanceOf(address(this)), 1_000_000_000e18);
        assertEq(t.totalSupply(), 1_000_000_000e18);
    }
}

// =====================================================================================================================
// LpDesk before and around registration
// =====================================================================================================================

contract LpDeskPreRegistrationTest is TestBase {
    function setUp() public {
        _etchImd();
        _launch(address(0));
    }

    function test_constructorRejectsZeroArguments() public {
        vm.expectRevert(LpDesk.ZeroAddress.selector);
        new LpDesk(address(0), DEV, PROJECT);
        vm.expectRevert(LpDesk.ZeroAddress.selector);
        new LpDesk(address(token), address(0), PROJECT);
        vm.expectRevert(LpDesk.ZeroAddress.selector);
        new LpDesk(address(token), DEV, address(0));
    }

    function test_everythingNeedingAModuleRevertsUntilDeployed() public {
        assertFalse(desk.moduleDeployed(LpDesk.ModuleKind.LpGovernor));
        assertFalse(desk.moduleDeployed(LpDesk.ModuleKind.PriceGuard));
        assertFalse(desk.moduleDeployed(LpDesk.ModuleKind.VenueV3));
        assertFalse(desk.moduleDeployed(LpDesk.ModuleKind.VenueV4));
        assertFalse(desk.registered());
        assertEq(desk.bootstrapEnd(), 0);
        vm.expectRevert(LpDesk.ModuleMissing.selector);
        desk.firmVault();
        vm.expectRevert(LpDesk.ModuleMissing.selector);
        desk.poolKey();
        vm.expectRevert(LpDesk.ModuleMissing.selector);
        vm.prank(address(vault));
        desk.creditFromFirmVault(1, 1);
        OpenParams memory p;
        vm.prank(DEV);
        vm.expectRevert(LpDesk.NotRegistered.selector);
        desk.open(p);
        // the governor is not there yet: its predicted address cannot call in
        address g = desk.governor();
        vm.prank(g);
        vm.expectRevert(LpDesk.NotGovernor.selector);
        desk.addAssetFromGovernor(address(0xA55E7));
        // FirmVault and the splitter refuse to act before registration
        vm.expectRevert(FirmVault.NotRegistered.selector); // registered() is false without PriceGuard
        vault.distribute(IMD);
        vm.expectRevert(GenesisSplitter.NotRegistered.selector);
        splitter.split();
    }

    function test_modulesDeployedButUnregistered() public {
        _deployModules();
        assertTrue(desk.moduleDeployed(LpDesk.ModuleKind.PriceGuard));
        assertFalse(desk.registered());
        assertEq(desk.bootstrapEnd(), 0);
        assertEq(desk.firmVault(), address(0));
        OpenParams memory p;
        vm.prank(DEV);
        vm.expectRevert(LpDesk.NotRegistered.selector);
        desk.open(p);
        vm.expectRevert(GenesisSplitter.NotRegistered.selector);
        splitter.split();
        vm.expectRevert(FirmVault.NotRegistered.selector);
        vault.distribute(IMD);
        // the operator cannot buy back before registration even with a zero amount
        vm.prank(DEV);
        vm.expectRevert(FirmVault.NotRegistered.selector);
        vault.buyback(0, 0);
        vm.prank(address(vault));
        vm.expectRevert(LpDesk.NotFirmVault.selector); // not FirmVault until registration names it
        desk.creditFromFirmVault(0, 0);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_deployModuleRejectsAnyOtherCode(uint8 kindSeed, bytes memory code) public {
        LpDesk.ModuleKind kind = LpDesk.ModuleKind(kindSeed % 4);
        vm.assume(keccak256(code) != desk.codeHashOf(kind));
        vm.expectRevert(LpDesk.WrongModuleCode.selector);
        desk.deployModule(kind, code);
    }

    function test_deployModuleWithAnotherKindsCodeReverts() public {
        vm.expectRevert(LpDesk.WrongModuleCode.selector);
        desk.deployModule(LpDesk.ModuleKind.PriceGuard, type(LpGovernor).creationCode);
        vm.expectRevert(LpDesk.WrongModuleCode.selector);
        desk.deployModule(LpDesk.ModuleKind.LpGovernor, type(PriceGuard).creationCode);
    }

    function test_registerUnknownLaunchNumberReverts() public {
        _deployModules();
        vm.startPrank(PROJECT);
        token.transfer(address(splitter), 600_000_000e18);
        factory.setRequester(launchNumber, address(vault));
        vm.stopPrank();
        vm.expectRevert(PriceGuard.WrongPool.selector);
        guard.registerNotStock(launchNumber + 1);
        vm.expectRevert(PriceGuard.WrongPool.selector);
        guard.registerNotStock(0);
        // the right one still works afterwards
        guard.registerNotStock(launchNumber);
        assertTrue(desk.registered());
        assertEq(desk.firmVault(), address(vault));
        assertEq(desk.bootstrapEnd(), block.timestamp + 604_800);
    }

    function test_splitterOneWeiShortBlocksRegistration() public {
        _deployModules();
        vm.startPrank(PROJECT);
        token.transfer(address(splitter), 600_000_000e18 - 1);
        factory.setRequester(launchNumber, address(vault));
        vm.stopPrank();
        vm.expectRevert(PriceGuard.SplitterUnderfunded.selector);
        guard.registerNotStock(launchNumber);
        vm.prank(PROJECT);
        token.transfer(address(splitter), 1);
        guard.registerNotStock(launchNumber);
        assertTrue(guard.registered());
    }
}

// =====================================================================================================================
// LpDesk after registration: access control and gates
// =====================================================================================================================

contract LpDeskAccessTest is TestBase {
    function setUp() public {
        _etchImd();
        _fullSetup(address(0));
    }

    function _p() internal pure returns (OpenParams memory p) {
        p.asset = address(0xABCD); // unlisted: proves the earlier gates were passed
        p.venue = FirmAddresses.UNI_V3_POSITION_MANAGER;
        p.feeTier = 3000;
        p.tickLower = -600;
        p.tickUpper = 600;
        p.sqrtPriceX96 = 79228162514264337593543950336;
        p.amount = 1e18;
    }

    function _assertOperatorOnly(address caller) internal {
        OpenParams memory p = _p();
        vm.startPrank(caller);
        vm.expectRevert(LpDesk.NotOperator.selector);
        desk.open(p);
        vm.expectRevert(LpDesk.NotOperator.selector);
        desk.collect(0);
        vm.expectRevert(LpDesk.NotOperator.selector);
        desk.close(0, 0, 0);
        vm.expectRevert(LpDesk.NotOperator.selector);
        desk.shiftRange(0, -60, 60, 0, 0);
        vm.expectRevert(LpDesk.NotOperator.selector);
        desk.moveLiquidity(0, 1, 1, 0, 0);
        vm.expectRevert(LpDesk.NotOperator.selector);
        desk.increaseLiquidity(0, 1, p.sqrtPriceX96, 0);
        vm.expectRevert(LpDesk.NotOperator.selector);
        desk.buyback(0, 1, 0);
        vm.expectRevert(LpDesk.NotOperator.selector);
        desk.burn(0);
        vm.expectRevert(LpDesk.NotOperator.selector);
        desk.setOperator(caller);
        vm.stopPrank();
    }

    function test_everyOperatorFunctionRefusesOthers() public {
        _assertOperatorOnly(alice);
        _assertOperatorOnly(PROJECT);
        _assertOperatorOnly(address(vault));
        _assertOperatorOnly(address(gov));
        _assertOperatorOnly(address(guard));
        _assertOperatorOnly(address(factory));
    }

    function test_governorEntriesRefuseOperatorAndOthers() public {
        OpenParams memory p = _p();
        address[3] memory callers = [DEV, alice, address(guard)];
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(LpDesk.NotGovernor.selector);
            desk.openFromGovernor(p);
            vm.expectRevert(LpDesk.NotGovernor.selector);
            desk.addAssetFromGovernor(address(0xA55E7));
            vm.expectRevert(LpDesk.NotGovernor.selector);
            desk.addVenueFromGovernor(address(0xA55E7), VenueKind.V3);
            vm.expectRevert(LpDesk.NotGovernor.selector);
            desk.bridgeOutFromGovernor(address(1), 1, address(2), 1, address(3));
            vm.stopPrank();
        }
    }

    function test_creditFromFirmVaultRefusesOthers() public {
        address[4] memory callers = [DEV, alice, PROJECT, address(gov)];
        for (uint256 i; i < 4; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(LpDesk.NotFirmVault.selector);
            desk.creditFromFirmVault(0, 0);
        }
        // even FirmVault cannot credit IMD it did not send
        vm.prank(address(vault));
        vm.expectRevert(LpDesk.AboveBasket.selector);
        desk.creditFromFirmVault(1, 0);
    }

    function test_priceGuardEntriesOnlyFromLpDesk() public {
        address[3] memory callers = [DEV, alice, address(gov)];
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(PriceGuard.NotLpDesk.selector);
            guard.addAsset(address(0xA55E7));
            vm.expectRevert(PriceGuard.NotLpDesk.selector);
            guard.addVenue(address(0xA55E7), VenueKind.V3);
            vm.stopPrank();
        }
    }

    function test_bootstrapBoundary() public {
        uint256 end = desk.bootstrapEnd();
        assertEq(end, guard.registeredAt() + 604_800);
        OpenParams memory p = _p();
        vm.warp(end - 1);
        vm.prank(DEV);
        vm.expectRevert(LpDesk.UnlistedAsset.selector); // the bootstrap gate passed
        desk.open(p);
        vm.warp(end);
        vm.prank(DEV);
        vm.expectRevert(LpDesk.BootstrapOver.selector);
        desk.open(p);
        vm.warp(end + 365 days);
        vm.prank(DEV);
        vm.expectRevert(LpDesk.BootstrapOver.selector);
        desk.open(p);
    }

    function test_openListedAssetUnlistedVenueAndNotStockAsAsset() public {
        OpenParams memory p = _p();
        p.asset = WETH;
        p.venue = FirmAddresses.SUSHI_V3_POSITION_MANAGER; // real venue elsewhere, but not listed at deploy
        vm.prank(DEV);
        vm.expectRevert(LpDesk.UnlistedVenue.selector);
        desk.open(p);
        p.asset = address(token); // NOTSTOCK paired with itself
        p.venue = FirmAddresses.UNI_V3_POSITION_MANAGER;
        vm.prank(DEV);
        vm.expectRevert(LpDesk.UnlistedAsset.selector);
        desk.open(p);
    }

    function test_operatorActionsOnMissingPositionRevert() public {
        assertEq(desk.positionCount(), 0);
        vm.startPrank(DEV);
        vm.expectRevert();
        desk.close(0, 0, 0);
        vm.expectRevert();
        desk.collect(0);
        vm.expectRevert();
        desk.shiftRange(0, -60, 60, 0, 0);
        vm.expectRevert();
        desk.increaseLiquidity(0, 0, 1, 0);
        vm.expectRevert();
        desk.buyback(0, 0, 0);
        vm.expectRevert();
        desk.moveLiquidity(0, 0, 1, 0, 0);
        vm.stopPrank();
    }

    function test_setOperatorZeroAndHandoverChain() public {
        vm.prank(DEV);
        vm.expectRevert(LpDesk.ZeroAddress.selector);
        desk.setOperator(address(0));
        vm.prank(DEV);
        desk.setOperator(alice);
        // the old operator lost every power, including FirmVault buyback and the veto
        _assertOperatorOnly(DEV);
        vm.prank(DEV);
        vm.expectRevert(FirmVault.NotOperator.selector);
        vault.buyback(0, 0);
        // the new one can hand it on again
        vm.prank(alice);
        desk.setOperator(bob);
        assertEq(desk.operator(), bob);
        vm.prank(alice);
        vm.expectRevert(LpDesk.NotOperator.selector);
        desk.burn(0);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_burnNeverExceedsFree(uint256 amount) public {
        uint256 free = desk.freeBalance(address(token));
        assertEq(free, 500_000_000e18);
        amount = bound(amount, 0, free * 2);
        vm.prank(DEV);
        if (amount > free) {
            vm.expectRevert(LpDesk.AboveFreeBalance.selector);
            desk.burn(amount);
        } else {
            desk.burn(amount);
            assertEq(token.balanceOf(DEAD), amount);
            assertEq(desk.freeBalance(address(token)), free - amount);
        }
    }

    function test_notStockSentByPlainTransferIsFree() public {
        uint256 before = desk.freeBalance(address(token));
        vm.prank(DEV);
        token.transfer(address(desk), 7e18);
        assertEq(desk.freeBalance(address(token)), before + 7e18);
        assertEq(desk.topUpBasket(address(token)), 0);
        assertEq(desk.buybackBasket(address(token)), 0);
    }

    function test_imdSentByPlainTransferIsFreeNotBasket() public {
        MockERC20(IMD).mint(address(desk), 10e18);
        assertEq(desk.freeBalance(IMD), 10e18);
        assertEq(desk.topUpBasket(IMD), 0);
    }
}

// =====================================================================================================================
// PriceGuard checks
// =====================================================================================================================

contract PriceGuardCheckTest is TestBase {
    function setUp() public {
        _etchImd();
        _fullSetup(address(0));
    }

    function test_checkAssetRejects() public {
        vm.expectRevert(PriceGuard.ZeroAddress.selector);
        guard.checkAsset(address(0));
        vm.expectRevert(PriceGuard.NotStockIsNotAnAsset.selector);
        guard.checkAsset(address(token));
        vm.expectRevert(PriceGuard.AlreadyListed.selector);
        guard.checkAsset(IMD);
        vm.expectRevert(PriceGuard.AlreadyListed.selector);
        guard.checkAsset(FirmAddresses.PLTR);
        guard.checkAsset(address(0xA55E7)); // does not revert
    }

    function test_checkVenueRejects() public {
        vm.expectRevert(PriceGuard.ZeroAddress.selector);
        guard.checkVenue(address(0), VenueKind.V3);
        vm.expectRevert(PriceGuard.AlreadyListed.selector);
        guard.checkVenue(FirmAddresses.UNI_V3_POSITION_MANAGER, VenueKind.V3);
        vm.expectRevert(PriceGuard.AlreadyListed.selector);
        guard.checkVenue(FirmAddresses.UNI_V4_POSITION_MANAGER, VenueKind.V4);
        vm.expectRevert(PriceGuard.NoCode.selector);
        guard.checkVenue(alice, VenueKind.V3);
        // a contract with no factory()/poolManager()
        vm.expectRevert(PriceGuard.NotAVenue.selector);
        guard.checkVenue(address(token), VenueKind.V3);
        vm.expectRevert(PriceGuard.NotAVenue.selector);
        guard.checkVenue(address(token), VenueKind.V4);
        // factory without code
        FakeVenue noCodeFactory = new FakeVenue(alice, WETH);
        vm.expectRevert(PriceGuard.NotAVenue.selector);
        guard.checkVenue(address(noCodeFactory), VenueKind.CL);
        // wrong WETH9
        FakeVenue wrongWeth = new FakeVenue(address(token), address(0xBEEF));
        vm.expectRevert(PriceGuard.NotAVenue.selector);
        guard.checkVenue(address(wrongWeth), VenueKind.V3);
        // V3-shaped contract offered as V4 has no poolManager()
        FakeVenue ok = new FakeVenue(address(token), WETH);
        vm.expectRevert(PriceGuard.NotAVenue.selector);
        guard.checkVenue(address(ok), VenueKind.V4);
        assertEq(guard.checkVenue(address(ok), VenueKind.V3), address(token));
    }

    function test_registrationIsPermanent() public {
        uint256 at = guard.registeredAt();
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(PriceGuard.AlreadyRegistered.selector);
        guard.registerNotStock(launchNumber);
        assertEq(guard.registeredAt(), at);
        assertEq(guard.firmVault(), address(vault));
        // the requester changing the fee recipient later does not move FirmVault
        vm.prank(address(vault));
        factory.setRequester(launchNumber, alice);
        assertEq(desk.firmVault(), address(vault));
    }
}

// =====================================================================================================================
// GenesisSplitter and Burner
// =====================================================================================================================

contract SplitterBurnerEdgeTest is TestBase {
    function setUp() public {
        _etchImd();
        _launch(address(0));
        _deployModules();
        _fundAndRegister();
    }

    function test_exactSplitAndOnce() public {
        vm.prank(alice);
        splitter.split();
        assertEq(token.balanceOf(address(desk)), 500_000_000e18);
        assertEq(token.balanceOf(DEV), 100_000_000e18);
        assertEq(token.balanceOf(address(splitter)), 0);
        assertTrue(splitter.done());
        vm.expectRevert(GenesisSplitter.AlreadySplit.selector);
        splitter.split();
        // tokens sent afterwards stay: split never reopens
        vm.prank(address(factory));
        token.transfer(address(splitter), 1e18);
        vm.expectRevert(GenesisSplitter.AlreadySplit.selector);
        splitter.split();
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_splitWithDonationLeavesNothing(uint256 extra) public {
        extra = bound(extra, 0, 400_000_000e18);
        if (extra > 0) {
            vm.prank(address(factory));
            token.transfer(address(splitter), extra);
        }
        uint256 bal = token.balanceOf(address(splitter));
        splitter.split();
        uint256 dev = token.balanceOf(DEV);
        uint256 toDesk = token.balanceOf(address(desk));
        assertEq(dev + toDesk, bal);
        assertEq(token.balanceOf(address(splitter)), 0);
        assertEq(dev, bal * 10 / 60);
        // LpDesk gets 50/60 rounded up, never less
        assertGe(toDesk * 60, bal * 50);
        assertLe(toDesk * 60, bal * 50 + 60);
    }

    function test_burnerEmptyRevertsAndBurnsWholeBalance() public {
        vm.expectRevert(Burner.NothingToBurn.selector);
        burner.burn();
        vm.prank(address(factory));
        token.transfer(address(burner), 3);
        vm.prank(bob);
        burner.burn();
        assertEq(token.balanceOf(DEAD), 3);
        assertEq(token.balanceOf(address(burner)), 0);
        vm.expectRevert(Burner.NothingToBurn.selector);
        burner.burn();
    }

    function test_burnerIgnoresOtherTokens() public {
        MockERC20(IMD).mint(address(burner), 5e18);
        vm.expectRevert(Burner.NothingToBurn.selector);
        burner.burn();
        assertEq(MockERC20(IMD).balanceOf(address(burner)), 5e18);
    }
}

// =====================================================================================================================
// FirmVault: distribute and buyback through a PoolManager stand-in
// =====================================================================================================================

contract FirmVaultEdgeTest is TestBase {
    MockPoolManager pm;

    function setUp() public {
        _etchImd();
        _fullSetup(address(0));
        MockPoolManager m = new MockPoolManager();
        vm.etch(FirmAddresses.UNI_V4_POOL_MANAGER, address(m).code);
        pm = MockPoolManager(FirmAddresses.UNI_V4_POOL_MANAGER);
        pm.setRate(2e18); // 2 NOTSTOCK per IMD
        vm.prank(DEV);
        token.transfer(address(pm), 50_000_000e18);
    }

    function _fillBucket(uint256 imd) internal {
        MockERC20(IMD).mint(address(vault), imd);
        vault.distribute(IMD);
    }

    function test_distributeOtherTokensReverts() public {
        vm.expectRevert(FirmVault.UnsupportedToken.selector);
        vault.distribute(WETH);
        vm.expectRevert(FirmVault.UnsupportedToken.selector);
        vault.distribute(address(0));
        vm.expectRevert(FirmVault.UnsupportedToken.selector);
        vault.distribute(address(vault));
    }

    function test_distributeEmptyMovesNothing() public {
        vault.distribute(IMD);
        vault.distribute(address(token));
        assertEq(vault.buybackBucket(), 0);
        assertEq(desk.topUpBasket(IMD), 0);
        MockERC20(IMD).mint(address(vault), 3); // below one wei per quarter
        vault.distribute(IMD);
        assertEq(vault.buybackBucket(), 0);
        assertEq(MockERC20(IMD).balanceOf(address(vault)), 3);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_distributeSplitsQuartersAndRepeatMovesNothing(uint256 a, uint256 b) public {
        a = bound(a, 0, 1e30);
        b = bound(b, 0, 1e30);
        MockERC20(IMD).mint(address(vault), a);
        MockERC20(IMD).mint(address(vault), b);
        uint256 q = (a + b) / 4;
        vault.distribute(IMD);
        assertEq(vault.buybackBucket(), q);
        assertEq(MockERC20(IMD).balanceOf(PROJECT), q);
        assertEq(desk.topUpBasket(IMD), q);
        assertEq(desk.freeBalance(IMD), q);
        assertEq(MockERC20(IMD).balanceOf(address(desk)), 2 * q);
        assertEq(MockERC20(IMD).balanceOf(address(vault)), a + b - 3 * q);
        assertLt(MockERC20(IMD).balanceOf(address(vault)) - vault.buybackBucket(), 4);
        vault.distribute(IMD);
        assertEq(vault.buybackBucket(), q);
        assertEq(MockERC20(IMD).balanceOf(PROJECT), q);
        assertEq(desk.topUpBasket(IMD), q);
    }

    function test_distributeNeverTouchesBucketAfterBuyback() public {
        _fillBucket(400e18); // bucket 100
        vm.prank(DEV);
        vault.buyback(40e18, 0); // bucket 60
        assertEq(vault.buybackBucket(), 60e18);
        vault.distribute(IMD);
        assertEq(vault.buybackBucket(), 60e18);
        assertEq(MockERC20(IMD).balanceOf(address(vault)), 60e18);
    }

    function test_creditBuybackOnlyFromLpDesk() public {
        MockERC20(IMD).mint(address(vault), 10e18);
        address[4] memory callers = [DEV, alice, PROJECT, address(gov)];
        for (uint256 i; i < 4; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(FirmVault.NotLpDesk.selector);
            vault.creditBuyback(1e18);
        }
        // LpDesk itself cannot credit IMD that is not there
        vm.prank(address(desk));
        vm.expectRevert(FirmVault.AboveBucket.selector);
        vault.creditBuyback(10e18 + 1);
    }

    function test_unlockCallbackOnlyFromPoolManager() public {
        PoolKey memory key = desk.poolKey();
        vm.prank(DEV);
        vm.expectRevert(FirmVault.NotPoolManager.selector);
        vault.unlockCallback(abi.encode(key, uint256(1)));
        vm.expectRevert(FirmVault.NotPoolManager.selector);
        vault.unlockCallback(abi.encode(key, uint256(1)));
    }

    function test_buybackHappyPathSendsAllOutToDead() public {
        _fillBucket(400e18);
        uint256 pmImd = MockERC20(IMD).balanceOf(address(pm));
        vm.prank(DEV);
        uint256 out = vault.buyback(25e18, 50e18); // minOut equal to the output executes
        assertEq(out, 50e18);
        assertEq(vault.buybackBucket(), 75e18);
        assertEq(token.balanceOf(DEAD), 50e18);
        assertEq(MockERC20(IMD).balanceOf(address(pm)) - pmImd, 25e18);
        assertEq(MockERC20(IMD).balanceOf(address(vault)), 75e18);
        // the full rest of the bucket
        vm.prank(DEV);
        vault.buyback(75e18, 0);
        assertEq(vault.buybackBucket(), 0);
        assertEq(token.balanceOf(DEAD), 200e18);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function test_buybackFailurePaths() public {
        _fillBucket(400e18); // bucket 100
        vm.prank(DEV);
        vm.expectRevert(FirmVault.BelowMinOut.selector);
        vault.buyback(10e18, 20e18 + 1);
        vm.prank(DEV);
        vm.expectRevert(FirmVault.AboveBucket.selector);
        vault.buyback(100e18 + 1, 0);
        address[4] memory callers = [alice, PROJECT, address(desk), address(gov)];
        for (uint256 i; i < 4; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(FirmVault.NotOperator.selector);
            vault.buyback(1e18, 0);
        }
        // nothing moved
        assertEq(vault.buybackBucket(), 100e18);
        assertEq(token.balanceOf(DEAD), 0);
    }

    function test_buybackFollowsOperatorHandover() public {
        _fillBucket(400e18);
        vm.prank(DEV);
        desk.setOperator(alice);
        vm.prank(DEV);
        vm.expectRevert(FirmVault.NotOperator.selector);
        vault.buyback(1e18, 0);
        vm.prank(alice);
        vault.buyback(1e18, 0);
        assertEq(vault.buybackBucket(), 99e18);
    }

    function test_distributedNotStockGoesToBurnerOnly() public {
        vm.prank(DEV);
        token.transfer(address(vault), 9e18);
        uint256 deskBefore = token.balanceOf(address(desk));
        vault.distribute(address(token));
        assertEq(token.balanceOf(address(burner)), 9e18);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(address(desk)), deskBefore);
        vault.distribute(address(token));
        assertEq(token.balanceOf(address(burner)), 9e18);
    }
}

// =====================================================================================================================
// LpGovernor edges
// =====================================================================================================================

contract GovernorEdgeTest is TestBase {
    address carol = makeAddr("carol");
    address constant NEW_ASSET = address(0xA55E7);

    function setUp() public {
        _etchImd();
        _fullSetup(address(0));
        vm.startPrank(DEV);
        token.transfer(alice, 10_000_000e18);
        token.transfer(bob, 10_000_000e18);
        token.transfer(carol, 10_000_000e18);
        vm.stopPrank();
    }

    function _stake(address who, uint256 amount) internal {
        vm.startPrank(who);
        token.approve(address(gov), amount);
        gov.stake(amount);
        vm.stopPrank();
    }

    function _propose(address who) internal returns (uint256 id) {
        vm.prank(who);
        id = gov.proposeAddAsset(NEW_ASSET);
    }

    function test_stakeUnstakeFailurePaths() public {
        vm.prank(alice);
        vm.expectRevert(LpGovernor.ZeroAmount.selector);
        gov.stake(0);
        vm.prank(alice);
        vm.expectRevert(LpGovernor.ZeroAmount.selector);
        gov.unstake(0);
        vm.prank(alice);
        vm.expectRevert(LaunchToken.InsufficientAllowance.selector);
        gov.stake(1);
        _stake(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(LpGovernor.InsufficientStake.selector);
        gov.unstake(100e18 + 1);
        vm.prank(bob);
        vm.expectRevert(LpGovernor.InsufficientStake.selector);
        gov.unstake(1);
        // unstake is always allowed, even while the staker's proposal is open and voted
        vm.roll(block.number + 1);
        uint256 id = _propose(alice);
        vm.prank(alice);
        gov.vote(id, true);
        vm.prank(alice);
        gov.unstake(100e18);
        assertEq(token.balanceOf(alice), 10_000_000e18);
        assertEq(gov.totalStaked(), 0);
        assertEq(token.balanceOf(address(gov)), 0);
    }

    function test_sameBlockStakeHasNoWeightAndNoQuorumBase() public {
        _stake(alice, 1_000e18);
        vm.roll(block.number + 1);
        _stake(bob, 500e18); // same block as the proposal
        uint256 id = _propose(alice);
        assertEq(gov.getProposal(id).quorumBase, 1_000e18);
        vm.prank(bob);
        vm.expectRevert(LpGovernor.NoWeight.selector);
        gov.vote(id, false);
        vm.prank(alice);
        gov.vote(id, true);
        vm.warp(block.timestamp + 3 days);
        assertTrue(gov.state(id) == LpGovernor.State.Passed);
    }

    function test_movedStakeCannotVoteTwice() public {
        _stake(alice, 1_000e18);
        _stake(bob, 1_000e18);
        vm.roll(block.number + 1);
        uint256 id = _propose(bob);
        vm.prank(alice);
        gov.unstake(1_000e18); // unstake before voting keeps the checkpointed weight
        vm.prank(alice);
        gov.vote(id, true);
        assertEq(gov.getProposal(id).forWeight, 1_000e18);
        vm.prank(alice);
        token.transfer(carol, 1_000e18);
        _stake(carol, 1_000e18);
        vm.roll(block.number + 5);
        vm.prank(carol);
        vm.expectRevert(LpGovernor.NoWeight.selector);
        gov.vote(id, false);
        vm.prank(alice);
        vm.expectRevert(LpGovernor.AlreadyVoted.selector);
        gov.vote(id, false);
        assertEq(gov.getProposal(id).forWeight, 1_000e18);
        assertEq(gov.getProposal(id).againstWeight, 0);
    }

    function test_quorumExactlyThreePercentPasses() public {
        _stake(alice, 30e18);
        _stake(bob, 970e18);
        vm.roll(block.number + 1);
        uint256 id = _propose(alice);
        vm.prank(alice);
        gov.vote(id, true);
        vm.warp(block.timestamp + 3 days);
        assertTrue(gov.state(id) == LpGovernor.State.Passed);
    }

    function test_quorumOneWeiBelowThreePercentFails() public {
        _stake(alice, 30e18 - 1);
        _stake(bob, 970e18 + 1);
        vm.roll(block.number + 1);
        uint256 id = _propose(alice);
        vm.prank(alice);
        gov.vote(id, true);
        vm.warp(block.timestamp + 3 days);
        assertTrue(gov.state(id) == LpGovernor.State.Failed);
        // failed is permanent: no later vote or execute
        vm.prank(bob);
        vm.expectRevert(LpGovernor.WrongState.selector);
        gov.vote(id, true);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(LpGovernor.WrongState.selector);
        gov.execute(id);
        // and it no longer blocks a new one
        _propose(alice);
    }

    function test_tieFails() public {
        _stake(alice, 500e18);
        _stake(bob, 500e18);
        vm.roll(block.number + 1);
        uint256 id = _propose(alice);
        vm.prank(alice);
        gov.vote(id, true);
        vm.prank(bob);
        gov.vote(id, false);
        vm.warp(block.timestamp + 3 days);
        assertTrue(gov.state(id) == LpGovernor.State.Failed);
    }

    function test_noStakeAtSnapshotAlwaysFails() public {
        // the operator proposes with nothing staked anywhere: quorum base 0 can never be met
        vm.prank(DEV);
        uint256 id = gov.proposeAddAsset(NEW_ASSET);
        assertEq(gov.getProposal(id).quorumBase, 0);
        vm.prank(alice);
        vm.expectRevert(LpGovernor.NoWeight.selector);
        gov.vote(id, true);
        vm.warp(block.timestamp + 3 days);
        assertTrue(gov.state(id) == LpGovernor.State.Failed);
    }

    function test_thresholdBoundary() public {
        _stake(alice, 1e18);
        _stake(bob, 999e18); // alice holds exactly 0.1%
        _propose(alice);
        vm.prank(carol);
        vm.expectRevert(LpGovernor.BelowThreshold.selector);
        gov.proposeAddAsset(address(0xB0B));
    }

    function test_thresholdOneWeiBelow() public {
        _stake(alice, 1e18);
        _stake(bob, 999e18 + 1);
        vm.prank(alice);
        vm.expectRevert(LpGovernor.BelowThreshold.selector);
        gov.proposeAddAsset(NEW_ASSET);
        vm.prank(carol);
        vm.expectRevert(LpGovernor.BelowThreshold.selector);
        gov.proposeAddAsset(NEW_ASSET);
    }

    function test_stateTimelineBoundaries() public {
        _stake(alice, 1_000e18);
        vm.roll(block.number + 1);
        uint256 id = _propose(alice);
        (uint256 voteEnd, uint256 vetoEnd, uint256 expiry) = gov.deadlines(id);
        assertEq(voteEnd, block.timestamp + 3 days);
        assertEq(vetoEnd, voteEnd + 2 days);
        assertEq(expiry, vetoEnd + 259_200);
        vm.prank(alice);
        gov.vote(id, true);
        vm.warp(voteEnd - 1);
        assertTrue(gov.state(id) == LpGovernor.State.Voting);
        vm.expectRevert(LpGovernor.WrongState.selector);
        gov.execute(id);
        vm.prank(DEV);
        vm.expectRevert(LpGovernor.WrongState.selector);
        gov.veto(id);
        vm.warp(voteEnd);
        assertTrue(gov.state(id) == LpGovernor.State.Passed);
        vm.prank(bob);
        vm.expectRevert(LpGovernor.WrongState.selector);
        gov.vote(id, false);
        vm.expectRevert(LpGovernor.WrongState.selector);
        gov.execute(id);
        vm.warp(vetoEnd - 1);
        assertTrue(gov.state(id) == LpGovernor.State.Passed);
        vm.warp(vetoEnd);
        assertTrue(gov.state(id) == LpGovernor.State.Executable);
        vm.prank(DEV);
        vm.expectRevert(LpGovernor.WrongState.selector);
        gov.veto(id);
        vm.warp(expiry - 1);
        assertTrue(gov.state(id) == LpGovernor.State.Executable);
        vm.warp(expiry);
        assertTrue(gov.state(id) == LpGovernor.State.Expired);
        vm.expectRevert(LpGovernor.WrongState.selector);
        gov.execute(id);
        assertFalse(gov.isOpen(id));
        assertFalse(guard.isAsset(NEW_ASSET));
    }

    function test_executeOnceNoValueAnyCaller() public {
        _stake(alice, 1_000e18);
        vm.roll(block.number + 1);
        uint256 id = _propose(alice);
        vm.prank(alice);
        gov.vote(id, true);
        vm.warp(block.timestamp + 5 days);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(LpGovernor.NoValueExpected.selector);
        gov.execute{value: 1}(id);
        vm.prank(bob);
        gov.execute(id);
        assertTrue(guard.isAsset(NEW_ASSET));
        assertTrue(gov.state(id) == LpGovernor.State.Executed);
        vm.expectRevert(LpGovernor.WrongState.selector);
        gov.execute(id);
        // the asset is now listed: proposing it again is refused
        vm.prank(alice);
        vm.expectRevert(PriceGuard.AlreadyListed.selector);
        gov.proposeAddAsset(NEW_ASSET);
    }

    function test_vetoOnlyOperatorOnceAndFollowsHandover() public {
        _stake(alice, 1_000e18);
        vm.roll(block.number + 1);
        uint256 id = _propose(alice);
        vm.prank(alice);
        gov.vote(id, true);
        vm.warp(block.timestamp + 3 days);
        vm.prank(alice);
        vm.expectRevert(LpGovernor.NotOperator.selector);
        gov.veto(id);
        vm.prank(DEV);
        desk.setOperator(bob);
        vm.prank(DEV);
        vm.expectRevert(LpGovernor.NotOperator.selector);
        gov.veto(id);
        vm.prank(bob);
        gov.veto(id);
        assertTrue(gov.state(id) == LpGovernor.State.Vetoed);
        vm.prank(bob);
        vm.expectRevert(LpGovernor.WrongState.selector);
        gov.veto(id);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(LpGovernor.WrongState.selector);
        gov.execute(id);
        assertFalse(guard.isAsset(NEW_ASSET));
        // a vetoed proposal stops blocking at once
        _propose(alice);
    }

    function test_vetoOnVotingOrFailedReverts() public {
        _stake(alice, 1_000e18);
        vm.roll(block.number + 1);
        uint256 id = _propose(alice);
        vm.prank(DEV);
        vm.expectRevert(LpGovernor.WrongState.selector);
        gov.veto(id);
        vm.warp(block.timestamp + 3 days); // nobody voted: failed
        vm.prank(DEV);
        vm.expectRevert(LpGovernor.WrongState.selector);
        gov.veto(id);
    }

    function test_bridgeOutProposalGates() public {
        _stake(alice, 1_000e18);
        vm.prank(alice);
        vm.expectRevert(LpGovernor.UnknownBridge.selector);
        gov.proposeBridgeOut(0, 1);
        vm.prank(DEV);
        vm.expectRevert(LpGovernor.UnknownBridge.selector);
        gov.proposeBridgeOut(type(uint256).max, 1);
        vm.prank(alice);
        vm.expectRevert(LpGovernor.BadBridge.selector);
        gov.proposeAddBridge(alice, 1, bob); // no code
        vm.prank(alice);
        vm.expectRevert(LpGovernor.BadBridge.selector);
        gov.proposeAddBridge(address(gov), 1, address(0)); // zero destination
        vm.prank(alice);
        vm.expectRevert();
        gov.proposeAddBridge(address(token), 1, bob); // token() missing
    }

    function test_voteOnUnknownProposalReverts() public {
        _stake(alice, 1_000e18);
        vm.prank(alice);
        vm.expectRevert();
        gov.vote(0, true);
        vm.expectRevert();
        gov.execute(0);
    }

    function test_operatorAndStakerSlotsAreSeparate() public {
        _stake(alice, 1_000e18);
        vm.roll(block.number + 1);
        _propose(alice);
        vm.prank(bob);
        vm.expectRevert(LpGovernor.BelowThreshold.selector);
        gov.proposeAddAsset(address(0xB0B));
        _stake(bob, 1_000e18);
        vm.prank(bob);
        vm.expectRevert(LpGovernor.KindAlreadyOpen.selector);
        gov.proposeAddAsset(address(0xB0B));
        vm.prank(DEV);
        gov.proposeAddAsset(address(0xB0B));
        vm.prank(DEV);
        vm.expectRevert(LpGovernor.KindAlreadyOpen.selector);
        gov.proposeAddAsset(address(0xC0C));
    }
}

// =====================================================================================================================
// PoolMath properties
// =====================================================================================================================

contract PoolMathPropertyTest is TestBase {
    PoolMathHarness h;

    function setUp() public {
        h = new PoolMathHarness();
    }

    function test_tickBounds() public {
        assertEq(h.sqrtAt(PoolMath.MIN_TICK), PoolMath.MIN_SQRT_RATIO);
        assertEq(h.sqrtAt(PoolMath.MAX_TICK), PoolMath.MAX_SQRT_RATIO);
        assertEq(h.sqrtAt(0), 1 << 96);
        vm.expectRevert(PoolMath.TickOutOfRange.selector);
        h.sqrtAt(PoolMath.MAX_TICK + 1);
        vm.expectRevert(PoolMath.TickOutOfRange.selector);
        h.sqrtAt(PoolMath.MIN_TICK - 1);
        vm.expectRevert(PoolMath.TickOutOfRange.selector);
        h.sqrtAt(type(int24).min);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_sqrtRatioStrictlyIncreasing(int24 t) public pure {
        t = int24(bound(int256(t), int256(PoolMath.MIN_TICK), int256(PoolMath.MAX_TICK) - 1));
        assertLt(PoolMath.getSqrtRatioAtTick(t), PoolMath.getSqrtRatioAtTick(t + 1));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_mulDivMatchesNative(uint128 x, uint128 y, uint256 d) public pure {
        d = bound(d, 1, type(uint256).max);
        uint256 p = uint256(x) * uint256(y);
        assertEq(PoolMath.mulDiv(x, y, d), p / d);
        assertEq(PoolMath.mulDivUp(x, y, d), p / d + (p % d == 0 ? 0 : 1));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_mulDivFullWidth(uint256 x, uint256 y) public pure {
        x = bound(x, 1, type(uint256).max);
        y = bound(y, 1, type(uint256).max);
        // x*y/y == x even when x*y overflows 256 bits
        assertEq(PoolMath.mulDiv(x, y, y), x);
    }

    function test_mulDivOverflowAndZeroDivisor() public {
        assertEq(h.mulDiv(type(uint256).max, type(uint256).max, type(uint256).max), type(uint256).max);
        vm.expectRevert(PoolMath.MulDivOverflow.selector);
        h.mulDiv(type(uint256).max, 2, 1);
        vm.expectRevert();
        h.mulDiv(1, 1, 0);
        vm.expectRevert(PoolMath.MulDivOverflow.selector);
        h.toUint128(uint256(type(uint128).max) + 1);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_priceBandIsHalfPercentEachWay(uint160 g) public pure {
        g = uint160(bound(g, 1 << 80, 1 << 150));
        assertTrue(PoolMath.within0_5Percent(g, g));
        // sqrt factors: 1.002 -> price x1.004004 (inside), 1.003 -> x1.006009 (outside)
        assertTrue(PoolMath.within0_5Percent(uint160(uint256(g) * 1002 / 1000), g));
        assertFalse(PoolMath.within0_5Percent(uint160(uint256(g) * 1003 / 1000), g));
        // 0.998 -> x0.996004 (inside), 0.997 -> x0.994009 (outside)
        assertTrue(PoolMath.within0_5Percent(uint160(uint256(g) * 998 / 1000), g));
        assertFalse(PoolMath.within0_5Percent(uint160(uint256(g) * 997 / 1000), g));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_amountsForLiquidityCoverLiquidity(uint128 amount, int24 lo, int24 hi, int24 cur) public pure {
        lo = int24(bound(int256(lo), -200_000, 199_940));
        hi = int24(bound(int256(hi), int256(lo) + 60, 200_000));
        cur = int24(bound(int256(cur), -200_000, 200_000));
        amount = uint128(bound(amount, 1, 1e24));
        uint160 sa = PoolMath.getSqrtRatioAtTick(lo);
        uint160 sb = PoolMath.getSqrtRatioAtTick(hi);
        uint160 sp = PoolMath.getSqrtRatioAtTick(cur);
        uint128 l0 = PoolMath.liquidityFromAmount0(sp, sa, sb, amount);
        if (l0 > 0) {
            (uint256 a0,) = PoolMath.getAmountsForLiquidity(sp, sa, sb, l0);
            // rounding up never asks for more than given plus one wei
            assertLe(a0, uint256(amount) + 1);
        }
        uint128 l1 = PoolMath.liquidityFromAmount1(sp, sa, sb, amount);
        if (l1 > 0) {
            (, uint256 a1) = PoolMath.getAmountsForLiquidity(sp, sa, sb, l1);
            assertLe(a1, uint256(amount) + 1);
        }
        // a range entirely above the price takes no token1, entirely below takes no token0
        if (sp <= sa) assertEq(PoolMath.liquidityFromAmount1(sp, sa, sb, amount), 0);
        if (sp >= sb) assertEq(PoolMath.liquidityFromAmount0(sp, sa, sb, amount), 0);
    }
}
