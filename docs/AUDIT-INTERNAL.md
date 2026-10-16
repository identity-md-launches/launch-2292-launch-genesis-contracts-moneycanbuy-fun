# Internal security audit: contracts v6

A security review of the contracts by the project itself, October 2026. It is not an independent audit by an
external firm; the IMD swarm audits the code again before each launch (`docs/LAUNCH-TASK.md`).

## Scope

- **Code audited:** the contracts as published in this repository. Round 1: findings, the C-03 fix, docs. Round 2:
  the fixes listed under "Decisions on the findings" at the end.
- **Code:** `contracts/src`, 29 files, 5,138 lines (Solidity 0.8.28, via-IR, Cancun), plus the wiring in
  `contracts/script/LaunchPlan.sol`. Paths of the form `src/…`, `test/…` and `script/…` below are relative to
  `contracts/`.
- **Areas**, each reviewed by its own auditor on an isolated copy of the tree:
  - **A, token and launch:** `token/*` (YoloToken, NftGate, YoloSplitter, Vestings, ProjectVesting), `YoloSweetener`,
    `oracles/*`, `adapters/UniswapV3SwapAdapter`.
  - **B, core:** `TaskVault`, `VaultParams`, `VaultTypes`, `ParamsRegistry`, `ProtocolDirectory`, `OracleAttestation`,
    `helpers/AttestationChecker`, `interfaces/*`.
  - **C, submissions and disputes:** `desks/*` (Desk, DeskApi, CaseDesk, DisputeDesk), `libraries/VoteLib`
    (BallotChecker), `helpers/SwarmQuestion`, `helpers/TextRules`, `DareTrophy`.
- **The promise the code was held to:** `docs/MECHANICS.md`, `docs/TOKENOMICS.md`, `docs/LAUNCH-TASK.md` and the
  NatSpec comments in `contracts/src`. Findings R-1 to R-8 (below) were re-run against this code.
- **Out of scope:** the site, optional off-chain helpers anyone can run (vote relayer, price keeper), the IMD swarm's own contracts (Intake, ProjectFactory),
  Uniswap, Chainlink, delegate.xyz, identity.md NFT.

## Method

1. **Five lenses per area:** money and math (rounding, dust, double payouts, stuck funds), rights and roles (who can
   call what, the 48 h timelocks), economics and manipulation (NFT votes, flash loans, sandwiches, first-hour sniping,
   Sybil), control flow (reentrancy, ordering, DoS, gas, loops), and conformance to the docs.
2. **Judge rule:** a finding counts only if a Foundry test reproduces it. The judge re-ran every PoC on the original
   code. Unit PoCs run on local mocks; A-01 was reproduced on a mainnet fork against the live IMD ProjectFactory,
   Uniswap v4 PoolManager and Universal Router.
3. **Fixes:** confirmed critical/high/medium are fixed when the fix does not change a rule of the game or the
   tokenomics. Anything that would change a rule is listed as an acknowledged finding. Each fix gets a
   regression test that fails on the original code.
4. **Round 2:** the open rule questions were decided in favour of the protocol and honesty to users (tokenomics shares
   and durations untouched); the decisions are listed at the end of this document. Each fix has a
   regression test that fails on the round-1 code (`test/audit/AuditFixP.t.sol`, `AuditFixQ.t.sol`); the round-1 PoCs
   of fixed findings were turned into guards (`test_Fixed_*`).
5. **After the fixes:** full `forge test`, fork tests with `FORK_URL`, launch gas against the 16,777,216 cap,
   `script/check-launch-task.py` and the "LAUNCH-TASK arguments = code" tests (`test/review/ReviewLaunch.t.sol`).

Acknowledged findings (A-01, A-02, A-04, B-03, B-04, B-06, B-07, C-01b, C-01c, C-04, C-05, C-05b, C-06) are described
here; each lists its impact and the accepted risk. Fixed findings keep their full description, and their regression
tests are in this repository.

Severity: **critical**, direct theft or permanent loss, or a bricked launch. **High**, loss under realistic
conditions, or a core public promise broken. **Medium**, bounded loss, cheap griefing, or a documented guarantee that
fails. **Low**, edge cases and minor griefing. **Info**, docs drift and hardening.

## Summary

| Severity | Found | Fixed in code | Acknowledged / open |
|---|---:|---:|---:|
| Critical | 0 | 0 | 0 |
| High | 1 | 0 | 1 (A-01: design limit of the factory launch, docs corrected) |
| Medium | 4 | 4 (C-01 partly) | C-01 Sybil remainder |
| Low | 7 | 2 (A-03, B-02 via B-01) | 5 |
| Info | 6 | 0 (A-05, B-05 fixed in docs) | 4 |

Items R-1, R-2 and R-3 are fixed too.

No path was found that steals funds or leaves money stuck. In every outcome path tested (accepted, rejected, tie, no
decision, swarm yes/no/silence, appeal won/lost/voided, expired, unwound, queued void) the books close at exactly zero:
every bucket is claimable, nothing is paid twice, `balance >= liabilities` holds throughout.

## Findings

| ID | Sev. | Title | Status |
|---|---|---|---|
| A-01 | High | ERC-6909 claims skip the NFT window and the buy tax | acknowledged, docs corrected |
| B-01 | Medium | A third party's answer to a copied question could decide a case via `submitAttestation` | **fixed** (fallback removed) |
| C-01 | Medium | The doer can shut honest disputers out of the swarm question | **fixed in part** (doer cannot dispute); Sybil remainder acknowledged |
| C-02 | Medium | Arrival-order relaying does not survive a public mempool | **fixed** (no instant decision) |
| C-03 | Medium | One ERC-1271 ballot could revert a whole vote batch | **fixed** |
| A-02 | Low | An NFT lent for one transaction can be bound to the borrower in the gate for good | acknowledged (no lending venue found) |
| A-03 | Low | Vesting clocks start at launch 0, not at the token's first block | **fixed** (clocks start at the split) |
| A-04 | Low | A wrong `NFT_GATE` address silently turns the whitelist off | acknowledged, launch checklist |
| B-02 | Low | Removing a leaked attester key also waits 48 h | **fixed by B-01** (a key alone no longer decides); 48 h kept |
| B-03 | Low | Timelocked proposals never expire; opposite attester proposals coexist | acknowledged |
| B-04 | Low | `createTask` has no expected-version guard | acknowledged |
| C-04 | Low | Zero bytes inside the canonical vote calldata are reimbursed at 16 gas | acknowledged |
| A-05 | Info | Docs drift in the token area | fixed (docs) |
| B-05 | Info | Docs drift in MECHANICS / comments | fixed (docs and comments) |
| B-06 | Info | Pinned dependencies of a parameter version cannot be replaced for live tasks | acknowledged |
| B-07 | Info | A $YOLO task created before YOLO has a price can hold less than the $5 minimum | acknowledged |
| C-05 | Info | User text can imitate parts of the swarm question | open (depends on the swarm) |
| C-06 | Info | Flash-borrowed NFTs vote | acknowledged, docs (decision now waits for the vote end) |

### A-01 · High · ERC-6909 claims skip the NFT window and the buy tax

- **Status:** acknowledged, docs corrected.
- **Where:** `src/token/YoloToken.sol:77-99` (`_update` sees only ERC-20 transfers out of the PoolManager).
- **Impact:** the NFT gate checks the buyer address of an ERC-20 transfer out of the PoolManager. A buy that stays
  inside the Uniswap v4 PoolManager as an ERC-6909 claim is not such a transfer, so neither the NFT window of minutes
  0-30 nor the buy tax of minutes 30-60 applies to it: contract buyers that keep claims are not gated or taxed.
- **Accepted risk:** no ERC-20 transfer happens, so the token cannot see it. Only a pool hook could, and the factory's
  `custom_token` launch allows none; moving buys out of the window would change the launch the factory runs. The window
  stays: it applies to wallets, chat trading bots and aggregators, which take the token out.
  The limit is now stated in `docs/TOKENOMICS.md`, the launch-1 text of `docs/LAUNCH-TASK.md` and the `YoloToken`
  comment (bytecode unchanged).

### B-01 · Medium · A third party's answer to a copied question could decide a case

- **Where:** `src/TaskVault.sol` `submitAttestation` (original code, since removed), `src/helpers/SwarmQuestion.sol:75`.
- **What:** the public fallback `submitAttestation` binds an attestation to our request only through
  `questionHash = keccak256(question)`. The question is predictable (`previewSwarmBody`, the Intake's `Requested`
  event) and does not cover the party texts or the body. Anyone can order the same question in their own Intake request
  with one-sided `definitions`, naming the vault as consumer; the attester's signature is then valid for our domain.
  Once our own request completes without a delivered answer (refused, no consensus, failed callback), that answer passes
  every check. Its comment (original code) promised the opposite.
- **Numbers:** 100 USDC task, NFT vote undecided. Erin orders the copied question with fabricated claims (0.5 IMD), gets
  "no", then calls the swarm; our request ends with no consensus. Honest outcome: silence, then the tie rule accepts
  (doer gets 90 USDC + 1.5 IMD). With the attack the case ends Rejected: the doer gets 0 USDC and loses their 1 IMD bond;
  Erin gets 1.75 IMD.
- **PoC:** now the regression test `test/audit/AuditB.t.sol` `test_Fixed_B01_ThirdPartyAnswerToACopiedQuestionCannotDecideOurCase`
  (the same attack, asserting the fix).
- **Latent because:** the real IMD `questionHash` formula is not `keccak256(question)`, so the fallback rejects
  every answer and a lost callback is silence. The risk appears only if the formula changes to match IMD's while
  it still covers the question text alone.
- **Fixed:** IMD's formula is unknown, so the fallback could not be bound properly; it was removed
  (`TaskVault.submitAttestation`, `InvalidAttestation`). A swarm answer counts only through the Intake callback, bound to
  the Intake address and our request id; an undelivered answer is silence (window again, money with whoever paid).
  TaskVault −966 bytes. Regression
  `test_FixP_D1_LostCallbackIsSilence_NoPublicFallback`; the PoC is now `test_Fixed_B01_*`.

### C-01 · Medium · The doer can shut honest disputers out of the swarm question

- **Where:** `src/desks/DisputeDesk.sol:192-205` (`appealReply`: "any disputer" replies once, the first reply ends the
  window), `:130-190` (first-come appeal / call slot), `:296-311` (`questionPart`: first `maxClaims` reasons);
  `src/desks/CaseDesk.sol:184`.
- **What:** the inputs of a swarm question are first-come (the appeal reply, the appeal / call slot, the first
  `maxClaims` reasons). C-01a: the doer could dispute their own submission and then answer their own appeal "for the
  disputers", spending the one reply and locking the real disputer out of the question.
- **PoC (fixed part):** `test/audit/AuditC.t.sol` `test_Fixed_C01a_DoerCannotAnswerHisOwnAppealInTheNameOfTheDisputers`.
- **Fixed in part:** the doer cannot dispute their own submission (`DoerCannotDispute`), so they can never answer
  an appeal "as a disputer" (C-01a closed, `test_FixP_D3_DoerCannotDispute`, `test_Fixed_C01a_*`).
- **C-01b, C-01c (acknowledged, Sybil limit):** other addresses one party controls cannot be told apart from people on
  chain, so they can take first-come slots too: the reason slots of the question (C-01b), or the appeal slot on the side
  the NFT vote favoured (C-01c). Impact: an honest disputer's reason may not reach the swarm, and a case may close before
  the other side appeals. Accepted risk: every first-come or reply-slot rule can be filled by such addresses, and dispute
  bonds are equal for everyone, so ordering by bond changes nothing. The panel is told that claims and replies are
  untrusted statements (`definitions`) and judges the proof against the condition itself.

### C-02 · Medium · Arrival-order relaying does not survive a public mempool

- **Where (original code):** `src/desks/DisputeDesk.sol:90`, `:114`; `src/desks/CaseDesk.sol:229-231`, `:317-333`.
- **What:** fix R-7 relays ballots in arrival order with the sides mixed, so a partial count does not
  decide early. In a public mempool anyone can copy one ballot out of a pending batch and relay it alone first.
- **Numbers:** a batch with 120 accept and 115 reject votes ends with no decision if counted whole. A front-runner with
  no NFT relays the 120-accept ballot alone: instant Accept (and they are reimbursed for it); the honest batch reverts
  `WrongPhase`, the 115 reject votes are never counted.
- **PoC:** now the regression test `test/audit/AuditC.t.sol` `test_Fixed_C02_FrontRunnerCannotUnbundleAMixedBatch` (the same
  attack, asserting the fix).
- **Fixed:** no instant decision. The NFTs decide only when the 24 h vote ends (margin ≥ 10); `CaseDesk.decide`
  is gone, `instantDelta` stays in the parameter set unread (ABI of `paramsOf` unchanged). A lifted ballot only counts
  as a vote; the rest of the batch still lands. CaseDesk −396, DisputeDesk −129 bytes; launch 2 14.64M → 14.32M gas.
  Regression `test_FixP_D2_NoDecisionOnAPartialCount`; the PoC is now `test_Fixed_C02_*`.

### C-03 · Medium · One ERC-1271 ballot could revert a whole vote batch — fixed

- **Where:** `src/libraries/VoteLib.sol:169` (original): an uncapped `SignatureChecker.isValidERC1271SignatureNow`.
- **What:** a contract "voter" answers "valid" when the gas price is 0 (so it passes `eth_call` / `estimateGas`) and
  burns all the gas it gets in a real transaction. Two such ballots eat 63/64 of the gas twice and the batch runs out of
  gas even at the 16M cap. The honest ballots in it are lost and the relayer pays for the failed transaction. No NFT
  is needed: the signature is checked before ownership. This broke the documented rule "bad ballots are skipped, never
  revert the batch".
- **Fix:** `BallotChecker._validSignature` makes the ERC-1271 staticcall with at most 500,000 gas and reads at most
  32 bytes of return data; otherwise the same semantics as OpenZeppelin's check. Side effect: a wallet whose signature
  check needs more than 500k gas cannot vote. BallotChecker runtime 2,574 → 2,410 bytes. ABI unchanged. A relayer
  should still budget 500k gas per ERC-1271 ballot.
- **Tests:** PoC `test_Fixed_C03_GasBurningErc1271BallotDoesNotRevertTheBatch` (passes in simulation; in the real
  transaction it reverted on the original code and goes through on the fixed one); regression `test_Fix_C03_GasBurnerSkipped_HonestErc1271StillVotes` (two burners,
  an EOA ballot of 20 votes and an honest ERC-1271 wallet of 5 votes: 20 + 5 counted). Both fail on the original code.

### Low

- **A-02 · NFT lent for one transaction can be bound to the borrower.** Acknowledged. `src/token/NftGate.sol:51-68`:
  `register` checks `ownerOf` only at that moment and binds for good. Impact: if a venue lent identity.md NFTs for a
  single transaction, the borrower could take those NFTs' window allowance and the real owner could not register them.
  Accepted risk: all 2,000 NFTs' holders that are contracts are EIP-7702 wallets, one Safe-style proxy and
  vaults with no loan function; no venue lends them for one transaction today. Re-checked before launch 1.
- **A-03 · Vesting clocks start at launch 0.** `src/token/ProjectVesting.sol:45` (original code; the fix is in `release`, `:90-93`). YOLO arrives only at launch 1, a
  separate swarm job; what vested in the gap unlocks at once. With a 14-day gap, 14.18M YOLO more than the published
  "Day 0" unlocks at the token's first block (dev 2.98M, team 1.92M). PoC now the regression test `test_Fixed_A03_vestingClocksStartAtTheSplit`.
  Fixed: each clock starts at the first `release` with a balance (`startOf(token)`), and `YoloSplitter.split`
  calls it on all four vestings right after the split, which also pays the at-once parts. Shares and durations are
  unchanged. Regressions `test_FixQ_D6_*`; the PoC is now `test_Fixed_A03_vestingClocksStartAtTheSplit`. Since swarm audit #2 only
  the bound starter (the YoloSplitter) starts a clock; a `release` by anyone else pays what is free and starts none.
- **A-04 · Wrong gate address turns the whitelist off.** Acknowledged, launch checklist. `src/token/YoloToken.sol:74`,
  `:81` (`gate.code.length != 0`, so a chain without the gate trades normally). Impact: a token deployed with a
  wrong gate address would run without the NFT window. Accepted risk: the rule keeps the token usable on a chain without
  the gate; the launch checklist covers it: before launch 1 the gate has code and `NftGate(gate).nft() == NFT`; right after it,
  `whitelistActive() == true`.
- **B-02 · Removing a leaked attester key waits 48 h.** `src/ParamsRegistry.sol:175-204`. A thief with a leaked key can
  forge a "no" for 47 h after removal is proposed. PoC now the
  regression test `test_Fixed_B02_LeakedAttesterKeyAloneCannotDecideDuringTheRemovalTimelock`: since B-01 an answer must
  arrive as the Intake's callback, so a leaked key alone decides nothing. The 48 h removal stays (an instant
  removal would create a lever over open cases).
- **B-03 · Stale proposals.** Acknowledged. `ParamsRegistry.sol:76-99`, `:175-204`; `ProtocolDirectory.sol:81-85`,
  `:100-123`. Impact: timelocked proposals never expire, and opposite attester proposals can coexist, so an old proposal
  can still take effect after a newer one. Accepted risk: each proposal is public
  for 48 h, and cancelling a pending proposal before filing the opposite one avoids the stale-proposal race.
- **B-04 · No expected-version guard on `createTask`.** Acknowledged. `TaskVault.sol:225-230`. Impact: a task pins the
  parameter version current when its transaction lands, which can be a newer one than the author saw. Accepted risk:
  every new version is public for 48 h before it can take effect; a guard needs an ABI change.
- **C-04 · Zero bytes reimbursed at 16 gas.** Acknowledged. `src/desks/DisputeDesk.sol:413-425`, `:440`
  Impact: the relayer's calldata reimbursement prices every byte at 16 gas, so a relayer can be reimbursed above
  its real cost. Accepted risk: the excess is bounded by the per-vote cap (30k + 60k × counted NFTs) and paid from the
  dispute ETH pot, then from the loser's bond.

### Info

- **A-05 · Docs drift, token area.** `MECHANICS.md` cited a token contract that is not part of the code (fixed); the
  `YoloSplitter.sol:18-19` comment about "a few wei short of 750M" is harmless (the factory caps the pool at 15%).
- **B-05 · Docs drift, core.** Stale "$YOLO without a price = minimum bond, no check" and "the oracle is never used for
  payouts" in `MECHANICS.md` (fixed); the sampling-attack paragraph (fixed); the same stale sentence in the
  `TaskVault.sol:243-244` comment and `YoloPoolSamples.sol:26-29` (R-4; corrected in round 2, comments only, runtime
  sizes unchanged); "two launches" and older gas figures in `MECHANICS.md` "Deployment layout" (rewritten after round 2:
  four launches, the figures below, and the code line references of `MECHANICS.md` brought to the current code). `bookEth(.., toTreasury = true)` is never
  used; the constructor does not check `yolo != imd / usdc`.
- **B-06 · Pinned dependencies.** Acknowledged. Impact: if a version's oracle dies, its ETH / USDC tasks cannot take new
  submissions; if its Intake dies, large tasks and appeals stop. `ParamsRegistry.renounceOwnership()` would freeze
  attester rotation for good. Accepted risk: money is not trapped (contributors withdraw, guard
  `test/audit/AuditB.t.sol` `test_Guard_DeadPinnedOracleNeverBlocksWithdrawals`), and a new core version is the remedy.
- **B-07 · A $YOLO task created before YOLO has a price can hold less than the $5 minimum.** Acknowledged.
  `src/TaskVault.sol:239-248`: while the oracle has no YOLO price there is no USD minimum, so such a task can carry a
  dust reward (1 wei); once the price appears, a submission to it is small (minimum Bond, no swarm check), while a new
  task that small is refused. Impact: none on users' money; nothing of value is at stake in such a task and the author
  fee is its only cost. Accepted risk: the minimum is a spam guard, and the author fee already prices spam. Test:
  `test/review/ReviewSweetener.t.sol` `test_Observation_S7_unpricedCreationSkipsTheMinimumForever`.
- **C-05, C-05b · User text can imitate parts of the swarm question.** Open (depends on the swarm). Impact: free text
  that users write (proof links, task conditions) can contain strings that look like fields of the swarm question. The
  JSON cannot be broken (quotes and backslashes banned, UTF-8 validated). Accepted risk: whether the panel is
  misled can only be shown by a real swarm question.
- **C-06 · Flash-borrowed NFTs vote.** Acknowledged, docs. `src/libraries/VoteLib.sol:186-205` (`_mayVote`) reads ownership when
  the batch lands. Impact: if a venue lent identity.md NFTs for one call, they could vote without capital. Accepted risk:
  no such venue exists today (see A-02); the decision waits for the vote end, where the full count decides; the swarm appeal is the remedy. Listed in `MECHANICS.md` "Trust assumptions".

### Items R-1 to R-8

- **R-1** (a sweetener bonus is not counted in the large threshold or the bond): **fixed.** Unless the swarm
  said yes to the accepted submission, the doer gets at most the YOLO worth `largeRewardUsd` ($300) by the task's
  oracle (without a reliable price the payout waits, and pays in full after 7 days: swarm audit #6); the rest returns to the sweeteners pro rata (`BonusCapped`, `returnBase`).
  Tests `test_FixQ_D8_*`, `test_Fixed_S1_*`. An inflated sample lowers the cap, never below 30,000 YOLO.
- **R-2** (one depressed sample takes the min-of-samples YOLO price to the floor and can strip the mandatory check):
  **fixed.** The price is the highest sample of the 2 h window (`highestYoloTick`; `lowestYoloTick` stays as a
  view); a pushed-down sample changes nothing, an inflated one only makes submissions dearer. Tests
  `test_FixQ_D9_*`, `test_Fixed_S4_*`.
- **R-3** (a bonus can be withdrawn right before a submission): **fixed.** Taking a bonus back from an open task
  needs `announceWithdraw` and works 1 to 25 hours later (`pendingWithdraw` view, `WithdrawAnnounced` event); no notice
  after expiry, unwind or past the deadline. Tests `test_FixQ_D10_*`, `test_Fixed_S2_*`.
- **R-4** (stale comments): see B-05.
- **R-5** (relayer reimbursement +43% after the core split into desks), **R-6** (emergency gas budget; heaviest lazy
  step 1,195,523 of 2,500,000): accepted, still hold.
- **R-7** ("fixed" by mixed-side relaying): defeated in a public mempool, re-reported as C-02. **R-8** (puppet claims,
  mitigated by the caller's own reason and "any disputer answers"): the mitigation fails, see C-01.

## Verified correct

- **Money:** every token move books `liabilities`; after everything is claimed the books close at exactly 0, including
  ETH-rejecting contracts and blocked IMD receivers (failed pushes become credits, `withdrawTo` works), payment by swap
  through ETH or USDC with random overpayment (fuzzed: exact IMD booked, surplus returned), `msg.value` settled exactly
  once on every payable route. Settlement splits add up to the full penalty; the fee split cannot underflow; every
  bucket is paid remaining-over-remaining, so the last claimant takes the dust; no double claims.
- **Rights:** bank and task hooks accept only the two desks; the appended sender cannot be spoofed; only interface
  selectors are forwarded; desks cannot be rewired; the Intake callback is bound to the Intake address and a known,
  unanswered request id; the vote EIP-712 domain binds chain and vault; `tryRecover` rejects high-s; the token bitmap
  stops one NFT voting twice; delegate.xyz is called with the right argument order and `rights = 0`; a task's parameter
  snapshot never changes (fuzzed); pause blocks only `createTask`; DareTrophy mints only for the doer of an accepted
  submission, once.
- **Control flow:** one transient lock over every state-changing path (the unlocked `onOracleResult` only writes request
  records); at most ~3 lazy transitions are ever due against the bound of 8;
  the emergency exit cannot beat a working machine; the Intake try/catch keeps its gas reserve and its spending is capped
  by the approval and measured.
- **Token and launch:** supply exactly 1B, minted once; no owner, mint, pause or burn anywhere; splitter shares
  250M / 150M / 77,777,777 / 50M + rest; vestings: incentives 62.5M at once then 730 days, treasury 74,074,074 then 365
  days, dev and team 365 days with no cliff, rounding down, releases sum exactly; the tax is exact at minutes 30, 45,
  59:59 and zero at 60, splitting buys saves nothing; sells are never blocked; the gate cannot be bricked and an NFT
  cannot be registered twice; the oracle's pool id, slot and tick decoding, token order, floor and cap, Chainlink
  staleness and `_pow10001` range are right; the sampler rejects EIP-7702 accounts; the swap adapter holds nothing and
  resets its approval.
- **Text:** `TextLib.validText` matches a byte-by-byte reference over 20,000 fuzz runs; question and body size limits
  hold.

## Tests and launch figures (after round 2)

- `forge test`: 53 suites, **318 passed, 0 failed, 5 skipped** (the fork suites); with `FORK_URL` (mainnet):
  **329 passed, 0 failed, 0 skipped**.
- Launch gas through the live ProjectFactory (cap 16,777,216; fork of the latest mainnet block): launch 0 **3.14M**
  (2.90M in round 1), launch 1 **12.72M** (margin 4.05M), launch 2 **14.32M** (14.64M in round 1, margin 2.46M),
  launch 3 **6.01M** (5.36M in round 1).
- Code-size margins (EIP-170): DisputeDesk 2,179 (was 2,050), CaseDesk 4,087 (3,691), TaskVault 4,732 (3,766),
  YoloSweetener 17,694 (20,687); launches 0–1 at least 8,645 (ParamsRegistry). `ReviewLaunch` L0–L5 green.
- `script/check-launch-task.py`: green; the launch texts in this repository (owner wallets as placeholders) are
  4,883 / 7,771 / 4,189 / 4,177 characters (limit 8,000).
- ABI: `TaskVault.json` lost `submitAttestation` and `InvalidAttestation`, gained `DoerCannotDispute`;
  `YoloSweetener.json` gained `announceWithdraw`, `pendingWithdraw`, `leavingAt`, `returnBase`, `NOTICE`, `NOTICE_VALID`,
  events `WithdrawAnnounced`, `BonusCapped`, errors `NoNotice`, `NoticeNotDue`. The oracle gained `highestYoloTick`, the
  vestings `startOf(token)` instead of `start`.
- Regression tests and guards: `contracts/test/audit/AuditA.t.sol`, `AuditB.t.sol`, `AuditC.t.sol`,
  `AuditFixP.t.sol`, `AuditFixQ.t.sol`; `test_Fixed_*` guards hold the fixes. When an acknowledged
  finding is fixed, the fix adds a `test_Fixed_*` regression test in `test/audit/` and records it in the swarm's ADAPTATION.md of that launch.

## Decisions on the findings (round 2)

1. A-01: the NFT window stays; the docs state that it applies to buyers that take the token out.
2. B-01: the public `submitAttestation` fallback is removed.
3. C-01: the doer cannot dispute their own submission; puppets are a documented Sybil limit.
4. C-02: no instant NFT decision; only the vote end decides.
5. A-02: the gate binding stays; no flash-lending venue exists (re-check before launch 1).
6. A-03: vesting clocks start at the split.
7. B-02: the 48 h removal timelock stays; B-01 already takes a leaked key's power away.
8. R-1: an unconfirmed bonus is capped at the large threshold, the rest returns.
9. R-2: the YOLO price is the highest sample of the window.
10. R-3: one hour of public notice before a bonus leaves an open task.

## Swarm audit of d9a1ee5

The IMD swarm audited this repository at commit `d9a1ee5`: 3 medium, 5 low, 3 info, no critical or high. All
eleven findings are fixed in the next commit. Every PoC of the report now passes as a regression test; the report gave
sources only for #1 and #2, the other tests follow its reproductions (`contracts/test/audit/swarm117/`:
`SampleSandwich.t.sol`, `VestingClockPreStart.t.sol`, `SwarmAudit117.t.sol`). The test names are the report's PoC
names, so they describe the reported behaviour; each test asserts the fixed one.

| # | Severity | Finding | Fix | Regression tests |
|---|---|---|---|---|
| 1 | Medium | A YOLO price sample could be sandwiched inside one block (swap up, sample, swap back) and, as the highest sample, be the price for 2 h | A sample is two calls in two blocks: `sampleYoloPrice` reads the pool (slot0 and both fee growth counters) and keeps the read pending; a call in a later block stores it only if the pool is exactly as read. Any swap after the read, the swap back of a sandwich included, raises a fee growth counter (1.25% LP fee) and voids it, so a price must be held across a block boundary, open to arbitrage. `sampleStep()` tells what a call does (0 nothing, 1 read, 2 store). The NatSpec now states what this does not stop (a price held across the block; moves through a range without liquidity, below the floor). Highest-of-window, the $0.01 cap and so the 30,000 YOLO floor of the sweetener cap stay | `SampleSandwichTest` (the report's two tests), `DoubleSandwichTest` (read and store both sandwiched, any swap between voids, same block stores nothing, `sampleStep`, the held-price limit) |
| 2 | Medium | Anyone could start a vesting clock with 1 wei before the split (A-03 bypass) | Only the `starter` starts a clock: the YoloSplitter binds itself in its constructor (`ProjectVesting.bindStarter`, accepted once and only in the vesting's deployment transaction, a transient flag as in `Desk.wire`; launch 0 deploys the vestings and the splitter in one transaction). A token the splitter never releases has no clock | `VestingClockPreStartTest` (the report's PoC, unchanged), `VestingStarterBindingTest`; the fork rehearsal runs launch 0 through the live factory |
| 3 | Medium | Relayer shortfall came out of the penalty before winners and correct voters, whatever side the relayer voted | Relayers of a case together get at most `MAX_SHORTFALL_BPS` = 20% of the penalty (after a winning caller's fee); winners and correct votes always share the other 80%. Chosen over "batches of at least N NFTs", which a griefer relaying others' ballots also meets | `test_losingVoterDrainsPenaltyByRelayingOwnBallots` |
| 4 | Low | The doer could appeal the acceptance of his own submission (or call the swarm against it) and take the single slot | `appeal` reverts `DoerCannotDispute` for the doer unless the NFT rejected him; `callSwarm` for the doer unless he sides with himself | `test_doerAppealsAgainstOwnAcceptance`, `test_doerMayStillAppealARejection`, `test_doerCannotCallTheSwarmAgainstHimself`; `ReviewRoles.testFuzz_RoleOverlap` |
| 5 | Low | One wallet could vote both sides with different NFTs and be paid whichever side won | A ballot of a voter who already voted the other side of the submission is skipped (`BallotSkipped` reason 4); its NFTs stay unused | `test_walletVotesBothSidesAndIsPaid` |
| 6 | Low | With no YOLO price an unconfirmed bonus went back to the sweeteners in full, at a moment anyone could pick | `payout` without a price (needed only for the cap) moves nothing and emits `PayoutDeferred`; once a price exists it pays by the cap as before. After `NO_PRICE_WAIT` (7 days) from the first such call, still without a price, it pays the doer in full, so an oracle outage cannot lock a bonus forever (anyone can make a price by sampling the pool in an hour). The sweetener's "swarm confirmed" now uses the same in-time rule as the CaseDesk | `test_sweetenerPayoutWithoutPriceReturnsAllToSweetener`, `test_sweetenerPayoutAfterAWeekWithoutPricePaysInFull`, `test_sweetenerCapStillAppliesWithAPrice`; `AuditFixQ.test_FixQ_D8_noPriceDefersThePayout` (was D8 "no price, nothing") |
| 7 | Low | An answer signed in time but delivered after the timeout counted only if nobody poked first | Judged by the signed time consistently: an answer counts if signed within the swarm timeout and delivered within `SWARM_DELIVERY_GRACE` (1 h) after it, and nothing is settled as silent before the grace ends (silence at timeout + 1 h; `stepDeadline` moves with it). The outcome no longer depends on who pokes when | `test_pokeAtDeadlineTurnsLateAnswerIntoSilence` (both orders end Rejected), `test_answerAfterTheGraceIgnoredWhoeverPoked`, `test_answerDeliveredAfterTheGraceIgnoredEvenUnpoked`, `test_answerSignedAfterTheTimeoutIsSilenceAtTheEndOfTheGrace` |
| 8 | Low | The author could pull the whole active share the moment the public proof appeared, before the doer's submit | `announceWithdraw(taskId)`: the active share of an Open task leaves only from 1 h after the notice, for 24 h (`withdrawNoticeAt`, `WithdrawAnnounced`, `NoNotice`, `NoticeNotDue`), like the sweetener's. Pending top-ups and Expired / Unwound tasks need no notice | `test_authorFrontRunsSubmitWithWithdrawal`, `test_announcedWithdrawalGivesTheDoerAnHour`, `test_noticeExpiresAfterADay`, `test_noNoticeNeededAfterExpiry` |
| 9 | Info | `AttestationChecker` did not check `expiresAt` | Code 6 (ignored as 16) when `expiresAt != 0 && expiresAt < now` | `test_expiredAttestationIsIgnored` |
| 10 | Info | Registry parameter levers not disclosed | `MECHANICS.md` "Trust assumptions": the effect of an attester change on live cases and the lever over future judging (a version naming other intake / nft / delegateRegistry / priceOracle). `executeAttester` refuses to remove the last attester (`LastAttester`, `attesterCount`); a rotation adds the new key first | `test_lastAttesterCannotBeRemoved`; `AuditB.test_Fixed_B02_*` now rotates the key |
| 11 | Info | LaunchPlan pinned Intake version 1 | `LaunchPlan.INTAKE` = version 2 `0xa43e6f75ee006411f79ac1c84120606c2330de82`, confirmed by the swarm's own reference (the IMD docs: "Version 2 … keeps every function, event and getter of version 1"; the capabilities endpoint: mainnet `intake` = v2, v1 under `legacyIntakes`). The launch 1 and launch 2 texts name it | `ReviewLaunch.test_L2` (launch text = plan), the fork suites (the v2 Intake on mainnet) |

Also changed: `YoloSweetener._swarmConfirmed` counts only an answer the CaseDesk counts (#7); the four launch texts
(vesting starter, two-block sample, Intake v2, delivery grace, bonus without price, gas figures,
test counts: 4,973 / 7,797 / 4,244 / 4,228 characters, `script/check-launch-task.py` green); `README.md`, `contracts/README.md`,
`MECHANICS.md`, `LAUNCH-TASK.md`.

Tests and figures after the fixes (fork of the latest mainnet block):

- `forge test`: 58 suites, **347 passed, 0 failed, 5 skipped** (was 318 + 5 at `d9a1ee5`); with
  `FORK_URL` **358 passed** (was 329).
- Launch gas through the live ProjectFactory: launch 0 **3.52M** (was 3.14M: the four `bindStarter` calls), launch 1
  **12.98M** (12.72M; margin 3.80M), launch 2 **14.56M** (14.32M; margin 2.22M, ~10.3 KB of new code by gas), launch 3
  **6.11M** (6.01M).
- Code-size margins (EIP-170): DisputeDesk **1,896** (2,179), TaskVault 3,992 (4,732), CaseDesk 4,009 (4,087),
  YoloSweetener 17,226 (17,694); launches 0–1 at least 8,435 (ParamsRegistry).
- New interface: TaskVault `announceWithdraw`, `withdrawNoticeAt`, `WithdrawAnnounced`, `NoNotice`, `NoticeNotDue`;
  ParamsRegistry `attesterCount`, `LastAttester`; YoloSweetener `NO_PRICE_WAIT`, `noPriceSince`, `PayoutDeferred`;
  the oracle `sampleStep`, `pendingRead`, `YoloPriceRead`; ProjectVesting `starter`, `bindStarter`, `StarterBound`,
  `BindingClosed`. `sampleYoloPrice` now returns false on the read.

## Second swarm audit, of `7714a24`

The IMD swarm audited this repository again at commit `7714a243271eeb1560e472d06167594e2f731ec0` (after the 11
findings above were fixed and `HiddenList` was added): verdict "ready for mainnet once the USDC/IMD pool's
observation ring is raised and verified before launch 2"; one medium, four low, no critical or high. Every fix
check of the first audit's 11 findings reproduced clean (one new low opened against finding #8, folded into #16
below). Every PoC of the report now passes as a regression test; the scratch reproductions are the report's own
(`contracts/test/audit/round2/`), the two `HiddenList` findings that needed a lasting regression test got one in
`contracts/test/HiddenList.t.sol` directly.

| # | Severity | Finding | Fix | Regression tests |
|---|---|---|---|---|
| 13a | Low | HiddenList's ">= 3 distinct hide wallets" bar counted `msg.sender`, not the NFT owner: one holder of 10 NFTs, delegated (delegate.xyz, no transfer) to two hot wallets, passed the bar alone | The round's real gate (`_won`) now checks a second counter, distinct NFT *owners* (`ownerOf` at vote time) behind the round's hide votes, not distinct callers; the public `hideWallets` in `status()` is unchanged (still counts callers, for display) | `Proof_476db268aaec.t.sol` (the report's PoC, now passing) |
| 13b | Medium | A round that ended short of quorum started the same 7-day cooldown whether or not anyone had defended the item, so a single NFT holder could keep an honest item un-hideable forever by opening an empty round on it every 8 days | The cooldown now applies only after a round that drew at least one keep vote (contested), or after `setState(VISIBLE)` (finding 13c, below); an uncontested round opens a fresh round at once on the next hide vote | `Proof_5d8c4edc729c.t.sol` (the report's PoC, now passing), `test_UncontestedFailedRoundRetriesAtOnce`; `test_FailedRoundCannotRetryBefore7Days` extended with a keep vote so it still exercises the contested path |
| 13c | Low | `roundEnd` never moved once a round opened: a cluster could open a round with one NFT, then add the rest in the last block with no time left for the keep side to answer; restoring `VISIBLE` after a passed round opened no cooldown, so the same cluster could re-hide the item the same day | A hide vote inside the round's last hour that would make the round pass now extends `roundEnd` by one hour; `setState(VISIBLE)` over a round that had started now opens the same 7-day cooldown a contested round would | `Proof_ced07852b14f.t.sol` (the report's PoC, now passing), `test_OwnerRestoreVisibleStartsCooldown` |
| 16 | Low | `TaskVault.announceWithdraw` and `YoloSweetener.announceWithdraw` let a standing notice renew every call: an author re-announcing every 24h always had a notice that was "due and valid", so the promised hour of warning before a withdrawal never really held, and a notice could be filed while a submission was active | Both methods now revert (`SubmissionActive`, `NoticeLive`) while an earlier notice is still live or a submission is active, so a fresh notice always starts from a real gap | covered by the existing `announceWithdraw`/`withdraw` suites in `test/Base.t.sol` and the sweetener's tests, which exercise the new revert paths; no dedicated new test file |
| 19 | Low | `Desk._priceReward` prices an ETH/USDC submission through `pool.observe([1800, 0])`, which reverts `'OLD'` whenever the USDC/IMD pool's observation ring is younger than 30 minutes (cardinality 1 on mainnet today); `docs/LAUNCH-TASK.md` listed `increaseObservationCardinalityNext` under "outside the launches", after launch 3, so *every* ETH/USDC submission would revert from the first task of launch 2 until that step ran | No code change (the cheaper fix, wrapping the oracle call in try/catch and falling into the large-task path, was weighed and set aside to keep the submit path unchanged for a low/hardening finding); `docs/LAUNCH-TASK.md` "Order of actions" now lists the cardinality call and a live `observe` check as a gate *before* launch 2, not after launch 3 | operational; verified against a stub pool in the report's own reproduction, not carried into this repository's suite |
| 20 | Low | `DareTrophy.price()` reads the *current* parameter version's oracle, not the task's, against `docs/MECHANICS.md`'s "per parameter version" description of the price oracle | Acknowledged, not changed: the correct fix (reading `vault.getTask(taskId).paramsVersion`) changes `price()`'s public signature, which the site and backend read today as one value shared by every unminted trophy; `docs/MECHANICS.md` "Trust assumptions" now states the actual rule and its bound (`maxYolo`, 48h visibility, no user funds) | none; documentation only |
| 22 (info) | — | Below the $300 mandatory-check threshold, a false proof risks `max(1 IMD, 0.5 IMD + 3% of R)` to win 90% of `R`: fraud is +EV whenever fewer than about 3-4% of false proofs get disputed. The report recommended raising `doerBondBps` toward 10% or lowering `largeRewardUsd` toward $100 | Kept at 3% / $300 (`docs/MECHANICS.md`, "Doer bond"): a rejected proof forfeits the bond and gets none of the reward; the forfeit pays whoever disputed and whoever voted correctly; `doerBondBps` is a 48h-timelocked parameter | none; a tokenomics decision, not a bug |

Also changed: `HiddenList.sol` NatSpec and inline comments describe the new rules; `docs/MECHANICS.md` gained "Doer bond" and the `DareTrophy.price()` exception under "Trust assumptions"; `docs/LAUNCH-TASK.md`
gained the launch-2 gate (above) and its gas/size figures moved: launch 2 14.56M → 14.59M (margin 2.22M → 2.19M),
launch 3 6.90M → 7.09M (margin 9.87M → 9.69M); size margins TaskVault 3,992 → 3,853, YoloSweetener 17,226 → 16,992,
HiddenList 21,451 → 20,815 (`announceWithdraw`'s two new checks and `HiddenList`'s extra bookkeeping cost code
size, not gas headroom at the launch cap).

Tests and figures after the fixes:

- `forge test`: 62 suites (was 59), **393 passed, 0 failed, 5 skipped** (fork suites, unchanged; was 388 passed);
  +2 tests in the existing `test/HiddenList.t.sol` suite (`test_UncontestedFailedRoundRetriesAtOnce`,
  `test_OwnerRestoreVisibleStartsCooldown`; `test_FailedRoundCannotRetryBefore7Days` was extended, not added) and
  +3 new suites in `test/audit/round2/` (the scratch PoCs, now passing).
- `script/check-launch-task.py`: green; the launch texts are unchanged by this round except the "Order of actions"
  prose, which the script does not check against the plan.
