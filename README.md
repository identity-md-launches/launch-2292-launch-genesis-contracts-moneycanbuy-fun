<p align="center">
  <img src="brand/wordmark-2400x600.png" alt="moneycanbuy.fun" width="720">
</p>

<h3 align="center">Everyone has a price.<br>Name yours.</h3>

<p align="center">A board of paid dares on Ethereum, judged by the IMD swarm.</p>

---

## What it is

People post dares with a reward attached. Others take them on, do them and submit a public proof link. The contract
holds the money the whole time and pays out by itself; nobody can take rewards or bonds. The dev wallet (the owner of
`DevPrices`) may cancel an open task: all money goes back to those who put it in, swarm fees already paid excepted,
and it takes nothing for itself. The same wallet sets the `DevPrices` prices and the buyback wallet of `BuybackBurner`,
both at once, without delay.

Judging is decentralised. Anyone but the doer can dispute a submission; identity.md NFT holders vote on disputes; the
[IMD swarm](https://imd.fun) is the court of appeal when the NFT vote does not decide, or when its decision is
appealed, paid by whoever calls it.

## How it works

1. **Post a dare.** Write the condition as a short yes/no rule, pick the proof type (X post, video, on-chain
   transaction or link) and fund the reward in ETH, USDC, IMD or $YOLO, at or above a per-currency minimum, with a
   deadline. Anyone can add to the reward before the deadline.
2. **Do it and submit proof.** The doer submits a proof link and puts down a small bond (0.5 IMD plus 3% of the
   author's reward, in the reward's currency). Every dare is judged the same way: no mandatory check by the swarm before payout.
3. **Get judged and paid.** A 24 h dispute window follows. No dispute: the doer gets the reward minus a 10% fee (less
   with a $YOLO stake behind the submission). A dispute goes to a 24 h vote of identity.md NFT holders; the decision
   can be appealed to the swarm, and anyone can call the swarm when the NFT vote does not decide; the swarm's answer
   is final. The losing side's bonds go to the winners and to the NFT voters who were right; the contract settles
   everything.

The full rules, with references to the code: [docs/MECHANICS.md](docs/MECHANICS.md).

## Architecture

- **Contracts** ([contracts/](contracts/)), Solidity 0.8.28, Foundry. `TaskVault` is the only address users call and
  approve for tasks (the $YOLO contracts below take their own $YOLO approvals); it holds every task's money and forwards submissions and disputes to two desks (`CaseDesk`,
  `DisputeDesk`). The doer stake lives in `YoloLockHub`, a $YOLO lock for 1 to 52 weeks whose power raises a doer's
  share of the fee on acceptance. `VotePower` tells the desks who may vote with an NFT now (its owner or a
  delegate.xyz delegate). Prices need no oracle: `DevPrices` holds the dollar prices the protocol uses, set directly rather than read from
  a market. Parameters live in `ParamsRegistry` within hard bounds; each task reads the version in effect at its creation. The state machine is lazy: any call on a task plays its timers, and anyone
  can settle it. The swarm answers through the IMD Intake callback with an EIP-712 attestation.
- **$YOLO**, the project token: 1B fixed supply, no owner, no mint, no pause; a snapshot of identity.md NFT holders
  buys in the first 30 minutes (no registration), a 30% sell tax in minutes 0 to 30, a buy and sell tax falling from 30% to 0 in minutes 30 to 60, then a plain
  ERC-20. 80% of the pool's 1.25% LP fee (1% of volume) goes to the treasury wallet; anyone may call `claimFees`.
  $YOLO bonuses on any dare (`YoloSweetener`), on-chain trophies of accepted dares paid in burned YOLO (`DareTrophy`),
  WILL DO / WON'T DO positions on a dare's outcome (`YoloPredict`) and a burner that burns the $YOLO share of the fees and
  sends the ETH, USDC and IMD shares to the buyback wallet (`BuybackBurner`). Supply split and unlocks: [docs/TOKENOMICS.md](docs/TOKENOMICS.md); what the
  token is used for in the product: [docs/YOLO.md](docs/YOLO.md).
- **Deployment by the swarm.** Everything goes live through the IMD ProjectFactory in four launches (genesis
  contracts, the token with its support contracts, the core, the $YOLO modules), each under the 16,777,216 gas
  cap. The launch texts: [docs/LAUNCH-TASK.md](docs/LAUNCH-TASK.md).
- **No server of our own.** The app that reads and writes the live contracts (not part of this repository) is a
  static site that the swarm publishes to IPFS. It reads the chain through a public RPC, and every action is
  signed and sent by the user's own wallet. Nothing stops or freezes if a helper service disappears: NFT holders
  can submit their own votes, and any visitor can settle a task. [landing/](landing/) is the project's teaser page
  (not the app above): static HTML/CSS/JS, no build step, no backend.

## Repository

```
README.md
brand/           logo, mascot, banners, favicons and the brand book
landing/         the teaser site (static HTML/CSS/JS, no build step)
docs/
  MECHANICS.md       the rules of the board, with code references
  TOKENOMICS.md      $YOLO supply, split and unlocks, and who gets the fee
  YOLO.md            what $YOLO is used for in the product: rewards, the doer stake, YOLO Predict, trophies, the burner
  LAUNCH-TASK.md     the four launch texts for the IMD swarm
foundry.toml     Foundry config: sources, tests, scripts and libraries in contracts/
contracts/       the Foundry project (contracts/README.md: the contracts in detail, gas and size figures)
  src/             the contracts
  test/            unit, fuzz, invariant and gas tests; test/review: findings turned into tests;
                   test/fork: mainnet fork tests
  script/          LaunchPlan.sol (the order and constructor arguments of the four launches),
                   check-launch-task.py (docs/LAUNCH-TASK.md against the code)
  lib/             dependencies as git submodules (not vendored)
```

## Build and test

You need [Foundry](https://getfoundry.sh) and git.

```
git clone --recursive <this repository>
cd <repository>                                       # foundry.toml is at the root, the project in contracts/
forge build
forge test                                            # fork tests under contracts/test/fork skip without FORK_URL
FORK_URL=<mainnet archive RPC> forge test --match-path "contracts/test/fork/*" -vv
python3 contracts/script/check-launch-task.py         # launch texts in docs/LAUNCH-TASK.md = arguments in the code
```

Cloned without `--recursive`: run `git submodule update --init --recursive` first. Dependencies are pinned:
forge-std v1.17.0, OpenZeppelin Contracts v5.1.0 and Uniswap v4-core at `46c6834`, from which only `TickMath` and `FullMath`
(with their dependencies) are used, by the fork rehearsal and the launch review tests. More in [contracts/README.md](contracts/README.md).
