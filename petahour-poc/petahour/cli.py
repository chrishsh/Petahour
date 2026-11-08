"""Command line entry point: python -m petahour.cli <command>."""
from __future__ import annotations

import argparse
import json
import os
import sys

from rich.console import Console

from . import chain as chain_mod
from .config import LABS_CURATOR_FEE_BPS, LABS_LICENCE_BPS, LABS_ORIGINATION_FEE_BPS, NETWORKS, fee_schedule, tag
from .marketplace import Marketplace
from .marketdata import SiliconDataClient, load_snapshot
from .mocks.server import VENDOR_API_KEY, MockServer
from .pricing import build_up, fx_sensitivity, three_year_case
from .scenarios import Demo

console = Console()


def cmd_market(args) -> int:
    with MockServer() as mock:
        snap = load_snapshot(live=not args.offline, vendor=SiliconDataClient(mock.base_url, VENDOR_API_KEY))
    console.print_json(json.dumps(snap.to_json()))
    return 0


def cmd_price(args) -> int:
    console.print_json(json.dumps({
        "report_4yr": build_up().as_dict(),
        "report_3yr": three_year_case().as_dict(),
        "fx_sensitivity": fx_sensitivity(load_snapshot(live=not args.offline).fx_ntd_per_usd),
        "fee_schedule": fee_schedule(),
        "labs_fees": {
            "curator_pct_of_interest": LABS_CURATOR_FEE_BPS / 100,
            "origination_pct_of_new_loans": LABS_ORIGINATION_FEE_BPS / 100,
            "licence_to_petahour_pct_of_average_loans": LABS_LICENCE_BPS / 100,
        },
    }))
    return 0


def run_demo(fork: str | None, offline: bool, keep: bool, only: str) -> int:
    try:
        node = chain_mod.LocalNode(fork=fork).start()
    except chain_mod.ChainBusy as exc:
        console.print(f"[bold red]{exc}[/]")
        return 1
    try:
        if fork:
            node.fund_actors()
        console.print(f"[bold]Local chain up[/] (chain id {node.chain_id}{', forked from ' + fork if fork else ''}); deploying both entities")
        chain_mod.deploy(node.rpc, node.chain_id)
        chain = chain_mod.Chain(node.rpc, node.chain_id)
        with MockServer() as mock:
            vendor = SiliconDataClient(mock.base_url, VENDOR_API_KEY)
            snap = load_snapshot(live=not offline, vendor=vendor)
            demo = Demo(Marketplace(chain, mock.base_url), snap, vendor, console)
            if only == "all":
                demo.run_all()
            else:
                demo.bootstrap()
                demo.s1_happy_path()
                extra = {"s2": demo.s2_seller_fraud, "s3": demo.s3_false_challenge, "s4": demo.s4_compliance,
                         "s5": demo.s5_attacks}
                if only == "s6":
                    demo.s3_false_challenge()
                    demo.s6_labs()
                elif only in extra:
                    extra[only]()
                demo.close()
        if keep:
            console.print(f"Chain left running at {node.rpc}. Press Ctrl+C to stop it.")
            node.proc.wait()
        return 0
    except AssertionError as exc:
        console.print(f"[bold red]Scenario check failed:[/] {exc}")
        return 1
    except KeyboardInterrupt:
        return 0
    finally:
        node.stop()


def cmd_demo(args) -> int:
    return run_demo(args.fork, args.offline, args.keep, args.scenario)


def cmd_deploy(args) -> int:
    """Deploys to a public testnet. Needs a funded mnemonic, read from the PETAHOUR_MNEMONIC variable."""
    mnemonic = os.environ.get("PETAHOUR_MNEMONIC")
    if not mnemonic:
        console.print("[red]Set PETAHOUR_MNEMONIC in your shell or .env first. See docs/04_INSTALL_AND_DEPLOY.md.[/]")
        return 2
    net = NETWORKS[args.network]
    rpc = os.environ.get(f"{args.network.upper().replace('-', '_')}_RPC_URL", net["rpc"])
    windows = {"DISPUTE_WINDOW": args.dispute_seconds, "RESPONSE_WINDOW": args.dispute_seconds, "CLAIM_GRACE": args.dispute_seconds}
    result = chain_mod.deploy(rpc, net["chain_id"], mnemonic, windows)
    console.print_json(json.dumps(result))
    return 0


def cmd_status(args) -> int:
    """Reads protocol state from a running chain (start one with: demo --keep)."""
    net = NETWORKS[args.network]
    chain = chain_mod.Chain(net["rpc"], net["chain_id"], simulated_time=False)
    c = chain.c
    usd = lambda atoms: round(atoms / 1e6, 2)
    trades = c["DvPEscrow"].functions.nextTradeId().call() - 1
    rounds = c["TCPIOracle"].functions.roundCount(tag("TCPI-B200")).call()
    latest = c["TCPIFeed"].functions.latestRoundData().call() if rounds else (0, 0)
    vault = c["ComputeCreditVault"].functions
    market = c["IsolatedLendingMarket"].functions
    console.print_json(json.dumps({
        "chainId": chain.chain_id,
        "block": chain.w3.eth.block_number,
        "trades": trades,
        "escrowLockedUsd": usd(c["DvPEscrow"].functions.totalLocked().call()),
        "defaultFundMutualPoolUsd": usd(c["DefaultFund"].functions.mutualPool().call()),
        "tcpiB200Usd": latest[1] / 1e8,
        "tcpiRounds": latest[0],
        "seniorVaultAssetsUsd": usd(vault.totalAssets().call()),
        "firstLossAssetsUsd": usd(c["FirstLossTranche"].functions.totalAssets().call()),
        "lendingPoolUsd": usd(vault.waterfall().call()[0]),
        "marketBorrowedUsd": usd(market.totalBorrowAssets().call()),
        "marketBadDebtUsd": usd(market.badDebtTotal().call()),
        "contracts": {k: v for k, v in chain.addresses.items() if k not in ("chainId",)},
    }))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(prog="petahour", description="Petahour on-chain PoC")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("market", help="fetch live market data with mock vendor cross-check")
    p.add_argument("--offline", action="store_true")
    p.set_defaults(func=cmd_market)

    p = sub.add_parser("price", help="reproduce the report's cost model, with live FX sensitivity")
    p.add_argument("--offline", action="store_true")
    p.set_defaults(func=cmd_price)

    p = sub.add_parser("demo", help="start a local chain, deploy, run scenarios")
    p.add_argument("--scenario", default="all", choices=["all", "s1", "s2", "s3", "s4", "s5", "s6"])
    p.add_argument("--offline", action="store_true", help="use static market data, no network")
    p.add_argument("--fork", choices=["arbitrum-sepolia", "base-sepolia"], help="fork live testnet state")
    p.add_argument("--keep", action="store_true", help="leave the chain running afterwards")
    p.set_defaults(func=cmd_demo)

    p = sub.add_parser("status", help="read live protocol state from a running chain")
    p.add_argument("--network", default="local", choices=list(NETWORKS))
    p.set_defaults(func=cmd_status)

    p = sub.add_parser("deploy", help="deploy to a public testnet")
    p.add_argument("--network", required=True, choices=["arbitrum-sepolia", "base-sepolia"])
    p.add_argument("--dispute-seconds", type=int, default=180)
    p.set_defaults(func=cmd_deploy)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
