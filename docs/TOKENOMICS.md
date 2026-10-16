# $YOLO tokenomics

$YOLO is the token of moneycanbuy.fun. The supply is fixed at **1,000,000,000 YOLO**. Nobody can mint more,
nobody can pause it, and the token has no owner. This page is the supply side: where every YOLO goes, how it
unlocks, and how the protocol prices things in dollars without a price oracle. What $YOLO is *used for* inside
the product (rewards, the doer stake, YOLO Predict, trophies, the NFT buy window) is
[docs/TOKEN-UTILITY.md](TOKEN-UTILITY.md).

## Split

| Bucket | Share | YOLO | Unlock |
|---|---:|---:|---|
| Incentives | 25% | 250,000,000 | 25% at launch, the rest linear over 24 months |
| Treasury | 22.222223% | 222,222,223 | one third at launch, the rest linear over 12 months |
| Liquidity | 15% | 150,000,000 | the factory pool at launch, locked forever |
| Stabilizer / MM fund | 15% | 150,000,000 | unlocked at launch |
| Swarm | 10% | 100,000,000 | the factory's share, at launch |
| Dev | 7.777777% | 77,777,777 | linear over 12 months |
| Future team | 5% | 50,000,000 | linear over 12 months |
| **Total** | **100%** | **1,000,000,000** | |

The percentages for Dev and Treasury are rounded for display; the YOLO amounts in the table are the exact
integer amounts and are what the code pays. All seven amounts add up to exactly 1,000,000,000.

- **Incentives.** A wallet, not a claim contract: a vesting contract releases 62,500,000 YOLO at launch and the
  rest linearly over 24 months to the project's incentives wallet. No contract of the protocol has access to this
  wallet and no mechanic pays from it — the project can only spend it the way any user would, by posting or
  sweetening ordinary tasks from it, each a separate decision, and the task contract pays the result from what
  it itself holds.
- **Treasury.** 74,074,074 YOLO at launch, the rest linearly over 12 months, to the treasury wallet. This vested
  allocation is a separate pot from the YOLO the treasury collects as protocol *income* (fees, the first-hour buy
  tax, the pool's YOLO-side fee): every unit of that income is burned, never kept (see "Where the fee goes" below).
- **Liquidity.** The IMD launch factory seeds the YOLO/IMD pool at launch, single-sided in YOLO. That LP position
  belongs to the factory and can never be withdrawn by anyone, including the project.
- **Stabilizer / MM fund.** One labeled project wallet with two jobs: capping the launch-hour pump, then acting as
  a market-making reserve. Fully unlocked at launch, run by hand against public rules — see "Stabilizer / MM fund"
  below.
- **Swarm.** The IMD launch factory's fixed cut, paid at launch.
- **Dev** and **Future team.** Linear over 12 months from launch, no cliff.

The vesting clocks start when the tokens arrive at launch: the first split pays every at-once amount and starts
every clock in the same transaction. The vesting contracts have no owner and nobody can speed them up; anyone may
call `release`, but it only pays the beneficiary wallet what its own schedule has already unlocked.

## Pricing without an oracle

The protocol uses **no price oracle at all** — not for $YOLO, not for ETH, not for IMD.
Three numbers are plain parameters, each set in a single transaction that emits an event the site reads:

| Parameter | Starting value | Used for |
|---|---:|---|
| $YOLO fully-diluted value (FDV) | a parameter | converting a non-YOLO reward to its YOLO-equivalent for the doer-stake bonus (see [TOKEN-UTILITY.md](TOKEN-UTILITY.md)) |
| ETH price | a parameter | the same, for ETH-denominated tasks |
| IMD price | a parameter | the same, for IMD-denominated tasks |
| USDC price | fixed at $1 | no parameter needed |

The YOLO price these parameters imply is the FDV divided by the 1,000,000,000 supply. This is the *only* place
these parameters matter. Reward minimums are flat amounts in each
currency (see "A fourth reward currency" in [TOKEN-UTILITY.md](TOKEN-UTILITY.md)), not a dollar figure run
through these parameters, and there is no per-task or per-protocol cap. These three parameters
have exactly one job left in the whole protocol: comparing a doer's locked YOLO against a reward in any currency
for the doer-stake bonus.

A live price feed (Chainlink, a pool TWAP) can be manipulated or can fail; a manually-set parameter cannot be
manipulated by a trade, but it can go stale while the market price moves. Nothing breaks when that happens:
payouts, bonds, disputes and YOLO Predict never depend on these parameters at all; the only thing that still
drifts from the real market price is the doer-stake bonus threshold — see "Risks and open questions".

The pool's own **opening price** is a different number from the FDV parameter above: the IMD launch factory
seeds the YOLO/IMD pool at a market cap denominated in IMD, fixed once at launch and unrelated to the FDV
parameter. The two numbers describe the same token but serve different purposes — one is the real, tradable
launch price, the other is an administrative conversion rate — and they are not kept in sync by any mechanism.
Do not read one from the other.

## Where the fee on an accepted reward goes

Every accepted task pays a 10% fee on its reward, split two ways (full flow, with the doer-stake mechanic, in
[TOKEN-UTILITY.md](TOKEN-UTILITY.md)):

- **5%, the "NFT part."** Goes to the identity.md NFT holders who voted correctly in a dispute. With no dispute,
  or a dispute the NFT vote got wrong or never decided, these 5% go to the treasury — unless the doer was staked,
  in which case they are burned instead (nobody validated the task, so there is nothing to pay the treasury a
  validation fee for).
- **5%, the "staker part."** Goes to the treasury, except a staked doer earns up to 4% of it as his own bonus
  (scaled by how much YOLO he has locked — see [TOKEN-UTILITY.md](TOKEN-UTILITY.md)); whatever is left after his
  bonus is split evenly between burning and the treasury.

**Every YOLO the treasury would otherwise receive as income is burned instead**, with no schedule and no
percentage kept: the fee YOLO of YOLO-denominated rewards and bonuses never reaches the treasury wallet at all
(the contract burns it directly); the first-hour buy tax and the pool's YOLO-side trading fee do land in the
treasury wallet first and are burned by hand on arrival, as a published, checkable transaction rather than a
contract rule. The treasury itself never accumulates $YOLO from protocol income — only from its 22.2% vesting
allocation above, and from its share of ETH, USDC and IMD fees.

## Unlock schedule

Share of the supply unlocked at each point after launch (the pool's 15% is counted as unlocked, since it can
never be withdrawn by anyone, including the project):

| When | Unlocked | YOLO |
|---|---:|---:|
| Day 0 | 54% | ~536.6M |
| Month 6 | 72% | ~721.4M |
| Month 12 | 91% | ~906.3M |
| Month 24 | 100% | 1,000,000,000 |

At month 12, Dev, Future team and Treasury are fully unlocked. Incentives keeps unlocking until month 24.

## Launch

The first hour of the pool follows a fixed schedule:

1. **Minutes 0–30.** Only identity.md NFT holders can buy. Each NFT registered in the gate lets its wallet buy up
   to 500,000 YOLO. Registering binds the NFT to that wallet for good; a cold wallet can delegate through
   delegate.xyz.
2. **Minutes 30–60.** Anyone can buy. A buy tax starts at 30% and falls linearly to 0% by minute 60, paid in YOLO
   to the treasury wallet.
3. **After 60 minutes.** $YOLO is a plain ERC-20: no tax, no limits, no owner, no mint, no pause.

The token only sees ERC-20 transfers out of the pool; the NFT gate checks the recipient of such a transfer. A buy
kept as an ERC-6909 claim inside the Uniswap v4 `PoolManager` is not a transfer, so a contract that keeps its
balance as a claim is neither gated nor taxed — a known limit of the design, not a bug (see "Risks" below). The
window and the tax stop ordinary wallets, Telegram trading bots and aggregators, which all take the token into a
wallet.

## Stabilizer / MM fund

At launch, the full 150,000,000 YOLO (15% of supply) of this bucket goes to one labeled wallet, run by hand
(not by a smart contract). Every rule below is a public promise, checkable against the wallet's on-chain
history:

| Rule | Value |
|---|---|
| Window | minute 30 to minute 60 after the pool opens (the NFT-only first 30 minutes are never touched) |
| Trigger | sells only while the pool price is at least **3×** the pool's opening price |
| Floor | never sells the price below 3× the opening price |
| Per sale | at most 2,500,000 YOLO (0.25% of supply), at most one sale per block |
| Per minute | at most 10,000,000 YOLO (1% of supply) |
| Total | at most 150,000,000 YOLO — the whole bucket, never more |
| Where | only the YOLO/IMD pool opened by the IMD launch factory |

Unsold YOLO and the IMD earned both stay in the wallet as a standing market-making reserve after minute 60: this
money is never burned and never paid to the team, dev or treasury. If the launch is quiet and the price never
reaches 3×, nothing is sold and the full 150,000,000 YOLO sits in the wallet as reserve. Every trade from this
wallet, in the launch hour and afterwards, is published with its transaction link. Because this is a manual
process and not a contract, these numbers are a public commitment, not a guarantee
enforced on-chain — see "Risks and open questions".

## Risks and open questions

- **No timelock on the three pricing parameters.** Unlike most protocol parameters (48-hour timelock, hard
  bounds), the FDV and the ETH/IMD price parameters move instantly in one transaction, which can misprice the
  doer-stake bonus threshold immediately, for every submission made afterwards — the one thing these parameters
  still affect, now that reward minimums are flat per-currency amounts and there are no caps anywhere in the
  protocol.
- **Stale prices cost nothing in money, but cost fairness.** If a price parameter is not updated after the
  market moves, no user's locked funds are at risk — but the doer-stake bonus threshold quietly becomes easier
  or harder to hit in real terms than intended.
- **The pool's opening price and the FDV parameter are two unrelated numbers for the same token** (see "Pricing
  without an oracle" above); reading tokenomics from one while expecting the other is an easy mistake to make.
- **The Stabilizer is a promise, not a contract.** Every number in its table is checkable only against public
  transaction history, not enforced by code.
- **Incentives and Treasury vesting have no spending plan.** The protocol guarantees these tokens unlock on
  schedule to their wallets; it makes no promise about what happens to them afterwards. Any claim about future
  incentive programs or treasury spending is a plan, not a protocol rule.
- **No oracle to cross-check the price parameters.** Because there is no live price feed, there is
  also no on-chain way to tell whether a price parameter is honest or current; the only check is public,
  off-chain scrutiny of the parameter's update transactions.
