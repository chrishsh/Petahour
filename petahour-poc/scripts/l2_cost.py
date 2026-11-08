"""Rough L2 cost of one trade, from real gas usage and today's mainnet L2 gas prices.

Execution gas only. L2 fees also include an L1 data component that varies with calldata size and
Ethereum congestion, so treat this as an order of magnitude and not a quote.
"""
import json
from pathlib import Path

import requests

ROOT = Path(__file__).resolve().parent.parent
NETS = {"Arbitrum One": "https://arb1.arbitrum.io/rpc", "Base": "https://mainnet.base.org"}


def gas_price(url: str) -> int:
    body = {"jsonrpc": "2.0", "id": 1, "method": "eth_gasPrice", "params": []}
    return int(requests.post(url, json=body, timeout=15).json()["result"], 16)


report = json.loads((ROOT / "reports" / "e2e_report.json").read_text())
gas = report["gas"]
eth = requests.get(
    "https://api.coingecko.com/api/v3/simple/price", params={"ids": "ethereum", "vs_currencies": "usd"}, timeout=15
).json()["ethereum"]["usd"]
paths = {
    "normal trade (match + claim + finalize)": gas["match orders"]["avg"] + gas["claim delivery"]["avg"] + gas["finalize"]["avg"],
    "disputed trade (adds challenge + zk proof)": gas["match orders"]["avg"] + gas["claim delivery"]["avg"]
    + gas["challenge"]["avg"] + gas["respond with zk proof"]["avg"],
}
out = {"eth_usd": eth, "networks": {}}
for name, url in NETS.items():
    price = gas_price(url)
    out["networks"][name] = {
        "gas_price_gwei": round(price / 1e9, 5),
        "cost_usd": {k: round(v * price / 1e18 * eth, 5) for k, v in paths.items()},
    }
out["gas"] = paths
(ROOT / "reports" / "l2_cost_estimate.json").write_text(json.dumps(out, indent=2))
print(json.dumps(out, indent=2))
