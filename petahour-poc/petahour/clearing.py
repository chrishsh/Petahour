"""Post-trade: the CCP view of each trade, VAT invoices and regulatory reports (all simulated).

On-chain settlement in PoC-0 is bilateral escrow with a default-fund backstop. This module shows
what a CCP records for the same trade: novation into two legs against the clearing house.
Report section 4.1.3 recommends buying the real engine, so this is only a mock of its outputs.
"""
from __future__ import annotations

import csv
import json

from .config import REPORTS
from .marketplace import Marketplace

CCP = "PETAHOUR-CCP"
VAT_RATE = 0.05


def novate(trade_id: int, t: dict) -> list[dict]:
    """One bilateral trade becomes two legs, each against the clearing house."""
    leg = {"trade_id": trade_id, "gpu_hours": t["gpuHours"], "price_usd": t["priceE6"] / 1e6}
    return [
        {**leg, "leg": "buy", "member": t["buyer"], "counterparty": CCP},
        {**leg, "leg": "sell", "member": t["seller"], "counterparty": CCP},
    ]


def invoice(trade_id: int, t: dict, fx: float) -> dict:
    """The listed price includes 5% VAT, so the tax is backed out of the gross amount."""
    gross_usd = t["notional"] / 1e6
    gross_ntd = gross_usd * fx
    net_ntd = gross_ntd / (1 + VAT_RATE)
    return {
        "trade_id": trade_id,
        "status": t["statusName"],
        "gpu_hours": t["gpuHours"],
        "unit_price_usd": t["priceE6"] / 1e6,
        "gross_usd": round(gross_usd, 2),
        "fx_ntd_per_usd": fx,
        "gross_ntd": round(gross_ntd, 2),
        "net_ntd": round(net_ntd, 2),
        "vat_ntd": round(gross_ntd - net_ntd, 2),
    }


def write_reports(ex: Marketplace, trade_ids: list[int], fx: float) -> dict:
    REPORTS.mkdir(exist_ok=True)
    trades = {i: ex.trade(i) for i in trade_ids}
    invoices = [invoice(i, t, fx) for i, t in trades.items()]
    with (REPORTS / "vat_invoices.csv").open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=list(invoices[0]))
        writer.writeheader()
        writer.writerows(invoices)

    legs = [leg for i, t in trades.items() for leg in novate(i, t)]
    statuses: dict[str, int] = {}
    for t in trades.values():
        statuses[t["statusName"]] = statuses.get(t["statusName"], 0) + 1
    report = {
        "report": "Daily position and surveillance report (SIMULATED, not a regulatory filing)",
        # No regulator has statutory oversight of a physical compute venue today. The FSC route is a
        # classification inquiry; MOEA and NSTC would be voluntary policy endorsement.
        "recipients": ["FSC (classification dialogue)", "MOEA / NSTC (voluntary)"],
        "trades": len(trades),
        "gpu_hours": sum(t["gpuHours"] for t in trades.values()),
        "gross_usd": round(sum(t["notional"] for t in trades.values()) / 1e6, 2),
        "vat_ntd_total": round(sum(i["vat_ntd"] for i in invoices), 2),
        "by_status": statuses,
        "ccp_legs": legs,
    }
    (REPORTS / "daily_position_report.json").write_text(json.dumps(report, indent=2))
    return report
