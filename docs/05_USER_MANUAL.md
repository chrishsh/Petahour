# User Manual: Demonstrating the PoC and the Mini-PoC

This guide is for running a demonstration, whether to yourself, an engineer or an investor. Install first using [the installation guide](04_INSTALL_AND_DEPLOY.md).

| Audience | Use | Time |
|---|---|---|
| Learning how it works, or a non-technical audience | **Mini-PoC notebook**, Part B | 20 to 30 minutes, reading along |
| Engineers, technical diligence | **Full PoC**, Part A | 15 minutes |
| Investors | Part A with the talk track, then the notebook's §9 and §12 | 20 minutes |

## What to say up front

Three sentences prevent most misunderstandings:

1. **"This is a proof of concept with simulated value."** No real GPUs, money or clients.
2. **"The mechanisms are real."** Real contracts on a real EVM, real signatures, a real zero-knowledge proof.
3. **"It is Petahour, not TCX."** The research says Taiwan Compute Exchange and TCX. Petahour is the global brand, and Taiwan is its first market. A petahour is a petaflop for an hour, the hardware-neutral unit the market trades.

## What is real and what is simulated

| Real | Simulated |
|---|---|
| Smart contracts on an EVM, including forks of live testnets | The GPUs and their telemetry |
| EIP-712 client signatures, checked on-chain | Clients and their orders |
| Groth16 zk proof, verified on-chain | Silicon Data (assumed protocol) |
| ES384 attestation tokens, in NVIDIA's format | NVIDIA NRAS itself |
| Live GPU offers and FX | KYC screening (fictional names) |
| Gas costs | tUSD, a worthless test token |

---

## Part A. Demonstrating the full PoC

```bash
cd ~/petahour-poc
```

```bash
conda activate petahour-poc
```

### A1. Show the market data and cost model (2 minutes)

```bash
make price
```

**Point out:** `report_4yr` reproduces the report's US$3.68, `fx_sensitivity` shows the move at today's live USD/TWD against the report's NT$31, and `fee_schedule` shows each year's take rate and Passport price from the financial model.

**Say:** "A new marketplace has no trades, so the opening price comes from a cost model. It reproduces the report line by line, and it takes FX live, because hardware is a dollar cost and power is an NT$ cost."

### A2. Run the whole system (2 minutes)

```bash
make demo
```

Output is colour-tagged by where each step happens:

| Tag | Meaning |
|---|---|
| `[live]` | Real external data |
| `[mock]` | A stand-in for a licensed or hardware service |
| `[off-chain]` | Python services |
| `[on-chain]` | A real transaction |
| `PASS` | A check that would stop the run if it failed |

### A3. Walk through the scenarios (10 minutes)

**S1 Happy path.** Look for the auction line, where hundreds of GPU-hours clear in microseconds, the `Passport fee` and `marketplace fee` lines, and the `audit:` lines.

*Say:* "Matching is off-chain and fast. But the operator can't touch funds. Every order is signed by the client, and the contract re-checks it. Then the index is rebuilt from on-chain trades alone and matched against what was published. The marketplace earns 2.5% in 2027, half from each side, and only on what was actually delivered."

**S2 Seller fraud.** Look for `Host measured 87.46%` and `Seller claimed 100.00%`.

*Say:* "The host's sealed telemetry is honest; the seller's claim isn't. The buyer re-runs the check, challenges, and the seller literally cannot produce a proof, because no valid one exists for a false statement. The waterfall then runs: collateral first, default fund for the shortfall, host suspended."

**S3 False challenge and honest outage.** Look for `Groth16 proof generated` and the public inputs line.

*Say:* "Here the seller is honest. It wins a dispute with a zero-knowledge proof, and the telemetry stays private: the chain sees a commitment, not the data. No human ruled on it. We don't use zkML to meter GPU-hours, because the report is right that it's far too slow. It's only for rare disputes, over a tiny model."

*Then:* "An honest seller who reports a real outage is paid pro rata. It can't be slashed for telling the truth."

**S4 Compliance.** *Say:* "Decentralized execution, permissioned access. Screening happens off-chain, so no personal data touches the chain, but the contract enforces the result. A freeze takes effect immediately."

**S5 Attacks.** Each line shows an attack and the exact contract error that stopped it. *Say:* "These are the attacks an investor's security team would ask about. Each is attempted for real."

**S6 Petahour Labs.** Look for the retail refusal, the Taiwan flag, the fee lines, what first-loss earned, and the last five lines.

*Say:* "This is the offshore layer, with its own keys and allow-list. Labs earns a curator fee and an origination fee, and pays Petahour a data licence. Petahour collects that with no role at Labs, which is the separation working. First-loss money is lent alongside senior money. With the book nearly full, seniors stop at 8% and first-loss keeps what is left, about 21% a year before losses. When the book goes thin, it earns nothing. TCPI falls 60%, the loan is liquidated, the collateral falls short, and the loss lands on the junior tranche at once. Senior depositors are whole. The last line is the honest one: they are whole because this loan is small against the pool. At the model's 13%, first-loss capital is used up at about a 40% fall, and that relies on liquidators paying about 75% of index. The Taiwan flag is deliberate: the natural borrowers are Taiwan GPU owners, and Taiwan's Virtual Asset Service Act may reach them. That needs a legal opinion."

### A4. Close with the numbers (1 minute)

The gas table prints at the end. For cost at live gas prices:

```bash
python scripts/l2_cost.py
```

*Say:* "A full trade costs cents in execution gas on either L2. As the report says, the bottleneck is the physical meter and the dispute window, never the chain."

### Optional: prove it runs on live networks

```bash
make demo-arbitrum
```

*Say:* "Same system, forked from live Arbitrum Sepolia: real chain ID and real state."

### Optional: inspect the chain yourself

Terminal 1, which leaves the chain running:

```bash
make demo-keep
```

Terminal 2:

```bash
conda activate petahour-poc && cd ~/petahour-poc
```

```bash
make status
```

To query a contract directly:

```bash
FEED=$(python -c "import json; print(json.load(open('deployments/31337.json'))['TCPIFeed'])")
```

```bash
cast call $FEED "latestRoundData()(uint80,int256,uint256,uint256,uint80)" --rpc-url http://127.0.0.1:8545
```

The second value is TCPI with 8 decimals. Press Ctrl+C in Terminal 1 to stop.

### Run one scenario

```bash
python -m petahour.cli demo --scenario s2
```

Choices are `s1` to `s6`. Each first runs setup and S1, because later scenarios depend on it.

### Reports to show afterwards

| File | Shows |
|---|---|
| `reports/e2e_report.json` | Every check and the gas used |
| `reports/tcpi_audit_trail.json` | Each index print and its input trades |
| `reports/vat_invoices.csv` | NT$ invoices with 5% VAT |
| `reports/daily_position_report.json` | Simulated regulatory report with CCP legs |

---

## Part B. Demonstrating the mini-PoC notebook

Open `mini-poc/Petahour_Mini_PoC.ipynb`. It arrives already executed, so you can read it before running anything. To run it fresh, choose *Run > Restart Kernel and Run All Cells*. It takes under a minute.

Each section explains a mechanism, then proves it with `PASS` checks. The last cell totals them.

| § | Mechanism | Point to make |
|---|---|---|
| 1 | Market data | Marketplace asks are not transaction prices |
| 2 | Cost model | Reproduces the report and agrees with Pantera's model |
| 3 | KYC, passport, federation | Hardware cannot self-certify; repeating a signature cannot fake a quorum |
| 4 | TEE attestation | A stolen token cannot vouch for another key. Why this cannot run on-chain |
| 5 | Matching | One uniform price; a cheaper offer is skipped if its SLA is too low |
| 6 | Escrow | The matcher cannot overcharge; a GPU-hour cannot be sold twice |
| 7 | Telemetry | Two commitments for two verifiers. The host seals, the seller claims |
| 8 | opML | Almost free when honest |
| 9 | **zkML** | **The centrepiece.** A real SNARK built from scratch, and why a false claim has no proof |
| 10 | Disputes | Four endings, and not one cent created or lost |
| 11 | TCPI | A wash trade cannot move it; anyone can audit a print |
| 12 | Petahour Labs | The junior tranche takes the hit; what it earns for that; how big a crash 13% can take; why not Singapore |
| 13 | Mapping | What the full PoC replaces |

**A good 10-minute version:** §6, §9 and §12.

**Try these live.** Add a new cell after §9 and run it. Each line should print `False`:

```python
print(witness_for(sample_features, 12345, sample_features[0] + 1, 1)[0].satisfied())   # claim 0.01% too much
print(verify(pk, public_list(dict(public, trade_id=2)), proof))                         # replay on another trade
```

Or edit a value and rerun from that cell:

| Change | Where | What happens |
|---|---|---|
| Set `LIVE_DATA = False` | Second code cell | Runs offline on a snapshot |
| Change the `0.40` in `crash_price` to `0.70` | §12 | A 30% fall: the collateral still covers the loan, so the junior tranche loses nothing |
| Set `WINSOR_BAND = 10` | §11 | The wash-trade check fails and stops the notebook, because the protection is off |

---

## Part C. Questions you will get

**Why a blockchain at all?** Not for speed. For programmable escrow tied to delivery, tokenized credit, and audit. The price index itself is a governance problem, not a ledger problem.

**Is there a token?** No native token, by design. `tUSD` is a test stablecoin.

**Why not zkML for everything?** Proving a real GPU workload costs 1,000x to 10,000x. It would cost more than the compute.

**What stops the federation colluding?** Nothing in code: it is a trust assumption, reduced by independent members, an M-of-N threshold and on-chain auditability.

**Is TEE attestation enough?** No. It proves real hardware, not hours delivered, and production needs CPU and GPU attestation together.

**Who regulates this?** Unsettled. No Taiwan statute defines compute as a commodity. The route is an FSC classification inquiry and voluntary MOEA/NSTC endorsement.

**Why Arbitrum or Base and not Solana?** Compatibility with Morpho and the EVM lending stack, not speed. The code runs on both.

**Is this production-ready?** No. The design document lists what is missing, including an audit, a public trusted-setup ceremony, multisig governance and real hardware.

**Does it compete with CME and Silicon Data?** The 5 November evaluation positions TCPI as a differentiated Taiwan-provenance index, linked by EFP and spreads, not head-to-head. CME's contracts were still pending CFTC review on 5 November.
