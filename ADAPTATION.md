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

## 7. Buyback partial fills debit the basket by what the pool took

Review finding cfbdc8d3 (medium), reproduced with the reviewer's proof: a v3/CL pool whose liquidity runs out stops
at the price limit with input left over and asks the callback only for what it consumed; VenueV3 kept the rest, and
LpDesk had already debited the whole amount from the buyback basket. Now both modules return every untaken input to
LpDesk in the same call (VenueV4 settles only the consumed delta instead of reverting `CurrencyNotSettled`), and
`LpDesk.buyback` debits `buybackBasket[asset]` by its own balance change of the call, reverting `BuybackMismatch` if
that exceeds `amount`. `BuybackExecuted` reports the swapped input. Still exact input: a pool with enough liquidity
takes the whole amount, as before. Tests: `VenueFlowTest.test_buybackPartialFillDebitsOnlyWhatWasSwapped` (offline,
thin pool), `ForkTest.test_partialFillBuybackV3` and `test_partialFillBuybackV4` (live pools).

## 8. Pending fees are collected and split before a top-up or a move into a position

Review finding a34ecfd2 (medium), reproduced on the Robinhood Chain fork: v4's `modifyLiquidity` credits the
position's pending fees on an increase too, and VenueV4 settles with `OPEN_DELTA`, so a pending fee paid for part of
the deposit and came back to LpDesk unsplit, and a pending fee larger than the debt made the call revert
`DeltaNotNegative`. `LpDesk.increaseLiquidity` now calls `_collect(id)` first and `moveLiquidity` calls `_collect(toId)`
before the increase (the source was already collected), so every fee is split as SPEC.md section 2 says and the top-up
basket pays for exactly what the position takes. Tests: `ForkTest.test_v4PendingFeesAreSplitBeforeMoveAndTopUp`,
`VenueFlowTest.test_moveAndTopUpCollectPendingFeesFirst`.

## 9. VenueV4.unlockCallback answers only the PoolManager it is inside an unlock of

Review finding 55ef5a4b (low), reproduced: the callback took the PoolManager from its own calldata. It now checks
`msg.sender` against `_pendingPoolManager`, set by `swapExactInToDead` before `unlock` and cleared after, as VenueV3
does with `_pendingPool`. Test: `VenueFlowTest.test_fakePoolManagerCannotDriveUnlockCallback`.

## 10. moveLiquidity moves at most what the source holds after the fee poke

Review finding cd21873d (low), reproduced: VenueV3.collectFees burns 1 wei of liquidity, so a move with the published
figure reverted in the position manager. `moveLiquidity` re-reads the source's liquidity after the collect and caps the
request to it. Tests: `ForkTest.test_v3MoveWithPublishedLiquidity`, `VenueFlowTest.test_moveLiquidityAcceptsPublishedLiquidity`.

## 11. VenueV4.collectFees skips an empty position

Review finding 0e020971 (low), reproduced on the fork: the PoolManager reverts `CannotUpdateEmptyPosition` on a
zero-liquidity poke, so a v4 position emptied by a move could never be collected or closed. `collectFees` returns
(0, 0) when `getPositionLiquidity` is 0 (v4 has credited every fee by then), as VenueV3 already did. Test:
`ForkTest.test_v4EmptiedPositionCanBeClosed`.

## 12. proposeOpenPosition checks the free balance of the token `amount` denominates

Review finding 3d06756d (low), reproduced: `amount` is the asset when the range takes no NOTSTOCK at the given price
(LpDesk reads it so at execute), but the creation check always compared with free NOTSTOCK. LpGovernor now derives the
token the same way. Test: `VenueFlowTest.test_openPositionProposalChecksTheAmountToken`.

## 13. Collected V3/CL fees are LpDesk's balance change

Review finding 9a74eb7d (info): VenueV3 reported the position manager's collect figure; SPEC.md section 2 defines the
split amount as the balance change of the call. VenueV3.collectFees now measures LpDesk's balance before and after,
less the poke's principal, as VenueV4 does. Equal for every listed asset; differs only for a fee-on-transfer asset.

## 14. within0_5Percent compares sqrt prices

Review finding 5395cffb (info): squaring the sqrt prices floored both to 0 below 2^48, so the band test passed every
pair there. The check is now `sqrt(0.995) <= actual/given <= sqrt(1.005)` on the sqrt prices with 9-digit constants,
full resolution at any price, no overflow. Same rate. Test: `PoolMathTest.test_priceBand`.

## 15. Trust notes recorded

Review findings 026f1db4 and 9aae86d1 (info) are the specified design: the one-step operator handover and the
governance slot and quorum rules of SPEC.md 2a. They are stated in the README under Trust and assumptions; no code
changed.
