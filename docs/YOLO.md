# $YOLO, the moneycanbuy.fun token

The token as the code defines it, with a code reference for each rule, plus its uses (the "Uses" section below
says which of them the code enforces and which are commitments of the project). Code references point to files
under `contracts/src/` unless they start with `script/` or `test/` (those are under `contracts/`); a function or constant name is given instead of a
line number. Launch values come from `script/LaunchPlan.sol` and its fork rehearsal test. How the rest of the
protocol works: [docs/MECHANICS.md](MECHANICS.md). The supply split, the unlock schedule and how the protocol
prices things without an oracle are in [docs/TOKENOMICS.md](TOKENOMICS.md).

## What it is

$YOLO is a plain ERC-20 with a fixed supply of 1,000,000,000 and 18 decimals, minted once to its deployer, the IMD
launch factory (`token/YoloToken.sol`). It has no owner, no admin, no pause, no mint or burn and no list of its own; its only rules are the fixed first hour below (NFT holders, then a falling tax), after which it is a
plain ERC-20. It is launched through the IMD swarm as a `custom_token` launch paired with IMD, together with the
support contracts of the protocol (`script/LaunchPlan.sol`, [docs/LAUNCH-TASK.md](LAUNCH-TASK.md)).

In the protocol it is the fourth reward currency of tasks, next to ETH, USDC and IMD (`TaskVault.sol`), the
currency of bonuses (`YoloSweetener`), of YOLO Predict positions and of the doer stake. No contract of the protocol
mints it or sells it. It is burned by sending it to `0x…dEaD` (the token has no burn function):
- the vault: the fee of a $YOLO reward that would go to the treasury, and the burn share of a staked doer's task,
  go to the `BuybackBurner` (`TaskVault.sol`);
- `YoloSweetener`: the part of a bonus's 10% fee that is not the doer's or the NFT votes' goes to the
  `BuybackBurner` (`YoloSweetener.sol`);
- `YoloPredict`: 5% of every position, held until the outcome, and the deferred 5% of a task not done; nothing of a
  cancelled task (`YoloPredict.sol`);
- `BuybackBurner`: $YOLO that reaches it goes to `0x…dEaD` by anyone's `burnYolo` (`BuybackBurner.sol`);
- `DareTrophy`: a trophy's price (`DareTrophy.sol`).

## Uses

Uses 1 to 3 and 6 to 8 are enforced by code. The incentives are a project wallet unlocked by a vesting; no mechanic
of the protocol pays from it (section "Incentives"). Use 4 and the manual part of use 5 are commitments of the
project, carried out by its wallets in public transactions; no contract enforces them.

1. **Rewards in $YOLO.** Any author can lock a task reward in YOLO (section "YOLO as a reward currency" below).
   The project may post its own tasks like any author; every payout is then made by the vault from the reward it
   holds.
2. **Sweeten with $YOLO.** Anyone can add a YOLO bonus to any open task, whatever the currency of its reward; the
   bonus is shown next to the reward (section "Sweeten with $YOLO" below).
3. **Trophies for burned $YOLO.** The doer of an accepted submission may mint its NFT trophy, once; the price (a
   fixed 7,777 YOLO) is burned (section "Trophies" below).
4. **Treasury-funded dares.** The pool's 1% of YOLO/IMD volume goes to the project treasury: the treasury wallet
   `0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C` pays for launch 1, so it is the pool's `requester` from the pool's
   first block; there is no transfer step. The project decides which dares to subsidize from that income in IMD
   (the YOLO side burns, use 5): it posts them as ordinary tasks or sweetens existing ones, so every reward and
   payout is made on chain by the contract that holds it.
5. **Treasury $YOLO income burns.** In the contracts it never reaches the treasury: the YOLO the treasury would
   get from a $YOLO reward's fee goes from the vault to the `BuybackBurner` (`TaskVault.sol`), and so does the
   treasury's part of a bonus's fee (`YoloSweetener.sol`); there anyone's `burnYolo` sends it to `0x…dEaD`. Outside the contracts, the first-hour tax
   paid straight to the treasury wallet (`token/YoloToken.sol` `taxRecipient`) and the YOLO side of the pool's fee
   cut are sent to `0x0000000000000000000000000000000000dEaD` by the project as they arrive, all of it (a manual
   transfer, published with its transaction hash). The burn shares paid in ETH, USDC or IMD go to the buyback wallet (section "Burner" below).
6. **YOLO Predict on a task's outcome** (`YoloPredict`, launch 3). Anyone may take a WILL DO or WON'T DO position
   in YOLO until the deadline, including the task's author, its contributors and its doer; 5% is held and burns at
   the outcome, 5% waits for the outcome (2.5% to the author and 2.5% to the doer if the task is done, otherwise
   burned), 90% is split among the winners; if the task is unwound, every position comes back in full.
7. **Doer stake** (`YoloLockHub`, launch 2). A doer locks YOLO for 1 to 52 weeks; the lock's power (amount × weeks
   / 52, fixed at the lock) at their submission earns them 4% × min(1, power / (the reward in YOLO + the YOLO
   add-on)) of the reward and of the add-on from the fee: the whole 4% once the power is worth the task's whole reward
   at the submission (the pot with every top-up) plus its YOLO add-on, less in proportion below it, from any power. The rest of the stakers' 5% goes half to the burn, half
   to the treasury. The share is fixed by the CaseDesk at submission; at payout the DisputeDesk only checks that
   the same lock still runs, and the vault books it from the fee it holds.
8. **Burner** (`BuybackBurner`, launch 1). The burn shares paid in ETH, USDC or IMD go from the vault's payout
   straight to the buyback wallet; the burner holds them only if that send fails, and anyone's `forward` sends them
   on. $YOLO there goes to `0x…dEaD` by anyone's `burnYolo`. The contract swaps nothing.

## What the token does not do

- **No bonds of its own.** A bond is 0.5 IMD plus a percent of the author's reward in the reward's currency, so in
  YOLO only on a YOLO task (`desks/Desk.sol`).
- **No control.** Holding YOLO gives no say over contracts, parameters or the treasury; there is no holder vote.
- **No income for holding.** No dividends or fee share for holders. The doer stake (use 7) pays only a doer, from
  the fee of a task they did and that was accepted; holding or staking alone earns nothing. The deferred 5% of
  YOLO Predict pays only the author and the doer of a task that was done. The burns reduce the supply; they are
  not a promise of any price.
- **No price promise.** The project says nothing about where the price goes and does not support it.

## Distribution

Every vesting clock starts when `YoloSplitter.split` pays it, right after launch 1 (12 months = 365 days, 24 months =
730 days); no cliff anywhere.

| Share | Amount | Where | Code |
|---|---|---|---|
| Swarm | 10% (100M) | the launch's MerkleDistributor, claimed by the agents and seats of the launch job after a 1 h lock | a constant of the IMD launch factory |
| Pool | 15% (150M) | YOLO/IMD Uniswap v4 pool, single-sided, locked for good by the factory | `script/LaunchPlan.sol` `YOLO_POOL_BPS` |
| Incentives | 25% (250M) | project-run incentives, unlocked by vesting: 62.5M (a quarter) at once, 187.5M linear over 24 months, to the incentives wallet | `token/Vestings.sol` `IncentivesVesting` |
| Stabilizer / MM fund | 15% (150M) | a labeled wallet, at once, no vesting | `token/YoloSplitter.sol` |
| Dev | 7.7777777% (77,777,777) | linear over 12 months, no cliff | `token/Vestings.sol` `DevVesting` |
| Future team | 5% (50M) | linear over 12 months, no cliff | `token/Vestings.sol` `TeamVesting` |
| Treasury | the rest, 22.2222223% (222,222,223) | a third at once (74,074,074), the rest linear over 12 months, no cliff | `token/Vestings.sol` `TreasuryVesting` |

The factory sends the project's 75% to `YoloSplitter` (the launch's `remainderTo`); one `split(token)` hands out
the fixed amounts above and the rest, the factory's rounding dust included, to the treasury vesting
(`token/YoloSplitter.sol`). The vestings know no token in advance and have no owner; a vesting pays only its
beneficiary what its schedule has opened (`token/ProjectVesting.sol`).

## Incentives

25% of the supply (250M) are project-run incentives, unlocked by vesting: `IncentivesVesting` (launch 0) opens
62,500,000 at once and the rest linearly over 730 days to the incentives wallet
`0x7085193516EDc587fAebFF7a48548eAC8db5fAb5`; anyone may call `release(token)`, it pays only that wallet. It is a
wallet and nothing more: no contract has access to it, no mechanic of the protocol pays from it and the protocol
promises nothing from it. Every transfer from the wallet is public.

## The first hour

The pool opens in the token's deployment transaction; trading opens at `openAt`, a time fixed at deployment (at most
30 days later; before it no buys, `TradingNotOpen`). From `openAt` a fixed schedule, then nothing (`token/YoloToken.sol`):

| Minutes | Who buys | Tax | Code |
|---|---|---|---|
| 0-30 | only wallets of the sealed `NftGate` snapshot of identity.md NFT holders: 500,000 YOLO per NFT in the snapshot | buys none; every sell 30% | `NotWhitelisted`, `NftAllowanceExceeded` |
| 30-60 | everyone | buys and sells: 30% at minute 30, falling linearly to 0 at minute 60, in YOLO to the project treasury wallet | `buyTaxBps()`, `sellTaxBps()` |
| 60+ | everyone | none, a plain ERC-20 for good | |

A buy is a transfer out of the Uniswap v4 `PoolManager`, a sell a transfer into it; the tax of a sell is taken from
the seller's wallet on top of what goes into the pool. Wallet-to-wallet transfers, the factory (seeding, fee claims)
and the `PoolManager` are never taxed; before trading opens nobody buys and sells are untaxed. If the gate address holds no code there is no whitelist.
Known limits: a buy kept as an ERC-6909 claim inside the `PoolManager` is no transfer: a contract without an NFT
can buy in minutes 0-30 and sell the claim back into the pool, or take it out after minute 60, without the gate
and without the tax (the token cannot see it; only a pool hook could). A router or aggregator that takes the
output itself is refused in minutes 0-30 (the Universal Router's `TAKE_ALL` pays the buyer and passes). The opening
valuation of about 15,000 IMD stays the main defence against fixed-size bot buys.

## The YOLO/IMD pool

The pool is opened by the IMD ProjectFactory (`0xfF03410d0Fe5fa8f7F59F743de35E333D9857120`, source on Sourcify),
not by this project. What the factory does (read from its source and a fork of mainnet):
- Uniswap v4, pair YOLO/IMD, LP fee 1.25% (`fee = 12500`, static), tick spacing 60, hook `PoolInitializationGuard`
  `0x784FF9a3ac5d88A30bfff6F7f2a270161FBE6000`, which only stops anyone but the factory from initializing the pool
  (`script/LaunchPlan.sol`).
- The pool share is seeded single-sided in YOLO from the first tick above the opening price; no IMD is needed. The
  opening price follows from `initialMarketCapWei` for the whole supply (policy range 250 to 250,000 IMD;
  rehearsal 15,000 IMD, `script/LaunchPlan.sol`).
- The LP position belongs to the factory and has no withdraw function: the liquidity is locked for good.
- Fees: 1% of volume goes to the launch's `requester` (the wallet that paid for the launch: the treasury, use 4),
  0.25% to the IMD network; anyone may call `claimFees(launchNumber)`. Buys pay the fee in IMD, sells in YOLO.

## YOLO as a reward currency

| Rule | Value | Code |
|---|---|---|
| Deposit | `createTask` / `topUp` with `currency = yolo`, pulled by `transferFrom` | `TaskVault.sol` |
| Bonds | always 0.5 IMD + 3% (doer) or 0.5 IMD + 1% (disputer) of the author's own reward (their share of the pot, their own top-ups included) in the reward's currency; the $YOLO add-on and others' top-ups are not in it; no floor, no doubling | `desks/Desk.sol`; `desks/CaseDesk.sol` |
| Minimum / maximum reward | no maximum; minimum is 1,000 YOLO, a separate protocol parameter in YOLO; no price is read at creation | `TaskVault.sol` |
| Fee on an accepted reward | 10% in YOLO; 5% to correct NFT votes after a dispute they decided right; everything the treasury would get burns; a staked doer gets up to 4% of R by their lock's power; the doer gets 90% (up to 94% staked) in YOLO | `desks/DisputeDesk.sol`; `TaskVault.sol` |
| Payouts | in YOLO, never converted; a failed transfer stays a credit to withdraw | `TaskVault.sol` |

**How the price is made (no oracle at all).** $YOLO price = the `yoloPriceUsd` parameter of `DevPrices` (USD per
whole YOLO). It changes by a transaction of the DevPrices owner, with an event, at most 10 times up or down per call
(`MAX_STEP`, `PriceSanity`); the site shows the current value. ETH and IMD prices
used elsewhere in the contract are protocol parameters the same way. There is no cap on $YOLO's price.

**Where the price is read.** Only at a submission, for the doer stake bonus: the task's whole reward (the pot) converted to
$YOLO at the price parameter (the $YOLO add-on is added as is), fixed in the submission (`desks/CaseDesk.sol`, `_stakeBps`). Without a $YOLO price
that bonus is 0; tasks, top-ups, bonds, bonuses (`YoloSweetener.sol`) and YOLO Predict markets in any
currency (`YoloPredict.sol`) read no price. The reward minimum is a separate per-currency protocol parameter —
1,000 YOLO for this currency. 
The price parameters change only by a transaction of the DevPrices owner.

**A stale price does not break the contract**: tasks, submissions, disputes and payouts keep working at whatever
the parameter says. A forgotten update only shifts the doer stake bonus for that period, until the parameter is
updated; nobody's locked money is at risk. A trophy costs its fixed 7,777 YOLO either way.

## Sweeten with $YOLO

A YOLO bonus on top of any task, in a module of its own (`YoloSweetener.sol`, launch 3 next to the trophies). The
rules follow the reward's.

| Rule | Value | Code |
|---|---|---|
| Who and when | anyone, while the task is Open and before its deadline, whatever its reward currency; reads no price; there is no limit on the bonus | `YoloSweetener.sol` |
| Where it sits | in the module, apart from the vault's money; `bonusOf(taskId)`, `givenBy(taskId, who)`; `gave(taskId, who)` records that they ever sweetened it | `YoloSweetener.sol` |
| Locked like the reward | nobody takes it back while the task is open, before or after the deadline, with no notice period | `withdraw` (`BonusLocked`) |
| Accepted submission | anyone calls `payout(taskId)` (the accepted submission is the task's `activeSub`). The whole bonus goes by the reward's rule: 10% fee; of it 5% to the NFT votes on "accept" if the NFT decided right (claimed here by `claimVoter(taskId, payTo)`, pro rata to their votes), the rest burns (the treasury's YOLO income); if the vault paid the doer the stake bonus on this submission (`Settlement.stakeBps`), they get the same share of the bonus as usual, even if they sweetened it themselves | `YoloSweetener.sol` |
| Expired or unwound task | each sweetener takes back their own (also an open task past its deadline with no submission in flight, which the vault expires at its next call) | `YoloSweetener.sol` |
| YOLO Predict's 5% | never come here: YoloPredict pays the author and the doer itself | `YoloSweetener.sol` |
| Binding | takes deposits only once bound to the vault (`TaskVault.bindSweetener`, after launch 3); the add-on is not in the bonds (the author's own reward) and is in the base of the stake power (with the pot); the doer's stake bonus is paid on the add-on too; there is no limit on the add-on | `YoloSweetener.sol`; `TaskVault.sol` |
| Owner, admin | none; the module reads the vault and plays its timers (`vault.poke`), and changes nothing else in it | `YoloSweetener.sol` |

The module plays the task's timers itself (`vault.poke` at the start of `sweeten`, `withdraw` and `payout`). Tested by
`test/Sweetener.t.sol` and an invariant in the vault's fuzz run (`invariant_SweetenerHoldsEveryBonus`): the
module's YOLO balance always equals the unpaid bonuses plus the unclaimed NFT shares, and an open task's bonus
never leaves before its deadline.

**Call-outs.** A call-out is a dare to one named person: the existing X post (or X reply) template with
"by @handle" instead of "any account", plus moneycanbuy.fun in the post. Its author pays an ordinary reward (the
usual per-currency minimum: 5 USDC, 0.002 ETH, 1 IMD, 1,000 YOLO); others add to it with Sweeten. The @handle
binds the post to the named person; whoever hands it in first is the doer, a wrong submitter is a matter for the dispute.

## Trophies

The doer of an accepted submission may mint an NFT trophy of it (`DareTrophy.sol`, ERC-721 "moneycanbuy.fun
trophy", symbol DARE, launch 3).

| Rule | Value | Code |
|---|---|---|
| Who | only the doer of the submission, only once it is accepted; one trophy per submission (token id = submission id) | `DareTrophy.sol` `mint` |
| Price | a fixed 7,777 YOLO, no USD conversion and no price read | `DareTrophy.PRICE`, `price()` |
| Where the YOLO goes | burned: sent to `0x…dEaD` (the token has no burn function); the trophy contract keeps none | `DareTrophy.sol` |
| Metadata | entirely on chain: `tokenURI` is a base64 JSON with the trophy's picture, the task and submission numbers, the title, the reward, the mint date, the proof link and the design's name | `DareTrophy.sol` `tokenURI` |
| Picture | the design `TrophyCatalog` gives the task's category at mint: the category's design, else the default design, else design 0, the built-in 24x24 pixel badge of the category (SVG, gold frame, one icon per category); a switched-off design is skipped. The trophy keeps that design id for good | `DareTrophy.sol` `mint`, `badge`; `TrophyCatalog.designFor` |
| Designs | `TrophyCatalog` (launch 3, holds no money), run by the project wallet (two-step owner transfer): `addDesign(name, svg)` (name 1 to 32 bytes under the text rules, SVG 11 to 8,192 bytes of printable ASCII, tab, CR or LF, from `<svg` to `</svg>`), `setCategoryDesign`, `setDefaultDesign`, `setDesignEnabled`. A design never changes once added; switching it off affects new mints only | `TrophyCatalog.sol` |
| Title | given by the doer at mint (the vault keeps the task title only in its `TaskCreated` event), 1 to 64 bytes under the vault's text rules | `mint` |
| Owner, admin | none on `DareTrophy`; its catalog address is fixed at deployment | `DareTrophy.sol` constructor |

Tested by `test/Trophy.t.sol` (`test_Catalog_*` for the designs) and an invariant in the vault's fuzz run: every trophy belongs to an accepted
submission and was minted by its doer, the trophies' `totalBurned` equals the sum of what they cost, the YOLO at
`0x…dEaD` is at least that sum, and the trophy contract keeps no YOLO.

## YOLO Predict, doer stake, burner

The core protocol uses these modules: the CaseDesk reads the hub at submission and the DisputeDesk at payout; the
vault sends $YOLO burn shares to the burner and ETH, USDC and IMD burn shares straight to the buyback wallet (to the
burner only if that send fails); YOLO Predict reads only the vault.

### YoloPredict (YOLO Predict)

| Rule | Value | Code |
|---|---|---|
| Market exists for | every task (every task has a deadline) | `TaskVault.sol` |
| Window | from task creation to its deadline; paused while a submission is under review (`SubmissionActive`); `predict` plays the task's timers first (`vault.poke`), so a submission whose timer has ended does not pause it | `YoloPredict.sol` |
| Who may not | nobody is excluded: the author, contributors and the doer may all predict like anyone else | `YoloPredict.sol` |
| Currency, revocability | $YOLO only, at least 1 YOLO, no withdrawal of a position | `YoloPredict.sol`; `script/LaunchPlan.sol` |
| Entry split | 5% to burn (held until the outcome, then to `0x…dEaD`), 5% deferred, 90% (`effPosition`) to the pool of its side | `YoloPredict.sol` |
| Weight | `w = (time left to the deadline / (deadline − task creation))²`, fixed at placement; the term counts from the task's creation, not from the first position | `YoloPredict.sol`; `VaultTypes.sol` |
| Outcome | task `Completed` → WILL DO wins (also when the submission was made before the deadline and accepted after it); `Expired` → WON'T DO wins; `Unwound` → void, every position comes back in full (no burn, no deferred part). If `Completed` and nobody predicted WILL DO, the losing pool (90% of WON'T DO) splits in half between the author and the accepted doer; if `Expired` and nobody predicted WON'T DO, the whole losing pool (90% of WILL DO) goes to the author. The losing side never gets anything back | `YoloPredict.sol` |
| Payout | `effPosition + losing pool × points / points still in the split`, paid from what is left (`splits`): the last winner to claim takes the rounding dust and the contract ends at exactly 0; a lone late winner takes the whole losing pool | `YoloPredict.sol` |
| Accepted doer, late contributors | no special treatment: every winner keeps their full share | `YoloPredict.sol` |
| Deferred 5% | task `Completed` → 2.5% to the author and 2.5% to the accepted doer, from YoloPredict itself, without the vault's fee, the same split even when nobody predicted WILL DO; `Expired` → burned; `Unwound` → back in full; never part of the task's reward | `YoloPredict.sol` |
| Pool cap | none: no bank cap, no per-address limit, no price; a market opens at the first position in any task currency | `YoloPredict.sol` |
| Void | only on `Unwound`; the reward is locked until the deadline | `YoloPredict.sol` |
| `settle`, `claim` | permissionless pull after the task left Open; the first `claim` settles; `settle` plays the task's timers first (`vault.poke`) | `YoloPredict.sol` |

### YoloLockHub: the doer stake (a lock for a term)

A lock of $YOLO with a fixed power; the CaseDesk fixes the bonus share at the submission and the DisputeDesk pays
it if the lock still runs.

| Rule | Value | Code |
|---|---|---|
| Lock | `lock(add, weeks)`: adds YOLO (pulled by `transferFrom`) and/or sets the end to 1-52 weeks from now; the end only moves later, the amount only grows; a lock that ended needs a new term | `YoloLockHub.sol` |
| Withdrawal | `withdraw()`: the whole amount once the lock ended; nothing before, no notice | `YoloLockHub.sol` |
| Power | amount × term in weeks / 52, fixed when the lock is set and constant until its end unless the lock is changed; extending sets it to the whole amount × weeks left / 52; adding without a new term sets it to power + added × weeks left / 52; read from the lock as it stood strictly before the moment asked; every change is checkpointed | `YoloLockHub.sol` |
| Bonus share | fixed at the submission: b = 4% × min(1, power / (R in $YOLO + A)), R = the task's whole reward at the submission (the pot: the author's share and every top-up), A = the task's $YOLO add-on at the submission; a reward in ETH, USDC or IMD converted at the $YOLO price parameter at submission. Any power counts, there is no threshold; no $YOLO price means no bonus; a doer who contributed to the task's reward gets the bonus as usual | `desks/CaseDesk.sol`; `VaultTypes.sol` |
| Paid at payout if | the same lock (never withdrawn) still runs (`stakePower(who, since)`) | `YoloLockHub.sol`; `desks/DisputeDesk.sol` |
| Split | the doer gets b of R, the rest of the stakers' 5% (5% − b) half burned, half to the treasury; the NFT 5% nobody earned burns; on a $YOLO reward the treasury half burns too | `desks/DisputeDesk.sol` |
| Examples, $100 USDC, no dispute | power worth $100: doer 94, burn 0.50 + NFT 5, treasury 0.50; worth $50: doer 92, burn 1.50 + 5, treasury 1.50; worth $5: doer 90.20, burn 2.40 + 5, treasury 2.40 | `test/YoloLockHub.t.sol`, `test/MoneyRules.t.sol` (`test_WorkedExamples`) |
| Fake | the lock is untouched: the punishment for a fake is the submission bond | — |
| Owner, admin | none; the hub pays nothing itself | `YoloLockHub.sol` |

### Burner (`BuybackBurner`)

| Rule | Value | Code |
|---|---|---|
| What comes in | the $YOLO the treasury would get, always; ETH, USDC and IMD burn shares only if the direct send to the buyback wallet at payout failed | `TaskVault.sol` |
| $YOLO | `burnYolo()`: all of it to `0x…dEaD` | `BuybackBurner.sol` |
| ETH, USDC, IMD | sent straight to the buyback wallet in the same transaction as the payout; `forward(token)` here is only the fallback for a send that reverted; no swap | `BuybackBurner.sol`, `TaskVault.sol` |
| Buyback wallet | set by the dev wallet (the DevPrices owner) with `setBuybackWallet`, at once, without delay; start `0x027E55f01e8Cf808E5D2a2Ad68E5e7f67fD6dF6E` | `BuybackBurner.sol`, `script/LaunchPlan.sol` |
| Reward for calling | none; uncalled, the money waits | `BuybackBurner.sol` |

## Risks and trusted parties

- **Price parameters (no oracle).** The $YOLO price, ETH USD and IMD USD are protocol parameters, each changed by a transaction
  of the DevPrices owner, at most 10 times up or down per call; USDC = $1. Nothing on chain reads a pool for price, so trading
  does not move a price parameter. The risk moves from market manipulation to whether the parameter is kept current:
  a stale parameter does not touch anyone's locked money — bonds and payouts never read a live price — it only
  shifts the doer stake bonus until the parameter is updated.
- **Project treasury wallet `0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C`** (an EOA, not a multisig). It receives
  the first-hour tax (liquid) and the treasury vesting. It pays for launch 1 and is the pool's fee
  recipient (use 4). One key: trust in the project. Publicly promised, not code: the tax YOLO and the pool's YOLO
  fees are burned on arrival (use 5); the fee YOLO of tasks never reaches it (code).
- **Incentives wallet.** 62.5M liquid at launch and the vested rest; a project wallet, no mechanic of the protocol
  pays from it (section "Incentives").
- **Stabilizer / MM fund wallet.** 150M, liquid at launch, a standing market-making reserve: nothing in it is
  burned, the IMD it earns stays in it, it is used only for market operations and every trade is posted; a public
  promise, not code.
- **Pool fee recipient.** The treasury wallet, as the `requester` of launch 1 from its first block: 1% of pool
  volume for as long as the pool trades, in IMD and YOLO (use 4). Which wallet pays for launch 1 is set by who
  pays the order, not by code; check `requester` at the factory right after the launch.
- **IMD launch factory.** Deploys the token, seeds and owns the pool position, and splits pool fees; the seeding
  ticks come from the manifest.
- **No owner of the token, the gate, the hub or YOLO Predict.** Nobody can change supply, the
  first-hour schedule, balances or transfers after deployment, nor take stakes, burn shares or positions. The
  snapshot of the gate is written by the project treasury wallet until `seal`; after `seal` nobody can change it.

Launch 0 (gate, vestings, splitter) goes first, so `remainderTo` and the gate are fixed addresses when the token
launches ([docs/LAUNCH-TASK.md](LAUNCH-TASK.md)).
