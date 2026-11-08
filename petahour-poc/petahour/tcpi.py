"""Traded Compute Price Index (report section 6.1).

TCPI is the daily VWAP of physically settled trades, normalised to PFLOP-hours. Defaulted trades
are excluded because nothing was delivered. Sub-indices are quoted per GPU-hour; the Composite
rolls them up per PFLOP-hour so that SKUs of different speeds can be compared.

Three properties come from the wider research file, because a benchmark that futures may one day
settle on must survive a regulator's manipulation test:
  * Winsorized: outliers are clamped before averaging, so one wash trade cannot move the print.
  * Volume-triggered sunset: the cost-model seed gives way once TRAILING 30-day volume crosses a
    pre-announced threshold, following the Dated Brent precedent.
  * Auditable: each print commits to its exact input trades, so it can be recomputed by anyone.
"""
from __future__ import annotations

import json
import math
from collections import deque
from dataclasses import dataclass

from web3 import Web3

from .config import (
    CME_CONTRACT_GPU_HOURS,
    METHODOLOGY_VERSION,
    SKUS,
    TCPI_SUNSET_WINDOW_DAYS,
    TCPI_VOLUME_THRESHOLD_GPU_HOURS,
    TCPI_WINSOR_BAND,
    pflop_hours_per_gpu_hour,
)


@dataclass(frozen=True)
class SettledTrade:
    sku: str
    gpu_hours: float
    price_usd: float
    trade_id: int = 0


@dataclass(frozen=True)
class IndexPrint:
    index: str
    usd_per_gpu_hour: float
    usd_per_pflop_hour: float
    volume_gpu_hours: float
    trades: int
    basis: str  # "VWAP" or "COST-MODEL-SEED"
    methodology: str = METHODOLOGY_VERSION

    @property
    def answer_e8(self) -> int:
        return round(self.usd_per_gpu_hour * 1e8)


def weighted_median(rows: list[SettledTrade]) -> float:
    """The price at which half the volume traded below and half above."""
    ordered = sorted(rows, key=lambda t: t.price_usd)
    half = sum(t.gpu_hours for t in ordered) / 2
    running = 0.0
    for i, t in enumerate(ordered):
        running += t.gpu_hours
        if math.isclose(running, half) and i + 1 < len(ordered):
            return (t.price_usd + ordered[i + 1].price_usd) / 2  # an exact split: the midpoint
        if running >= half:
            return t.price_usd
    return ordered[-1].price_usd


def winsorized_vwap(rows: list[SettledTrade], band: float = TCPI_WINSOR_BAND) -> float:
    """VWAP with each price clamped to a band around the volume-weighted median.

    Clamping keeps the trade's volume but limits its pull on the price. A band around the median
    is used, not percentile cut-offs, because percentiles mean little on a day with few trades.
    """
    median = weighted_median(rows)
    low, high = median * (1 - band), median * (1 + band)
    volume = sum(t.gpu_hours for t in rows)
    return sum(t.gpu_hours * min(max(t.price_usd, low), high) for t in rows) / volume


def inputs_hash(rows: list[SettledTrade]) -> bytes:
    """Commitment to the exact trades behind a print, in a canonical order."""
    canonical = sorted([t.trade_id, round(t.gpu_hours, 6), round(t.price_usd, 6)] for t in rows)
    return Web3.keccak(text=json.dumps(canonical, separators=(",", ":")))


class TcpiEngine:
    """Daily prints for one SKU.

    The sunset triggers on trailing-window volume and is then one-way: once crossed, the index
    never returns to the cost model, even if volume later falls. After that each day prints its
    own winsorized VWAP, and a day with no settled trades carries the last print forward.
    """

    def __init__(self, sku_key: str, threshold: float = TCPI_VOLUME_THRESHOLD_GPU_HOURS,
                 window_days: int = TCPI_SUNSET_WINDOW_DAYS):
        self.sku_key = sku_key
        self.threshold = threshold
        self.daily_volumes: deque[float] = deque(maxlen=window_days)
        self.sunset = False
        self.last: IndexPrint | None = None

    @property
    def trailing_volume(self) -> float:
        return sum(self.daily_volumes)

    def daily_print(self, day_trades: list[SettledTrade], cost_seed_usd: float) -> IndexPrint:
        rows = [t for t in day_trades if t.sku == self.sku_key]
        volume = sum(t.gpu_hours for t in rows)
        self.daily_volumes.append(volume)
        self.sunset = self.sunset or self.trailing_volume >= self.threshold
        factor = pflop_hours_per_gpu_hour(SKUS[self.sku_key])
        name = f"TCPI-{self.sku_key}"
        if not self.sunset:
            price, basis = cost_seed_usd, "COST-MODEL-SEED"
        elif rows:
            price, basis = winsorized_vwap(rows), "VWAP"
        else:
            price, basis = self.last.usd_per_gpu_hour, "CARRIED-FORWARD"
        self.last = IndexPrint(name, round(price, 6), round(price / factor, 6), volume, len(rows), basis)
        return self.last


def basis_report(tcpi_usd: float, vendor_usd: float | None) -> dict:
    """TCPI against the vendor index, per GPU-hour and per CME-sized contract.

    The two measure different things: TCPI is physical, Taiwan-resident, reserved-style capacity,
    while Silicon Data tracks on-demand neocloud rental. That gap is the provenance spread, and
    the 5 Nov venue evaluation says it must be managed and published. Reporting only: vendor data
    never feeds the index.
    """
    report = {"tcpi_usd": round(tcpi_usd, 4), "contract_gpu_hours": CME_CONTRACT_GPU_HOURS,
              "tcpi_contract_value_usd": round(tcpi_usd * CME_CONTRACT_GPU_HOURS, 2)}
    if vendor_usd is not None:
        spread = tcpi_usd - vendor_usd
        report.update(vendor_usd=vendor_usd, basis_usd=round(spread, 4),
                      basis_per_contract_usd=round(spread * CME_CONTRACT_GPU_HOURS, 2))
    return report


def composite(prints: list[IndexPrint]) -> float | None:
    """Volume-weighted USD per PFLOP-hour across SKUs. Weighting stops one SKU dominating."""
    weights = [
        (p.volume_gpu_hours * pflop_hours_per_gpu_hour(SKUS[p.index.removeprefix("TCPI-")]), p.usd_per_pflop_hour)
        for p in prints
        if p.basis == "VWAP"
    ]
    total = sum(w for w, _ in weights)
    return sum(w * price for w, price in weights) / total if total else None
