# ADAPTATION: launch 0 (genesis) of moneycanbuy.fun, an `evm_contracts` launch on Ethereum mainnet

The six contracts of this launch (`NftGate`, `IncentivesVesting`, `DevVesting`, `TeamVesting`, `TreasuryVesting`,
`YoloSplitter`, all in `src/token/`) are launched **as they arrived**. No source file under `src/` or `script/`
changed. This file lists what was checked, what the imported audit found, and what was added.

## Launch rules: checked, nothing to change

| Rule (evm_contracts reference) | Where it holds |
|---|---|
| 1-8 named contracts, each a Solidity name of at most 32 characters | 6 contracts, names of 7 to 17 characters (`script/LaunchPlan.sol`, `genesisLaunch`) |
| Nonpayable constructors, static argument types, at most 16 arguments, no post-deployment call | `NftGate(address,address)`, each vesting `(address)`, `YoloSplitter(address x5)`; the schedules are compiled-in constants (`src/token/Vestings.sol`) |
| `$contract:` references point backward and fill address arguments | the splitter (6th) names the four vestings (2nd to 5th) |
| A constructor must not require another contract to exist (the launch checks run it on an empty chain) | `YoloSplitter._bind` calls `bindStarter` only on an address that has code; alone on an empty chain it deploys with plain addresses; in the factory's one transaction the vestings exist and accept the binding (their transient flag lives for that transaction) |
| No owner given to `msg.sender` (the factory) or `tx.origin`; IMD never owns a contract | none of the six has an owner, admin, pause, upgrade path, fee, `owner()` or `receive`; the gate's writer is the static project wallet `0x3c587Eff…E48C` from the brief (it is also `$owner`) |
| No DELEGATECALL, CALLCODE, SELFDESTRUCT, proxy, minting or freezing | none; runtimes 1.9-2.1 KB (scanned by `GenesisLaunchRulesTest`) |
| Library functions internal (nothing left unlinked) | only OpenZeppelin `SafeERC20` (internal) |
| `bytecode_hash = "none"` | already in `foundry.toml` (protected, unchanged) |
| Deployment sends no ETH | the constructors are nonpayable (tested) |
| `launch.json` | not written (the manifest step's) |

Constructor arguments stay exactly those of the brief: `script/LaunchPlan.sol` `genesisLaunch` encodes them and
`test/review/ReviewLaunch.t.sol::test_L0_docLaunch0Args_matchPlan` compares them byte for byte with the launch text
in `docs/LAUNCH-TASK.md`. Shares, schedules, the allowance per NFT and the recipients are unchanged.

## Imported audit: five findings, each reproduced, none required a change

Each reproduction is a test in `test/audit/genesis/GenesisLaunchAudit.t.sol` (`GenesisAuditFindingsTest`), so the
behaviour the finding describes is pinned and a later change to it is a deliberate one.

1. **[low] NftGate: a mistaken snapshot entry cannot be corrected before the seal; the only remedy (never sealing)
   closes minutes 0-30 to everyone.** Reproduced (`test_F1_wrongEntryCannotBeLoweredOrRemovedBeforeTheSeal`,
   `test_F1_theOnlyRemedyNeverSealingClosesTheWindowToEveryone`): `record` refuses a wallet already recorded, there
   is no lowering or removing path, `seal` takes any block value, and an unsealed gate (or one sealed at or after
   `openAt`) makes the token refuse every buy in minutes 0-30. **Not changed.** The brief states these as the rules
   of the gate ("each wallet once", "after the seal nobody can change it") and lists the off-chain snapshot as
   accepted by design; no funds are at risk (the worst case is one wallet with a larger allowance for 30 minutes,
   still paying the pool price, or a window closed to all). A correction path (a writer-only overwrite or remove
   before the seal) would change the brief's rule and the meaning of the running `snapshotHash` that
   `script/snapshot/snapshot.py` computes over the list in order, which the brief forbids without a finding that
   requires it. The auditor's own expected outcome admits "an explicit acceptance of the operational risk": this is
   it. **Operational rule for the writer** (the project wallet): send the batches from one published json, compare
   `snapshotHash()`, `walletCount()` and `totalNfts()` on chain with the script's output, and only then call
   `seal(block)` with the json's block, well before `openAt`. A wrong batch means a new gate cannot be wired in
   (launch 1 takes the gate address as an immutable argument), so the check comes before the seal, not after.
2. **[info] ProjectVesting: tokens arriving after a clock started vest pro rata to the elapsed time.** Reproduced
   (`test_F2_laterArrivalsThroughTheSplitterVestProRataToTheElapsedTime`): 1,000 YOLO forwarded to
   `TreasuryVesting` 300 days after the split are 300/365 free at once, and anything after day 365 is free in full.
   **Not changed**: documented behaviour of the single-clock schedule ("whatever arrives counts"), affecting only
   the project's own later arrivals; no third party loses anything.
3. **[info] ProjectVesting: a token sent straight to a vesting never gets a clock; for DevVesting and TeamVesting it is
   locked forever.** Reproduced (`test_F3_tokenSentStraightToAVestingHasNoClock`): only the bound starter starts a
   clock and the splitter reaches it only through a first `split(token)` with more than 527,777,777 of that token.
   **Not changed**: stated in the docs ("a token the starter never releases has no clock"); the brief wants no owner
   and no sweep. Recorded here so that stuck third-party tokens are not treated as an incident later.
4. **[info] YoloToken (launch 1, not one of these six): its constructor refuses a real `openAt` on a chain whose
   timestamp is far below it.** Reproduced (`test_F4_yoloTokenConstructorNeedsARealisticChainTime`): at
   `block.timestamp == 1` a real `openAt` reverts `BadOpenAt`; within 30 days before `openAt` it deploys. **Not
   changed** here: `YoloToken` is not deployed by this launch. It is a lead for the adapter of launch 1 (the
   custom_token rehearsal must run at a realistic time, on a fork or with `vm.warp`), and nothing in launch 0 depends
   on it.
5. **[info] Coverage boundary** (the factory internals, the custom_token rehearsal and the mainnet fork were not
   executed by the auditor). Not a defect. This adaptation ran the full unit suite (`forge test`, see below) and adds
   `test_F5_firstSplitPaysEveryShareOnceAndStartsEveryClock`, the whole launch 0 on the local factory with the real
   creation codes: the first split pays every share once, starts the four clocks, a second call pays nothing twice,
   and after a year each beneficiary, and only it, has received what its schedule opened. The mainnet fork rehearsal
   (`test/fork/LaunchRehearsal.fork.t.sol`, needs `FORK_URL`) is unchanged and was not run on this machine (no RPC).

## Own review of the six (read in full, nothing found that reproduces)

- Access: `record`/`seal` writer-only; `consume`, `release`, `split` open to anyone by design and each only moves
  the caller's own books, the beneficiary's opened share, or the fixed five recipients' shares.
- Value: checks-effects-interactions kept (`released` before the transfer in `release`, `done` before the transfers
  in `split`); the only tokens moved are those the caller names, to fixed addresses; no `receive`, no ETH.
- Arithmetic: `used ≤ allowance` always (booked only when it fits, `nftsOf` frozen by the seal), so `left` and
  `consume` never underflow; `free ≤ total` in `vestedAmount`; amounts stay far below 2^256.
- Binding: `bindStarter` works only in the vesting's own deployment transaction and only once; a vesting deployed
  in an earlier transaction can never be bound (`test/audit/swarm117/VestingClockPreStart.t.sol`).
- Timing: the first split cannot run before the factory's remainder is there (`bal > FIXED`); a remainder a few wei
  short still splits (the treasury takes the gap).

## Files added

- `test/audit/genesis/GenesisLaunchAudit.t.sol`: the launch-rule checks (`GenesisLaunchRulesTest`: one-call
  deployment on an empty chain with the mainnet arguments, runtime scan for forbidden opcodes and size, no `owner()`,
  no `receive`, each constructor alone on an empty chain, nonpayable constructors) and the five reproductions above.
- `ADAPTATION.md`: this file.

## Checks run

- `forge build` with the project's own configuration (unchanged `foundry.toml`, via-IR, `bytecode_hash = "none"`).
- `forge test` with `FOUNDRY_FUZZ_SEED=0x444f25c92ff5b5a2dfec50c1a60c3bfe268b2f54ef932d5e4d0444598aeacba8`: the
  existing 686 tests plus the 10 added here: 696 passed, 0 failed, 3 skipped (the fork rehearsal without `FORK_URL`).
