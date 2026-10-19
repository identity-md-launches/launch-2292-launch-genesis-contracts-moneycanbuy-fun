# TaskVault (Foundry)

The task board contracts: Reward (ETH, USDC, IMD or the project token $YOLO), Submission with a Bond, Dispute, NFT
vote, Ask the swarm / Appeal, payouts. The rules in words: `docs/MECHANICS.md`, the token: `docs/YOLO.md` and
`docs/TOKENOMICS.md`, the launch texts: `docs/LAUNCH-TASK.md`.

```
# from the repository root (foundry.toml there); dependencies are git submodules in contracts/lib/
# (OpenZeppelin 5.1.0, forge-std 1.17.0, v4-core math for the fork rehearsal)
forge build --sizes
forge test                                   # every suite; the fork suites skip without FORK_URL
FORK_URL=<mainnet archive RPC> forge test --match-path "contracts/test/fork/*" -vv   # all four launches via the live factory
FOUNDRY_FUZZ_RUNS=5000 forge test --match-contract ScenariosTest            # deep fuzz
FOUNDRY_INVARIANT_RUNS=300 FOUNDRY_INVARIANT_DEPTH=200 forge test --match-contract InvariantTest
forge test --match-contract GasTest -vv      # gas of the main functions
python3 contracts/script/check-launch-task.py   # docs/LAUNCH-TASK.md against contracts/test/review/ReviewLaunch.t.sol
```

## Layout for the launch through the IMD swarm

The IMD launch worker links no libraries, takes constructor arguments of addresses and integers only and deploys a
launch in one factory transaction under the 16,777,216 gas cap. The core is split into contracts that call each other
with plain CALLs. Runtime sizes are from `forge build --sizes`.

| Contract | Launch | Runtime | Role |
|---|---|---|---|
| `token/NftGate` | 0 | 1.9 KB | who may buy $YOLO in its first 30 minutes: a sealed snapshot of identity.md NFT holders, 500,000 YOLO per NFT; no owner, no clock |
| `token/Vestings` (`IncentivesVesting`, `DevVesting`, `TeamVesting`, `TreasuryVesting`) | 0 | 1.9 KB each | `ProjectVesting` with compiled-in schedules; each clock starts when the token arrives from the YoloSplitter; no owner, no acceleration |
| `token/YoloSplitter` | 0 | 2.1 KB | launch 1's `remainderTo`: one `split(token)` hands out the project's 75% and starts the four vesting clocks |
| `token/YoloToken` | 1 (the launch's token) | 4.0 KB | $YOLO, 1B, no owner/mint/pause; minutes 0-30 after trading opens only snapshot wallets buy (NftGate), minutes 30-60 a buy and sell tax falling from 30% to 0 to the project treasury wallet, then a plain ERC-20 |
| `DevPrices` | 1 | 2.5 KB | USD prices of $YOLO, ETH and IMD (USDC fixed at $1), no oracle; they size only the stake bonus comparison |
| `UniswapV3SwapAdapter` | 1 | 1.7 KB | payment method A: swaps through Uniswap v3 |
| `ParamsRegistry` | 1 | 13.6 KB | parameters within hard bounds (version 1 compiled in: `VaultParams.sol` `LaunchParams`), attesters |
| `helpers/TextRules`, `helpers/SwarmQuestion` (`SwarmQuestionBuilder`), `VotePower`, `helpers/AttestationChecker` | 1 | 5.2 / 5.7 / 0.9 / 2.1 KB | stateless checks, the swarm question body, NFT vote power |
| `BuybackBurner` | 1 | 2.6 KB | $YOLO burns by anyone's `burnYolo`; ETH, USDC and IMD go from the vault's payout straight to the buyback wallet, `forward` is the fallback if that send reverted |
| `YoloLockHub` | 2 (first) | 3.2 KB | the doer stake: a $YOLO lock for 1-52 weeks (`lock`, `withdraw` after the end); power = amount × weeks / 52, fixed at the lock |
| `desks/CaseDesk` | 2 | 19.8 KB | submissions and the lazy state machine |
| `desks/DisputeDesk` | 2 | 21.3 KB | disputes, NFT votes, appeals, settlements, claims; the fee split and the doer stake bonus |
| `TaskVault` | 2 (last) | 20.6 KB | the only address users call, approve and read: money, tasks, swarm requests and callbacks; forwards the rest to the desks with the sender and msg.value appended |
| `YoloSweetener` | 3 | 6.7 KB | «Sweeten with $YOLO»: a YOLO bonus on any task (below) |
| `DareTrophy` | 3 | 11.7 KB | ERC-721 trophy of an accepted submission, paid in burned YOLO, metadata on chain (below) |
| `ProtocolDirectory` | 3 | 4.5 KB | the list of core versions (vault + modules) and the current one for new tasks; no money |
| `HiddenList` | 3 | 3.8 KB | the site's hide list; reads nothing here, nothing here reads it |
| `YoloPredict` | 3 | 6.0 KB | YOLO Predict: WILL DO / WON'T DO positions in $YOLO on a task's outcome (`docs/YOLO.md`) |
| `TrophyCatalog` | 3 (second) | 4.2 KB | the trophy designs (a name and an SVG each) and which design new trophies of a category get; no money |

The desks are wired to the vault by its constructor and accept that only in the transaction that deployed them
(transient-storage flag), so the desks and the vault are one launch (launch 2, after the doer stake hub).
`script/LaunchPlan.sol` holds the order and the constructor arguments of all four launches;
`test/fork/LaunchRehearsal.fork.t.sol` runs them through the live ProjectFactory, gas counted at the deployer's address
(calldata at least at the EIP-7623 floor), and trades the token's first hour through the live Universal Router.
Launch 0 is `evm_contracts`, launch 1 the `custom_token` launch of $YOLO (token, YOLO/IMD pool 15%, the swarm's 10%,
the eight support contracts; the remainder, 75%, to the YoloSplitter), launches 2 and 3 are `evm_contracts`. Gas and
size headroom per launch: `docs/LAUNCH-TASK.md`. `script/DeployMainnet.s.sol` runs launches 1-3 of the same plan as a Foundry script (no launch 0, no token);
without `--broadcast` it is a dry run.

## Sweeten with $YOLO (`YoloSweetener`)

- Anyone adds YOLO to any open task before its deadline, whatever its reward currency (`sweeten(taskId, amount)`);
  the bonus sits in the module, apart from the vault's money. There is no limit on the bonus. The module only reads
  the vault (task, accepted submission, its settlement and votes) and changes nothing there; no owner.
- Locked like the reward: nobody takes it back while the task is open; expired or unwound (or open past its deadline
  with no submission in flight): each sweetener `withdraw(taskId)`s their own.
- Accepted: anyone calls `payout(taskId)`. The whole bonus goes by the reward's fee rule: the doer gets 90%; 5% go to
  the NFT votes on "accept" if the NFT decided right (claimed here with `claimVoter(taskId, payTo)`), the rest of the
  10% burns; if the vault paid the doer the stake bonus on this submission (`Settlement.stakeBps`), the doer gets the
  same share of the bonus. Takes deposits only once bound to the vault (`TaskVault.bindSweetener`, once, after
  launch 3).
- Tests: `test/Sweetener.t.sol`, the invariant `invariant_SweetenerHoldsEveryBonus` and `_settleSweetener` at the end
  of every scenario (nothing stuck).

Events of submissions and disputes come from the desks: whoever reads logs reads the vault and both desks.

## Trophies (`DareTrophy`)

- The doer of an accepted submission mints its ERC-721 trophy once (`mint(subId, title)`, token id = submission id).
  Price: a fixed 7,777 YOLO (`PRICE`), sent to `0x…dEaD` (burned; the contract keeps none).
- `tokenURI` builds a base64 JSON on chain: the picture, task and submission numbers, the title the doer gave at mint
  (vault text rules), reward, mint date, proof link, the design's name.
- The picture is the design `TrophyCatalog.designFor(category)` gave at mint (the category's, else the default, else
  0 = the built-in SVG badge of the category); the trophy keeps that design id for good. The catalog's owner (the
  project wallet, two-step transfer) adds designs (`addDesign(name, svg)`, a design never changes), assigns them to
  categories or as the default and switches them off for new mints.
- `DareTrophy` has no owner; its catalog address is fixed in the constructor. Tests: `test/Trophy.t.sol`
  (`test_Catalog_*`), the invariant `invariant_TrophiesOnlyForAcceptedDoersAndEveryYoloBurned`.

## Task and submission fields on chain

`createTask(currency, amount, deadline, title, rules, category, proofType, cover, payIn)`. Every field is set once and
has no setter. Only `rules`, the proof and the proof type reach the swarm.

| Field | Where it lives | Limit (revert) | Who reads it |
|---|---|---|---|
| `title` | `TaskCreated` only | 1..64 bytes, `checkText` rule (`BadTitle`) | site (card, task page) |
| `rules` = `TaskRules{task, proof, noIf}` | `Task.rulesHash` (keccak256 of the 3 texts, resupplied when the swarm is asked, `RulesMismatch`) + `TaskCreated` | each of the 3 texts 1..`maxTextBytes` (512), `checkText` (`BadText`) | swarm (definitions `task`, `task_proof`, `task_no`), NFT voters, site |
| `category` | `Task.category` + `TaskCreated` | `< 9`: 0 trash, 1 crazy, 2 action, 3 sport, 4 food, 5 prank, 6 shill, 7 onchain, 8 other (`BadCategory`) | site |
| `proofType` | `Task.proofType` + `TaskCreated` | `< 4`: 0 x_post, 1 video, 2 onchain_tx, 3 link (`BadProofType`) | `submit` check, swarm (`PROOF TYPE:`), site |
| `cover` | `TaskCreated` only | empty, `ipfs://…` or `https://…`, ≤ 160 bytes of link characters (`BadCover`) | site |
| `proofUri` (submit) | `Submission.proofUri` + `Submitted` | 1..512 bytes (`BadText`), an allowlisted `https://` host (`HostNotAllowed`) except `onchain_tx`, and the form of the task's proof type (`BadProof(proofType)`) | swarm (`PROOF:`), NFT voters, site |

Proof forms (link characters = printable ASCII without space, `"`, `'`, `\`, `<`, `>`):
- `x_post`: `https://[www.|m.|mobile.](x.com|twitter.com)/<handle 1-15 [A-Za-z0-9_]>/status/<1-19 digits>`, then nothing,
  or `?` / `/` and link characters.
- `video`: `https://[www.|m.|mobile.](youtube.com|youtu.be)/<non-empty path>`, or an `x_post` link (a video posted on X).
- `onchain_tx`: `0x` + 64 hex digits (an Ethereum mainnet transaction hash).
- `link`: `https://` + link characters.

Host allowlist (`TextRules`), checked first for every link proof (`x_post`, `video`, `link`) and for the evidence
screenshot link: `https://`, host = from `https://` to the first `/`, `?`, `#` or the end, one `www.` / `m.` /
`mobile.` prefix dropped, then byte-equal to one of the hosts listed in `src/helpers/TextRules.sol`
(`HostNotAllowed` otherwise).

Swarm question: `<prefix>TASK: definitions task, task_proof and task_no | PROOF: <proofUri> | PROOF TYPE: <x_post|video|onchain_tx|link> | DOER:
0x… | DOER CODE: IMD-<taskId>-<DOER, 0x + 40 hex lowercase> | CASE: t/s/n`. The contract computes the doer code
itself. The default prefix tells the panel the post, video description or page must contain the whole DOER CODE, and
for `onchain_tx` the transaction must be sent from DOER. Fixed parts are at most `ParamsBounds.QUESTION_FIXED` bytes
at the largest ids, and the parameter bounds keep the whole body within the Intake limits; the worst question is
built directly in `ReviewQuestionSize` and `EvidenceTest`.

Swarm answer: an attestation counts only from the panel the vault orders (`minPanelSize` / `minQuorum`, both exactly
the `panelSize` / `quorum` of `bodyFields`). A smaller panel or quorum, or inconsistent counts, is not a verdict: it is
ignored (`AttestationIgnored`), and the question ends as swarm silence.

## Submission states

| From | Event | To |
|---|---|---|
| — | `submit`, task is free | `Review` |
| — | `submit`, another submission is active | `Queued` |
| `Queued` | the previous one ended rejected | `Review` |
| `Queued` | task accepted / unwound | `Void` (Bond back, `claimVoidSubmission`) |
| `Review` | window over, no disputes | `Final/Accepted` |
| `Review` | first `dispute` (the only one; a second is rejected) | `Voting` (24 h) |
| `Voting` | margin ≥ 20 (instant) or end of voting, margin ≥ 10 | `Decided` |
| `Voting` | end of voting, otherwise | `NoDecision` (24 h window) |
| `NoDecision` | `callSwarm` (anyone, picks a side; a stranger pays fee + Bond; the doer or the disputer for their own side posts no Bond and pays the fee, the first call out of their own Bond's IMD) | `Asked` |
| `NoDecision` | window over | `Final/Accepted` (tie: the disputers' Bonds to the doer) |
| `Decided` | `appeal` (anyone, against the decision; a stranger pays fee + Bond; the doer or the disputer for their own side posts no Bond and pays the fee, the first call out of their own Bond's IMD) | `Appealed` |
| `Decided` | window over | `Final` per the NFT decision |
| `Appealed` | `askAppealSwarm` (anyone) | `Asked` (or the Appeal is voided and refunded if the Intake fails or nobody asks within 6 h) |
| `Asked` | answer within 6 h | `Final` per the swarm answer |
| `Asked` | silence | back to `NoDecision` / `Decided`, a new 24 h window from the moment of silence; the caller's Bond is refunded, the fee stays spent; the third silence ends the submission as if nobody had called |
| any open step | each step's own timer above settles it (the swarm at most 6 h plus a 1 h delivery grace per call, up to 3 calls) | `Final/Accepted` or `Final/Rejected` |
| any open step | `cancelTask` (the dev wallet, the owner of `DevPrices`) | `Final/Unwound` |

## Settlement

Bonds: 0.5 IMD + 3% R for the doer and 0.5 IMD + 1% R for a disputer/appellant/swarm caller, R in the reward's
currency (R = the author's own reward: top-ups of others and $YOLO add-ons are not counted), never doubled. Each NFT
holder votes with their own transaction (`vote(subId, side, payTo, tokenIds)`): no signatures, no relaying, no gas
refund.

Accepted: the doer gets the whole pot (the author's reward plus every top-up) − 10% (a staked doer up to the pot − 6%: the
stake bonus is fixed at the submission). Fee: 5% to
the correct NFT votes after a dispute they decided right, the rest to the Treasury; with a staked doer the second 5%
pays the doer's bonus and the rest of it goes half to the burn ($YOLO to the `BuybackBurner` for `burnYolo`, other tokens straight to the buyback
wallet, in the same transaction, `BuybackBurner` only as a fallback), half to the Treasury, and an unearned NFT 5%
burns; $YOLO the Treasury would get is burned (`docs/MECHANICS.md`). The doer's Bond comes back.

The losing side's Bonds (plus the Bond of a losing swarm caller) form the penalty, split separately in IMD and in the
reward currency. Swarm fees are not refunded; a third-party appellant (neither the doer nor the disputer) who wins
first gets 0.5 IMD of the loser's IMD bond. Then: NFT vote right: 50% to the winners pro rata to their Bonds, 50% to
the correct votes; otherwise (NFT wrong or undecided, the tie included) everything to the winners. A winner who also
funded the task gets their share like any winner. The Reward never goes to
a disputer. One dispute per submission: the first disputer whose transaction lands.

Unwind: all Bonds and unspent prepayments back, contributions back; what was already paid to the swarm is not
returned.

## External assumptions

- IMD is a bridged (OFT) token whose issuer can affect it; if the vault address got blocked for IMD, Bonds would
  freeze. IMD has no transfer fee (payment method B measures what arrived by balance anyway).
- The Intake price and callback gas are set by the swarm; with a cut callback gas, swarm answers turn into silence.
  `appeal` and `callSwarm` take `maxImdIn`.
- The side that benefits from swarm silence writes part of the question text (proof, note, dispute reason); claims are marked
  as untrusted statements for the panel.
