# Launch texts for the IMD swarm: v6 with $YOLO in four launches

Checked against the code in `contracts/` (constructors, `script/LaunchPlan.sol`, `test/fork/LaunchRehearsal.fork.t.sol`) at
the commit given in this file's git history. Where documents disagree, they are not the source: `LaunchPlan.sol` is.
The constructor arguments of all four texts below are checked by the test `test/review/ReviewLaunch.t.sol`
(`test_L0_docLaunch0Args_matchPlan`, `test_L2_docLaunch1Args_matchPlan`, `test_L3_docLaunch2Args_matchPlan`,
`test_L5_docLaunch3Args_matchPlan`): there the argument strings are copied from this file as they are, the placeholders
are replaced with the plan's addresses, and the creation code is compared with `LaunchPlan` byte for byte. Change the
arguments here, change them there too. That the test's strings appear in this file verbatim and that every text fits in
8,000 characters is checked by `python3 contracts/script/check-launch-task.py` (it also prints the fingerprints of the
texts for the record): under the launch rules Foundry does not read files.

The swarm takes the repository as it is, audits it, changes only what is proven, writes `launch.json` and deploys
in one transaction through the IMD ProjectFactory (`0xfF03…7120`), 0.5 IMD per launch.

## The four launches and their gas headroom

- **Launch 0** (`evm_contracts`):
  `NftGate` (the whitelist of the first 30 minutes), four vestings (`IncentivesVesting` for the incentives, 25%; `DevVesting`,
  `TeamVesting`, `TreasuryVesting`) and `YoloSplitter`. In the swarm's manifest `economics.remainderTo` is a static address
  (no `$contract:`), and the token needs the gate's address. So all of these are deployed in advance and know no token
  (`release(token)`, `split(token)`, like OpenZeppelin's `VestingWallet`); the `YoloSplitter` address
  goes into `remainderTo` of launch 1, the `NftGate` address into the token's arguments.
- **Launch 1** (`custom_token`): the token, its pool, the swarm's allocation and seven support contracts. The token goes
  here because the oracle needs the address of its pool and the vault of launch 2 needs the token's address.
- **Launch 2** (`evm_contracts`): the core. Three contracts must be one transaction: TaskVault's constructor wires the
  modules, and a module accepts wiring only in the transaction that created it (a flag in transient storage,
  `src/desks/Desk.sol`).
- **Launch 3** (`evm_contracts`): two $YOLO modules next to the core, `YoloSweetener` ("Sweeten with $YOLO", a bonus on
  any task) and `DareTrophy` (an NFT trophy of an accepted submission, paid in burned YOLO). They need the vault's address
  (their only address argument; they read everything else from it), so they come after launch 2. They are separate from
  the core so that launch 2 keeps gas headroom for the swarm's changes. Third, `ProtocolDirectory`, the list of core
  versions: version 1 = the vault of launch 2 and the two modules of this launch, written by the
  constructor. Here, not in launch 0 or 1: only in launch 3 are all addresses of version 1 known, and so version 1 exists
  from the first block without the 48 h wait. It holds no money, and the core does not read it. Fourth, `HiddenList`,
  the site's hide list: a separate contract, neither reads the core nor is read by it, has no `payable`/`receive` and
  never calls a token. Its NFT and delegate.xyz addresses are the same ones `ParamsRegistry` and `NftGate` already
  take. Here, not a launch of its own: it needs no address from an earlier launch, so it rides along on launch 3
  without another 0.5 IMD.

Everything does not fit in one factory transaction (EIP-7825 cap: 16,777,216 gas). Gas is that of the whole transaction
through the live ProjectFactory on a fork of the latest mainnet block, execution metered at the deployer's address, calldata not below the
EIP-7623 floor. The rehearsal (`LaunchRehearsal.fork.t.sol`) and the review tests (`ReviewLaunch.test_F1`, `test_F1b`,
`test_F1d`) give the same figures; the method was checked against three real launches of the
platform (0.3–1.5%).

| Launch | What | Gas | Headroom to the cap |
|---|---|---|---|
| 0 `evm_contracts` | NftGate, 4 vestings, YoloSplitter | 3.52M | 13.26M |
| 1 `custom_token` | YoloToken + YOLO/IMD pool (15%) + swarm allocation + 7 support contracts | 12.98M | 3.80M |
| 2 `evm_contracts` | CaseDesk, DisputeDesk, TaskVault | 14.59M | 2.19M |
| 3 `evm_contracts` | YoloSweetener, DareTrophy, ProtocolDirectory, HiddenList | 7.09M | 9.69M |

The swarm's changes will hit the 24,576-byte per-contract limit (EIP-170) before the gas cap: by gas, launch 2 could take
~10.3 KB more new code (216 gas per byte, `ReviewLaunch.test_F2`). Size headroom (`ReviewLaunch.test_L1`):
**DisputeDesk 1,896 bytes**, CaseDesk 4,009, TaskVault 3,853; YoloSweetener 16,992, DareTrophy 12,163, ProtocolDirectory
20,030, HiddenList 20,815; the support contracts 8,435 (ParamsRegistry) and more. A swarm change of more than 1.8 KB in DisputeDesk breaks
launch 2 on size. Launch 1 has seven of the eight contracts the factory allows: if needed, one more helper can be moved
there. Launch 0 has six of eight, all under 4 KB (NftGate 1,719, vestings 1,888 (IncentivesVesting and TreasuryVesting
1,936), YoloSplitter 2,113); YoloToken is 3,149.

## Owner wallets (placeholders)

The five wallets are project-held EOAs. Their real addresses are filled in at launch time and are not published here; the
texts below carry the placeholders `<TREASURY_WALLET>`, `<INCENTIVES_WALLET>`, `<STABILIZER_WALLET>`, `<DEV_WALLET>` and
`<TEAM_WALLET>`. The same addresses are arguments of the plan (`LaunchPlan.projectOwners()`, constants `PROJECT_*`); the
contract code does not contain them. The "arguments in the text = code" test (`ReviewLaunchStatic`) checks the texts with
exactly these addresses; the rehearsal and the other tests run on stand-ins `0x7EA5`, `0x1CE7`, `0x57AB`, `0xDE7`,
`0x7EA0`.

- **Treasury** `<TREASURY_WALLET>`: one address for everything: parameters of future tasks and the swarm signers
  change behind 48 h (pause applies only to task creation; it does not touch money), and the current core version
  for new tasks in `ProtocolDirectory` also changes behind 48 h (the address is set once and for good); recipient
  of the buy tax in minutes 30–60 (a token argument), the fee treasury in all four currencies, and beneficiary of
  TreasuryVesting (the remainder, 222,222,223: 74,074,074 at once, the rest linear over 12 months). Every change of
  the rules or the versions waits 48 h in public, and there is no function that moves or freezes users' money.
- **Incentives** `<INCENTIVES_WALLET>`: the project wallet for incentives, beneficiary of IncentivesVesting (250M:
  62,500,000 at once, the rest linear over 730 days). How to hand them out (tasks, leaderboard) the project decides
  itself, outside the contracts.
- **Stabilizer / MM fund** `<STABILIZER_WALLET>`: the project wallet that steadies the price around launch, then works as the market-making fund; its address is published at
  launch and every move is visible on chain. Receives 150M (15%) from YoloSplitter at once, without vesting. A single
  project-held key.
- **Dev** `<DEV_WALLET>`: beneficiary of DevVesting (77,777,777 YOLO, linear over 12 months from the first `YoloSplitter.split`, no cliff).
- **Team** `<TEAM_WALLET>`: beneficiary of TeamVesting (50M for the future team: linear over 12 months from the first
  `YoloSplitter.split`, no cliff).
- The pool share is **not a placeholder**: `poolBps` 1500 (15% through the swarm), `LaunchPlan.YOLO_POOL_BPS`.
- The initial market cap is **not a placeholder**: `initialMarketCapWei` = 15,000 IMD for 1 billion YOLO
  (`LaunchPlan.YOLO_OPENING_MCAP_IMD`); the oracle's YOLO price floor comes from it too (`yoloFloorImd` =
  15,000,000,000,000 IMD wei per YOLO). A different market cap means changing `LaunchPlan` (A) and both numbers in the
  launch 1 text, otherwise the oracle's floor will not match the pool's opening price.
- The wallet that pays 0.5 IMD for launch 1: the treasury `<TREASURY_WALLET>`. The paying wallet is the pool's
  `requester` from the first block, so 80% of the pool's 1.25% LP fee (1% of the pool's volume, in IMD and YOLO) goes
  to the treasury wallet; anyone may call `claimFees`. Launches 0, 2 and 3 open no pool; they are paid by dev
  `<DEV_WALLET>`. The treasury is a vesting-funded project wallet; the dares the project funds are paid from the
  incentives wallet.
- The trophy price is **not a placeholder**: $1.50 in YOLO, 10,000 YOLO while YOLO has no price
  (`LaunchPlan.TROPHY_PRICE_USD`, `TROPHY_FALLBACK_YOLO`, the DareTrophy arguments in the launch 3 text).
- `<REPO_URL>`: this repository. The Foundry project is `contracts/` (dependencies as git submodules); paths in the
  launch texts are relative to it. `forge test` runs 398 tests, 11 of them on a mainnet fork: without `FORK_URL`
  forge reports 393 passed and 5 skipped (one per fork suite), with `FORK_URL` all 398 pass. The suite holds unit,
  fuzz, invariant and gas tests and the regression tests of the internal audit (`test/audit/`, `test/review/`) and
  of the two swarm audits (`test/audit/swarm117/`, `test/audit/round2/`); each
  of them holds a rule of the docs or a fix; `test_Observation_*` pins the acknowledged B-07 behaviour
  (docs/AUDIT-INTERNAL.md).

## Order of actions

1. An audit job of the swarm (`template: "audit"`, 0.5 IMD) on this repository before the first launch.
2. Launch 0 (`evm_contracts`: NftGate, four vestings, YoloSplitter). The vestings count from the token's first split
   (`split`, audit A-03), not from this deployment. From this moment NFT holders can register (the site's "NFT" page;
   the site is not part of this repository); we publish the number of registered NFTs before launch 1.
3. Put the `YoloSplitter` address into `remainderTo`, the `NftGate` address into the token's arguments (`<NFT_GATE>`)
   and the launch 0 number into the launch 1 text (from the launch 0 page and `launch.json` in the swarm's PR).
4. Launch 1 (`custom_token`), paid by `<TREASURY_WALLET>`, the pool's requester. The pool opens in its transaction:
   from that block, 30 minutes for NFT holders only, then 30 minutes of tax. Right after, anyone calls
   `YoloSplitter.split(<YOLO>)` (the project calls it in the first minute if nobody else has), so that every vesting
   clock starts and every share sits with its recipient from the first minutes.
5. Put six addresses and the number from launch 1 into the launch 2 order (from the launch page and `launch.json` in the
   swarm's PR).
6. **Gate before launch 2, not after launch 3** (audit round 2, finding 19/13b): `increaseObservationCardinalityNext(180)`
   on the USDC/IMD pool `0x894d…c520` (callable by anyone, no address of this project needed — the pool already
   exists, is not ours), then 30 minutes of swaps in it, and a check before continuing:
   `pool.observe([1800, 0])` must not revert `'OLD'`. Without this step `submit` on any ETH/USDC task reverts `'OLD'`
   from the very first launch-2 task (`Desk._priceReward` → `imdWeiPerUsdc` → `pool.observe`, no try/catch).
   Tasks can still be *created* in ETH/USDC
   (`createTask` only reads Chainlink) without this step, but no proof can be submitted to them. Tasks in IMD are
   unaffected.
7. Launch 2. Nothing needs to be called after it: the wiring happens in TaskVault's constructor.
8. Put the TaskVault address (`<TASK_VAULT>`), the launch 2 number and its block number (`<CORE_BLOCK>`) into the
   launch 3 order. Launch 3. Nothing needs to be called after it either: version 1 is written by ProtocolDirectory's
   constructor.
9. Outside the launches:
   - Incentives: `IncentivesVesting.release(<YOLO>)` by anyone, the YOLO arrives at `<INCENTIVES_WALLET>`; handing it
     out is the project's decision (tasks on the board, leaderboard), with no contract.
   - YOLO price samples: `sampleYoloPrice()` on the oracle from a plain wallet (a contract cannot), at most once per 15
     minutes; the price appears after 5 samples (no earlier than an hour after the pool opens). A sample is two calls
     in two blocks: the first reads the pool, the second stores the read if no swap came between (swarm audit #1).
     Anyone can sample, by hand or with a small optional keeper that calls it on a timer from its own wallet
     (~2 x 30-50k gas per sample, at most 96 samples a day). Without a price (or when the oracle fails) a YOLO task is created without the $5 minimum, and every
     submission to it counts as large: the mandatory swarm check and bonds as at the large threshold (40 IMD).
10. The site switches to the addresses from launch 2 (`vault`, `caseDesk`, `disputeDesk`), launch 3 (`sweetener`,
    `trophy`, `directory`) and launch 1 (`yolo`, the oracle); the ABI comes from the swarm's PR if it changed the code.
    The site reads the version list from `directory`; the version 1 addresses in its config stay as a fallback.

---

## Launch 0 text (`evm_contracts`, NFT gate, vestings and the $YOLO split)

```
Launch the genesis contracts of moneycanbuy.fun from this repository as they are: an evm_contracts launch on Ethereum mainnet (no token), the first of four. They exist before the project token $YOLO: the token's custom_token launch (the second) takes the YoloSplitter below as its remainderTo and the NftGate below as a constructor argument of the token; the core and the $YOLO modules follow as the third and fourth launches. script/LaunchPlan.sol is all four launches in code (genesisLaunch, then yoloTokenCode and support, then core, then extras).

Contracts, in this order:
1. NftGate, constructorArgs ["0x0000ec93127baa929e58e97dd0095a2bfb38ec1d", "0x00000000000000447e69651d841bd8d104bed493"]
2. IncentivesVesting, constructorArgs ["<INCENTIVES_WALLET>"]
3. DevVesting, constructorArgs ["<DEV_WALLET>"]
4. TeamVesting, constructorArgs ["<TEAM_WALLET>"]
5. TreasuryVesting, constructorArgs ["<TREASURY_WALLET>"]
6. YoloSplitter, constructorArgs ["$contract:IncentivesVesting", "$contract:DevVesting", "$contract:TeamVesting", "$contract:TreasuryVesting", "<STABILIZER_WALLET>"]

What they do. NftGate is the whitelist of $YOLO's first 30 minutes: the holder of an identity.md NFT (0x0000ec93127baa929e58e97dd0095a2bfb38ec1d, 2,000 NFTs) or a delegate.xyz v2 delegate of the holder (whole wallet, this NFT contract or this token id) registers NFTs to the calling wallet, each once and for good (moving the NFT later gives nobody a second allowance); every registered NFT allows 500,000 YOLO of buys in the window. The token calls consume(buyer, amount) on a buy in its window; the gate books it per calling token (any other caller only spends its own books, so the gate needs no token address), books it only if it fits, and returns the allowance and what was used before; it never calls back and holds nothing. No owner, no clock: the window is the token's.
IncentivesVesting, DevVesting, TeamVesting and TreasuryVesting are ProjectVesting with their schedules compiled in, none with a cliff, each clock started only by the YoloSplitter, which binds itself as the one starter in this launch's transaction (bindStarter, a transient flag) and starts all four at its split: incentives 62,500,000 at once and the rest linear over 730 days, to <INCENTIVES_WALLET> (the project's wallet for incentives it runs itself, off chain); dev linear over 365 days, to <DEV_WALLET>; team linear over 365 days, to <TEAM_WALLET>; treasury 74,074,074 at once and the rest linear over 365 days, to <TREASURY_WALLET>. They know no token in advance (release(token), like OpenZeppelin's VestingWallet); whatever arrives counts; no owner, no acceleration; anyone may call release, which only pays the beneficiary what the schedule has opened.
YoloSplitter receives the project's 75% of $YOLO from the factory (the remainderTo of the token launch). The first split(token) once more than 527,777,777 have arrived pays 250,000,000 to IncentivesVesting, 150,000,000 to the Stabilizer wallet <STABILIZER_WALLET> (the Stabilizer / MM fund, at once, no vesting), 77,777,777 to DevVesting, 50,000,000 to TeamVesting, and the rest (222,222,223, give or take the factory's rounding of the pool seed) to TreasuryVesting; the factory sends the remainder within the launch transaction, so it has all arrived before anyone can call; anything arriving later goes to TreasuryVesting on the next call. Right after the first split it calls release on the four vestings, which starts their clocks and pays the at-once parts. Anyone may call it. With the swarm's 10% and the pool's 15% that is the whole supply. No share is airdropped or burned.

Constructors take only addresses and make no external call. Nothing here holds funds until the token launch. No owner, admin, pause or upgrade path in any of the six.

Known and accepted by design: an NFT stays bound to the wallet that registered it; a holder may register during the window too; the gate trusts the NFT's ownerOf and delegate.xyz; the incentives are spent by the project's wallet off chain, the contract only unlocks them on schedule.

The tests must keep passing: forge test (398 tests, 11 of them need FORK_URL), and forge test with FORK_URL set to a mainnet archive RPC: test/fork/LaunchRehearsal.fork.t.sol runs all four launches through the live ProjectFactory (launchContracts, launchCustom, launchContracts, launchContracts), checks each against the 16,777,216 gas cap (this one is about 3.5M), splits the remainder and checks every share, and trades the token's first hour through the live Universal Router with real NFT holders and a real delegate.xyz delegation.

Audit it as it arrived. Adapt only what the launch rules or a reproduced audit finding require, and record each change in ADAPTATION.md. Do not change the shares, the schedules, the allowance per NFT, the recipients or the constructor arguments, and do not add an owner, a pause, an upgrade path or a fee, unless a reproduced finding requires it; record it in ADAPTATION.md.
```

## Launch 1 text (`custom_token`, $YOLO + support contracts)

```
Launch the token and the support contracts of moneycanbuy.fun from this repository as they are: a custom_token launch on Ethereum mainnet, paired with IMD, the second of four. The YoloSplitter of launch #<GENESIS_LAUNCH_NUMBER> is the remainderTo and its NftGate an argument of the token; the core (CaseDesk, DisputeDesk, TaskVault) follows as a separate evm_contracts launch with the addresses of this one as static arguments, then the $YOLO modules (YoloSweetener, DareTrophy) as a fourth. script/LaunchPlan.sol is all four launches in code (genesisLaunch, then yoloTokenCode and support, then core, then extras).

Token: contract YoloToken, name "YOLO", symbol YOLO, 18 decimals, constructorArgs ["$poolManager", "<NFT_GATE>", "<TREASURY_WALLET>"], totalSupply 1000000000000000000000000000 (1,000,000,000 minted once to msg.sender, the factory). No owner, no mint, burn or pause, no list anyone can edit. A buy is a transfer out of the Uniswap v4 PoolManager. For one hour from deployment (the pool opens in the same transaction) buys follow a fixed schedule that ends by itself:
- minutes 0-30: identity.md NFT holders only. On a buy the token calls consume(buyer, amount) on the NftGate <NFT_GATE> of launch #<GENESIS_LAUNCH_NUMBER> and reverts NotWhitelisted(buyer) when the receiver has no registered NFT, NftAllowanceExceeded(buyer, left, wanted) when the buy is above what is left of 500,000 YOLO per registered NFT for the whole window. No tax. If no code is deployed at the gate address there is no whitelist: written into the token so that a chain without the gate trades normally, not a switch anyone controls.
- minutes 30-60: anyone buys, with a buy tax that falls linearly from 30% at minute 30 to 0 at minute 60, tax = amount x 3000 x (3600 - seconds since deployment) / 18,000,000 rounded down, paid in YOLO to the project wallet <TREASURY_WALLET> fixed at deployment (checked non-zero, compared with nothing).
- from minute 60: a plain ERC-20 for good.
Sells, transfers between wallets and everything into the pool are never touched; the deployer (the factory: seeding and claimFees) and the PoolManager itself are exempt. The PoolManager address comes from $poolManager and is compared with nothing.

Known limits, accepted by design: the external call to the gate on a buy in minutes 0-30 (a fixed address deployed before the token, it writes only its own storage and never calls back); the gate and the tax see only ERC-20 transfers out of the PoolManager: a buy kept as an ERC-6909 claim inside the PoolManager is no transfer, and the NFT gate checks the buyer address of a transfer, so contract buyers that keep claims are not gated or taxed (audit A-01, docs/AUDIT-INTERNAL.md); in minutes 0-30 a route that takes the output to a router or aggregator first is refused even for NFT holders, because the router holds no NFT (the Universal Router's TAKE_ALL pays the buyer directly and passes, tested on a fork); the PoolManager wraps the token's error in WrappedError, the reason inside is intact; an NFT stays bound to the wallet that registered it; in minutes 30-60 the router checks its minimum output before the tax, so a buyer gets up to 30% less than a pre-tax quote; scanners show "cannot buy" in minutes 0-30, a buy tax in minutes 30-60, and a whitelist and an external call in the code afterwards.

Economics, copied into launch.json exactly: poolBps 1500, initialMarketCapWei 15000000000000000000000, remainderTo <YOLO_SPLITTER> (the YoloSplitter of launch #<GENESIS_LAUNCH_NUMBER>). Pool: fee 12500, tickSpacing 60; the oracle below is built for this pool key and its opening price.

Contracts, in this order:
1. ChainlinkUniV3PriceOracle, constructorArgs ["0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7", "0x5f4ec3df9cbd43714fe2740f5e3616155c5b8419", "0x8fffffd4afb6115b954bd326cbe7b4ba576818f6", "0x894d4e6d3d2abc64fc0de0e4e2ea63a93bc9c520", "1800", "7200", "172800", "$token", "0x000000000004444c5dc75cb358380d2e3de08a90", "0x784ff9a3ac5d88a30bfff6f7f2a270161fbe6000", "12500", "60", "10000000000000000", "15000000000000"]
2. UniswapV3SwapAdapter, constructorArgs ["0x68b3465833fb72a70ecdf485e0e4c7bd8665fc45", "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2"]
3. ParamsRegistry, constructorArgs ["<TREASURY_WALLET>", "0xa43e6f75ee006411f79ac1c84120606c2330de82", "$contract:ChainlinkUniV3PriceOracle", "$contract:UniswapV3SwapAdapter", "0x0000ec93127baa929e58e97dd0095a2bfb38ec1d", "0x00000000000000447e69651d841bd8d104bed493", "<TREASURY_WALLET>", "0x5598aa9146215bc13eb26f2c692ad1461fd32982"]
4. TextRules, constructorArgs []
5. SwarmQuestionBuilder, constructorArgs []
6. BallotChecker, constructorArgs []
7. AttestationChecker, constructorArgs ["$contract:ParamsRegistry"]

What each does: the oracle sizes bonds, the large-task threshold and the minimum reward. ETH and USDC come from Chainlink, IMD from the 30-minute TWAP of the Uniswap v3 USDC/IMD pool, YOLO from samples of the YOLO/IMD v4 pool this launch opens: any plain EOA (no contract or EIP-7702 account) may store one per 15 minutes, read in one block and stored in a later one if no swap came between, the price is the highest of the last 2 hours, needs 5 samples, is never below the pool's opening price (15,000,000,000,000 IMD wei per YOLO, the initialMarketCapWei above), never above $0.01 per YOLO, and is absent otherwise. Prices never decide who is paid; the amounts they set are a relayer's gas shortfall, paid in IMD from a losing bond at the oracle's ETH rate, and, in the fourth launch, a trophy's YOLO price and the cap on a YOLO bonus the swarm did not confirm. The adapter swaps ETH or USDC to IMD through SwapRouter02 for users who pay bonds in another currency. ParamsRegistry holds versioned parameters (version 1 compiled in, LaunchParams) and the set of swarm answer signers; both can change only behind a 48-hour timelock, inside bounds compiled into ParamsBounds, and the creation of new tasks can be paused. It has no function that moves or freezes money, but the signer set is global: a change applies to every open case. TextRules, SwarmQuestionBuilder, BallotChecker and AttestationChecker are stateless helpers of the core launch.

Every constructor takes only addresses and integers and makes no external call. None of these seven contracts holds funds; the swarm gets 10% and the pool 15%, the remainder (75%) goes to the YoloSplitter of launch #<GENESIS_LAUNCH_NUMBER>, which hands it to the four vestings (incentives, dev, team, treasury) and the Stabilizer wallet. The core's TaskVault will take YOLO as its fourth reward currency, with bonds in IMD; the fourth launch adds YOLO bonuses on any task and trophies paid in burned YOLO.

The tests must keep passing: forge test (398 tests, 11 of them need FORK_URL), and forge test with FORK_URL set to a mainnet archive RPC: test/fork/LaunchRehearsal.fork.t.sol runs all four launches through the live ProjectFactory (launchContracts, launchCustom, launchContracts, launchContracts), checks each against the 16,777,216 gas cap (this one ~13.0M), trades YOLO's first hour through the live Universal Router (the NFT gate with real holders and a delegate, routes through a router refused, the edges of minutes 30 and 60, the exact tax, the factory's fee claim exempt), samples its pool and runs tasks in IMD and YOLO end to end.

Audit it as it arrived. Adapt only what the launch rules or a reproduced audit finding require, and record each change in ADAPTATION.md. Do not change the token, its supply, the gate, the tax or the schedule, the economics, the recipients, the parameter values, bounds, timelock or constructor arguments, and do not add an owner, a pause, an upgrade path, minting or a fee, unless a reproduced finding requires it; record it in ADAPTATION.md.
```

## Launch 2 text (`evm_contracts`, core)

```
Launch the core of moneycanbuy.fun from this repository as it is: an evm_contracts launch on Ethereum mainnet (no token), the third of four. It uses the token and the contracts of launch #<SUPPORT_LAUNCH_NUMBER> as static arguments; the fourth launch adds two modules that only read this vault.

Contracts, in this order:
1. CaseDesk, constructorArgs ["<PARAMS_REGISTRY>", "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7", "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", "<TEXT_RULES>", "<SWARM_QUESTION_BUILDER>"]
2. DisputeDesk, constructorArgs ["<PARAMS_REGISTRY>", "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7", "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", "<TEXT_RULES>", "<BALLOT_CHECKER>"]
3. TaskVault, constructorArgs ["<PARAMS_REGISTRY>", "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7", "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", "<YOLO>", "<ATTESTATION_CHECKER>", "<TEXT_RULES>", "$contract:CaseDesk", "$contract:DisputeDesk"]

What it is: an escrow for real-world tasks judged by the IMD swarm. Authors post rewards in ETH, USDC, IMD or YOLO (the token of launch #<SUPPORT_LAUNCH_NUMBER>); doers submit a proof link with an IMD bond; anyone but the doer may dispute with an IMD bond; identity.md NFT holders vote with EIP-712 signatures relayed in batches; the swarm, asked through the Intake 0xa43e6f75ee006411f79ac1c84120606c2330de82 (version 2), is the final instance and is paid by whoever calls it. Bonds are IMD in every reward currency. TaskVault is the only address users call and approve: it holds all the money, the tasks and the swarm requests, receives the Intake callback (onOracleResult) and forwards the other calls with a plain CALL, never DELEGATECALL, appending the sender and msg.value. CaseDesk keeps submissions and the lazy state machine; DisputeDesk keeps disputes, votes, appeals and settlements. The desks hold no funds and accept calls only from the vault and each other. Money invariant: for every token, the vault's balance >= liabilities[token], and every amount sits in exactly one bucket.

TaskVault's constructor wires the two desks, which accept wiring only once, only in the transaction that deployed them (a transient-storage flag) and only into their own slot, so these three contracts must stay one launch, in this order. Constructors take only addresses and make no external call except to the desks of this launch and AttestationChecker.registry(). Nothing is called after the launch.

Known trust assumptions, accepted by design: the swarm attester key set in ParamsRegistry, global for all open cases; the swarm price can change without delay (every payer passes maxImdIn); a swarm answer counts only through the Intake callback (no public fallback: an answer not delivered within an hour after the swarm timeout is silence); prices come from Chainlink, a TWAP and samples of the YOLO pool; they size bonds, thresholds and the minimum reward and set only the IMD amount of a relayer's gas shortfall; a YOLO task without a reliable YOLO price (fewer than 5 samples, or any oracle call failing) has no USD minimum at creation, and every submission to it counts as large: the mandatory swarm check and bonds as at the large threshold, so a missing price can only make a submission dearer; the vault takes the oracle's number as it is, and the oracle's floor (the pool's opening price) and its highest-sample rule keep a depressed price out.

The tests must keep passing: forge test (398 tests including invariants of the money buckets, 11 of them need FORK_URL), and forge test with FORK_URL set to a mainnet archive RPC, which runs this launch through the live ProjectFactory against the 16,777,216 gas cap (about 14.6M) and tasks end to end. Keep the launch under the cap; DisputeDesk has about 1.9 KB left under the 24,576-byte contract size limit.

Audit it as it arrived. Adapt only what the launch rules or a reproduced audit finding require, and record each change in ADAPTATION.md. Do not change fees, bonds, windows, shares, recipients, the parameter values, the currencies, the constructor arguments or the split into these three contracts, and do not add an owner, a pause, an upgrade path, minting or a fee, unless a reproduced finding requires it; record it in ADAPTATION.md.
```

## Launch 3 text (`evm_contracts`, $YOLO modules)

```
Launch the $YOLO modules and the version directory of moneycanbuy.fun from this repository as they are: an evm_contracts launch on Ethereum mainnet (no token), the last of four. The two modules only read the TaskVault of launch #<CORE_LAUNCH_NUMBER>, their one address argument; the registry, the token and the CaseDesk they read from it.

Contracts, in this order:
1. YoloSweetener, constructorArgs ["<TASK_VAULT>"]
2. DareTrophy, constructorArgs ["<TASK_VAULT>", "1500000000000000000", "10000000000000000000000"]
3. ProtocolDirectory, constructorArgs ["<TREASURY_WALLET>", "<TASK_VAULT>", "$contract:YoloSweetener", "$contract:DareTrophy", "<CORE_BLOCK>"]
4. HiddenList, constructorArgs ["<TREASURY_WALLET>", "0x0000ec93127baa929e58e97dd0095a2bfb38ec1d", "0x00000000000000447e69651d841bd8d104bed493"]

YoloSweetener ("Sweeten with $YOLO") holds YOLO bonuses that anyone adds to any open task, whatever its reward currency. It reads the vault (task status, whether a submission is active) and the CaseDesk (the accepted submission) and changes nothing there. When a submission is accepted anyone calls payout and the doer gets the bonus minus the task's protocol fee (feeBps, 10%) on what they get, the fee goes to the treasury; unless the swarm said yes to that submission they get at most the YOLO worth largeRewardUsd by the task's oracle (without a reliable price payout waits, and pays all of it after 7 days with none) and the rest goes back to the sweeteners pro rata; when the task expires or is unwound every sweetener takes back their own; while the task is open with no active submission they may take it back 1 to 25 hours after announceWithdraw; while one is active nothing leaves. Invariant: its YOLO balance equals the sum of open bonuses, and each open bonus equals what its sweeteners may take back.

DareTrophy is an ERC-721: the doer of an accepted submission may mint its trophy once (token id = submission id), paying $1.50 in YOLO at the oracle's YOLO price, or 10,000 YOLO while YOLO has no price or the oracle fails, under a maxYolo the doer passes; the YOLO is burned by a transfer to 0x000000000000000000000000000000000000dEaD (the token has no burn function) and the contract keeps none. Metadata are fully on chain: tokenURI is a base64 JSON with a 24x24 SVG pixel badge of the task's category, the task and submission numbers, the title the doer gives at mint (checked by the vault's text rules, 1..64 bytes), the reward, the mint date and the proof link. Invariant: every trophy belongs to an accepted submission and was minted by its doer, and the YOLO burned equals what the trophies cost.

ProtocolDirectory lists the versions of the core: a new version is a new vault with its own modules deployed next to the old ones, nothing is replaced or migrated, and the token stays the same. Its constructor lists version 1 (the vault of launch #<CORE_LAUNCH_NUMBER>, the two modules above, <CORE_BLOCK> the block of that launch, label "v1") and makes it current, the version new tasks go to. A new version or a new current version can be proposed; either takes effect 48 hours later (the timelock of ParamsRegistry) and anyone executes it then; it may be cancelled before that. Listed versions are never removed or edited. It holds no money and no contract of the core reads it: only off-chain readers such as the site use it, so it can stop nothing and redirect nothing.

HiddenList is the site's hide list: the site does not show a task or proof this contract marks hidden. It is standalone, neither reads the core nor is read by it, has no payable or receive function and never calls a token, so it cannot hold, freeze or redirect any task, bond or reward; it only tells an off-chain reader what not to render. An instant `setState` path (no transfer, no timelock) sets a batch of (vault, kind, id) items, both ways. Separately, an identity.md NFT holder (or their delegate.xyz delegate) may vote an item hidden: the first hide vote opens a 24-hour round, which passes at 10 or more hide votes, more hide than keep votes, and 3 or more distinct hide wallets; a round that does not pass may be retried only 7 days later; `setState` always closes whatever round is open, so its last call stands until a fresh vote passes. Every state change is a public event.

Neither $YOLO module has an owner, an admin, a pause or an upgrade path; the directory only has a timelocked list, and HiddenList only an instant, untimelocked setState (and anyone's NFT vote, bounded by the quorum above). Constructors make no external call except view calls to the vault of launch #<CORE_LAUNCH_NUMBER>. Nothing is called after the launch.

The tests must keep passing: forge test (398 tests, 11 of them need FORK_URL), and forge test with FORK_URL set to a mainnet archive RPC, which runs this launch through the live ProjectFactory against the 16,777,216 gas cap (about 6.9M).

Audit it as it arrived. Adapt only what the launch rules or a reproduced audit finding require, and record each change in ADAPTATION.md. Do not change the fee, the price of a trophy, the burn, the recipients, the directory's timelock, HiddenList's quorum or round/cooldown windows, or the constructor arguments, and do not add an owner, a pause, an upgrade path, minting or a fee, unless a reproduced finding requires it; record it in ADAPTATION.md.
```

## Placeholders between launches

- Launch 1 from launch 0: `<YOLO_SPLITTER>` (the YoloSplitter address, `remainderTo`), `<NFT_GATE>` (the NftGate address,
  a token argument) and `<GENESIS_LAUNCH_NUMBER>`. `<TREASURY_WALLET>` is the same as in launch 0.
- Launch 2 from launch 1: six addresses and the number (from the launch page and `launch.json` in the swarm's PR):
  `<PARAMS_REGISTRY>` (3), `<TEXT_RULES>` (4), `<SWARM_QUESTION_BUILDER>` (5), `<BALLOT_CHECKER>` (6),
  `<ATTESTATION_CHECKER>` (7), `<YOLO>` (the launch's token), `<SUPPORT_LAUNCH_NUMBER>`. TaskVault's argument order:
  `yolo` fourth, between USDC and AttestationChecker; without it the constructor takes TextRules for AttestationChecker
  and reverts.
- Launch 3 from launch 2: `<TASK_VAULT>` (the TaskVault address), `<CORE_LAUNCH_NUMBER>` and `<CORE_BLOCK>` (the block
  number of the launch 2 transaction, in decimal: the site reads the events of version 1 from it).
  `<TREASURY_WALLET>` is the same as in launches 0 and 1.
