# Not Firm: notSTOCK ($NOTSTOCK)

Don't work for the firm. Let the firm work for you.

Token name "Not Firm", symbol NOTSTOCK, on Robinhood Chain (chain 4663), paired with IMD. 18 decimals,
1 000 000 000 NOTSTOCK, minted once at launch. The binding rules are in SPEC.md; the cash model is in FINMODEL.md;
every change a launch rule or a reproduced audit finding required is in ADAPTATION.md.

## Tokenomics (1 000 000 000 NOTSTOCK)

- 30% seeded into the NOTSTOCK/IMD pool by the launch factory (fee 1.25%, opening cap 2 500 IMD, set by the launch).
- 10% to the swarm, by the launch policy (MerkleDistributor).
- 10% to the dev wallet 0x8Ad18E99F4C8d8406f9Ba8899CF308000518A981, via GenesisSplitter (10/60 of its balance).
- 50% to LpDesk, via GenesisSplitter (50/60 of its balance), as one free NOTSTOCK balance.

The 60% leaves the factory to the project wallet 0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C, which transfers exactly
600 000 000 NOTSTOCK to GenesisSplitter after the launch.

## Contracts (src/)

| Contract | Constructor | Role |
| --- | --- | --- |
| `LaunchToken` | none | NOTSTOCK: fixed supply, 18 decimals, plain transfers. No owner, mint, burn, fee, pause or upgrade. |
| `LpDesk` | `($token, operator = dev wallet, project wallet)` | Liquidity desk (SPEC 2). Creates `Burner` in its constructor; predicts and later deploys its modules by CREATE2. |
| `FirmVault` | `(project wallet, $contract:LpDesk)` | Pool fee recipient (SPEC 2.2, 5): `distribute(token)` by anyone; `buyback(amount, minOut)` by LpDesk's operator. |
| `GenesisSplitter` | `($contract:LpDesk, dev wallet)` | `split()` once, after registration: 10/60 to the dev wallet, the rest to LpDesk. |
| `Burner` | created by LpDesk | `burn()` by anyone sends its whole NOTSTOCK balance to 0x000000000000000000000000000000000000dEaD. |

Modules, deployed after launch by anyone with `LpDesk.deployModule(kind, creationCode)` (kinds 0..3), each at the
address LpDesk predicted, each with its creation code hash fixed as a constant in LpDesk:

| Kind | Module | Holds |
| --- | --- | --- |
| 0 | `LpGovernor` | staking, proposals, votes, veto, execute, bridge records (SPEC 2a) |
| 1 | `PriceGuard` | venue list, asset list, NOTSTOCK registration (SPEC 2b) |
| 2 | `VenueV3` | V3 and CL venue code and their buyback swap |
| 3 | `VenueV4` | Uniswap v4 venue code and its buyback swap |

`script/DeployModules.s.sol` calls `deployModule` for every module not yet deployed (`LP_DESK` in the environment
when broadcasting; tests call `deployAll(desk)` directly). The verification input of each module is its file under
`src/modules/`, solc 0.8.26, via_ir, optimizer runs 1, evm cancun, `bytecode_hash = "none"`, no constructor argument.

Runtime sizes of this build: LpDesk 19.1 KB (limit 24 576 B), FirmVault 4.4 KB (10 240), GenesisSplitter 1.1 KB
(2 048), Burner 647 B (1 024), every module under 24 576 B, LpDesk initcode 20.9 KB (49 152).

## After launch (in this order; the website's Setup section offers each step)

1. `LpDesk.deployModule` for kinds 0, 1, 2, 3 (anyone), or run `script/DeployModules.s.sol`.
2. The project wallet transfers exactly 600 000 000 NOTSTOCK to GenesisSplitter.
3. The project wallet calls the launch factory's `setRequester(launchNumber, FirmVault)`.
4. Anyone calls `PriceGuard.registerNotStock(launchNumber)`. It checks the factory's own record: a pool of NOTSTOCK and
   IMD at fee 12500 with the factory's `poolHook()`, the token's name, symbol and supply, the registry artifacts named
   `LpDesk` (this LpDesk) and `GenesisSplitter`, at least 600 000 000 NOTSTOCK in GenesisSplitter, and a fee recipient
   whose `lpDesk()` is this LpDesk. It stores the pool key and FirmVault and starts LpDesk's 7-day bootstrap.
5. Anyone calls `GenesisSplitter.split()`: LpDesk 500 000 000, dev wallet 100 000 000, GenesisSplitter 0.

Nothing here needs an action by anyone outside the launch's wallets and contracts, and no value is set after launch
other than through these calls.

## Fee rule

- Every NOTSTOCK fee (FirmVault or LpDesk) goes to Burner; `burn()` by anyone sends it to the dead address.
- Every other fee token: 25% buyback and burn (IMD into FirmVault's buyback bucket; any other asset into LpDesk's buyback
  basket of that asset), 25% project wallet, 25% LpDesk top-up basket of that token, 25% LpDesk free balance.
- FirmVault `distribute(IMD)` splits the undistributed IMD the same way (its buyback bucket, the project wallet, LpDesk's
  IMD top-up basket, LpDesk's free IMD); up to 3 wei of rounding stay undistributed for the next call.
- Buybacks: FirmVault `buyback(amount, minOut)` swaps bucket IMD in the registered NOTSTOCK/IMD pool; LpDesk
  `buyback(positionId, amount, minOut)` swaps an asset's buyback basket in that position's own pool (never IMD). All
  NOTSTOCK out goes to the dead address in the same call. `minOut` is manual slippage set by the operator.

## LpDesk rules in short

- Positions only on listed venues: Uniswap v4 (PositionManager 0x58daec3116aae6D93017bAAea7749052E8a04fA7), Uniswap v3
  (0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3) and Aero Slipstream (0x4857DB576eE0e45F10525eC59527BfD10beeC60b) at
  deploy; more only by an executed AddVenue; never removed. Only with listed assets (IMD, WETH, USDG, cbBTC and the nine
  Robinhood stock tokens of SPEC 2b at deploy; more only by AddAsset).
- Bootstrap: 604 800 seconds from registration, the operator opens positions directly. After it, only an executed
  OpenPosition proposal opens one. The operator may propose too.
- The operator alone, at any time: collect, shift range, move liquidity between positions of the same pair, close,
  increaseLiquidity (asset only, from the top-up basket), buyback (from the buyback basket), burn free NOTSTOCK,
  hand over the operator role. Shift and close take manual minimum outs; open and top-up need minimums of at least
  99.5% of the amounts the given price implies and revert if an existing pool's price is more than 0.5% away.
- No function moves NOTSTOCK or any held asset to a wallet other than the project wallet (its 25% fee share). Assets
  leave LpDesk only into a position, as the fee split, by buyback or burn to the dead address, or by an executed
  BridgeOut to a registered destination LpDesk.
- LpDesk never deposits a position NFT into any staking, gauge or farm contract; positions earn only pool fees.
- Governance (LpGovernor): stake NOTSTOCK to vote; 0.1% of staked to propose (the operator needs no stake); 3-day vote;
  3% quorum of the staked total at the checkpoint (end of the block before creation); for > against; 2-day operator
  veto; `execute()` by anyone in the following 259 200 seconds, then the proposal expires. One open proposal per kind
  per author class (stakers / operator).
- No owner, mint, pause or upgrade in any contract.

## Views the website reads

`LpDesk`: `positions()`, `getPosition(id)`, `positionLiquidity(id)`, `freeBalance(token)`, `topUpBasket(token)`,
`buybackBasket(token)`, `bootstrapEnd()`, `registered()`, `firmVault()`, `poolKey()`, `operator()`, `burner()`,
`governor()`, `priceGuard()`, `venueV3()`, `venueV4()`, `moduleDeployed(kind)`, `moduleAddress(kind)`.
`PriceGuard`: `venues()`, `assets()`, `isAsset()`, `registeredAt()`, `launchNumber()`. `LpGovernor`: `proposalCount()`,
`getProposal(id)`, `state(id)`, `deadlines(id)`, `staked()`, `totalStaked()`, `bridges()`, `bridgedOut(id)`.
`FirmVault`: `buybackBucket()`. Pending (uncollected) fees are not computed on chain: `positionLiquidity` and the
venue's own position views give the position state, and `collect` realises fees.

## Trust and assumptions

- Operator (dev wallet): opens positions in the bootstrap, manages ranges and minimums by hand, runs buybacks and burns,
  vetoes proposals. It cannot send funds anywhere but into positions, the dead address and the fee split.
- Governance: a passed, unvetoed AddVenue or AddBridge can list a contract that answers the spec's interface checks.
  BridgeOut additionally requires the NOTSTOCK to land in the adapter itself (ADAPTATION.md 3). The operator's 2-day
  veto is the protection against a malicious venue or adapter proposal; with little NOTSTOCK staked, quorum is small.
- Prices: open, top-up and governed opens compare against the pool's own price, never a market reference, as SPEC.md
  requires; the operator (or proposal author) sets the price and range by hand.
- Fee split dust: a quarter is rounded down; the remainder of a collected fee stays in LpDesk's free balance.
- The launch factory's record (`positionOf`, `registry().artifactsOf`, `setRequester`) is read once at registration.
  The fee used in that check is the constant 12500 (ADAPTATION.md 1).

## What the brief asked that the token does not do

Nothing: the token is the standard launch token. Every fee, buyback, burn and allocation lives in the contracts beside
it, and the supply split is done by the launch factory.

## Tests

- `forge build`, `forge test`, `forge fmt --check` with the pinned solc 0.8.26. Unit tests (`test/Units.t.sol`) run
  offline against mocks of the factory's read surface; fork tests (`test/Fork.t.sol`) run every live-venue case of
  SPEC.md 6 on a Robinhood Chain fork and skip elsewhere:
  `forge test --fork-url <robinhood rpc> --fork-block-number 112364504`.
- forge-std is vendored under `test/vendor/forge-std` with relative imports; no `lib/`, no `remappings.txt`.
- The verifier's fuzz seed was used locally: `FOUNDRY_FUZZ_SEED=0x840174e71399babdb71fe833ed05b4cd6d1df57a8be3da89226553b890dbbcc7`.

## Files

- SPEC.md: binding specification. ADAPTATION.md: every adaptation and why.
- FINMODEL.md: 12-month cash model, three scenarios. SITE.md: rules of the website.
- docs/abi/: ABI of every contract. brand/: logo, logo-64, compare.
