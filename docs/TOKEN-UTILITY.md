# $YOLO token utility

What $YOLO is actually used for inside moneycanbuy.fun, with the real dollar-example numbers behind each rule.
The supply split, the unlock schedule and how the protocol prices things without an oracle are in
[docs/TOKENOMICS.md](TOKENOMICS.md).

Three words used below: **author** (posted the task and put up the reward), **doer** (submits the proof of
completion), **contributor** (anyone, including the author, who added money to the reward).

## 1. A fourth reward currency

Any task's reward can be posted in ETH, USDC, IMD or $YOLO, and any contributor can top it up in the same
currency. Minimums are flat amounts in each currency, not a dollar figure run through a price conversion — so
creating a $YOLO task needs no price at all:

| Currency | Minimum reward |
|---|---:|
| USDC | 5 USDC |
| ETH | 0.002 ETH |
| IMD | 1 IMD |
| $YOLO | 1,000 YOLO |

**There is no maximum.** No cap per task, across all open tasks, or on how much a contributor can add to a
reward, in any currency including $YOLO.

## 2. Sweetening any task with $YOLO

Anyone can add a YOLO bonus on top of a task's reward, whatever currency that reward is already in — a $YOLO
add-on on a USDC task, for instance. The add-on:

- follows exactly the same lock-until-deadline rule as the reward itself: if the task is not done by its
  deadline, the add-on goes back to whoever added it, same as an unspent reward goes back to the author;
- has no cap of its own, same as the reward it sweetens (section 1 above);
- pays out by the same 10%-fee rule as the reward (section 4 below) — a $YOLO add-on's fee is 10% in YOLO,
  split exactly the way a $YOLO reward's fee would be.

## 3. The doer's bond

Submitting proof of completion costs the doer a bond, posted in the reward's own currency plus a small fixed IMD
part:

> **bond = 0.5 IMD + 3% of the reward, in the reward's currency** (a $YOLO add-on pays its own 3% in YOLO)

| Reward | Bond |
|---|---|
| 100 USDC | 0.5 IMD + 3 USDC |
| 0.04 ETH | 0.5 IMD + 0.0012 ETH |
| 1,000,000 YOLO | 0.5 IMD + 30,000 YOLO |

The bond is always 0.5 IMD + 3%, flat — it does not grow for a resubmission after a rejection or for jumping a
queue of pending submissions. The bond comes back in full if the
submission is accepted; if it is rejected as fake, the doer loses all of it (section 4).

## 4. Disputes: bond, margins and no gas reimbursement

Anyone but the doer (including the author) can dispute an accepted-looking submission within 24 hours, by
posting:

> **dispute bond = 0.5 IMD + 1% of the reward, in the reward's currency**

**One dispute per submission, ever (while it is live).** Whoever's dispute transaction lands first is "the"
disputer; a second dispute attempt simply fails while the first is still open, and the second challenger's money
never leaves their wallet. The doer gets no separate round to reply to a dispute — his case for the submission
being genuine is the proof he already posted when he submitted, nothing more is asked or accepted from him
afterwards.

A dispute goes to a vote of identity.md NFT holders, one NFT = one vote, open for 24 hours:

- **Early decision.** The moment one side is ahead by **20 votes or more** (and has at least one voting wallet),
  the vote closes immediately and that side wins.
- **End-of-window decision.** If nobody reaches a 20-vote margin, whichever side is ahead by **10 votes or more**
  at the 24-hour mark wins.
- **No decision.** Anything closer than that is a non-decision: the result, if nobody appeals to the swarm, is
  treated as if the submission had never been disputed (the doer is paid).

A task keeps the values of these three numbers it opened with.

**Calling the swarm: anyone, not just the two sides.** An NFT decision (or a non-decision) can be pushed to the
IMD swarm for a final, binding answer by either side of the dispute, or by a third party with nothing at stake.
The caller pays the dispute bond again plus the live swarm fee. If an outside caller (neither the doer
nor the original disputer) wins, the loser's bond pays them first: 0.5 IMD (refunding the swarm fee they fronted),
then whatever is left follows the normal rule below, split between the winning side and the outside caller in
proportion to their bonds. An outside caller who loses is treated exactly like any other losing side — bond gone,
fee not refunded.

The swarm answers within 6 hours of being asked. Silence counts as no answer: the case falls back to whatever it
was right before that call (the earlier NFT decision, or no decision at all), and the fee paid for the silent
call is gone, not refunded — only a fresh call by a new or the same caller, paying the fee again, tries the swarm
again.

**There is no separate ETH fee for disputes or votes**: an NFT holder who votes pays their own transaction's gas
and is never reimbursed for it from the protocol's money. The whole flow — dispute, vote, appeal — moves no ETH
through the contract at all.

**Where the loser's bond goes**, the general rule behind every scenario in section 5: the winning side always
gets its own bond back; of the loser's bond, if the NFT vote decided and the final result agrees with it, 50%
goes to the winner and 50% to the NFT holders who voted for the winning side; if the NFT vote never decided or
got overturned by the swarm, the winner gets the whole thing.

## 5. Where the money goes on a $100 reward

Four outcomes, with and without a doer stake (section 6) at full power (locked YOLO worth at least as much as
the reward):

**Accepted, no dispute**
| | Doer | Burn | Treasury |
|---|---:|---:|---:|
| No stake | $90 | — | $10 |
| Full-power stake | $94 | $5.50 | $0.50 |
| Half-power stake | $92 | $6.50 | $1.50 |

(Half power here means the doer's locked YOLO is worth $50 — half the reward — giving him half the maximum 4%
bonus, i.e. 2% = $2. See section 6 for the power formula; below a tenth of the reward's worth, the doer earns
nothing extra and the outcome is the same as "no stake.")

**Disputed, NFT voted correctly, submission accepted**
| | Doer | NFT voters | Burn | Treasury |
|---|---:|---:|---:|---:|
| No stake | $90 | $5 | — | $5 |
| Full-power stake | $94 | $5 | $0.50 | $0.50 |

**Disputed, NFT got it wrong or never decided, swarm accepts the submission** — the NFT voters get nothing; their
$5 goes to the treasury if the doer had no stake, or is burned if he did (same two bottom rows as "accepted, no
dispute" above).

**Rejected as fake** — the reward stays locked in the task, which reopens for new submissions; the doer's whole
bond is split 50/50 between the disputer and the NFT holders who voted correctly (or 100% to whichever side won,
if the NFT vote never decided).

Every row sums to the original $100 (or, for the bond, to the original bond): nothing is created or destroyed by
a payout, only redirected.

## 6. The doer's stake: locking YOLO for a bigger share

A doer can lock $YOLO in a dedicated lock (1 to 52 weeks, no early exit) to earn a bigger cut of the fee on tasks
he completes, instead of the base 90%.

- **Power** = amount locked × (weeks locked ÷ 52). Fixed the moment the lock is set or extended — it does not
  fall as the lock runs down, unlike a typical vote-escrow curve. Adding more YOLO or extending the term
  recalculates power upward, never down.
- **Bonus** b = 4% × min(1, power ÷ reward-in-YOLO), where "reward" includes any $YOLO add-on. A non-YOLO reward
  is converted to YOLO using the FDV parameter (see [TOKENOMICS.md](TOKENOMICS.md)) as it stands in the
  block the submission is made in; the power is read from the same block. A later change to the FDV
  parameter does not reach back and change this submission's bonus — only submissions made after the change use
  the new value.
- Power below a tenth of the reward earns nothing — same payout as having no stake at all.
- The power and the bonus are both fixed at the moment of submission; at payout the contract only checks that
  the same lock is still running. A lock that ended early forfeits the bonus (not the locked YOLO itself — only
  the submission bond punishes a fake). A doer who also contributed to this task's reward keeps the bonus just
  like anyone else; there is nothing to gain by it beyond getting back his own contribution at 90–94% like any
  other winner.
- On a reward paid in $YOLO itself, the treasury's whole normal share would have been burned anyway, so a
  full-power staked doer burns 6% total instead of 10%, with the other 4% going to him.

The locked YOLO itself is never slashed for a fake submission — only the ordinary submission bond (section 3) is
at risk. Locking is pure opportunity cost: the YOLO is out of circulation and out of the holder's control for the
whole term, with no early exit under any circumstance.

## 7. YOLO Predict: betting on whether a task gets done

Any task gets an automatic prediction market, open from its creation to its deadline, paused while a submission
is under review. **Anyone can take a WILL DO or WON'T DO position** — the author, a contributor to the reward,
whoever added a YOLO bonus, even the doer who ends up doing the task, with no exclusions. In $YOLO only,
irrevocably (a position can never be withdrawn or cancelled):

- **5% of every position burns immediately.**
- **5% is deferred**, paid out only if the task gets done: 2.5% to the author, 2.5% to the accepted doer,
  straight from the Predict contract, with no further fee. If the task is not done, this 5% burns instead — it
  never becomes part of anyone's position payout.
- **The remaining 90%** goes into the pool of its side.
- **Weight**: a position's voting power is (time left until the deadline ÷ the task's whole length)², fixed the
  moment it is placed — an early position counts for much more than a late one, and the "whole length" is always
  measured from the task's creation, not from the first position on it.
- **Payout**: the task being completed on time (even if judged after its deadline, through a dispute or a
  queued submission) makes WILL DO the winner; the deadline passing with nothing accepted makes WON'T DO the
  winner. Winners split the losing side's 90% pool by points (position × weight), on top of getting their own
  90% back.
- **Nobody predicted the winning side.** There is no void: the losing side's pool is not returned to the people
  who placed it, and nobody who bet the wrong way gets anything back.
  - Task done, nobody predicted WILL DO: the WON'T DO side's whole 90% pool splits evenly between the author and
    the accepted doer, on top of their usual 2.5%/2.5% deferred share.
  - Task not done, nobody predicted WON'T DO: the WILL DO side's whole 90% pool goes to the author in full, and
    the deferred 5% burns as it does for any task that was not done.

**Known, accepted risk: no cap, no exclusion, no undo.** There is no limit on the total size of either side of
the pool and no limit per wallet (such caps are trivially defeated by using more than one wallet). Nobody is kept out of the market either: a doer can bet WON'T DO
on his own task and then simply not do it, an author can bet against the task he posted, and neither position can
be cancelled once placed. On a task only one specific person can realistically finish, that person profits more
from betting against it and walking away than from doing it and collecting the reward.

**Known, accepted risk: an author profits from a task nobody does.** If a task attracts WILL DO positions but
nobody bets WON'T DO, and the task is then not done, the author collects the whole WILL DO pool (see "Nobody
predicted the winning side" above) on top of keeping the reward itself. An author can post a task that looks
doable enough to attract predictions while making sure, on his own side, that it never actually gets accepted.

## 8. Trophies

Once a submission is accepted, its doer (and only its doer) can mint a one-off NFT trophy of it, once. Minting
burns $1.50 worth of $YOLO, priced off the FDV parameter (see [TOKENOMICS.md](TOKENOMICS.md)) at mint
time. The YOLO is burned outright; the trophy contract keeps
none of it and charges no further fee.

## 9. identity.md NFT: the buy window and dispute voting

Holding an identity.md NFT does two things for $YOLO specifically:

- **The first-hour buy window** (see [TOKENOMICS.md](TOKENOMICS.md)): only a registered NFT's wallet can buy
  YOLO in the pool's first 30 minutes, up to 500,000 YOLO per NFT. Registering an NFT to a wallet is permanent.
- **Dispute voting** (section 4): one NFT, one vote, on every dispute across the whole protocol, not specific to
  $YOLO-denominated tasks. A correct vote earns a share of the loser's bond and, on a $YOLO-denominated task, a
  share of that task's fee — paid in whatever currency the task's reward was in. Voting itself costs the voter
  only their own gas; the protocol neither collects nor refunds ETH for it.

Holding or staking $YOLO itself carries **no governance power and no right to vote** — only the NFT does. $YOLO
and the identity.md NFT are two separate assets with two separate utilities that happen to interact at the buy
window and in how a correct vote gets paid.

## 10. Money flow, at a glance

| Flow | Who pays | Who/what receives |
|---|---|---|
| Task reward | author, topped up by any contributor | locked in the task contract until a result |
| YOLO add-on | anyone | locked alongside the reward, same rules |
| Submission bond | the doer | returned to the doer on acceptance; split between the disputer and correct NFT voters (or the winning side) on rejection |
| Dispute / appeal bond | the disputer / appellant | returned to the winner; the loser's share goes to the winner and/or correct NFT voters |
| Swarm question fee | whoever calls the swarm | the IMD swarm, in IMD; never refunded even on silence |
| Accepted-reward fee (10%) | the task contract, out of the reward | split between burn, the treasury and (on a dispute decided right, or a doer stake) the NFT voters and/or the doer |
| YOLO Predict entry (10% of a position) | the predictor | 5% burned at once, 5% deferred to the author/doer or burned |
| Trophy mint ($1.50 in YOLO) | the minting doer | burned |
| Doer stake bonus | the accepted reward's fee, not a separate source | the staked doer, up to 4% of the reward |

Every flow above moves money the paying contract already holds. Nothing here is ever paid out of the Incentives
wallet, the Stabilizer/MM fund or the Treasury's vested allocation — those are plain wallets with no contract
access, spent only by hand, one decision at a time (see [TOKENOMICS.md](TOKENOMICS.md)).

## Risks and open questions

- **YOLO Predict has no manipulation defense beyond "don't do it."** Section 7's risk — a task's own doer (or
  author) betting against it and simply walking away — is not mitigated; the market is open to everyone involved
  in the task.
- **The doer-stake YOLO conversion trusts the FDV parameter, not a market price.** There is no sampling window
  and nothing to go stale in the sense an oracle would: the number is whatever the parameter was last set to. If
  it is not updated while the real market price moves, the only thing this still affects — the doer-stake bonus
  threshold — drifts from reality. No money is at risk from this; a doer's bonus can simply end up priced on a
  number nobody has touched in months.
- **No project server runs any of this.** There is no backend, bot or keeper: whoever wants the buyback burner
  triggered has to call that function themselves, through the website, paying their own gas. If nobody bothers,
  the mechanic simply stalls — no money is lost, but nothing moves either.
- **There is no cap anywhere** (section 1 and 2): a reward, a YOLO add-on, or a YOLO Predict position
  can be any size, limited only by what the payer is willing to lock up.
- **Dispute margins (20 / 10 / 1 wallet) are parameters**, not constants; a 48-hour-delayed change only affects
  tasks created after it lands, so two tasks running at the same time can be judged by different margins.
