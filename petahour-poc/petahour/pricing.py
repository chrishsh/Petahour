"""Compute-unit cost build-up (report section 3.3.2, Table 3.4) and bid/ask tiers (Table 3.5).

The report states its result at NT$31.00 per US$1. Hardware is priced in USD while power and
facility costs are in NT$, so the exchange rate genuinely moves the result; pass the live rate
to see how far.
"""
from __future__ import annotations

from dataclasses import asdict, dataclass, replace

HOURS_PER_YEAR = 8_760


@dataclass(frozen=True)
class CostInputs:
    capex_usd: float = 50_000.0
    useful_life_years: float = 4.0
    utilization: float = 0.75
    gpu_kw: float = 1.7875
    pue: float = 1.4
    tariff_ntd_kwh: float = 3.5
    facility_ntd: float = 6.50
    network_ntd: float = 4.50
    operator_margin: float = 0.20
    vat: float = 0.05
    local_premium: float = 0.15
    fx_ntd_per_usd: float = 31.0


@dataclass(frozen=True)
class CostStack:
    amortization_ntd: float
    power_ntd: float
    facility_ntd: float
    network_ntd: float
    subtotal_ntd: float
    margin_ntd: float
    pre_vat_ntd: float
    vat_ntd: float
    domestic_base_ntd: float
    premium_ntd: float
    reference_ntd: float
    reference_usd: float
    fx_ntd_per_usd: float

    def as_dict(self) -> dict:
        return {k: round(v, 4) for k, v in asdict(self).items()}


def build_up(i: CostInputs = CostInputs()) -> CostStack:
    billable_hours = i.useful_life_years * HOURS_PER_YEAR * i.utilization
    amortization = i.capex_usd / billable_hours * i.fx_ntd_per_usd
    power = i.gpu_kw * i.pue * i.tariff_ntd_kwh
    subtotal = amortization + power + i.facility_ntd + i.network_ntd
    margin = subtotal * i.operator_margin
    pre_vat = subtotal + margin
    vat = pre_vat * i.vat
    domestic = pre_vat + vat
    premium = domestic * i.local_premium
    reference = domestic + premium
    return CostStack(
        amortization_ntd=amortization,
        power_ntd=power,
        facility_ntd=i.facility_ntd,
        network_ntd=i.network_ntd,
        subtotal_ntd=subtotal,
        margin_ntd=margin,
        pre_vat_ntd=pre_vat,
        vat_ntd=vat,
        domestic_base_ntd=domestic,
        premium_ntd=premium,
        reference_ntd=reference,
        reference_usd=reference / i.fx_ntd_per_usd,
        fx_ntd_per_usd=i.fx_ntd_per_usd,
    )


def three_year_case(i: CostInputs = CostInputs()) -> CostStack:
    """[Report] Compressing useful life to 3 years lifts the reference to about US$4.60."""
    return build_up(replace(i, useful_life_years=3.0))


def fx_sensitivity(live_fx: float, i: CostInputs = CostInputs()) -> dict:
    """How the reference price moves between the report's rate and a live rate."""
    base = build_up(i)
    live = build_up(replace(i, fx_ntd_per_usd=live_fx))
    return {
        "report_fx": i.fx_ntd_per_usd,
        "live_fx": live_fx,
        "report_ntd": round(base.reference_ntd, 2),
        "live_ntd": round(live.reference_ntd, 2),
        "report_usd": round(base.reference_usd, 4),
        "live_usd": round(live.reference_usd, 4),
        "ntd_change_pct": round((live.reference_ntd / base.reference_ntd - 1) * 100, 2),
        "usd_change_pct": round((live.reference_usd / base.reference_usd - 1) * 100, 2),
    }


def pantera_reconciliation(i: CostInputs = CostInputs()) -> dict:
    """Cross-check against Pantera's US model, per the C2 verification memo.

    Pantera depreciates US$61,853 per GPU over 5 years of calendar hours with no utilization
    haircut (US$1.41/hr). Restating that on Petahour's 75% utilization gives about US$1.88/hr, within
    US$0.02 of Petahour's own US$1.90 amortization: the two models agree once conventions are aligned.
    """
    pantera_capex, pantera_life_hours, pantera_direct = 61_853.0, 43_800.0, 2.27
    stack = build_up(i)
    calendar = pantera_capex / pantera_life_hours
    return {
        "petahour_amortization_usd": round(stack.amortization_ntd / i.fx_ntd_per_usd, 2),
        "pantera_calendar_usd": round(calendar, 2),
        "pantera_at_petahour_utilization_usd": round(calendar / i.utilization, 2),
        "petahour_direct_floor_usd": round(stack.subtotal_ntd / i.fx_ntd_per_usd, 2),
        "pantera_direct_usd": pantera_direct,
        "direct_gap_usd": round(stack.subtotal_ntd / i.fx_ntd_per_usd - pantera_direct, 2),
    }


# [Report] Table 3.5: spread as a share of mid, by liquidity tier.
SPREAD_TIERS = {1: (0.02, 0.05), 2: (0.05, 0.08), 3: (0.08, 0.15)}


def quote(mid: float, tier: int, liquidity: float = 0.5) -> tuple[float, float]:
    """Bid and ask around mid. liquidity runs from 0 (widest) to 1 (tightest)."""
    low, high = SPREAD_TIERS[tier]
    spread = high - (high - low) * min(max(liquidity, 0.0), 1.0)
    return mid * (1 - spread / 2), mid * (1 + spread / 2)
