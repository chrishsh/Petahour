# Claude Code Prompt: Review, Plan, Build and Test the Petahour On-Chain PoC

**What this is.** A complete prompt for Claude Code. It was refined by doing the work: the build in this folder is what it produces, and its pitfalls section records what actually went wrong.

**When to use it.** To rebuild the PoC from scratch, to hand the work to another team, or as a starting point for PoC-1. If you only want to extend the existing build, use the short prompt at the end.

**How to use it.** Open Claude Code in an empty folder, then paste everything below the line. Check the paths in section 1 first.

---

You are the lead engineer for a proof of concept of the Petahour. Work through four stages in order: Review, Plan, Build and Test, Document. Stop at each gate marked **GATE** and show me your output before continuing.

## 1. Inputs

Read these. Where sources conflict, the newest wins. Tell me about every conflict you find.

| Priority | Source | Use |
|---|---|---|
| 1 | `Taiwan Compute Exchange/Petahour_GTM_Financial_Model_v5.xlsx` (7 Nov 2026) | Business model: the name Petahour, the take rate, the Passport fee and Petahour Labs |
| 2 | `Taiwan Compute Exchange/TW-SG eval_Claude.pdf` (5 Nov 2026; a scanned PDF, so OCR it) | Latest corrections. Overrides the report |
| 3 | `Taiwan Compute Exchange/2026-11-03_Taiwan_Compute_Exchange_Research.pdf` | Primary requirements. Figures 4.2, 4.3 and 5.1 are images: render and read them |
| 4 | `C3_TCX_OnChain_Feasibility_and_PoC_Architecture.docx` | PoC architecture, Petahour Labs rationale, sunset rule |
| 5 | `C2_TCX_B200_...Pantera...`, `C5_Global_Compute_Exchange_Landscape...`, `C6_...Unified_Proposal`, `T6-consol_...EN` | Cost reconciliation, index methods, governance, Passport fields |
| 6 | `Claude.pdf` (scanned) | Where blockchain does and does not add value |
| 7 | Any memory or earlier conversation | Context only |

Do not treat a prior prototype as correct because it exists. If one is present, compile and run it before relying on it.

## 2. Objective

Build a working, tested, documented PoC of the four-layer architecture in report Figure 4.3, focused on the on-chain architecture:

- The **Petahour Labs** entity, legally and technically separate from the onshore venue.
- **Oracle and Proof-of-Delivery**.
- **zkML**.
- **Arbitrum and Base** (EVM L2 rollups).
- **On-chain and off-chain integration**.

Also produce a **mini-PoC Jupyter notebook** explaining each mechanism, and full documentation.

Target stage: PoC-0 complete, with PoC-1 and PoC-2 interfaces prototyped.

## 3. Ground rules

1. **Be honest about what is real.** Every mock must be labelled in code, output and documents. Never let a reader think something simulated is real.
2. **Use real cryptography even when the surroundings are simulated.** Real ECDSA, real EIP-712, real ES384 tokens, real zk proofs. An HMAC is not a hardware signature. A Freivalds check is not zero-knowledge.
3. **Contracts must compile and run on a real EVM.** A Python class that imitates a chain is acceptable only in the mini-PoC notebook, where it must be labelled.
4. **Verify facts against live sources** rather than memory, for any external interface.
5. **Do not fabricate results.** Every number in a document must come from a run. If something was not tested, say so.
6. **Do not spend real money, deploy to a public network, or use real keys** without asking me.
7. **Do not modify the research folder** or any prior prototype.
8. **Do not install into my global environment.** Use an isolated environment. Dependencies must not sit in a cloud-synced folder.

## 4. Required architecture decisions

These are settled. Do not reopen them without telling me why.

**Trust boundary.** Clients sign EIP-712 orders. The off-chain matcher proposes trades, and the contract re-verifies signatures, limits, eligibility and capacity. A compromised matcher must be able to fail to match, and nothing worse.

**Entity separation.** Petahour and Petahour Labs deploy from different keys. Labs has its own allow-list, and only reads Petahour contracts. Assert on-chain that Labs holds no role on Petahour contracts. Figure 4.3 draws Labs inside the Taiwan boundary; follow the text, not the figure.

**Proof of Delivery in three layers:**

| Layer | Question | When |
|---|---|---|
| TEE attestation | Is this real, unmodified hardware? | Once, at start-up |
| opML T+1 window | Did anyone object to this claim? | Every trade |
| zkML | Is the disputed claim true, without showing the data? | Rare disputes only |

**zkML scope.** The report rejects zkML for metering (1,000x to 10,000x overhead). Respect that. Use it only on the dispute path, over a tiny model, to prove an SLA claim from TEE-committed telemetry. Its value is privacy. Never use it to meter GPU-hours.

**Split of duties.** The host measures and seals. The seller claims. Keep these separate, or there is nothing to dispute.

**Model scope.** The model judges delivery quality only. Prove uptime separately by comparing it with the claim, so an honest outage is always provable and is paid pro rata. Make weights private circuit inputs bound by a hash, so a retrained model needs no new trusted setup.

**Attestation path.** NVIDIA NRAS signs with P-384 and the EVM has no P-384 precompile. Verify tokens off-chain in each federation node, and anchor the hash. On-chain, check the federation quorum and the TEE's secp256k1 seal. Bind the sealed key through the nonce. Note that production needs dual CPU and GPU attestation.

**TCPI** (as a future settlement benchmark):

- Input: physically settled trades only, read back from the chain.
- Winsorized VWAP, normalized to PFLOP-hours.
- Cost-model seed until trailing 30-day volume crosses a pre-announced threshold, one-way.
- Federation quorum, a deviation guard with an explicit emergency flag.
- An on-chain inputs hash, so anyone can recompute a print.
- A Chainlink-shaped feed and a Morpho-shaped adapter that fails closed.
- Vendor data is a cross-check and basis report only, never an input. Silicon Data licenses settlement reference separately.

**Fees:** follow the financial model. The take rate is 2.5% of delivered value in 2027, stepping down to 1.25% by 2031, paid by both sides and only on what was delivered. The Passport costs the seller US$60 per GPU a year, at half price in 2027, and a lapsed Passport cannot sell.

**Labs fees:** a 10% curator fee on interest, a 0.5% origination fee on loan growth, and a 0.10% data licence paid to Petahour on average loans. A fee must never count interest that only refills a loss as income.

**Petahour Labs:** ERC-721 receipts, capped at physical capacity; a restricted ERC-20 wrapper, because Morpho Blue accepts ERC-20 collateral only; an isolated Morpho-shaped market; a senior ERC-4626 vault; a first-loss ERC-4626 tranche, lent alongside senior money, that takes losses first and keeps what is left after an 8% senior yield. On a fully lent book it must reproduce the model's 21.8%, 6.5% and 25.7%. Labs holds 25% of the tranche. Use settings real Morpho allows: an 84% oracle value and a 62.5% LLTV, a 52.5% advance, with Morpho's incentive at that LLTV. No native compute token.

**Compliance:** only pass/fail flags on-chain, never personal data. Labs onboarding refuses retail, and flags Taiwan users for a Virtual Asset Service Act opinion.

**Language.** Use the corrected facts from the 5 November evaluation:

- The research calls the venture "Taiwan Compute Exchange" and "TCX". Use "Petahour" everywhere, and call TCPI the Traded Compute Price Index. Research filenames keep the old name.
- Do not say MOEA oversees the venue. Use "FSC classification inquiry plus voluntary MOEA/NSTC endorsement".
- The Foreign Trade Act amendment is a pending bill.
- Petahour Labs goes in Switzerland or Cayman/BVI, not Singapore.
- CME's GPU1 and GPU2 are pending CFTC review.

## 5. External data

| Source | Handling |
|---|---|
| GPU prices | Vast.ai public offers, live, no key. These are asks, not trades, so label them |
| FX | open.er-api.com, live, no key. Do not hard-code NT$31 |
| Silicon Data (`SDB200RT`, `SDH100RT`, `SDA100RT`) | Licensed, and the schema is not public. Build a client plus a mock on an **assumed** protocol, labelled in every response |
| NVIDIA NRAS | Mock with the real shape: `/v4/attest/gpu`, Bearer auth, ES384 EAT, JWKS, claims `x-nvidia-overall-att-result`, `eat_nonce`, `measres`, `secboot`, `dbgstat`, `hwmodel` |
| KYC and EAR | Mock with fictional names and an illustrative country list |
| Client orders | Simulated and seeded, through a FIX-style gateway |
| GPU telemetry | Simulated and seeded: healthy, partial, degraded, idle-fraud |

Every live source must fall back cleanly, so all demos run with no network.

## 6. Stack

Solidity 0.8.28 with Foundry, EVM target `cancun`; OpenZeppelin 5.x; circom and snarkjs (Groth16); Python 3.12 with web3.py; Node 22; Anvil. Pin versions. Every contract must stay under the 24,576-byte limit, and the design must deploy to both L2s unchanged.

## 7. Stage 1: Review

Read the inputs in full. Produce:

1. A source table: what each document contributes.
2. A findings table: every place the sources conflict, are out of date, or leave a gap. Check at least: report facts against the 5 November evaluation; whether the design can really work, for example whether the EVM can verify NVIDIA's signature, whether Morpho accepts the proposed collateral, and whether honest behaviour can ever be punished.
3. Live checks of every external interface you depend on.

**GATE 1:** show me the findings.

## 8. Stage 2: Plan

Produce the contract list, data flows, test plan, and a list of what will be real, mocked or out of scope. Flag decisions that are mine to make.

**GATE 2:** show me the plan.

## 9. Stage 3: Build and test

Build in this order, testing each before moving on. Start with the riskiest parts.

1. Core contracts and their tests.
2. zk circuit, trusted setup, generated verifier, and a real-proof test. Do this early: it is the biggest technical risk.
3. Petahour Labs contracts.
4. Off-chain services, each with tests.
5. Integration layer and deployment script.
6. Six scenarios on a real EVM, each asserting its outcome: happy path; seller fraud; false challenge and honest outage; compliance; attacks; Petahour Labs stress.
7. The notebook.

### Required test evidence

| Evidence | Requirement |
|---|---|
| Solidity | Unit, fuzz, invariant, and real-proof tests |
| Attacks | A test for each threat, asserting the specific error |
| Report fidelity | Tests that the cost model matches Table 3.4 line by line |
| **Mutation check** | Inject at least 20 deliberate bugs, one at a time. All must be caught. Confirm a green baseline first |
| **Invariant coverage** | Measure what random runs reach, and fail if a settlement path was never hit |
| Static analysis | Run Slither, and triage every High and Medium finding in writing |
| Coverage | Report line and branch coverage |
| Live networks | Run all scenarios on forks of Arbitrum Sepolia and Base Sepolia |
| Gas | Real gas from receipts, and cost at live L2 gas prices, stating that L1 data fees are excluded |
| Clean room | Follow your own install guide from a fresh copy, and fix whatever breaks |

### Known pitfalls from the previous build

- **Green tests can prove nothing.** An invariant handler using `try/catch` passed while opening no trades. Count what it actually does.
- **Do not trust a mutation run on a red baseline.** Every mutant looks caught.
- **The two worst defects were caught by no test.** One slashed honest sellers; one was a 16-bit overflow into the next hour's allocation. After the tests pass, reason through the economics: can an honest participant ever be punished? Does any cast or packed field overflow?
- **`vm.prank` applies to the next external call**, including one in an argument. Compute signatures first.
- **With `via_ir`, `block.timestamp` is constant within a call.** A later `vm.warp(block.timestamp + x)` can reuse the old time, and a saved copy can be re-read. Warp to fixed offsets from a constant.
- **A fee on any increase in vault assets charges refilled losses.** Use a high-water mark that a senior loss does not lower.
- **Capital held as cash earns nothing, and capital that is lent cannot pay out in a default.** Make first-loss capital a recorded claim on the pool, so a loss just reduces it.
- **Put a waterfall in one read-only view, and make settling only store it.** Then you can fuzz the strongest property: settling never moves anyone's money.
- **Size a stress test at the real ratio.** A small loan against a large cushion passes any crash, and proves nothing about the plan.
- **Check a stand-in against the real platform's rules.** A stand-in accepts any setting, which can hide that a value cannot deploy. Morpho allows only approved LLTVs and sets the incentive itself.
- **The same advance can carry very different risk.** What the oracle counts is what a liquidator pays, so the split between oracle value and LLTV decides how much a crash costs.
- **Check your patches applied.** A failed edit script can leave a passing result from old code.
- **A quantized model needs exact integer agreement** between Python and the circuit.
- **Do not use `=====` at the start of a shell echo in zsh.** Use `-----`.
- **Scanned PDFs** return no text. Use OCR. On macOS, Vision and PDFKit need no install.
- **`conda` is often a shell function.** Call the binary in scripts.
- **Mermaid does not render in Word.** Use image diagrams, and look at them. Auto-layout tools can produce unreadable sprawl.

**GATE 3:** show me the results, including anything that failed along the way.

## 10. Stage 4: Document

| File | Contents |
|---|---|
| `docs/01_DESIGN.md` | Sources; findings; architecture; PoD; zkML; TCPI; Petahour Labs; integration; security model; limitations; decisions needed from me |
| `docs/02_IMPLEMENTATION.md` | Layout, stack, contracts, how to change things, including renaming |
| `docs/03_TEST_REPORT.md` | Real results; defects found and how; what was not tested |
| `docs/04_INSTALL_AND_DEPLOY.md` | Step by step for both PoC and mini-PoC, each with a check that it worked |
| `docs/05_USER_MANUAL.md` | A demo script with a talk track, what is real, likely questions |
| `README.md` | Start here |

Use image diagrams, because Mermaid does not render everywhere. Write plainly, for a finance professional who is technical but not a Solidity engineer. Lead with findings. Never overstate.

## 11. Acceptance criteria

The work is done when all of these are true:

- [ ] All contracts compile, and each fits the size limit.
- [ ] Every test passes, and mutation score is 100%.
- [ ] All six scenarios pass on a local chain and on both forks.
- [ ] A real Groth16 proof is verified on-chain.
- [ ] An attack is refused, for the right reason, for every threat listed.
- [ ] The cost model reproduces US$3.68 and US$4.60.
- [ ] A TCPI print can be recomputed from on-chain data alone.
- [ ] The escrow reconciles exactly after every scenario.
- [ ] The notebook runs top to bottom in pure Python, with a real zk proof.
- [ ] A clean-room install succeeds using only the guide.
- [ ] Every mock is labelled, and every number comes from a run.
- [ ] The final summary states what was not done.

---

## Short prompt for extending the existing build

> Read `README.md` and `docs/01_DESIGN.md` in `compute_ex`, then `docs/03_TEST_REPORT.md`. Work in a copy at `~/petahour-poc`. Your task is: [DESCRIBE THE CHANGE]. Keep `make test`, `make mutation` and `make demo` green, add tests for anything new, add a mutant for any new security check, and update the affected documents with real results. Tell me what you could not verify.
