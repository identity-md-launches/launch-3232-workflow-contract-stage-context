// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "./TestBase.sol";
import {
    MockERC20,
    MockFactory,
    MockOFTAdapter,
    EvilAdapter,
    FakeVenue,
    ThinPool,
    MockV3Manager,
    FakePoolManager
} from "./Mocks.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LpDesk} from "../src/LpDesk.sol";
import {FirmVault} from "../src/FirmVault.sol";
import {GenesisSplitter} from "../src/GenesisSplitter.sol";
import {Burner} from "../src/Burner.sol";
import {LpGovernor} from "../src/modules/LpGovernor.sol";
import {PriceGuard} from "../src/modules/PriceGuard.sol";
import {VenueV3} from "../src/modules/VenueV3.sol";
import {VenueV4} from "../src/modules/VenueV4.sol";
import {PoolMath} from "../src/libraries/PoolMath.sol";
import {OpenParams, VenueKind, Venue, PosRef} from "../src/interfaces/ILpDesk.sol";
import {PoolKey, IERC20} from "../src/interfaces/IExternal.sol";
import {FirmAddresses} from "../src/FirmAddresses.sol";

contract TokenTest is TestBase {
    function test_supplyNameSymbolTransfer() public {
        LaunchToken t = new LaunchToken();
        assertEq(t.totalSupply(), 1_000_000_000e18);
        assertEq(t.balanceOf(address(this)), 1_000_000_000e18);
        assertEq(t.decimals(), 18);
        assertEq(t.name(), "Not Firm");
        assertEq(t.symbol(), "NOTSTOCK");
        assertTrue(t.transfer(alice, 5e18));
        assertEq(t.balanceOf(alice), 5e18);
        assertEq(t.balanceOf(address(this)), 1_000_000_000e18 - 5e18);
        vm.expectRevert(LaunchToken.InsufficientBalance.selector);
        vm.prank(alice);
        t.transfer(bob, 6e18);
    }
}

contract BytecodeTest is TestBase {
    function setUp() public {
        _etchImd();
        _launch(address(0));
        _deployModules();
    }

    function test_runtimeAndInitcodeLimits() public view {
        assertLt(address(desk).code.length, 24_576);
        assertLt(address(vault).code.length, 10_240);
        assertLt(address(splitter).code.length, 2_048);
        assertLt(address(burner).code.length, 1_024);
        assertLt(address(gov).code.length, 24_576);
        assertLt(address(guard).code.length, 24_576);
        assertLt(address(v3).code.length, 24_576);
        assertLt(address(v4).code.length, 24_576);
        assertLt(type(LpDesk).creationCode.length, 49_152);
    }

    function test_moduleHashesMatchCreationCode() public view {
        assertEq(desk.LP_GOVERNOR_CODE_HASH(), keccak256(type(LpGovernor).creationCode));
        assertEq(desk.PRICE_GUARD_CODE_HASH(), keccak256(type(PriceGuard).creationCode));
        assertEq(desk.VENUE_V3_CODE_HASH(), keccak256(type(VenueV3).creationCode));
        assertEq(desk.VENUE_V4_CODE_HASH(), keccak256(type(VenueV4).creationCode));
        assertEq(address(gov), desk.governor());
        assertEq(address(guard), desk.priceGuard());
        assertEq(gov.lpDesk(), address(desk));
        assertTrue(desk.moduleDeployed(LpDesk.ModuleKind.VenueV4));
    }

    function test_deployModuleRejectsOtherCodeAndRepeats() public {
        LpDesk fresh = new LpDesk(address(token), DEV, PROJECT);
        vm.expectRevert(LpDesk.WrongModuleCode.selector);
        fresh.deployModule(LpDesk.ModuleKind.LpGovernor, type(PriceGuard).creationCode);
        fresh.deployModule(LpDesk.ModuleKind.LpGovernor, type(LpGovernor).creationCode);
        vm.expectRevert(LpDesk.ModuleExists.selector);
        fresh.deployModule(LpDesk.ModuleKind.LpGovernor, type(LpGovernor).creationCode);
    }

    function test_launchFactoryIsConstructorCaller() public view {
        assertEq(desk.launchFactory(), address(factory));
        assertEq(desk.operator(), DEV);
        assertEq(desk.projectWallet(), PROJECT);
        assertEq(vault.lpDesk(), address(desk));
    }
}

contract PoolMathTest is TestBase {
    function test_knownSqrtRatios() public pure {
        assertEq(PoolMath.getSqrtRatioAtTick(0), 79228162514264337593543950336);
        assertEq(PoolMath.getSqrtRatioAtTick(PoolMath.MIN_TICK), PoolMath.MIN_SQRT_RATIO);
        assertEq(PoolMath.getSqrtRatioAtTick(PoolMath.MAX_TICK), PoolMath.MAX_SQRT_RATIO);
        assertEq(PoolMath.mulDiv(type(uint256).max, 3, 7), type(uint256).max / 7 * 3 + (type(uint256).max % 7) * 3 / 7);
    }

    function test_priceBand() public pure {
        uint160 p = 79228162514264337593543950336;
        assertTrue(PoolMath.within0_5Percent(p, p));
        // +0.4% price = sqrt(1.004) ~ 1.001998
        assertTrue(PoolMath.within0_5Percent(uint160(uint256(p) * 1001998 / 1000000), p));
        // +0.6% price = sqrt(1.006) ~ 1.0029955
        assertFalse(PoolMath.within0_5Percent(uint160(uint256(p) * 1003000 / 1000000), p));
        assertFalse(PoolMath.within0_5Percent(uint160(uint256(p) * 996990 / 1000000), p));
        // full resolution at any price (finding 5395cffb): a 4x ratio and a 0.6% move at sqrt prices below 2^48
        assertFalse(PoolMath.within0_5Percent(uint160(1) << 47, uint160(1) << 46));
        assertFalse(PoolMath.within0_5Percent(uint160((uint256(1) << 47) * 1003000 / 1000000), uint160(1) << 47));
        assertTrue(PoolMath.within0_5Percent(uint160((uint256(1) << 47) * 1001998 / 1000000), uint160(1) << 47));
        assertTrue(PoolMath.within0_5Percent(type(uint160).max - 1, type(uint160).max));
    }

    function testFuzz_liquidityRoundTrip(uint128 amount, int24 lo, int24 hi) public pure {
        amount = uint128(bound(amount, 1e6, 1e27));
        lo = int24(bound(lo, -200000, 190000));
        hi = int24(bound(hi, int256(lo) + 600, 200000));
        uint160 sa = PoolMath.getSqrtRatioAtTick(lo);
        uint160 sb = PoolMath.getSqrtRatioAtTick(hi);
        uint160 p = PoolMath.getSqrtRatioAtTick((lo + hi) / 2);
        uint128 l = PoolMath.liquidityFromAmount0(p, sa, sb, amount);
        (uint256 a0,) = PoolMath.getAmountsForLiquidity(p, sa, sb, l);
        assertLe(a0, uint256(amount) + 2);
    }
}

contract RegistrationTest is TestBase {
    function setUp() public {
        _etchImd();
        _launch(address(0));
        _deployModules();
    }

    function test_registersWithExtraTokensAndOnlyOnce() public {
        vm.startPrank(PROJECT);
        token.transfer(address(splitter), 600_000_000e18);
        factory.setRequester(launchNumber, address(vault));
        vm.stopPrank();
        // anyone may top it up; extra tokens do not block
        factory.releasePoolShare(address(token), alice);
        vm.prank(alice);
        token.transfer(address(splitter), 7);
        guard.registerNotStock(launchNumber);
        assertTrue(desk.registered());
        assertEq(desk.firmVault(), address(vault));
        assertEq(desk.bootstrapEnd(), block.timestamp + 604_800);
        assertEq(desk.poolKey().fee, 12500);
        vm.expectRevert(PriceGuard.AlreadyRegistered.selector);
        guard.registerNotStock(launchNumber);
    }

    function test_revertsUnderfundedOrWrongRecipient() public {
        vm.startPrank(PROJECT);
        token.transfer(address(splitter), 600_000_000e18 - 1);
        factory.setRequester(launchNumber, address(vault));
        vm.stopPrank();
        vm.expectRevert(PriceGuard.SplitterUnderfunded.selector);
        guard.registerNotStock(launchNumber);
        vm.prank(PROJECT);
        token.transfer(address(splitter), 1);
        // fee recipient is still a wallet, not FirmVault
        vm.prank(address(vault));
        factory.setRequester(launchNumber, PROJECT);
        vm.expectRevert(PriceGuard.WrongFeeRecipient.selector);
        guard.registerNotStock(launchNumber);
        // a contract whose lpDesk() is another desk
        FirmVault other = new FirmVault(PROJECT, address(0xBEEF));
        vm.prank(PROJECT);
        factory.setRequester(launchNumber, address(other));
        vm.expectRevert(PriceGuard.WrongFeeRecipient.selector);
        guard.registerNotStock(launchNumber);
    }

    function test_revertsOtherTokenFeeOrHook() public {
        // another launch record (another token) on the same factory
        (uint64 n2,,,,) = factory.launch(PROJECT, 12500, IMD);
        vm.expectRevert(PriceGuard.WrongPool.selector);
        guard.registerNotStock(n2);
        // wrong fee record
        MockFactory f3 = new MockFactory(address(0));
        (uint64 n3,, address d3,,) = f3.launch(PROJECT, 3000, IMD);
        PriceGuard g3 = PriceGuard(LpDesk(d3).deployModule(LpDesk.ModuleKind.PriceGuard, type(PriceGuard).creationCode));
        vm.expectRevert(PriceGuard.WrongPool.selector);
        g3.registerNotStock(n3);
        // wrong hook: the record's hook differs from the factory's poolHook()
        factory.setPoolHook(address(0x1234));
        vm.startPrank(PROJECT);
        token.transfer(address(splitter), 600_000_000e18);
        factory.setRequester(launchNumber, address(vault));
        vm.stopPrank();
        vm.expectRevert(PriceGuard.WrongPool.selector);
        guard.registerNotStock(launchNumber);
    }

    /// @dev Audit finding 6331aad7: a later LaunchFees.setPoolFee must not lock registration.
    function test_liveFeeChangeDoesNotBlockRegistration() public {
        factory.feesContract().setPoolFee(3000);
        _fundAndRegister();
        assertTrue(desk.registered());
    }

    function test_wrongLpDeskArtifactReverts() public {
        MockFactory f = new MockFactory(address(0));
        (uint64 n, address t,, address v, address s) = f.launch(PROJECT, 12500, IMD);
        // a second LpDesk deployed by the same factory but not the one in the registry
        vm.prank(address(f));
        LpDesk rogue = new LpDesk(t, DEV, PROJECT);
        PriceGuard g = PriceGuard(rogue.deployModule(LpDesk.ModuleKind.PriceGuard, type(PriceGuard).creationCode));
        vm.startPrank(PROJECT);
        LaunchToken(t).transfer(s, 600_000_000e18);
        f.setRequester(n, v);
        vm.stopPrank();
        vm.expectRevert(PriceGuard.WrongLaunchRecord.selector);
        g.registerNotStock(n);
    }
}

contract SplitterBurnerTest is TestBase {
    function setUp() public {
        _etchImd();
        _launch(address(0));
        _deployModules();
    }

    function test_splitRequiresRegistrationThenSplits50and10() public {
        vm.prank(PROJECT);
        token.transfer(address(splitter), 600_000_000e18);
        vm.expectRevert(GenesisSplitter.NotRegistered.selector);
        splitter.split();
        vm.prank(PROJECT);
        factory.setRequester(launchNumber, address(vault));
        guard.registerNotStock(launchNumber);
        vm.prank(alice);
        splitter.split();
        assertEq(token.balanceOf(address(desk)), 500_000_000e18);
        assertEq(token.balanceOf(DEV), 100_000_000e18);
        assertEq(token.balanceOf(address(splitter)), 0);
        assertEq(desk.freeBalance(address(token)), 500_000_000e18);
        vm.expectRevert(GenesisSplitter.AlreadySplit.selector);
        splitter.split();
    }

    /// @dev Audit finding 6e61c2a0: no dust stays behind.
    function test_splitLeavesNoDust() public {
        vm.startPrank(PROJECT);
        token.transfer(address(splitter), 600_000_000e18);
        factory.setRequester(launchNumber, address(vault));
        vm.stopPrank();
        factory.releasePoolShare(address(token), alice);
        vm.prank(alice);
        token.transfer(address(splitter), 5);
        guard.registerNotStock(launchNumber);
        splitter.split();
        assertEq(token.balanceOf(address(splitter)), 0);
        uint256 total = 600_000_000e18 + 5;
        assertEq(token.balanceOf(DEV), total * 10 / 60);
        assertEq(token.balanceOf(address(desk)), total - total * 10 / 60);
    }

    function test_burnerBurnsWholeBalanceByAnyone() public {
        vm.expectRevert(Burner.NothingToBurn.selector);
        burner.burn();
        vm.prank(PROJECT);
        token.transfer(address(burner), 123e18);
        uint256 deadBefore = token.balanceOf(DEAD);
        vm.prank(alice);
        burner.burn();
        assertEq(token.balanceOf(address(burner)), 0);
        assertEq(token.balanceOf(DEAD), deadBefore + 123e18);
        assertEq(burner.lpDesk(), address(desk));
    }
}

contract FirmVaultTest is TestBase {
    function setUp() public {
        _etchImd();
        _launch(address(0));
        _deployModules();
    }

    function test_distributeRevertsBeforeRegistration() public {
        MockERC20(IMD).mint(address(vault), 100e18);
        vm.expectRevert(FirmVault.NotRegistered.selector);
        vault.distribute(IMD);
    }

    function test_distributeImdSplitsExactQuarters() public {
        _fundAndRegister();
        MockERC20(IMD).mint(address(vault), 100e18);
        MockERC20(IMD).mint(address(vault), 300e18);
        uint256 projBefore = MockERC20(IMD).balanceOf(PROJECT);
        vm.prank(alice);
        vault.distribute(IMD);
        assertEq(vault.buybackBucket(), 100e18);
        assertEq(MockERC20(IMD).balanceOf(PROJECT), projBefore + 100e18);
        assertEq(desk.topUpBasket(IMD), 100e18);
        assertEq(desk.freeBalance(IMD), 100e18);
        assertEq(desk.buybackBasket(IMD), 0);
        assertEq(MockERC20(IMD).balanceOf(address(vault)), 100e18);
        // repeat moves nothing
        vault.distribute(IMD);
        assertEq(vault.buybackBucket(), 100e18);
        assertEq(desk.topUpBasket(IMD), 100e18);
        assertEq(MockERC20(IMD).balanceOf(PROJECT), projBefore + 100e18);
        // 7 wei: 1 wei each, 3 wei stay undistributed and counted
        MockERC20(IMD).mint(address(vault), 7);
        vault.distribute(IMD);
        assertEq(vault.buybackBucket(), 100e18 + 1);
        assertEq(MockERC20(IMD).balanceOf(address(vault)) - vault.buybackBucket(), 3);
    }

    function test_distributeNotStockGoesToBurnerAndOthersRevert() public {
        _fundAndRegister();
        factory.releasePoolShare(address(token), alice);
        vm.prank(alice);
        token.transfer(address(vault), 10e18);
        vault.distribute(address(token));
        assertEq(token.balanceOf(address(burner)), 10e18);
        assertEq(token.balanceOf(address(vault)), 0);
        vm.expectRevert(FirmVault.UnsupportedToken.selector);
        vault.distribute(WETH);
    }

    function test_creditPathsAreGuarded() public {
        _fundAndRegister();
        vm.expectRevert(FirmVault.NotLpDesk.selector);
        vault.creditBuyback(1);
        vm.expectRevert(LpDesk.NotFirmVault.selector);
        desk.creditFromFirmVault(1, 1);
        // LpDesk's IMD buyback share: 100% to the bucket
        MockERC20(IMD).mint(address(vault), 5e18);
        vm.prank(address(desk));
        vault.creditBuyback(5e18);
        assertEq(vault.buybackBucket(), 5e18);
        vault.distribute(IMD); // nothing undistributed
        assertEq(vault.buybackBucket(), 5e18);
    }

    function test_buybackAccess() public {
        _fundAndRegister();
        MockERC20(IMD).mint(address(vault), 40e18);
        vault.distribute(IMD);
        vm.expectRevert(FirmVault.NotOperator.selector);
        vm.prank(alice);
        vault.buyback(1e18, 0);
        vm.expectRevert(FirmVault.AboveBucket.selector);
        vm.prank(DEV);
        vault.buyback(10e18 + 1, 0);
    }
}

contract LpDeskUnitTest is TestBase {
    function setUp() public {
        _etchImd();
        _fullSetup(address(0));
    }

    function test_burnOnlyOperatorOnlyFree() public {
        vm.expectRevert(LpDesk.NotOperator.selector);
        vm.prank(alice);
        desk.burn(1);
        vm.prank(DEV);
        desk.burn(1_000e18);
        assertEq(token.balanceOf(DEAD), 1_000e18);
        assertEq(desk.freeBalance(address(token)), 500_000_000e18 - 1_000e18);
        vm.expectRevert(LpDesk.AboveFreeBalance.selector);
        vm.prank(DEV);
        desk.burn(500_000_000e18);
    }

    function test_openGates() public {
        OpenParams memory p;
        p.asset = WETH;
        p.venue = FirmAddresses.UNI_V3_POSITION_MANAGER;
        p.feeTier = 3000;
        p.tickLower = -600;
        p.tickUpper = 600;
        p.sqrtPriceX96 = 79228162514264337593543950336;
        p.amount = 1e18;
        vm.expectRevert(LpDesk.NotOperator.selector);
        desk.open(p);
        p.asset = address(0xABCD);
        vm.expectRevert(LpDesk.UnlistedAsset.selector);
        vm.prank(DEV);
        desk.open(p);
        p.asset = WETH;
        p.venue = address(0xABCD);
        vm.expectRevert(LpDesk.UnlistedVenue.selector);
        vm.prank(DEV);
        desk.open(p);
        vm.warp(desk.bootstrapEnd());
        vm.expectRevert(LpDesk.BootstrapOver.selector);
        vm.prank(DEV);
        desk.open(p);
        vm.expectRevert(LpDesk.NotGovernor.selector);
        desk.openFromGovernor(p);
    }

    function test_operatorHandover() public {
        vm.prank(DEV);
        desk.setOperator(alice);
        assertEq(desk.operator(), alice);
        vm.expectRevert(LpDesk.NotOperator.selector);
        vm.prank(DEV);
        desk.burn(1);
    }

    function test_venueAndAssetListsAtDeploy() public view {
        Venue[] memory vs = guard.venues();
        assertEq(vs.length, 3);
        assertEq(vs[0].positionManager, FirmAddresses.UNI_V4_POSITION_MANAGER);
        assertTrue(vs[0].kind == VenueKind.V4);
        assertEq(vs[0].factory, FirmAddresses.UNI_V4_POOL_MANAGER);
        assertEq(vs[1].positionManager, FirmAddresses.UNI_V3_POSITION_MANAGER);
        assertEq(vs[1].factory, FirmAddresses.UNI_V3_FACTORY);
        assertEq(vs[2].positionManager, FirmAddresses.AERO_CL_POSITION_MANAGER);
        assertTrue(vs[2].kind == VenueKind.CL);
        address[] memory as_ = guard.assets();
        assertEq(as_.length, 13);
        assertEq(as_[0], IMD);
        assertEq(as_[1], WETH);
        assertEq(as_[2], FirmAddresses.USDG);
        assertEq(as_[3], FirmAddresses.CBBTC);
        assertEq(as_[4], FirmAddresses.GOOGL);
        assertEq(as_[12], FirmAddresses.PLTR);
        assertTrue(guard.isAsset(FirmAddresses.NVDA));
        assertFalse(guard.isAsset(address(token)));
    }
}

contract GovernanceTest is TestBase {
    function setUp() public {
        _etchImd();
        _fullSetup(address(0));
        // stakers get NOTSTOCK from the dev wallet's share
        vm.startPrank(DEV);
        token.transfer(alice, 10_000_000e18);
        token.transfer(bob, 10_000_000e18);
        vm.stopPrank();
    }

    function _stake(address who, uint256 amount) internal {
        vm.startPrank(who);
        token.approve(address(gov), amount);
        gov.stake(amount);
        vm.stopPrank();
    }

    function _pass(uint256 id) internal {
        vm.prank(alice);
        gov.vote(id, true);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        assertTrue(gov.state(id) == LpGovernor.State.Passed);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        assertTrue(gov.state(id) == LpGovernor.State.Executable);
    }

    function test_stakeUnstakeCheckpoints() public {
        // literal block numbers: via-IR re-evaluates a cached block.number after vm.roll
        vm.roll(100);
        _stake(alice, 100e18);
        assertEq(gov.staked(alice), 100e18);
        assertEq(gov.totalStaked(), 100e18);
        vm.roll(101);
        assertEq(gov.stakeAt(alice, 100), 100e18);
        assertEq(gov.stakeAt(alice, 99), 0);
        vm.prank(alice);
        gov.unstake(40e18);
        assertEq(gov.staked(alice), 60e18);
        assertEq(token.balanceOf(alice), 10_000_000e18 - 60e18);
        assertEq(gov.stakeAt(alice, 100), 100e18);
        assertEq(gov.stakeAt(alice, 101), 60e18);
        assertEq(gov.totalStakedAt(101), 60e18);
        assertEq(gov.totalStakedAt(100), 100e18);
        vm.expectRevert(LpGovernor.InsufficientStake.selector);
        vm.prank(alice);
        gov.unstake(61e18);
    }

    function test_thresholdAndOperatorException() public {
        _stake(alice, 1_000_000e18);
        _stake(bob, 999e18); // below 0.1%
        vm.roll(vm.getBlockNumber() + 1);
        vm.expectRevert(LpGovernor.BelowThreshold.selector);
        vm.prank(bob);
        gov.proposeAddAsset(address(0xA55E7));
        vm.expectRevert(LpGovernor.BelowThreshold.selector);
        vm.prank(makeAddr("nobody"));
        gov.proposeAddAsset(address(0xA55E7));
        vm.prank(DEV);
        uint256 id = gov.proposeAddAsset(address(0xA55E7));
        assertTrue(gov.getProposal(id).byOperator);
    }

    function test_addAssetLifecycleAndKindBlocking() public {
        _stake(alice, 1_000e18);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(alice);
        uint256 id = gov.proposeAddAsset(address(0xA55E7));
        // second non-operator proposal of the kind blocked; operator's not
        vm.expectRevert(LpGovernor.KindAlreadyOpen.selector);
        vm.prank(alice);
        gov.proposeAddAsset(address(0xA55E8));
        vm.prank(DEV);
        uint256 opId = gov.proposeAddAsset(address(0xA55E8));
        vm.expectRevert(LpGovernor.KindAlreadyOpen.selector);
        vm.prank(DEV);
        gov.proposeAddAsset(address(0xA55E9));
        // votes: once, with checkpointed weight
        vm.prank(alice);
        gov.vote(id, true);
        vm.expectRevert(LpGovernor.AlreadyVoted.selector);
        vm.prank(alice);
        gov.vote(id, true);
        vm.expectRevert(LpGovernor.NoWeight.selector);
        vm.prank(bob);
        gov.vote(id, true);
        vm.expectRevert(LpGovernor.WrongState.selector);
        gov.execute(id);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        assertTrue(gov.state(id) == LpGovernor.State.Passed);
        assertTrue(gov.state(opId) == LpGovernor.State.Failed); // nobody voted
        // failed one stops blocking
        vm.prank(DEV);
        gov.proposeAddAsset(address(0xA55E9));
        vm.expectRevert(LpGovernor.WrongState.selector);
        gov.execute(id);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        gov.execute(id);
        assertTrue(guard.isAsset(address(0xA55E7)));
        vm.expectRevert(LpGovernor.WrongState.selector);
        gov.execute(id);
        (uint256 ve, uint256 vt, uint256 ex) = gov.deadlines(id);
        assertEq(vt - ve, 2 days);
        assertEq(ex - vt, 259_200);
    }

    function test_quorumAndMajority() public {
        _stake(alice, 1_000e18);
        _stake(bob, 100_000e18);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(alice);
        uint256 id = gov.proposeAddAsset(address(0xA55E7));
        vm.prank(alice);
        gov.vote(id, true); // 1,000 of 101,000 staked < 3%
        vm.warp(vm.getBlockTimestamp() + 3 days);
        assertTrue(gov.state(id) == LpGovernor.State.Failed);
        vm.prank(alice);
        uint256 id2 = gov.proposeAddAsset(address(0xA55E7));
        vm.prank(alice);
        gov.vote(id2, true);
        vm.prank(bob);
        gov.vote(id2, false);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        assertTrue(gov.state(id2) == LpGovernor.State.Failed);
    }

    function test_vetoWindow() public {
        _stake(alice, 1_000e18);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(alice);
        uint256 id = gov.proposeAddAsset(address(0xA55E7));
        vm.prank(alice);
        gov.vote(id, true);
        vm.expectRevert(LpGovernor.WrongState.selector);
        vm.prank(DEV);
        gov.veto(id); // still voting
        vm.warp(vm.getBlockTimestamp() + 3 days + 1);
        vm.expectRevert(LpGovernor.NotOperator.selector);
        vm.prank(alice);
        gov.veto(id);
        vm.prank(DEV);
        gov.veto(id);
        assertTrue(gov.state(id) == LpGovernor.State.Vetoed);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.expectRevert(LpGovernor.WrongState.selector);
        gov.execute(id);
        // vetoed does not block a new one
        vm.prank(alice);
        uint256 id2 = gov.proposeAddAsset(address(0xA55E7));
        vm.prank(alice);
        gov.vote(id2, true);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        vm.expectRevert(LpGovernor.WrongState.selector);
        vm.prank(DEV);
        gov.veto(id2); // window over
        gov.execute(id2);
        assertTrue(guard.isAsset(address(0xA55E7)));
    }

    function test_expiry() public {
        _stake(alice, 1_000e18);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(alice);
        uint256 id = gov.proposeAddAsset(address(0xA55E7));
        _pass(id);
        vm.warp(vm.getBlockTimestamp() + 259_200);
        assertTrue(gov.state(id) == LpGovernor.State.Expired);
        vm.expectRevert(LpGovernor.WrongState.selector);
        gov.execute(id);
        vm.prank(alice);
        gov.proposeAddAsset(address(0xA55E7)); // expired does not block
    }

    function test_addAssetGate() public {
        _stake(alice, 1_000e18);
        vm.roll(vm.getBlockNumber() + 1);
        vm.startPrank(alice);
        vm.expectRevert(PriceGuard.ZeroAddress.selector);
        gov.proposeAddAsset(address(0));
        vm.expectRevert(PriceGuard.NotStockIsNotAnAsset.selector);
        gov.proposeAddAsset(address(token));
        vm.expectRevert(PriceGuard.AlreadyListed.selector);
        gov.proposeAddAsset(WETH);
        vm.stopPrank();
        vm.expectRevert(PriceGuard.NotLpDesk.selector);
        guard.addAsset(address(0xA55E7));
        vm.expectRevert(LpDesk.NotGovernor.selector);
        desk.addAssetFromGovernor(address(0xA55E7));
    }

    function test_addVenueGate() public {
        _stake(alice, 1_000e18);
        vm.roll(vm.getBlockNumber() + 1);
        vm.startPrank(alice);
        vm.expectRevert(PriceGuard.ZeroAddress.selector);
        gov.proposeAddVenue(address(0), VenueKind.V3);
        vm.expectRevert(PriceGuard.AlreadyListed.selector);
        gov.proposeAddVenue(FirmAddresses.UNI_V3_POSITION_MANAGER, VenueKind.V3);
        vm.expectRevert(PriceGuard.NoCode.selector);
        gov.proposeAddVenue(address(0xC0DE), VenueKind.V3);
        // factory() reverts
        vm.expectRevert(PriceGuard.NotAVenue.selector);
        gov.proposeAddVenue(address(token), VenueKind.V3);
        // factory without code
        FakeVenue noFactoryCode = new FakeVenue(address(0xF00), WETH);
        vm.expectRevert(PriceGuard.NotAVenue.selector);
        gov.proposeAddVenue(address(noFactoryCode), VenueKind.V3);
        // wrong WETH9
        FakeVenue wrongWeth = new FakeVenue(address(token), address(0xBAD));
        vm.expectRevert(PriceGuard.NotAVenue.selector);
        gov.proposeAddVenue(address(wrongWeth), VenueKind.V3);
        // V4 kind: poolManager() reverts
        vm.expectRevert(PriceGuard.NotAVenue.selector);
        gov.proposeAddVenue(address(wrongWeth), VenueKind.V4);
        vm.stopPrank();
    }

    /// @dev Audit finding 4cd6b95d (b): a fake manager that answers the spec's checks still needs a passed, unvetoed
    /// vote; the operator veto is what stops it.
    function test_fakeVenueNeedsVoteAndVetoStopsIt() public {
        FakeVenue fake = new FakeVenue(address(token), WETH);
        _stake(alice, 1_000e18);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(alice);
        uint256 id = gov.proposeAddVenue(address(fake), VenueKind.V3);
        vm.prank(alice);
        gov.vote(id, true);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.prank(DEV);
        gov.veto(id);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.expectRevert(LpGovernor.WrongState.selector);
        gov.execute(id);
        (, bool listed) = guard.venueOf(address(fake));
        assertFalse(listed);
    }

    function test_bridgeAddAndOut() public {
        MockOFTAdapter adapter = new MockOFTAdapter(address(token));
        MockOFTAdapter wrong = new MockOFTAdapter(IMD);
        address dst = makeAddr("dstLpDesk");
        _stake(alice, 1_000e18);
        vm.roll(vm.getBlockNumber() + 1);
        vm.expectRevert(LpGovernor.BadBridge.selector);
        vm.prank(alice);
        gov.proposeAddBridge(address(wrong), 30101, dst);
        vm.expectRevert(LpGovernor.UnknownBridge.selector);
        vm.prank(alice);
        gov.proposeBridgeOut(0, 1e18);
        vm.prank(alice);
        uint256 id = gov.proposeAddBridge(address(adapter), 30101, dst);
        _pass(id);
        gov.execute(id);
        assertEq(gov.bridgeCount(), 1);
        LpGovernor.BridgeRecord[] memory recs = gov.bridges();
        assertEq(recs[0].adapter, address(adapter));
        assertEq(recs[0].dstEid, 30101);
        assertEq(recs[0].dstLpDesk, dst);
        // BridgeOut above free NOTSTOCK reverts at creation
        vm.expectRevert(LpGovernor.AboveFreeBalance.selector);
        vm.prank(alice);
        gov.proposeBridgeOut(0, 500_000_001e18);
        vm.prank(alice);
        uint256 out = gov.proposeBridgeOut(0, 1_000_000e18);
        // without a passed vote
        vm.expectRevert(LpGovernor.WrongState.selector);
        gov.execute(out);
        _pass(out);
        uint256 deskBefore = token.balanceOf(address(desk));
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        gov.execute{value: 0.01 ether}(out);
        assertEq(token.balanceOf(address(adapter)), 1_000_000e18);
        assertEq(deskBefore - token.balanceOf(address(desk)), 1_000_000e18);
        assertEq(token.allowance(address(desk), address(adapter)), 0);
        assertEq(gov.bridgedOut(0), 1_000_000e18);
        (uint32 eid, bytes32 to, uint256 amt, uint256 minAmt,,,) = adapter.last();
        assertEq(eid, 30101);
        assertEq(to, bytes32(uint256(uint160(dst))));
        assertEq(amt, 1_000_000e18);
        assertEq(minAmt, 1_000_000e18);
        // direct calls to LpDesk's governance entries revert
        vm.expectRevert(LpDesk.NotGovernor.selector);
        desk.bridgeOutFromGovernor(address(adapter), 30101, dst, 1, bob);
    }

    /// @dev Audit finding 4cd6b95d (a): an adapter that moves the NOTSTOCK anywhere but into itself reverts.
    function test_evilAdapterCannotDrain() public {
        address thief = makeAddr("thief");
        EvilAdapter evil = new EvilAdapter(address(token), thief);
        _stake(alice, 1_000e18);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(alice);
        uint256 id = gov.proposeAddBridge(address(evil), 30101, makeAddr("dst"));
        _pass(id);
        gov.execute(id);
        vm.prank(alice);
        uint256 out = gov.proposeBridgeOut(0, 1_000_000e18);
        _pass(out);
        vm.expectRevert(LpDesk.BridgeMismatch.selector);
        gov.execute(out);
        assertEq(token.balanceOf(thief), 0);
        assertEq(token.balanceOf(address(desk)), 500_000_000e18);
    }

    function test_openPositionProposalAboveFreeReverts() public {
        _stake(alice, 1_000e18);
        vm.roll(vm.getBlockNumber() + 1);
        OpenParams memory p;
        p.asset = WETH;
        p.venue = FirmAddresses.UNI_V3_POSITION_MANAGER;
        p.tickLower = -600;
        p.tickUpper = 600;
        p.sqrtPriceX96 = 79228162514264337593543950336;
        p.amount = 500_000_001e18;
        vm.expectRevert(LpGovernor.AboveFreeBalance.selector);
        vm.prank(alice);
        gov.proposeOpenPosition(p);
    }
}

/// @notice LpDesk position flow offline on a mock V3 manager etched at the listed Uniswap v3 address, with a thin
/// pool: buyback partial fills (finding cfbdc8d3), moveLiquidity with the published liquidity (cd21873d), fees split
/// before a top-up (a34ecfd2), the asset-only proposal check (3d06756d) and a fake PoolManager (55ef5a4b).
contract VenueFlowTest is TestBase {
    uint160 constant ONE = 79228162514264337593543950336;
    address constant V3PM = FirmAddresses.UNI_V3_POSITION_MANAGER;
    MockV3Manager mgr;
    ThinPool pool;
    bool n0;

    function setUp() public {
        _etchImd();
        _fullSetup(address(0));
        MockERC20 w = new MockERC20("Wrapped Ether", "WETH", 18);
        vm.etch(WETH, address(w).code);
        MockV3Manager m = new MockV3Manager();
        vm.etch(V3PM, address(m).code);
        mgr = MockV3Manager(V3PM);
        n0 = address(token) < WETH;
        (address t0, address t1) = n0 ? (address(token), WETH) : (WETH, address(token));
        pool = new ThinPool(t0, t1);
        mgr.init(address(pool));
        vm.prank(DEV);
        token.transfer(address(pool), 1_000e18);
        MockERC20(WETH).mint(address(desk), 1_000e18);
    }

    function _params(int24 lo, int24 hi, uint256 amount) internal view returns (OpenParams memory p) {
        p = OpenParams(WETH, V3PM, 3000, 60, lo, hi, ONE, amount, 0, 0);
        uint160 sa = PoolMath.getSqrtRatioAtTick(lo);
        uint160 sb = PoolMath.getSqrtRatioAtTick(hi);
        uint128 l = n0
            ? PoolMath.liquidityFromAmount0(ONE, sa, sb, amount)
            : PoolMath.liquidityFromAmount1(ONE, sa, sb, amount);
        if (l == 0) {
            l = n0
                ? PoolMath.liquidityFromAmount1(ONE, sa, sb, amount)
                : PoolMath.liquidityFromAmount0(ONE, sa, sb, amount);
        }
        (uint256 a0, uint256 a1) = PoolMath.getAmountsForLiquidity(ONE, sa, sb, l);
        p.amount0Min = a0 * 995 / 1000;
        p.amount1Min = a1 * 995 / 1000;
    }

    function _open(int24 lo, int24 hi, uint256 amount) internal returns (uint256 id) {
        vm.prank(DEV);
        id = desk.open(_params(lo, hi, amount));
    }

    /// @dev Books `amount` of WETH fees on the position and collects them: the WETH basket gains a quarter.
    function _feesAndCollect(uint256 id, uint256 amount) internal {
        uint256 tokenId = desk.getPosition(id).tokenId;
        MockERC20(WETH).mint(address(mgr), amount);
        if (n0) mgr.addFees(tokenId, 0, amount);
        else mgr.addFees(tokenId, amount, 0);
        vm.prank(DEV);
        desk.collect(id);
    }

    function test_buybackPartialFillDebitsOnlyWhatWasSwapped() public {
        uint256 id = _open(-600, 600, 10e18);
        _feesAndCollect(id, 400e18);
        assertEq(desk.buybackBasket(WETH), 100e18);
        uint256 free = desk.freeBalance(WETH);
        uint256 deskWeth = IERC20(WETH).balanceOf(address(desk));
        uint256 dead = token.balanceOf(DEAD);
        vm.expectEmit(true, false, false, true);
        emit LpDesk.BuybackExecuted(id, 60e18, 30e18);
        vm.prank(DEV);
        uint256 out = desk.buyback(id, 100e18, 30e18);
        assertEq(out, 30e18);
        assertEq(token.balanceOf(DEAD) - dead, 30e18, "all NOTSTOCK out to the dead address");
        // the pool took 60e18: the basket keeps the other 40e18, nothing is stranded or re-labelled
        assertEq(desk.buybackBasket(WETH), 40e18, "basket debited by what was swapped");
        assertEq(deskWeth - IERC20(WETH).balanceOf(address(desk)), 60e18, "LpDesk paid exactly the swapped input");
        assertEq(IERC20(WETH).balanceOf(address(pool)), 60e18);
        assertEq(IERC20(WETH).balanceOf(address(v3)), 0, "module holds nothing");
        assertEq(desk.freeBalance(WETH), free, "free balance untouched");
        // minOut is checked against the actual output
        vm.expectRevert(LpDesk.BelowMinOut.selector);
        vm.prank(DEV);
        desk.buyback(id, 40e18, 12e18 + 1);
        vm.expectRevert(LpDesk.AboveBasket.selector);
        vm.prank(DEV);
        desk.buyback(id, 40e18 + 1, 0);
        vm.prank(DEV);
        desk.buyback(id, 40e18, 12e18);
        assertEq(desk.buybackBasket(WETH), 16e18);
        assertEq(IERC20(WETH).balanceOf(address(v3)), 0);
    }

    function test_moveLiquidityAcceptsPublishedLiquidity() public {
        uint256 a = _open(-600, 600, 10e18);
        uint256 b = _open(-1200, 1200, 10e18);
        uint128 la = desk.positionLiquidity(a);
        uint128 lb = desk.positionLiquidity(b);
        assertGt(la, 1);
        // the published figure moves the whole position even though the fee poke burns 1 wei first
        vm.prank(DEV);
        desk.moveLiquidity(a, b, la, 0, 0);
        assertEq(desk.positionLiquidity(a), 0);
        assertGt(desk.positionLiquidity(b), lb);
        assertEq(IERC20(WETH).balanceOf(address(v3)), 0);
        assertEq(token.balanceOf(address(v3)), 0);
    }

    function test_moveAndTopUpCollectPendingFeesFirst() public {
        uint256 a = _open(-600, 600, 10e18);
        uint256 b = _open(-1200, 1200, 10e18);
        // an asset-only range (entirely on the WETH side of 1:1)
        uint256 c = n0 ? _open(-6000, -60, 1e18) : _open(60, 6000, 1e18);
        _feesAndCollect(c, 400e18); // top-up basket 100e18
        // pending fees on the destination of a move and on the topped-up position are split in the same call
        MockERC20(WETH).mint(address(mgr), 80e18);
        mgr.addFees(desk.getPosition(b).tokenId, n0 ? 0 : 40e18, n0 ? 40e18 : 0);
        mgr.addFees(desk.getPosition(c).tokenId, n0 ? 0 : 40e18, n0 ? 40e18 : 0);
        uint256 proj = IERC20(WETH).balanceOf(PROJECT);
        uint128 la = desk.positionLiquidity(a);
        vm.prank(DEV);
        desk.moveLiquidity(a, b, la, 0, 0);
        assertEq(IERC20(WETH).balanceOf(PROJECT) - proj, 10e18, "destination fees split by the move");
        assertEq(desk.topUpBasket(WETH), 110e18);
        proj = IERC20(WETH).balanceOf(PROJECT);
        uint160 sa = PoolMath.getSqrtRatioAtTick(desk.getPosition(c).tickLower);
        uint160 sb = PoolMath.getSqrtRatioAtTick(desk.getPosition(c).tickUpper);
        uint128 expectL = n0
            ? PoolMath.liquidityFromAmount1(ONE, sa, sb, 100e18)
            : PoolMath.liquidityFromAmount0(ONE, sa, sb, 100e18);
        uint128 before = desk.positionLiquidity(c);
        vm.prank(DEV);
        desk.increaseLiquidity(c, 100e18, ONE, expectL * 995 / 1000);
        assertEq(IERC20(WETH).balanceOf(PROJECT) - proj, 10e18, "position fees split by the top-up");
        assertEq(desk.topUpBasket(WETH), 20e18, "basket paid the whole top-up, fees added their quarter");
        assertGe(desk.positionLiquidity(c) - before, expectL * 995 / 1000);
        assertEq(IERC20(WETH).balanceOf(address(v3)), 0);
    }

    function test_openPositionProposalChecksTheAmountToken() public {
        vm.prank(DEV);
        token.transfer(alice, 10_000_000e18);
        vm.startPrank(alice);
        token.approve(address(gov), 1_000e18);
        gov.stake(1_000e18);
        vm.stopPrank();
        vm.roll(vm.getBlockNumber() + 1);
        // LpDesk holds 1 000 WETH free: an asset-only range for more reverts at creation, for less is created
        OpenParams memory p = n0 ? _params(-6000, -60, 1_000e18 + 1) : _params(60, 6000, 1_000e18 + 1);
        vm.expectRevert(LpGovernor.AboveFreeBalance.selector);
        vm.prank(alice);
        gov.proposeOpenPosition(p);
        p.amount = 1_000e18;
        vm.prank(alice);
        gov.proposeOpenPosition(p);
        // a NOTSTOCK-denominated range is still checked against free NOTSTOCK
        p = _params(-600, 600, 500_000_000e18 + 1);
        vm.expectRevert(LpGovernor.AboveFreeBalance.selector);
        vm.prank(DEV);
        gov.proposeOpenPosition(p);
    }

    function test_fakePoolManagerCannotDriveUnlockCallback() public {
        vm.prank(DEV);
        token.transfer(address(v4), 1e18);
        FakePoolManager fake = new FakePoolManager();
        PoolKey memory key = PoolKey(address(token), address(0xBEEF), 3000, 60, address(0));
        bytes memory data = abi.encode(key, address(token), uint256(1e18));
        vm.expectRevert(abi.encodeWithSelector(VenueV4.NotPoolManager.selector));
        fake.attack(address(v4), data);
        vm.expectRevert(VenueV4.NotPoolManager.selector);
        v4.unlockCallback(data);
        assertEq(token.balanceOf(address(v4)), 1e18, "module balance untouched by a fake PoolManager");
    }
}
