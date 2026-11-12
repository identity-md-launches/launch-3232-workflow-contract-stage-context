# Adaptations

Each entry is a change the launch rules or a reproduced audit finding required. Nothing else in SPEC.md was changed:
no rate, recipient, limit or split differs, and no owner power, pause, upgrade or minting was added.

## 1. Registration compares the pool fee with the constant 12500, not with the live `fees().poolFee()`

Audit finding 6331aad7 (medium), reproduced: the live LaunchFees contract at the factory's `fees()` is owned by an
outside wallet and exposes `setPoolFee(uint24)`. The launch's pool fee is fixed at creation, so a later change by that
owner would make `registerNotStock` revert forever and lock GenesisSplitter's 600,000,000 NOTSTOCK and every FirmVault
fee. SPEC.md section 0 forbids a rule that relies on an outside protocol owner's action, and section 2b gives the fee in
parentheses as 12500. `PriceGuard.registerNotStock` therefore checks `key.fee == LAUNCH_POOL_FEE (12500)` and
`key.hooks == factory.poolHook()`. Test: `RegistrationTest.test_liveFeeChangeDoesNotBlockRegistration`.

## 2. GenesisSplitter sends `balance - devShare` to LpDesk

Audit finding 6e61c2a0 (low), reproduced: `50/60` and `10/60` each rounded down leave dust locked when the balance
is not a multiple of 6. The dev share is `balance * 10 / 60`; LpDesk receives the rest. The exact 600,000,000 case is
unchanged (500,000,000 / 100,000,000). Test: `SplitterBurnerTest.test_splitLeavesNoDust`.

## 3. BridgeOut checks that the NOTSTOCK landed in the adapter

Audit finding 4cd6b95d (medium), reproduced for part (a): an adapter whose `token()` returns NOTSTOCK but whose
`send()` moves the tokens elsewhere passed every check. `LpDesk.bridgeOutFromGovernor` now reverts with
`BridgeMismatch` unless LpDesk's balance fell by exactly `amount` and the adapter's balance rose by exactly `amount`,
which is what a LayerZero OFT adapter (a lockbox) does and what a thief contract cannot do while stealing. Test:
`GovernanceTest.test_evilAdapterCannotDrain`.

Part (b), AddVenue: SPEC.md 2b fixes the AddVenue checks exactly (code, `factory()` with code, `WETH9()` equal to WETH;
`poolManager()` with code for V4), so they were not tightened. A fake manager that passes them still needs a passed,
unvetoed vote; the operator's 2-day veto is the protection, and `GovernanceTest.test_fakeVenueNeedsVoteAndVetoStopsIt`
pins that down. Part (c), the proposal threshold: SPEC.md says "a holder with a staked balance of at least 0.1%", and
a zero stake is read as no staked balance, so a non-operator proposer must hold a nonzero stake; the quorum base stays
the checkpointed total staked, as written. These two residual risks are documented in the README under Trust.

## 4. Launch rehearsal through the live factory's `launch()`

The live ProjectFactory's `launch(...)` ABI is not published on chain or in this repository and the explorer refused the
source request, so the rehearsal in `test/Fork.t.sol` runs through `test/Mocks.sol:MockFactory`, which mirrors the
live factory's read surface exactly as observed on chain 4663 (`positionOf(uint64)` returning the pool key, range and
requester; `registry().artifactsOf(uint64)` returning `(bytes32 kind, bytes32 name, address)` records; `fees()`,
`poolHook()`, `setRequester(uint64,address)` reverting `NotRequester` for anyone but the requester). The gas of
deploying LpDesk and FirmVault is asserted under 16,777,216 in `test_launchRehearsalAccounting`. The real launch is
IMD's deployer's step; the launch gas is reported by that step.

## 5. "At least 99.5%" is compared with the rounded-down 99.5%

`amount0Min`, `amount1Min` and `minLiquidity` must be at least 99.5% of the amount or liquidity the given price
implies. The contract compares against `amount * 995 / 1000` (rounded down), the same value an executed OpenPosition
sets, so a minimum computed as floor(99.5%) by the operator or the website is accepted and one a single wei below it is
refused. An exact rational comparison rejected every minimum whose 99.5% was not a whole number of wei. No rate changed.

## 6. Fork tests skip off the fork

SPEC.md 6 asks for every fork test to run under `--fork-url`. The independent verifier runs with no network, so each
fork test calls `vm.skip(true)` when `block.chainid != 4663` and runs fully with `--fork-url`.
