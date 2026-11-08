# Petahour On-Chain PoC: Test Report

Results from the final regression and a clean-room replay on 7 November 2026, on an Apple M3 with macOS, on the final Petahour code. Section 11 has the commands to reproduce them.

## 1. Summary

| Layer | Method | Result |
|---|---|---|
| Solidity | Unit, fuzz, invariant, real zk proofs | **214 of 214 passed** |
| Python | Unit and integration, including all scenarios | **63 of 63 passed** |
| End to end, local chain, live market data | Six scenarios, 134 transactions | **61 of 61 checks** |
| End to end, fork of live Arbitrum Sepolia (421614) | Same | **61 of 61 checks** |
| End to end, fork of live Base Sepolia (84532) | Same | **61 of 61 checks** |
| Mini-PoC notebook | Top-to-bottom execution, real Groth16 | **102 of 102 checks**, under a minute |
| Test quality | Mutation check: deliberate bugs injected | **82 of 82 caught** |
| Line coverage | `forge coverage`, excluding generated code | **96.8%** lines, 95.2% statements, 95.8% functions, 81.5% branches. `DvPEscrow`: 99.5% lines. `ComputeCreditVault`: 96.9%. `LabsTreasury`: 95.2%. The lines reported as missed in those last two are calls to `_settle` and `_clearLicence`, which this coverage mode misreports: mutants on those lines are caught |
| Static analysis | Slither | 1 real item, fixed. Others triaged in section 6 |
| Clean-room install | Install guide replayed from the Drive copy, starting with no environment | **Every stage passed** on the final code. See section 8 |

**What these results do not show.** Nothing ran on real GPUs, on a public network, or with real funds. Tests prove the logic, not the business case or the legal position. No external audit has been done.

## 2. Test layers

**Unit tests** check each rule and each refusal: a limit, a signature, a window.

**Fuzz tests** try hundreds of random inputs. `testFuzz_valueIsConserved` drives every settlement path with random quantity, price and uptime, 512 times, and checks no value appears or disappears. `testFuzz_packedAllocationMatchesNaiveModel` checks the bit-packed capacity logic against a simple reference model.

**Invariant tests** run random sequences of actions and check a rule after each. The escrow test asserts it holds exactly what its ledger owes. The vault test mixes deposits, exits, loans, repayments, crashes and settlements, and asserts six rules: the two tranches always add up to the pool, settling moves nobody's money, seniors see no loss while first-loss capital lasts, seniors stop at their hurdle, everyone can get out once loans are repaid, and a wiped-out tranche can always restart. `make test-heavy` runs these for 200,000 random actions.

**Real-proof tests** use no mocks: a real snarkjs Groth16 proof against the generated verifier, on-chain.

**Scenario tests** run the whole system on a real EVM, and assert their outcomes.

**Mutation check** asks a different question: can these tests fail? It is described in section 5.

## 3. Solidity results

| Suite | Tests |
|---|---|
| `DvPEscrowTest` | 48 |
| `FirstLossYieldTest` | 39 |
| `LabsFeesTest` | 29 |
| `FeesTest` | 21 |
| `LendingTest` | 17 |
| `ReceiptTest` | 10 |
| `FederationTest` | 9 |
| `PassportTest` | 8 |
| `TCPITest` | 8 |
| `RealProofTest` | 7 |
| `CapacityPoolTest` | 7 |
| `OracleTest` | 5 |
| `MemberRegistryTest` | 3 |
| `EscrowInvariantTest` | 1 (64 runs x 64 calls) |
| `VaultInvariantTest` | 2, one of them six invariants (64 runs x 64 calls) |

**Invariant coverage.** An invariant test that swallows failures can pass while doing nothing, and this one did at first (see section 7). So each run now records what it reached, and `scripts/invariant_coverage.py` fails if any path was never hit. Final run of the escrow test: 328 trades opened, 137 claims, 82 challenges, 43 settled, 48 defaulted, across 65 runs. Vault test: 73 crashes, 20 of them past first-loss capital, excess paid on 113 steps, 200 senior exits and 195 first-loss exits, across 65 runs. The vault test also passed a heavy run of 200,000 random actions, and its fuzz tests 5,000 cases each. The heavy run matters: it found a defect the standard run missed (defect 28).

**Real-proof attacks, all rejected:** tampered proof; wrong commitment; proof reused on another trade; proof for a lower uptime than claimed; model rotated; threshold raised.

## 4. End-to-end scenarios

| Scenario | What it shows | Checks |
|---|---|---|
| **S1** Happy path | Passport and its fee, attestation, signed orders, auction, escrow, seal, T+1 release, marketplace fee from both sides, TCPI, on-chain audit | 11 |
| **S2** Seller fraud | 87.46% measured, 100% claimed: watchtower catches it, no proof can exist, seller slashed, default fund pays | 7 |
| **S3** False challenge and honest outage | Seller wins with zkML, telemetry stays private. An honest outage is paid pro rata and not slashed | 7 |
| **S4** Compliance | Denied party and restricted country refused; frozen member cannot trade or withdraw | 6 |
| **S5** Attacks | Overcharging, forged signature, double-selling, forged telemetry, tampered firmware, rogue oracle, index manipulation | 7 |
| **S6** Petahour Labs | Separation, retail refused, Taiwan flagged, receipts, lending, curator and origination fees, Petahour collects its licence, first-loss earns what is left and nothing on a thin book, Labs takes its share, 60% TCPI crash, first-loss protects senior, the crash compared with the model's ratio, and lending settings read back from the chain and checked against Morpho's rules | 22 |
| Reconciliation | Escrow holds exactly what its ledger owes | 1 |

**Selected results from the live-data run:**

| Measure | Result |
|---|---|
| Passport fee | 720.00 tUSD for 24 GPUs, at the 2027 launch price of 30.00 per GPU |
| Auction | 384 GPU-hours cleared at US$3.6150 in 27 microseconds |
| Marketplace fee | 17.34 from the buyer and 17.34 from the seller, 2.50% of 1,387.47 tUSD delivered |
| Labs fees | 9.40 origination on the first loan, 0.6798 curator fee on 6.7979 of interest. Petahour collected 0.0566 of licence for the day |
| First-loss return | With 90% of the pool lent for a day, seniors earned 4.3843, stopped at 8% a year. First-loss earned the 1.7338 left, or 21.1% a year before losses. Labs' quarter was 0.4335. With the book thin the next day, it earned nothing |
| TCPI | US$3.6286 (cost-model seed, because 384 GPU-hours is below the 500 threshold), then US$3.6534 (VWAP, recomputed from on-chain trades alone) |
| Basis vs mock vendor | US$-2.86 per GPU-hour, or US$-2,090 per 730 GPU-hour contract |
| S2 default waterfall | Refund 705.40, 125.40 from collateral, 48.77 from default fund, reward 13.93 tUSD. No fee from either side |
| zk proof | Generated in about 479 ms, verified and settled for 324,450 gas |
| S6 crash | Bad debt 791.47 tUSD, 42% of the loan. Senior stayed at 20,004.94; first-loss fell from 3,001.73 to 2,210.26, of which Labs took 197.87 |
| Lending settings | 62.5% LLTV, an approved Morpho value; 84% oracle value; 12.68% incentive from Morpho's formula; 52.5% advance |
| Trades reported | 8 trades, 1,152 GPU-hours, NT$6,551 VAT, 7 settled and 1 defaulted |

**First-loss return against the financial model.** On 10,000 of loans, funded 87% senior and 13% first-loss and lent for a year, the vault's balances match the model to within 3 atoms of tUSD (`test_theModelsBaseCase`, and the bear and bull cases):

| Case | Credit losses | Curator | Seniors | Left for first-loss | Return on 1,300 |
|---|---|---|---|---|---|
| Base | 100 | 120 | 696 | 284 | 21.8% |
| Bear | 300 | 120 | 696 | 84 | 6.5% |
| Bull | 50 | 120 | 696 | 334 | 25.7% |

**Reproducing the report.** Automated tests confirm the cost model matches Table 3.4 line by line: NT$58.98, 8.76, 78.74, 94.49, 99.21 and US$3.68, plus the US$4.60 three-year case. The Pantera cross-check reproduces C2's figures: US$1.88 against US$1.90 amortization, and a US$0.27 direct-cost gap.

## 5. Mutation check

A passing test suite shows the code passes the tests. It does not show the tests can catch anything. `scripts/mutation_check.py` injects one bug at a time, first confirms the unmodified baseline is green, and requires the suite to fail. **All 82 mutants were caught.** An earlier run caught 77 of 78: the survivor, dust staying owed to nobody, showed a test that never reached that state, so a test was added and every mutant was run again:

Buyer limit not enforced; overfill not checked; order signature not checked; TEE seal not checked; zk proof not checked; dispute window skipped; fee over-credited; seller fee not charged; seller fee not pro rata; buyer fee not locked; seller fee cap removed; lapsed passport can sell; passport fee not collected; launch discount can be stockpiled; renewal loses paid time; discount above 100% accepted; default fund cover dropped; duplicate signers accepted; oversell guard removed; bit-packing shift broken; 16-bit lane overflow allowed; attestation replay allowed; proof not bound to trade; deviation guard removed; audit hash not signed; stale prices accepted; receipt transfer unrestricted; bad debt charged repeatedly; origination fee not taken from the loan; rollovers pay origination again; licence clock loses time; a senior loss comes off the mark; a covered loss stays on the mark; the mark falls with the vault; the curator is paid twice for one gain; curator paid double; deposits counted as income; withdrawals not taken off the mark; quoted value ignores the fee; deposit price ignores the fee; last lender leaves the fee behind; seniors earn without limit; the curator's fee comes out of the seniors' yield; losses never reach first-loss capital; the excess vanishes; senior value includes first-loss money; the yield hurdle never rises; settling loses the yield earned so far; settling counts the same days twice; dust stays owed to nobody; the hurdle ignores interest kept by seniors; the next senior inherits an old hurdle; a deposit skips settlement; a late investor catches past earnings; anyone can draw first-loss money; anyone can book first-loss capital; first-loss capital not recorded; first-loss money counted as income; first-loss exit not recorded; first-loss exit stays on the mark; first-loss can leave ahead of a loss; first-loss exit raises no cash; a shortfall follows new first-loss money; the tranche can be rebound; anyone can bind the tranche; anyone can lend the pool; anyone can pull the pool from the market; anyone can burn valuable first-loss shares; clearing shares moves a loss onto seniors; any senior yield accepted; fee recipient can block depositors; licence paid repeatedly; Labs can withdraw ahead of the licence; withdrawal skips the licence; Labs co-invests ahead of the licence; anyone can co-invest Labs' money; anyone can pull Labs' co-investment; anyone can withdraw Labs' money; treasury can be rebound; healthy positions liquidatable; frozen wallets stay eligible; passport transferable.

## 6. Static analysis

Slither ran over all contracts except generated and test code.

| Finding | Count | Assessment |
|---|---|---|
| `uninitialized-state` (High) on `TCPIOracle._rounds` | 1 | **False positive.** Filled through a storage pointer Slither does not follow. Tests read it back |
| `incorrect-equality` (Medium) | 7 | Intentional zero checks |
| `uninitialized-local` (Medium) | 5 | Intentional defaults of zero |
| `unused-return` (Medium) | 7 | Intentional: unused share counts and tuple fields |
| `timestamp` (Low) | 30 | Intended: the protocol's windows and the senior hurdle are time-based |
| `missing-zero-check` (Low) on the Passport `treasury` | 1 | Accepted: a zero address makes the first fee transfer revert, so a bad deployment fails closed |
| `reentrancy-benign`, `reentrancy-events` (Low) | 8 | Trusted token and internal calls, behind guards |
| `events-maths` (Low) on `fundFirstLoss`, `releaseFirstLoss` | 2 | Accepted: the tranche emits ERC-4626 `Deposit` and `Withdraw` for the same moves |

## 7. Defects found and fixed during the build

Passing tests are only part of the story. This is the honest record of what went wrong, and what caught it.

| # | Defect | Found by | Fix |
|---|---|---|---|
| 1 | **Design flaw.** A seller honestly reporting an outage could not answer a challenge, and would be slashed | Reviewing settlement logic; no test caught it | Model judges quality only; uptime proven separately. Regression tests added |
| 2 | **Overflow.** A host above 65,535 GPUs would corrupt the next hour's allocation | Code review | Capped at lane width. Regression test and mutant added |
| 3 | **Vacuous test.** The invariant test passed while opening no trades on some runs, and proved little | Adding progress counters | Coverage now measured across runs, and enforced |
| 4 | **Invalid check.** The first mutation run was meaningless, because the baseline was failing | Noticing the failing baseline | Script now requires a green baseline first |
| 5 | **Wrong index.** TCPI averaged all trades ever, not daily | Comparing with report section 6.1 | True daily prints, with carry-forward |
| 6 | **Wrong trigger.** Sunset used lifetime volume, while C3 specifies trailing 30-day | Folder review | Trailing window, one-way |
| 7 | **Missing protection.** VWAP had no outlier filter. One wash trade could move it 20% | Folder review (C5, C6) | Winsorized VWAP |
| 8 | **Bias.** Weighted median picked the lower price on an exact even split | Failing unit test | Midpoint on exact splits |
| 9 | **Reentrancy pattern** in `coverBadDebt` | Slither | `nonReentrant` |
| 10 | **Overstated legal language**: MOEA oversight, enacted Foreign Trade Act amendment | Folder review (5 Nov evaluation) | Language corrected in code, notebook and documents |
| 11 | **Incomplete Passport record** against report section 4.1.1 | Folder review | All fields included |
| 12 | **Install failed from clean.** `conda env create` read Anaconda's default channels and stopped at a Terms of Service prompt | Clean-room replay; the development environment never hit it | Bootstrap now uses conda-forge only, so no terms prompt arises |
| 13 | **Stale figure.** "About 6,000 constraints" predated circuit optimization; the real count is 2,259 | Checking the claim against the built circuit | Corrected |
| 14 | Missing order salt in the notebook; test helper prank ordering; a garbled scenario check; a notebook patch that silently failed to apply | Test failures and output review | Corrected and re-verified |
| 15 | **Unclear error.** Starting a demo while another was running ended in a long traceback, which is easy to hit by leaving `make demo-keep` open | Clean-room replay | One-line message that says how to stop the other chain. Test added |
| 16 | **A second copy of the fee.** `petahour/risk.py` kept its own 0.10%, so the pre-trade check would have passed buyers the escrow then refuses | Listing every use before changing the fee | Reads the same setting as the deployment. Test added |
| 17 | **Rename hit real filenames.** The first bulk rename changed research filenames in the prompt and design doc, which would have pointed readers at files that do not exist | Reading the result, then checking every name against the folder | Restored. The later rename to Petahour protected real names before replacing anything |
| 18 | **A check that depended on the market.** Below the volume threshold, S1 skipped one audit, so a live run reported 49 checks and an offline run 50 | Comparing the run totals | Both paths now assert something |
| 19 | **Tests that measured the wrong time.** Two fee tests looked like an underpaid and then an overpaid curator. The contract was right: with `via_ir`, `block.timestamp` is constant within a call, so a second `vm.warp` missed its target | Working the arithmetic by hand before changing anything | Tests warp to fixed times. Recorded in the build prompt |
| 20 | **Exit and dip gap.** The old `coverBadDebt` step left a window after a default: a depositor could buy senior shares at the low and a first-loss holder could leave before being charged | Designing the first-loss yield | Losses now land the moment the market records them. Tests added for both attacks |
| 21 | **First-loss capital earned nothing and could not have.** It sat as idle cash, while the model's return assumes it is lent | Rebuilding the model's formula against the contracts | First-loss money is now lent, as a recorded claim on the pool |
| 22 | **S6 could not show a yield.** Its one loan is about 8% of the pool, and first-loss earns only above about 64% | Reading the scenario before writing the code | A second borrower fills the book for a day |
| 23 | **Flattering stress test.** S6 keeps seniors whole only because the loan is small against the cushion. At the model's 13%, the same crash cost seniors about 40% on the first settings, and costs them 33% now | Sizing the test at the model's ratio | Reported in the demo, design document and notebook, and a test added. Not fixed: it is a sizing decision |
| 24 | **Rounding went the wrong way.** Rounding the hurdle cap up made settling move value on a nearly empty vault. Rounding it down costs seniors under one atom, and never adds up | Vault invariant test, on a 9-step sequence | Rounds down |
| 25 | **A check that could not fail.** The first vault coverage guard asserted `x + 1 > 0` | Reviewing the test before relying on it | Real per-run counters, enforced by `scripts/invariant_coverage.py` |
| 26 | **Duplicated model note.** The script editing the workbook's notes hit one note twice, because the new text starts with the old | Reading the log line, then the cell | Matches whole cells. Only four note cells differ from the previous file |
| 27 | **Settings that could not deploy.** The 75% LLTV and flat 5% incentive worked on the stand-in market, but real Morpho allows neither. The nearest approved LLTV, 77%, would have made the protection worse | Checking Morpho's documentation before recommending a change | 84% oracle, 62.5% LLTV and Morpho's incentive, at the same advance. The demo reads them back from the chain, and tests pin the formula |
| 28 | **Tranche could stop taking capital.** Each total wipe-out left worthless shares that new deposits had to outweigh, adding about nine digits to the supply, until the eighth deposit overflowed. No money was lost, but seniors would have had no first-loss capital again. Written in the first-loss work, and missed by the standard run | Heavy invariant run, then a test that reproduced it | `clearWorthless`, which anyone may call once shares are worth nothing. It settles first, or the loss would fall back on seniors. `make test-heavy` added |

Defects 1 and 2 are the ones to remember: **no test caught them**. They came from reasoning about what the code should do. Testing is not a substitute for review, which is also why an external audit remains necessary.

## 8. Clean-room install

The install guide was replayed from the published Drive copy as a new user would run it: development tools off the path, and the conda environment and `~/petahour-poc` deleted first. It took eight runs, and only the last counts.

| Replay | Outcome |
|---|---|
| 1 | Failed at install on the Anaconda Terms of Service prompt (defect 12) |
| 2 | Passed install, tests, demos and `make status`, then hung. The fault was in the replay script, not the PoC: it sent Ctrl+C in a way that background jobs ignore. A second copy of the script then overlapped with it, so its results were discarded |
| 3 | Every stage passed, as a single run with a lock against overlap. This was before the rename and fee changes |
| 4 | Every stage passed after the rename and fee changes, before Labs' fees were added |
| 5 | Every stage passed with Labs' fees added, before the rename to Petahour |
| 6 | Every stage passed after the rename to Petahour, before first-loss yield |
| 7 | Every stage passed with first-loss yield, before the move to Morpho's settings |
| 8 | **Every stage passed** on the final code |

Replay 8 ran on 7 November 2026 and took 11 minutes 54 seconds in total.

| Stage | Command | Result |
|---|---|---|
| Drive guard | `bash scripts/bootstrap.sh` inside Drive | Refused, as designed |
| Install | `bash scripts/bootstrap.sh` in `~/petahour-poc` | Passed in 207 seconds |
| Tests | `make test` | 214 Solidity and 63 Python tests passed in 81 seconds |
| Demo, live data | `make demo` | 61 of 61 checks, 44 seconds |
| Demo, offline | `make demo-offline` | 61 of 61 checks, 37 seconds |
| Reports | `make price`, `make market` | Passed |
| Single scenarios | `python -m petahour.cli demo --offline --scenario s2`, then `s6` | 19 of 19 and 41 of 41 checks |
| Inspect a running chain | `make demo-keep`, `make status`, `cast call` | 8 trades. The TCPI read directly from the feed matched `make status` |
| Stop a running chain | Ctrl+C, sent to the process group as a terminal does | Stopped in 1.6 seconds. Ports 8545 and 8799 were freed |
| Second demo while one runs | `make demo-offline` | Refused with a clear message and no traceback |
| Arbitrum Sepolia fork | `make demo-arbitrum` | 61 of 61 checks, 129 seconds |
| Base Sepolia fork | `make demo-base` | 61 of 61 checks, 44 seconds |
| Mini-PoC | New Python 3.13 environment, notebook read from Drive | 102 of 102 checks, 59 seconds |

Measured disk use was 140 MB for `~/petahour-poc`, 1.1 GB for the conda environment, and 599 MB for the mini-PoC environment. The mini-PoC packages took 87 seconds to install the first time and about 20 seconds with pip's cache warm.

**What this replay does not show.** It ran on the Mac the PoC was built on, so a different machine may reveal something it could not, and downloads there will take longer. The notebook was run with `jupyter nbconvert --execute`, not by hand in JupyterLab. Option B, Colab, Linux, `make zk` and public testnet deployment were not replayed. `make mutation` and `make gas` ran in the 7 November regression, not in this replay.

## 9. Gas and cost

Real gas from transaction receipts:

| Operation | Average gas |
|---|---|
| `matchOrders` (24-hour trade) | 426,824 |
| `claimDelivery` | 143,474 |
| `finalize` | 92,136 |
| `challenge` | 101,979 |
| `respondWithProof`, including Groth16 verification | 324,450 |
| `resolveTimeout` | 117,950 |
| `mintPassport`, including the fee | 353,216 |
| `submitAttestation` | 137,007 |
| `publish` (TCPI) | 151,824 |
| `mintReceipt` | 228,123 |
| `borrow`, including the fee | 204,428 |
| `liquidate` | 160,458 |
| Full deployment, both entities | 22.8 million, in 31 transactions |

Estimated cost at live L2 gas prices on 7 November 2026, with ETH at US$2,246:

| Path | Gas | Arbitrum One (0.020 gwei) | Base (0.006 gwei) |
|---|---|---|---|
| Normal trade | 662,434 | US$0.030 | US$0.009 |
| Disputed trade | 996,727 | US$0.045 | US$0.013 |

**This is execution gas only.** L2 fees also carry an L1 data component that varies with calldata and Ethereum congestion, and gas prices move. Treat these as orders of magnitude. The conclusion holds regardless: on a US$700 trade, on-chain settlement is a rounding error.

## 10. Not tested

- Real GPU attestation, or any real NVIDIA service. Token format and claim names follow public sources; the flow was never run against NRAS.
- Real Silicon Data, KYC or Morpho integrations.
- A public testnet deployment. Forks exercise real chain state, but not real sequencers, faucets or fees.
- L2-specific behaviour such as L1 data fees or sequencer downtime.
- Performance under load, or concurrent transactions.
- Colab and Linux installation.
- Model accuracy on real telemetry. All training data is simulated.
- VAT and invoicing of the marketplace, Passport and Labs fees. The invoices cover the compute only.
- A year of first-loss return on a live chain. The demo runs one full day, because it cannot jump a year without expiring memberships and attestations. The yearly cases are Foundry tests.
- A Passport lapsing in the demo. It is covered by Foundry tests, because the demo cannot jump a year without expiring memberships and attestations.

## 11. Reproduce these results

From `~/petahour-poc`, with the environment active:

```bash
make test
```

```bash
make mutation
```

```bash
make demo
```

```bash
make demo-arbitrum
```

```bash
make demo-base
```

```bash
make gas
```

Mutation takes about 5 minutes. Others take about a minute. Market figures will differ with live data.
