# $YOLO tokenomics

$YOLO is the token of moneycanbuy.fun. The supply is fixed at **1,000,000,000 YOLO**. Nobody can mint more,
and nobody can pause it. The token has no owner. This page is the supply side: where every YOLO goes and how it
unlocks. What $YOLO is used for inside the product is in [docs/YOLO.md](YOLO.md).

## Split

| Bucket | Share | YOLO | Unlock |
|---|---:|---:|---|
| Incentives | 25% | 250,000,000 | 25% at launch, the rest linear over 24 months |
| Treasury | 22.2222223% | 222,222,223 | one third at launch, the rest linear over 12 months |
| Liquidity | 15% | 150,000,000 | the factory pool at launch, locked forever |
| Stabilizer / MM fund | 15% | 150,000,000 | unlocked at launch |
| Swarm | 10% | 100,000,000 | the factory's share, at launch |
| Dev | 7.7777777% | 77,777,777 | linear over 12 months |
| Future team | 5% | 50,000,000 | linear over 12 months |
| **Total** | **100%** | **1,000,000,000** | |

- **Incentives.** A project wallet, not a claim contract. A vesting contract releases them to the project's
  incentives wallet: 62,500,000 at launch and the rest linearly over 24 months. No contract has access to the
  wallet, no mechanic of the protocol pays from it and the protocol promises nothing from it.
- **Treasury.** 74,074,074 at launch, the rest linearly over 12 months, to the treasury wallet. This vested
  allocation is separate from the YOLO the treasury collects as *income*: every unit of that income burns — the
  fee YOLO of tasks and bonuses is burned by the contracts and never reaches the wallet; the first-hour tax
  and the pool's YOLO fees reach the wallet and are burned by hand on arrival ([docs/YOLO.md](YOLO.md), use 5).
- **Liquidity.** The factory seeds the YOLO/IMD pool at launch. That position can never be withdrawn.
- **Stabilizer / MM fund.** Market-making tokens, fully unlocked at launch.
- **Swarm.** The IMD factory's share, paid at launch.
- **Dev** and **Future team.** Linear over 12 months from launch, with no cliff.

The vesting clocks start when the tokens arrive: the first split right after launch pays the at-once parts and
starts every clock. The vestings have no owner, and nobody can speed them up. Anyone can call `release`, but it
only pays the beneficiary what the schedule has already unlocked.

## Burn sources and where the fee goes

These rules add burns and determine who gets the 10% fee of an accepted reward. None of this changes the split
above, and none of it pays from a fund wallet: every amount comes from money the paying contract holds. Mechanics
with code references: [docs/MECHANICS.md](MECHANICS.md) "Money and fees", [docs/YOLO.md](YOLO.md).

**The 10% fee of an accepted reward** (`desks/DisputeDesk.sol`), in the reward's currency:
- 5% to the NFT holders who voted right in a dispute; with no dispute, or a wrong or missing NFT decision, these
  5% go to the treasury when the doer has no stake and are burned when they have one;
- the other 5% (the stakers' part) to the treasury when the doer has no stake;
- **staked doer**: YOLO locked in `YoloLockHub` for 1 to 52 weeks, power = amount × weeks / 52, fixed at the lock;
  any power above 0 at their submission counts, also when they put money into the task. Bonus b = 4% × min(1,
  power / the reward in YOLO) of the reward to them (the reward = the task's whole pot at the submission, every
  top-up included, no YOLO add-on; a non-YOLO reward converted at the $YOLO price parameter at submission), the rest of
  the stakers' 5% (5% − b) half burned, half to the treasury. Example, $100 accepted without a dispute: power
  worth $100: doer $94, burn $0.50 + $5 (the NFT part nobody earned), treasury $0.50; worth $50: doer $92, burn
  $1.50 + $5, treasury $1.50; worth $5: doer $90.20, burn $2.40 + $5, treasury $2.40; no stake: doer $90, treasury
  $10. The treasury gets less from staked doers' tasks, not nothing. The bigger the task, the more locked YOLO the
  whole 4% needs: a stake is demand for YOLO that grows with the rewards on the board.

**Burn sources**
- **Staked doers' fee share.** Half of (5% − b), plus the NFT 5% when nobody earned it: from 5.5% (full power, no
  dispute) to almost 7.5% (a small power: b near 0), 0.5% to almost 2.5% when the NFT votes got theirs. In $YOLO it
  goes to the `BuybackBurner`, where anyone's `burnYolo` sends it to `0x…dEaD`; in ETH, USDC or IMD straight to the buyback wallet in the same transaction
  (`TaskVault.sol`); `BuybackBurner` holds it only if that send fails, and anyone's `forward` sends it on
  (`BuybackBurner.sol`). No one is paid for calling it.
- **YOLO income of the treasury.** On a $YOLO reward the treasury's part of the fee goes from the vault to the
  `BuybackBurner` for burning (`TaskVault.sol`): 10% of the reward without a stake (5% when the NFT votes got theirs); with a staked doer,
  everything but their bonus — 10% − b (5% − b when the NFT votes got theirs). The same rule applies to $YOLO
  bonuses (`YoloSweetener.sol`). The first-hour tax and the YOLO side of the pool's 1% fee reach the treasury
  wallet and are burned by hand on arrival (a commitment, not code).
- **YOLO Predict.** 5% of every position is held and burns when the market resolves; another 5% is deferred and
  burns if the task is not done; if it is done, those 5% go 2.5% to the author and 2.5% to the doer. If the task is
  unwound, every position comes back in full, nothing burns (`YoloPredict.sol`).
- **Trophies.** The price of a trophy (a fixed 7,777 YOLO) burns (`DareTrophy.sol`).

**Lock, not burn.** The doer stake sits in `YoloLockHub` (`YoloLockHub.sol`), out of circulation for its term (1 to
52 weeks, no early exit) but not destroyed, and returns to its owner on `withdraw` after the end.

## Unlock schedule

Share of the supply unlocked at each point after launch (the pool's 15% is counted as unlocked):

| When | Unlocked | YOLO |
|---|---:|---:|
| Day 0 | 54% | ~536.6M |
| Month 6 | 72% | ~721.4M |
| Month 12 | 91% | ~906.3M |
| Month 24 | 100% | 1,000,000,000 |

At month 12, Dev, Future team and Treasury are fully unlocked. Incentives keep unlocking until month 24.

## Launch

The first hour of the pool follows fixed rules in the token contract:

1. **Minutes 0–30.** Only wallets of a sealed snapshot of identity.md NFT holders can buy: 500,000 YOLO per NFT
   held at the snapshot. Every sell pays a 30% tax.
2. **Minutes 30–60.** Anyone can buy and sell. A tax on both sides starts at 30% and falls to 0% by minute 60.
   The tax goes to the treasury wallet.
3. **After 60 minutes.** $YOLO is a plain ERC-20: no tax, no limits, no owner, no mint, no pause.

The token sees only ERC-20 transfers. A buy kept as an ERC-6909 claim inside the Uniswap v4 PoolManager is not one,
so a contract that never takes the token out can buy in minutes 0–30 without an NFT and sell the claim back
without the tax. The NFT window and the tax stop simple snipers: wallets, Telegram bots and aggregators, which
take the token into a wallet. A purpose-built contract can skip both.
