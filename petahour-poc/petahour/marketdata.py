"""External market data, each source behind one small adapter with an honest provenance label.

  Vast.ai public offers   LIVE and free. Asks on a thin marketplace, not trades.
  open.er-api.com FX      LIVE and free. Daily USD/TWD.
  Silicon Data            LICENSED. Its API schema is not public, so the client below follows an
                          ASSUMED protocol and runs against the mock in petahour.mocks.server.

Vendor indices are cross-checks only. They never feed TCPI: a marketplace benchmark must come from
its own settled trades, and Silicon Data licenses settlement reference and redistribution
separately from data access.
"""
from __future__ import annotations

import json
import statistics
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path

import requests

from .config import REPORTS, SKUS

VAST_URL = "https://console.vast.ai/api/v0/bundles/"
FX_URL = "https://open.er-api.com/v6/latest/USD"
TIMEOUT = 15
SNAPSHOT = REPORTS / "market_snapshot.json"
FALLBACK_FX = 33.05  # USD/TWD observed 2026-11-06, used only when offline


@dataclass
class SkuQuote:
    sku: str
    median_usd: float
    low_usd: float
    high_usd: float
    offers: int
    source: str


@dataclass
class MarketSnapshot:
    fx_ntd_per_usd: float
    fx_source: str
    quotes: dict[str, SkuQuote] = field(default_factory=dict)
    vendor_index: dict[str, float] = field(default_factory=dict)
    taken_at: float = 0.0
    mode: str = "offline"

    def to_json(self) -> dict:
        d = asdict(self)
        d["quotes"] = {k: asdict(v) for k, v in self.quotes.items()}
        return d


def fetch_vast_quotes() -> dict[str, SkuQuote]:
    """Public, keyless. Prices are per machine, so they are divided by GPU count."""
    wanted = [name for sku in SKUS.values() for name in sku.vast_names]
    query = {"rentable": {"eq": True}, "gpu_name": {"in": wanted}, "type": "on-demand", "limit": 300}
    resp = requests.get(VAST_URL, params={"q": json.dumps(query)}, timeout=TIMEOUT)
    resp.raise_for_status()
    prices: dict[str, list[float]] = {}
    for offer in resp.json().get("offers", []):
        gpus = offer.get("num_gpus") or 0
        if gpus > 0 and offer.get("dph_total"):
            prices.setdefault(offer["gpu_name"], []).append(offer["dph_total"] / gpus)
    quotes = {}
    for key, sku in SKUS.items():
        rows = [p for name in sku.vast_names for p in prices.get(name, [])]
        if rows:
            quotes[key] = SkuQuote(
                key, round(statistics.median(rows), 4), round(min(rows), 4), round(max(rows), 4), len(rows), "vast.ai (live asks)"
            )
    return quotes


def fetch_fx() -> float:
    resp = requests.get(FX_URL, timeout=TIMEOUT)
    resp.raise_for_status()
    return float(resp.json()["rates"]["TWD"])


class SiliconDataClient:
    """ASSUMED protocol: API-key header, one JSON document per ticker."""

    def __init__(self, base_url: str, api_key: str):
        self.base_url = base_url.rstrip("/")
        self.headers = {"X-API-Key": api_key}

    def latest(self, ticker: str) -> dict:
        resp = requests.get(f"{self.base_url}/v1/indices/{ticker}/latest", headers=self.headers, timeout=TIMEOUT)
        resp.raise_for_status()
        return resp.json()

    def history(self, ticker: str, days: int = 30) -> list[dict]:
        resp = requests.get(
            f"{self.base_url}/v1/indices/{ticker}/history", params={"days": days}, headers=self.headers, timeout=TIMEOUT
        )
        resp.raise_for_status()
        return resp.json()["points"]


def offline_snapshot() -> MarketSnapshot:
    """Report benchmarks (Table 3.2), so every demo still runs with no network."""
    quotes = {
        key: SkuQuote(key, sku.report_spot_usd, sku.report_spot_usd, sku.report_spot_usd, 0, "report Table 3.2 (static)")
        for key, sku in SKUS.items()
    }
    return MarketSnapshot(FALLBACK_FX, "static fallback", quotes, {}, time.time(), "offline")


def load_snapshot(live: bool = True, vendor: SiliconDataClient | None = None) -> MarketSnapshot:
    """Live data where available, degrading per source. Never fails because a free API is down."""
    snap = offline_snapshot()
    if live:
        try:
            snap.fx_ntd_per_usd = round(fetch_fx(), 4)
            snap.fx_source = "open.er-api.com (live)"
            snap.mode = "live"
        except (requests.RequestException, KeyError, ValueError):
            pass
        try:
            snap.quotes.update(fetch_vast_quotes())
            snap.mode = "live"
        except (requests.RequestException, ValueError):
            pass
    if vendor is not None:
        for key, sku in SKUS.items():
            if sku.vendor_ticker:
                try:
                    snap.vendor_index[sku.vendor_ticker] = vendor.latest(sku.vendor_ticker)["value"]
                except requests.RequestException:
                    pass
    snap.taken_at = time.time()
    REPORTS.mkdir(exist_ok=True)
    SNAPSHOT.write_text(json.dumps(snap.to_json(), indent=2))
    return snap
