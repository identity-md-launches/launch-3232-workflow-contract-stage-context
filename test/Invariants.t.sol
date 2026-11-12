// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "./vendor/forge-std/src/Test.sol";
import {TestBase} from "./TestBase.sol";
import {MockERC20} from "./Mocks.sol";
import {MockPoolManager} from "./Adversarial.t.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LpDesk} from "../src/LpDesk.sol";
import {FirmVault} from "../src/FirmVault.sol";
import {Burner} from "../src/Burner.sol";
import {LpGovernor} from "../src/modules/LpGovernor.sol";
import {FirmAddresses} from "../src/FirmAddresses.sol";

// =====================================================================================================================
// LaunchToken: fixed supply over random transfers, approvals and transferFroms
// =====================================================================================================================

contract TokenHandler is Test {
    LaunchToken public t;
    address[4] public actors;

    constructor() {
        t = new LaunchToken();
        actors = [makeAddr("t0"), makeAddr("t1"), makeAddr("t2"), makeAddr("t3")];
        for (uint256 i; i < 4; ++i) {
            t.transfer(actors[i], 250_000_000e18);
        }
    }

    function transfer(uint256 from, uint256 to, uint256 amount) external {
        address f = actors[from % 4];
        amount = bound(amount, 0, t.balanceOf(f));
        vm.prank(f);
        t.transfer(actors[to % 4], amount);
    }

    function approve(uint256 owner, uint256 spender, uint256 amount) external {
        vm.prank(actors[owner % 4]);
        t.approve(actors[spender % 4], amount);
    }

    function transferFrom(uint256 spender, uint256 from, uint256 to, uint256 amount) external {
        address s = actors[spender % 4];
        address f = actors[from % 4];
        uint256 a = t.allowance(f, s);
        uint256 b = t.balanceOf(f);
        amount = bound(amount, 0, a < b ? a : b);
        vm.prank(s);
        t.transferFrom(f, actors[to % 4], amount);
        if (a != type(uint256).max) assertEq(t.allowance(f, s), a - amount, "allowance not reduced by amount");
    }

    function transferTooMuch(uint256 from, uint256 extra) external {
        address f = actors[from % 4];
        extra = bound(extra, 1, 1e30);
        vm.prank(f);
        vm.expectRevert(LaunchToken.InsufficientBalance.selector);
        t.transfer(actors[(from + 1) % 4], t.balanceOf(f) + extra);
    }

    function sumBalances() external view returns (uint256 s) {
        for (uint256 i; i < 4; ++i) {
            s += t.balanceOf(actors[i]);
        }
        s += t.balanceOf(address(this));
    }
}

contract TokenInvariantTest is Test {
    TokenHandler h;

    function setUp() public {
        h = new TokenHandler();
        targetContract(address(h));
    }

    /// forge-config: default.invariant.runs = 64
    function invariant_supplyFixedAndFullyHeld() public view {
        assertEq(h.t().totalSupply(), 1_000_000_000e18);
        assertEq(h.sumBalances(), 1_000_000_000e18);
    }
}

// =====================================================================================================================
// LpGovernor: staked NOTSTOCK is exactly what the stakers are owed; checkpoints never rewrite history
// =====================================================================================================================

contract StakeHandler is Test {
    LpGovernor public gov;
    LaunchToken public token;
    address[3] public actors;
    uint256 public constant START = 1_000_000e18;

    // A recorded past block and each actor's (and the total) stake at its end.
    uint256 public snapBlock;
    uint256[3] public snapStake;
    uint256 public snapTotal;
    bool public hasSnap;

    constructor(LpGovernor g, LaunchToken t, address[3] memory a) {
        gov = g;
        token = t;
        actors = a;
    }

    function stake(uint256 who, uint256 amount) external {
        address a = actors[who % 3];
        uint256 bal = token.balanceOf(a);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.startPrank(a);
        token.approve(address(gov), amount);
        gov.stake(amount);
        vm.stopPrank();
    }

    function unstake(uint256 who, uint256 amount) external {
        address a = actors[who % 3];
        uint256 s = gov.staked(a);
        if (s == 0) return;
        amount = bound(amount, 1, s);
        vm.prank(a);
        gov.unstake(amount);
    }

    function unstakeTooMuch(uint256 who, uint256 extra) external {
        address a = actors[who % 3];
        extra = bound(extra, 1, 1e30);
        uint256 s = gov.staked(a);
        vm.prank(a);
        vm.expectRevert(LpGovernor.InsufficientStake.selector);
        gov.unstake(s + extra);
    }

    function nextBlock(uint256 n) external {
        n = bound(n, 1, 20);
        vm.roll(block.number + n);
        vm.warp(block.timestamp + n * 2);
    }

    /// @dev Records the current values, then closes the block so they become history.
    function snapshot() external {
        snapBlock = block.number;
        for (uint256 i; i < 3; ++i) {
            snapStake[i] = gov.staked(actors[i]);
        }
        snapTotal = gov.totalStaked();
        hasSnap = true;
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 2);
    }
}

contract StakingInvariantTest is TestBase {
    StakeHandler h;
    address[3] actors;

    function setUp() public {
        _etchImd();
        _fullSetup(address(0));
        actors = [makeAddr("s0"), makeAddr("s1"), makeAddr("s2")];
        vm.startPrank(DEV);
        for (uint256 i; i < 3; ++i) {
            token.transfer(actors[i], 1_000_000e18);
        }
        vm.stopPrank();
        h = new StakeHandler(gov, token, actors);
        targetContract(address(h));
    }

    /// forge-config: default.invariant.runs = 64
    function invariant_heldEqualsOwed() public view {
        uint256 sum;
        for (uint256 i; i < 3; ++i) {
            uint256 s = gov.staked(actors[i]);
            sum += s;
            // nobody gains or loses: wallet + stake is what they started with
            assertEq(token.balanceOf(actors[i]) + s, 1_000_000e18, "staker balance not conserved");
            // the current checkpoint matches the live value
            assertEq(gov.stakeAt(actors[i], block.number), s, "checkpoint != staked");
        }
        assertEq(gov.totalStaked(), sum, "total != sum of stakes");
        assertEq(token.balanceOf(address(gov)), sum, "governor holds != owed");
        assertEq(gov.totalStakedAt(block.number), sum, "total checkpoint != total");
    }

    /// forge-config: default.invariant.runs = 64
    function invariant_pastCheckpointsNeverChange() public view {
        if (!h.hasSnap()) return;
        uint256 b = h.snapBlock();
        uint256 sum;
        for (uint256 i; i < 3; ++i) {
            assertEq(gov.stakeAt(actors[i], b), h.snapStake(i), "past stake rewritten");
            sum += h.snapStake(i);
        }
        assertEq(gov.totalStakedAt(b), h.snapTotal(), "past total rewritten");
        assertEq(h.snapTotal(), sum);
    }
}

// =====================================================================================================================
// FirmVault + LpDesk IMD accounting: every IMD received is in exactly one place; the bucket only falls by buybacks
// =====================================================================================================================

contract VaultHandler is Test {
    FirmVault public vault;
    LpDesk public desk;
    LaunchToken public token;
    Burner public burner;
    MockPoolManager public pm;
    address public constant IMD = FirmAddresses.IMD;
    address public constant PROJECT = FirmAddresses.PROJECT_WALLET;
    address public constant DEAD = FirmAddresses.DEAD;
    address public constant DEV = FirmAddresses.DEV_WALLET;

    uint256 public ghostDonatedImd;
    uint256 public ghostBucket;
    uint256 public ghostProject;
    uint256 public ghostTopUp;
    uint256 public ghostDeskFree;
    uint256 public ghostSpentImd;
    uint256 public ghostBoughtOut;
    uint256 public ghostBurnedViaBurner;
    uint256 public ghostNotStockToVault;
    uint256 public violations;
    uint256 public buybacks;

    constructor(FirmVault v, LpDesk d, LaunchToken t, MockPoolManager p) {
        vault = v;
        desk = d;
        token = t;
        burner = Burner(d.burner());
        pm = p;
    }

    function donateImd(uint256 amount) external {
        amount = bound(amount, 0, 1e27);
        MockERC20(IMD).mint(address(vault), amount);
        ghostDonatedImd += amount;
    }

    function distributeImd(uint256 callerSeed) external {
        uint256 undistributed = MockERC20(IMD).balanceOf(address(vault)) - ghostBucket;
        uint256 q = undistributed / 4;
        vm.prank(address(uint160(bound(callerSeed, 1, type(uint160).max))));
        vault.distribute(IMD);
        ghostBucket += q;
        ghostProject += q;
        ghostTopUp += q;
        ghostDeskFree += q;
        // a repeat with nothing new moves nothing
        uint256 vb = MockERC20(IMD).balanceOf(address(vault));
        uint256 pb = MockERC20(IMD).balanceOf(PROJECT);
        vault.distribute(IMD);
        if (MockERC20(IMD).balanceOf(address(vault)) != vb || MockERC20(IMD).balanceOf(PROJECT) != pb) violations++;
    }

    function donateNotStock(uint256 amount) external {
        amount = bound(amount, 0, token.balanceOf(address(this)));
        token.transfer(address(vault), amount);
        ghostNotStockToVault += amount;
    }

    function distributeNotStock() external {
        vault.distribute(address(token));
    }

    function burn() external {
        uint256 b = token.balanceOf(address(burner));
        if (b == 0) return;
        burner.burn();
        ghostBurnedViaBurner += b;
    }

    function buyback(uint256 amount, uint256 rate) external {
        uint256 bucket = vault.buybackBucket();
        if (bucket == 0) return;
        amount = bound(amount, 1, bucket);
        rate = bound(rate, 0, 10e18);
        pm.setRate(rate);
        uint256 expectedOut = amount * rate / 1e18;
        if (expectedOut > token.balanceOf(address(pm))) return;
        vm.prank(desk.operator());
        uint256 out = vault.buyback(amount, expectedOut);
        if (out != expectedOut) violations++;
        ghostBucket -= amount;
        ghostSpentImd += amount;
        ghostBoughtOut += out;
        buybacks++;
    }

    function buybackAboveBucket(uint256 extra) external {
        extra = bound(extra, 1, 1e27);
        uint256 bucket = vault.buybackBucket();
        vm.prank(desk.operator());
        try vault.buyback(bucket + extra, 0) {
            violations++;
        } catch {}
    }

    function buybackByOther(address caller, uint256 amount) external {
        if (caller == desk.operator()) return;
        amount = bound(amount, 0, vault.buybackBucket());
        vm.prank(caller);
        try vault.buyback(amount, 0) {
            violations++;
        } catch {}
    }

    function forgeCredits(address caller, uint256 amount) external {
        amount = bound(amount, 0, 1e24);
        if (caller != address(desk)) {
            vm.prank(caller);
            try vault.creditBuyback(amount) {
                violations++;
            } catch {}
        }
        if (caller != address(vault)) {
            vm.prank(caller);
            try desk.creditFromFirmVault(amount, amount) {
                violations++;
            } catch {}
        }
    }
}

contract VaultInvariantTest is TestBase {
    VaultHandler h;
    MockPoolManager pm;
    uint256 deskNotStockStart;

    function setUp() public {
        _etchImd();
        _fullSetup(address(0));
        MockPoolManager m = new MockPoolManager();
        vm.etch(FirmAddresses.UNI_V4_POOL_MANAGER, address(m).code);
        pm = MockPoolManager(FirmAddresses.UNI_V4_POOL_MANAGER);
        h = new VaultHandler(vault, desk, token, pm);
        vm.startPrank(DEV);
        token.transfer(address(pm), 50_000_000e18);
        token.transfer(address(h), 10_000_000e18);
        vm.stopPrank();
        deskNotStockStart = token.balanceOf(address(desk));
        targetContract(address(h));
    }

    /// forge-config: default.invariant.runs = 64
    function invariant_imdConservedAndBucketed() public view {
        uint256 vaultImd = MockERC20(IMD).balanceOf(address(vault));
        uint256 deskImd = MockERC20(IMD).balanceOf(address(desk));
        uint256 projImd = MockERC20(IMD).balanceOf(PROJECT);
        uint256 pmImd = MockERC20(IMD).balanceOf(address(pm));
        assertEq(vaultImd + deskImd + projImd + pmImd, h.ghostDonatedImd(), "IMD created or lost");
        assertEq(vault.buybackBucket(), h.ghostBucket(), "bucket moved other than by distribute/buyback");
        assertGe(vaultImd, vault.buybackBucket(), "bucket not backed");
        assertEq(projImd, h.ghostProject(), "project wallet share");
        assertEq(desk.topUpBasket(IMD), h.ghostTopUp(), "top-up basket");
        assertEq(desk.freeBalance(IMD), h.ghostDeskFree(), "free IMD");
        assertEq(desk.buybackBasket(IMD), 0, "IMD never enters LpDesk's buyback basket");
        assertEq(pmImd, h.ghostSpentImd(), "IMD left other than by buyback");
        // every distribute(IMD) gives the four destinations equal shares
        assertEq(h.ghostProject(), h.ghostTopUp());
        assertEq(h.ghostTopUp(), h.ghostDeskFree());
        assertEq(h.violations(), 0, "a forbidden call succeeded or a repeat moved funds");
    }

    /// forge-config: default.invariant.runs = 64
    function invariant_notStockOnlyToBurnerAndDead() public view {
        assertEq(token.totalSupply(), 1_000_000_000e18);
        // NOTSTOCK sent to FirmVault ends in the vault, Burner or dead only
        uint256 inFlight = token.balanceOf(address(vault)) + token.balanceOf(address(burner));
        assertEq(inFlight + h.ghostBurnedViaBurner(), h.ghostNotStockToVault(), "vault NOTSTOCK leaked");
        assertEq(token.balanceOf(DEAD), h.ghostBurnedViaBurner() + h.ghostBoughtOut(), "dead balance");
        assertEq(token.balanceOf(address(desk)), deskNotStockStart, "LpDesk NOTSTOCK touched");
    }
}
