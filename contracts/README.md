# Contracts v6 (Foundry)

> Current $YOLO rules: [docs/TOKENOMICS.md](../docs/TOKENOMICS.md) and [docs/TOKEN-UTILITY.md](../docs/TOKEN-UTILITY.md). Where this code differs from them, they apply.

The dare board contracts: Reward (ETH, USDC, IMD or the project token $YOLO), Submission with a Bond, Dispute,
gasless NFT vote, Ask the swarm / Appeal, payouts. The rules in plain words:
[docs/MECHANICS.md](../docs/MECHANICS.md).

## Build and test

```
git submodule update --init --recursive      # from the repository root, if cloned without --recursive
cd contracts
forge build --sizes
forge test                                   # 393 pass, 5 fork suites (11 tests) skip without FORK_URL
FORK_URL=<mainnet archive RPC> forge test --match-contract Fork -vv          # 11 fork tests, incl. all four launches via the live factory
FOUNDRY_FUZZ_RUNS=5000 forge test --match-contract ScenariosTest            # deep fuzz
FOUNDRY_INVARIANT_RUNS=300 FOUNDRY_INVARIANT_DEPTH=200 forge test --match-contract InvariantTest
forge test --match-contract GasTest -vv      # gas of the main functions
python3 script/check-launch-task.py          # docs/LAUNCH-TASK.md against the code
```

The full build compiles with via-IR and takes a few minutes.

### Dependencies

Not vendored: git submodules under `lib/`, pinned (see `../.gitmodules`).

| Library | Version | Used for |
|---|---|---|
| `forge-std` | v1.17.0 (`f3dae6e`) | tests and scripts |
| `@openzeppelin/contracts` | v5.1.0 (`69c8def`) | ERC-20 and ERC-721 bases, SafeERC20, ECDSA, ERC-1271, Ownable2Step, Base64, Strings, Math |
| `v4-core` | commit `46c6834` | only `TickMath`, `FullMath`, `BitMath`, `CustomRevert`, by the fork rehearsal (pool seed math); no contract in `src/` imports it |

Without git, the same versions:

```
cd contracts
forge install --no-git foundry-rs/forge-std@v1.17.0 OpenZeppelin/openzeppelin-contracts@v5.1.0 Uniswap/v4-core@46c6834698c48bc4a463a86d8420f4eb1d7f3b75
```

### Placeholders

The five project wallets (treasury, incentives, Stabilizer, dev, team) are placeholders in this repository:
`address(0xF001)`…`address(0xF005)` in `script/LaunchPlan.sol`, `<TREASURY_WALLET>` and so on in
`docs/LAUNCH-TASK.md` (`test/review/ReviewLaunch.t.sol` resolves them to the plan). No contract holds an owner
address in its code; the real wallets are written in right before the launch.

## Layout for the launch through the IMD swarm

The IMD launch worker links no libraries, takes constructor arguments of addresses and integers only and deploys a
launch in one factory transaction under the 16,777,216 gas cap. The core (~78 KB of code) does not fit one contract, so
it is split into contracts that call each other with plain CALLs:

| Contract | Launch | Runtime | Role |
|---|---|---|---|
| `TaskVault` | 2 (main) | 20.6 KB | the only address users call, approve and read: money, tasks, swarm requests and callbacks; forwards the rest to the desks with the sender and msg.value appended |
| `desks/CaseDesk` | 2 | 20.6 KB | submissions and the lazy state machine |
| `desks/DisputeDesk` | 2 | 22.7 KB | disputes, NFT votes, appeals, settlements, claims |
| `ParamsRegistry` | 1 | 16.1 KB | parameters (version 1 compiled in: `VaultParams.sol` `LaunchParams`), attesters, 48 h timelock |
| `ChainlinkUniV3PriceOracle`, `UniswapV3SwapAdapter` | 1 | 6.0 / 1.7 KB | prices for bonds, thresholds, the relayer shortfall, the YOLO bonus cap and the trophy price (with `YoloPoolSamples`: $YOLO from its v4 pool); mode A swaps |
| `token/YoloToken` | 1 (the launch's token) | 3.1 KB | $YOLO, 1B, no owner/mint/pause; minutes 0-30 after the pool opens only identity.md NFT holders buy (NftGate, 500,000 YOLO per NFT), minutes 30-60 a buy tax 30% → 0 to the project treasury wallet, then a plain ERC-20; no gate code = no whitelist |
| `token/NftGate` | 0 | 1.7 KB | the whitelist of the first 30 minutes: an NFT registered by its owner or a delegate.xyz delegate, bound to that wallet for good; books per calling token; no owner, no clock |
| `token/YoloSplitter` | 0 | 2.1 KB | launch 1's `remainderTo` (a fixed address, so it comes first and knows no token): one `split(token)` hands out the project's 75%: incentives vesting 250M, Stabilizer 150M, dev 77,777,777, team 50M, the rest to the treasury, then starts the four vesting clocks (`release`) |
| `token/Vestings` (`IncentivesVesting`, `DevVesting`, `TeamVesting`, `TreasuryVesting`: `ProjectVesting` with compiled-in schedules) | 0 | 1.9 KB each | incentives (project-run, spent off chain) 62.5M at once, the rest over 24 months; dev and team linear over 12 months; treasury 74,074,074 at once, the rest over 12 months; every clock starts when the token arrives (the split's `release`, `startOf`: only the YoloSplitter, bound as the starter in launch 0's transaction, starts a clock; audit A-03, swarm audit #2); no cliff; no owner, no acceleration |
| `helpers/TextRules`, `helpers/SwarmQuestion` (`SwarmQuestionBuilder`), `libraries/VoteLib` (`BallotChecker`), `helpers/AttestationChecker` | 1 | 4.1 / 5.5 / 2.4 / 2.1 KB | stateless checks and the swarm question body |
| `YoloSweetener` | 3 | 7.4 KB | "Sweeten with $YOLO": a YOLO bonus on any task (below) |
| `DareTrophy` | 3 | 12.4 KB | ERC-721 trophy of an accepted submission, paid in burned YOLO, metadata on chain (below) |
| `ProtocolDirectory` | 3 | 4.5 KB | the list of core versions (vault + modules) and the current one for new tasks, changeable after 48 h; no money |
| `HiddenList` | 3 | 3.7 KB | the site's hide list: standalone, reads nothing here and nothing here reads it, no money; an instant hide path (no timelock), or identity.md NFT holders vote by quorum |

The desks are wired to the vault by its constructor and accept that only in the transaction that deployed them
(transient-storage flag), so the three core contracts are one launch. `script/LaunchPlan.sol` holds the order and
the constructor arguments of all four launches; `test/fork/LaunchRehearsal.fork.t.sol` runs them through the live
ProjectFactory, gas counted at the deployer's address (calldata at least at the EIP-7623 floor), and trades the
token's first hour through the live Universal Router. Launch 0 (`evm_contracts`): NftGate, the four vestings,
YoloSplitter, 3.52M gas. Launch 1 is a `custom_token` launch of $YOLO (token, YOLO/IMD pool 15%, the swarm's 10%, the
seven support contracts; the remainder, 75%, to the YoloSplitter): 12.98M; launch 2 (`evm_contracts`, the core
with $YOLO as a static argument): 14.59M; launch 3 (`evm_contracts`, `YoloSweetener` and `DareTrophy`, the vault their
one argument, then `ProtocolDirectory` with version 1 = this vault and these modules, then `HiddenList`, the site's
hide list): 7.09M (forked mainnet).
`python3 script/check-launch-task.py` checks that the constructor arguments the review test holds against the plan
stand verbatim in `docs/LAUNCH-TASK.md` and that each launch text fits 8,000 characters.
The task for the swarm: `docs/LAUNCH-TASK.md`.

## $YOLO as a reward currency

- Rewards, fees and refunds of a $YOLO task are in YOLO; Bonds stay in IMD, sized from the oracle's YOLO value.
- A v4 pool keeps no price history, so `sampleYoloPrice()` (any plain EOA; anyone can run a keeper that calls it on a
  timer) stores the pool tick at most every 15 minutes, eight samples kept. A sample takes two calls: one reads the
  pool, a call in a later block stores that read only if the pool's slot0 and fee growth are unchanged, so a
  swap-sample-swap-back inside one block stores nothing (swarm audit #1; `sampleStep` tells what a call would do).
  The price is the HIGHEST sample of the last two hours (`lowestYoloTick` stays as a view), only with at least five
  samples there, never below the pool's opening price `yoloFloorImd` (the factory seeds the pool single-sided above
  it: below there is no liquidity), times the IMD TWAP, never above `yoloMaxUsd` ($0.01 per YOLO, a $10M valuation).
  A contract can't sample, so nobody can read and store in one transaction (fork test `ReviewYoloFork.test_Y6_*`).
- Without a reliable price (fewer than five samples, `hasPrice(yolo)` false, or any oracle call reverting): no USD
  minimum at creation (the author fee is the spam guard), and at submission the task counts as large, whatever the
  size: the mandatory swarm check and Bonds as for a reward at `largeRewardImd` (40 IMD), never below a priced value
  (`Desk._priceYolo`). A missing price can only make a submission dearer. The vault takes the oracle's number as it is;
  a depressed sample never lowers the highest one and the price never goes below the opening price, so a depressed
  price does not reach the vault. An inflated sample makes a submission dearer, but lowers the YOLO a task needs for
  the $5 minimum.

## Sweeten with $YOLO (`YoloSweetener`)

- Anyone adds YOLO to any open task, whatever its reward currency (`sweeten(taskId, amount)`); the bonus sits in the
  module, apart from the vault's money. The module only reads the vault (`submitTerms`: status, busy; `requests`) and
  the CaseDesk (`subCore`, `getSubmission`: the accepted submission and its swarm request) and changes nothing there;
  no owner.
- Accepted: anyone calls `payout(taskId, subId)`. If the swarm confirmed the submission (its latest swarm request
  answered "yes": the mandatory check or an escalation / appeal), or the bonus is worth at most the large threshold
  (`largeRewardUsd` of the task's parameters, by that version's oracle), the doer gets all of it; otherwise they get
  the threshold's worth (no reliable price: the payout waits, nothing moves, and pays all of it after 7 days with
  still no price; swarm audit #6) and the rest goes back to the sweeteners pro rata to what each
  put in (`withdraw`, no notice; the last one takes what is left). The doer pays the task's `feeBps` (10%) on what they
  get, the fee goes to the treasury of the current parameters, all in YOLO.
- Expired or unwound (or open past its deadline): each sweetener `withdraw(taskId)`s their own. Open with no active
  submission: they may also take it back after an hour of public notice (`announceWithdraw`, event
  `WithdrawAnnounced`, view `pendingWithdraw`; the notice holds a day after it matures); while
  a submission is active nothing leaves. The module plays no timers: poke the task first.
- Launch 3, after the vault (its constructor reads the registry, $YOLO and the CaseDesk from it); 7.4 KB. Tests:
  `test/Sweetener.t.sol`, the invariant `invariant_SweetenerHoldsEveryBonus` (balance = open bonuses = what their
  sweeteners may take back) and `_settleSweetener` at the end of every scenario (nothing stuck).
Events of submissions and disputes come from the desks: whoever reads logs reads the vault and both desks.

## Trophies (`DareTrophy`)

- The doer of an accepted submission mints its ERC-721 trophy once (`mint(subId, title, maxYolo)`, token id =
  submission id). Price: `priceUsd` ($1.50) at the oracle's YOLO price, `fallbackYolo` (10,000 YOLO) while YOLO has
  no price or the oracle fails; paid in YOLO and sent to `0x…dEaD` (burned; the contract keeps none).
- `tokenURI` builds a base64 JSON on chain: a 24x24 SVG badge of the task's category (`badge(category)`: gold frame,
  category colour, a 16x16 white icon), task and submission numbers, the title the doer gave at mint (vault text
  rules, 1..64 bytes; the vault keeps the task title only in `TaskCreated`), reward, mint date, proof link.
- No owner. Tests: `test/Trophy.t.sol`, the invariant `invariant_TrophiesOnlyForAcceptedDoersAndEveryYoloBurned`.

## Rules at a glance

| Rule | How it works |
|---|---|
| Dispute window | 24 h for every task; the parameter's lower bound in code is 24 h |
| Fee without a dispute | the full 10% to a single Treasury (in the Reward currency) |
| Fee after a dispute | NFT vote decided and was right: 6% to the votes on the winning side (of this submission), 4% to the Treasury; no NFT decision or a wrong one: 10% to the Treasury |
| Loser's Bond | 50/50 between the winners and the correct NFT votes; NFT vote wrong or undecided: all to the winners |
| NFT tie, nobody asked the swarm | accepted, the disputers' Bonds split 50/50 between the doer and the Treasury |
| Ask the swarm on a tie | anyone, picking a side (`callSwarm(subId, sidesDoer)`) |
| Swarm silence | the 6 h timeout plus the 1 h delivery grace, or Intake already `completed` without an answer (status 1/2): silence right away |
| Silence on the mandatory check (R ≥ $300) | same as silence: a normal dispute window opens from the moment of silence |
| Queued submission with a mandatory check | the question is asked automatically on activation from the doer's prepayment; if it can't be asked (price went up, Intake broken): same as silence, prepayment refunded |
| Appeal after the reply window | the question is asked lazily by any call on the task (`poke`); if Intake fails, the Appeal is voided and everything is refunded |
| Outcomes | Accepted / Rejected / Unwound (there is no "not proven") |
| Mandatory check says no, no disputes | the doer's Bond goes to the Treasury (there is no winner) |
| NFT voter pay | directly from their submission, no epoch pool |
| Fee on contributors | none |
| Treasury | one (`treasury`, the project wallet); the vault pays no cost out of it; `sweepTreasury` takes the address from the current registry version |
| Submission protection | `submit(..., minReward, maxImdIn, ...)`: the Reward can't be swapped right before a submission, the Bond/fee can't be inflated |
| Swarm fee cap | `appeal(..., maxImdIn, ...)`, `callSwarm(..., reason, maxImdIn, ...)` (the price can change with no delay) |
| Number of disputers | unlimited; the swarm question carries the first `maxClaims` reasons plus the caller's own reason |
| Texts | valid UTF-8 only (any script): broken text could make Intake refuse, which equals silence |
| Swarm question size | parameter bounds guarantee a body ≤ 16,384 bytes (the Intake limit) |
| Window after a check answer | from the moment the answer is recorded in the contract (never less than 24 h) |

Also: Bonds of max(1 IMD, 0.5 + 3% R) for the doer (×2 after rejections and in the queue) and max(1 IMD, 0.5 + 1% R) for a disputer / appellant / swarm caller; the swarm fee is refunded to the winner from the loser's Bond; the Reward never goes to a disputer; EIP-712 votes in batches with gas refunds to the relayer; NFT decision at the vote end at a margin of 10 (no instant decision, audit C-02) / at least 1 winning wallet; emergency exit 30 days after a step timer; parameters behind a 48 h timelock within hard bounds, copied into the task at creation; payment method A (swap through Uniswap v3) and B (your own IMD).

## Task and submission fields on chain

`createTask(currency, amount, deadline, title, condition, category, proofType, cover, authorFee, payIn)`. Every field is
set once and can never change (no setter: nothing can be swapped during a dispute). Only `condition`, the proof and the
proof type reach the swarm question.

| Field | Where it lives | Limit (revert) | Who reads it |
|---|---|---|---|
| `title` | `TaskCreated` only | 1..80 bytes, `checkText` rule (`BadTitle`) | site (card, task page) |
| `condition` | `Task.condition` + `TaskCreated` | 1..`maxTextBytes` (256), `checkText` (`BadText`) | swarm (`TASK:`), NFT voters, site |
| `category` | `Task.category` (packed, no extra SSTORE) + `TaskCreated` | `< 7`: 0 social, 1 stream, 2 irl, 3 onchain, 4 dev, 5 art, 6 other (`BadCategory`) | site |
| `proofType` | `Task.proofType` (same slot) + `TaskCreated` | `< 4`: 0 x_post, 1 video, 2 onchain_tx, 3 link (`BadProofType`) | `submit` check, swarm (`PROOF TYPE:`), site |
| `cover` | `TaskCreated` only | empty, `ipfs://…` or `https://…`, ≤ 160 bytes of link characters (`BadCover`) | site |
| `proofUri` (submit) | `Submission.proofUri` + `Submitted`… | ≤ 256 bytes (`BadText`) and the form of the task's proof type (`BadProof(proofType)`) | swarm (`PROOF:`), NFT voters, site |

Proof forms (`TextLib.checkProof`; link characters = printable ASCII without space, `"`, `'`, `\`, `<`, `>`):
- `x_post`: `https://[www.|mobile.](x.com|twitter.com)/<handle 1-15 [A-Za-z0-9_]>/status/<1-19 digits>`, then nothing,
  or `?` / `/` and link characters.
- `video`: `https://[www.|m.](youtube.com|youtu.be|kick.com|twitch.tv|clips.twitch.tv)/<non-empty path>`, or an
  `x_post` link (a video posted on X).
- `onchain_tx`: `0x` + 64 hex digits (an Ethereum mainnet transaction hash).
- `link`: `https://` + link characters.

Swarm question: `<prefix>TASK: <condition> | PROOF: <proofUri> | PROOF TYPE: <x_post|video|onchain_tx|link> | DOER:
0x… | DOER CODE: IMD-<taskId>-<DOER, 0x + 40 hex lowercase> | CASE: t/s/n`. The contract computes the doer code itself,
byte for byte what the site shows the doer. The whole address: any shorter part
can be ground out by a vanity tool in seconds, and a thief could then hand in an honest doer's post first. The default prefix tells
the panel the post, video description or page must contain the whole DOER CODE, and for `onchain_tx` the transaction
must be sent from DOER instead. Fixed parts are at most `ParamsBounds.QUESTION_FIXED` = 234 bytes at the largest ids
(the task id is in it twice), so the bound is `prefix + 2 × maxTextBytes ≤ 1766` (2000 Intake limit); the worst
question is built directly in `ReviewQuestionSize` and `EvidenceTest` (exactly 2000 at the bound).

Doer's evidence (`submit(taskId, proofUri, Evidence{screenshot, screenshotRaw, note}, minReward, maxImdIn, payIn)`,
both parts optional): `screenshot` = sha2-256 digest of the IPFS block (CIDv1 raw or dag-pb, one slot instead of four
for `ipfs://<CID>`), `note` ≤ 200 bytes with the condition's text rule. Stored only when given (the swarm question is
built on chain in whatever transaction asks it: a queued check activated by someone's poke, the lazy appeal) and
emitted in `EvidenceAttached`. They go to `definitions` next to `doer_reply` (`doer_note`, `doer_shot` =
`https://ipfs.io/ipfs/<CID>`), never into the question text; the template marks them untrusted statements of the doer.
`bodySize` counts both members; `EvidenceTest.test_WorstBodyFitsIntakeLimit` builds the whole body at the largest
parameters the bounds accept (15 479 of 16 384 bytes).

Swarm answer: an attestation counts only from the panel we order, `minPanelSize` 7 / `minQuorum` 5 (hard
bounds: panel 3..101, quorum a strict majority and at most the panel, both exactly the `panelSize` / `quorum` of
`bodyFields`; changed like every parameter, through the 48 h timelock, for new tasks). A smaller panel or quorum, or
inconsistent counts, is not a verdict: ignored (`AttestationIgnored` code 14), and
the question ends as swarm silence.

Title and cover are only in the event (`forge test --match-contract CoverTest -vv`): a 66-byte `ipfs://<CIDv1>`
costs ~18k gas extra in `createTask`, the same string in storage ~87k more (4 new slots, measured 112.5k vs 25.9k).
Nothing on chain reads them; the site reads `TaskCreated` with `eth_getLogs`.

Gas (`GasTest`): the title in the event and the proof type cost ~4.6k in `createTask`; the proof form check (~13k) and
the longer question cost ~14k in `submit`.

## Submission states

| From | Event | To |
|---|---|---|
| — | `submit`, task is free | `Review` (large task: first a swarm question in the same transaction) |
| — | `submit`, another submission is active | `Queued` |
| `Queued` | the previous one ended rejected | `Review` (large: the question is asked right away from the prepayment) |
| `Queued` | task accepted / unwound | `Void` (Bond back, `claimVoidSubmission`) |
| `Review` large | swarm says yes | 24 h dispute window from the moment the answer is recorded in the contract (`CaseDesk.sol:363-365`, `recordedAt`) |
| `Review` large | swarm says no | `Final/Rejected`, Bond to the Treasury |
| `Review` large | silence | 24 h dispute window from the moment of silence |
| `Review` | window over, no disputes | `Final/Accepted` |
| `Review` | first `dispute` | `Voting` (24 h), doer reply 12 h, more disputers can join until the dispute window ends |
| `Voting` | end of voting, margin ≥ 10 | `Decided` |
| `Voting` | end of voting, otherwise | `NoDecision` (24 h window) |
| `NoDecision` | `callSwarm` (anyone, fee + Bond, picks a side) | `Asked` |
| `NoDecision` | window over | `Final/Accepted` (tie rule) |
| `Decided` | `appeal` (anyone, against the decision, fee + Bond) | `Appealed` |
| `Decided` | window over | `Final` per the NFT decision |
| `Appealed` | the other side replies or 12 h pass, then any call | `Asked` (or the Appeal is voided if the price went up / Intake fails) |
| `Asked` | answer signed within 6 h, delivered within 7 h | `Final` per the swarm answer |
| `Asked` | silence | back to `NoDecision` / `Decided`, a new 24 h window from the moment of silence; the caller's Bond is refunded, the fee is lost |
| any open step | 30 days after the timer, `emergencyExit` | `Final/Unwound` |

## Settlement

Accepted: the doer gets R − 10%. Fee: see the table above. The doer's Bond comes back.

The losing side's Bonds (plus the Bond of a losing swarm caller) form the penalty. In order: (0) a winning swarm caller is refunded the swarm fee; (1) relayers' gas shortfall; (2) tie without the swarm: 50% to the doer, 50% to the Treasury; NFT vote right: 50% to the winners pro rata to their Bonds, 50% to the correct votes; otherwise everything to the winners. A winner who also funded the task gets only their own Bond back; their share goes to the correct votes (if the NFT vote was right) or to the Treasury. The dispute gas-fee pot, after relayers, goes to the disputers pro rata to their fees.

Unwind: all Bonds and unspent prepayments back, contributions back; what was already paid to the swarm and the relayers is not returned.

## Gas (direct call, without the 21k base; Intake is a mock)

| Function | Gas | Function | Gas |
|---|---|---|---|
| createTask (USDC / ETH, no cover; +18k with an ipfs cover) | 360k / 295k | submitVotes (1 signature, 20 NFTs) | 362k |
| topUp (free / during a submission) | 190k / 229k | submitVotes (3 signatures, 17 NFTs) | 436k |
| submit (small / large with a swarm question) | 458k / 797k | poke: end of voting → decision | 121k |
| dispute (first / second) | 397k / 299k | poke: appeal → swarm question | 666k |
| reply | 122k | poke: settle rejection / acceptance | 356k / 246k |
| appeal | 276k | callSwarm (Bond + fee + question) | 684k |
| claimDisputer / claimVoterReward | 167k / 135k | onOracleResult (200k limit) | 41k |
| withdraw / withdrawContribution | 70k / 80k | poke: swarm silence → window | 197k |
| announceWithdraw | 62k | | |

## Tests

398 tests in 62 suites, as Foundry counts them (the three invariants of `InvariantTest` run as one). Without `FORK_URL`:
393 pass and the 5 fork suites skip (Foundry counts each skipped suite as one). With a mainnet archive RPC the 11 fork
tests pass as well. Acknowledged findings are described in `docs/AUDIT-INTERNAL.md`; each lists its impact and why it
was accepted.

| Folder | Suites | Tests | What |
|---|---:|---:|---|
| `test/` | 21 | 256 | unit tests per area (`Tasks`, `Disputes`, `Swarm`, `Votes`, `Payments`, `Desks`, `Yolo*`, `Sweetener`, `Trophy`, `HiddenList`, …), fuzzed `Scenarios`, `Invariant` (money in = money out, every bonus and trophy accounted for), `Gas` |
| `test/audit/` | 15 | 58 | the internal audit (`docs/AUDIT-INTERNAL.md`): PoCs of fixed findings turned into guards, the regression tests of the round-2 fixes, and guards of rules that must always hold; `swarm117/`: the PoCs and regression tests of the swarm audit of `d9a1ee5`; `round2/`: the PoCs of the second swarm audit of `7714a24` |
| `test/review/` | 23 | 87 | finding proofs flipped into checks, the launch texts of `docs/LAUNCH-TASK.md` against `LaunchPlan` byte for byte, gas and size limits; 8 of the 87 run on a mainnet fork (`ReviewLaunchFork`, `ReviewYoloFork`) |
| `test/fork/` | 3 | 3 | mainnet fork: the price oracle, the Uniswap v3 adapter, and the rehearsal of all four launches through the live IMD ProjectFactory |
| **Total** | **62** | **398** | 393 without `FORK_URL`, plus 11 on a fork |

The Uniswap adapter and the price oracle are covered by fork tests (`FORK_URL=... forge test --match-contract Fork`,
read only).

## Risks and external assumptions

- The NFT decides only when the 24 h vote ends (audit C-02); the doer cannot dispute their own submission (audit C-01).
- There can be any number of disputers, but only the first `maxClaims` (16) reasons go into the swarm question, and the doer's sock puppets could take them. Whoever asks the swarm or appeals always adds their own reason; the doer cannot dispute their own submission (audit C-01), but other addresses they control can, and the panel is told that claims are untrusted statements.
- A vote by a contract that owns NFTs is checked via ERC-1271: a contract that answers "valid" to everything gives its NFT votes to any relayer. Rare (NFT escrow/staking).
- The token can be affected via the bridge/OFT; if the vault address got blocked for IMD, Bonds would freeze and the emergency exit would not help. IMD has no transfer fee (payment method B measures what arrived by balance anyway).
- The swarm price and callback gas can change with no delay; with a cut callback gas, swarm answers turn into "silence".
- The side that benefits from swarm silence writes part of the question text (appeal reply, proof). How the IMD plan handles free text and how often it refuses a body on mainnet is not verified.

## Not in this version

- Uniswap v4 adapter (where the main IMD/ETH liquidity is): swaps go through Uniswap v3, and the IMD price comes from Chainlink and the 30-minute TWAP of the USDC/IMD v3 pool (`src/oracles/ChainlinkUniV3PriceOracle.sol`).
- The `questionHash` formula of the IMD plane (not needed by the contract: there is no public `submitAttestation` fallback, audit B-01).
- Mainnet deployment: the contracts go live only through the IMD swarm launches of `docs/LAUNCH-TASK.md`.
