# Installation and Deployment Guide

There are two independent systems. The **mini-PoC** is a single notebook with no blockchain tooling, so start there if you want to see the mechanisms quickly. The **full PoC** runs real contracts on a real EVM.

| | Mini-PoC notebook | Full PoC |
|---|---|---|
| Time to run | About 2 minutes to install, then about a minute per run | 3 to 5 minutes to install, then under a minute per local demo and 1 to 2 minutes per fork demo |
| Needs | Python | Conda, internet for the first install |
| Disk | About 600 MB with Jupyter | About 1.3 GB |

These steps were replayed from a clean copy on macOS (Apple Silicon) on 7 November 2026, on the Mac the PoC was built on, and the timings above come from that replay. Expect longer on a machine that has to download everything. Linux should work, as `bootstrap.sh` handles it, but was not tested. Windows needs WSL2.

Commands below use `COMPUTE_EX` for the folder that holds this guide. To get it from GitHub:

```bash
git clone https://github.com/chrishsh/Petahour.git ~/Petahour
```

```bash
export COMPUTE_EX="$HOME/Petahour"
```

If you have the project in a synced folder such as Google Drive instead, set `COMPUTE_EX` to that folder.

---

## Part 1. Mini-PoC notebook

The notebook can run straight from Google Drive, because it has no heavy dependencies.

### Option A: a small virtual environment (recommended)

**Step 1.** Create an environment outside Drive:

```bash
python3 -m venv ~/petahour-mini
```

**Step 2.** Activate it:

```bash
source ~/petahour-mini/bin/activate
```

**Step 3.** Install the packages:

```bash
pip install -r "$COMPUTE_EX/mini-poc/requirements.txt"
```

**Step 4.** Start Jupyter:

```bash
jupyter lab "$COMPUTE_EX/mini-poc/Petahour_Mini_PoC.ipynb"
```

**Step 5.** In Jupyter, choose *Run > Restart Kernel and Run All Cells*.

**Check it worked:** the last cell prints `102 of 102 checks passed`. The count of live-data rows may vary, but the checks should not.

### Option B: the full PoC environment

If you have done Part 2, `conda activate petahour-poc` and run Step 4.

### Option C: Google Colab

Upload `Petahour_Mini_PoC.ipynb` to Colab and run all cells. The first code cell installs what is missing. This route was not tested.

**No network?** Set `LIVE_DATA = False` in the second code cell.

---

## Part 2. Full PoC on a local chain

### Prerequisites

Conda (Anaconda or Miniconda), plus `git` and `curl`. Nothing else: Node, Python, Foundry and all libraries are installed for you, into one conda environment.

### Step 1. Copy the project out of Google Drive

Dependencies add about 30,000 small files, which a cloud-synced folder would try to upload. The bootstrap script refuses to run inside one.

```bash
cp -R "$COMPUTE_EX/petahour-poc" ~/petahour-poc
```

```bash
cd ~/petahour-poc
```

### Step 2. Install everything

```bash
bash scripts/bootstrap.sh
```

This creates the `petahour-poc` conda environment, downloads Foundry 1.9.0 and verifies its published checksum, then installs the Python and Node packages and compiles the contracts. It writes nothing to your shell profile.

**Check it worked:** it ends with `Setup complete`.

### Step 3. Activate the environment

```bash
conda activate petahour-poc
```

Do this in every new terminal.

### Step 4. Run the tests

```bash
make test
```

**Check it worked:** Foundry reports `214 tests passed` or more, and pytest ends with `passed` and no failures. Takes about a minute.

### Step 5. Run the demo

```bash
make demo
```

This starts a local chain, deploys both entities, runs all six scenarios and shuts the chain down.

**Check it worked:** the last line reads `61/61 checks passed across 134 transactions`. Results are in `reports/`.

With no internet, use `make demo-offline`.

---

## Part 3. Run against live testnet state

This forks live Arbitrum Sepolia or Base Sepolia into a local node. It uses the real chain ID and real chain state, and it needs no wallet, no funds and no signup.

```bash
make demo-arbitrum
```

```bash
make demo-base
```

**Check it worked:** the same pass line, with chain ID 421614 or 84532 in `reports/e2e_report.json`.

---

## Part 4. Deploy to a public testnet

**Before you do this:** a public deployment is permanent and visible to anyone. The contracts carry the name Petahour, so confirm it is final first: changing it later means redeploying. Also, the six scenarios cannot run on a public network, because they jump time forward and a real delivery window takes hours. This step proves deployment, not the full flow.

**Step 1.** Create a brand-new wallet, and never reuse a wallet holding real funds:

```bash
cast wallet new-mnemonic
```

**Step 2.** Save the settings. In `~/petahour-poc`:

```bash
cp .env.example .env
```

Open `.env` and paste the mnemonic after `PETAHOUR_MNEMONIC=`.

**Step 3.** Print the two deployer addresses:

```bash
set -a; source .env; set +a; python -c "from petahour.chain import actors; import os; a=actors(os.environ['PETAHOUR_MNEMONIC']); print('Petahour admin ', a['petahour_admin'].address); print('Labs admin', a['labs_admin'].address)"
```

**Step 4.** Fund both addresses with Sepolia ETH on your target network, using a faucet listed in the [Arbitrum](https://docs.arbitrum.io/) or [Base](https://docs.base.org/) documentation. The deployment uses about 20 million gas in total, which is a tiny amount at testnet prices. A small faucet drip to each address should be plenty.

**Step 5.** Deploy. `--dispute-seconds` shortens the T+1 window so it can be observed:

```bash
python -m petahour.cli deploy --network arbitrum-sepolia --dispute-seconds 180
```

For Base, use `--network base-sepolia`.

**Step 6.** Confirm it:

```bash
python -m petahour.cli status --network arbitrum-sepolia
```

**Check it worked:** the status shows the contract addresses and zero trades. Addresses are saved in `deployments/421614.json`. Delete `.env` when finished.

---

## Part 5. Rebuild the zk artifacts (optional)

The repository ships with these already built. Rebuild only if you change the circuit.

```bash
make zk
```

Takes about 3 minutes and writes a new verifier. Then run `make test`.

This runs a single-party trusted setup: whoever runs it could forge proofs. That is fine for a PoC and not for production.

---

## Part 6. Uninstall

```bash
conda env remove -n petahour-poc
```

```bash
rm -rf ~/petahour-poc ~/petahour-mini
```

The compiler cache in `~/.svm` can also be removed if nothing else uses it.

---

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `This folder is inside a cloud-synced drive` | Working as designed. Do Part 2, Step 1 |
| `conda not found` | Install Miniconda. If conda exists but is not found, set `CONDA_EXE` to its path |
| `forge: command not found` | Run `conda activate petahour-poc` |
| `port 8545 is busy` | Another chain is running, often a `make demo-keep` left open. Press Ctrl+C in its terminal, or run `lsof -ti:8545 \| xargs kill` |
| `port 8799` in use | A mock server was left running from an interrupted demo. Run `lsof -ti:8799 \| xargs kill` |
| Fork demo fails or is slow | The public RPC is rate-limiting. Retry, or set your own URL in `petahour/config.py` |
| Market data shows `static` | A free API was unreachable. The demo continues on report data |
| `Scenario check failed` | A real failure. The line above it names the check; please treat it as a bug |
| Notebook cannot import a package | Check the virtual environment is active, or let the first cell install it |
