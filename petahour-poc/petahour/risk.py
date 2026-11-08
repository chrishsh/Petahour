"""Pre-trade checks and SPAN-style margin (report section 4.1.1, domain 4).

The escrow already pre-funds every trade on-chain, so a failed check here is an early, friendly
rejection and not the last line of defence. The margin function shows how a collateral rate
would be calibrated: a 99% one-sided move over two days, as the report specifies.
"""
from __future__ import annotations

import math
import statistics
from dataclasses import dataclass

from .config import BUYER_FEE_BPS

Z_99 = 2.326  # one-sided 99% normal quantile
HOLDING_DAYS = 2


class RiskReject(Exception):
    pass


def margin_rate(daily_prices: list[float], floor: float = 0.05) -> float:
    """Share of notional covering a 99% move over the holding period."""
    returns = [math.log(b / a) for a, b in zip(daily_prices, daily_prices[1:])]
    if len(returns) < 2:
        return floor
    return max(floor, Z_99 * statistics.stdev(returns) * math.sqrt(HOLDING_DAYS))


@dataclass
class PreTradeRisk:
    max_order_gpu_hours: int = 2_000
    price_band: float = 0.25  # reject prices more than 25% away from reference
    fee_bps: int = BUYER_FEE_BPS
    collateral_bps: int = 2_000

    def required_funds(self, is_buy: bool, qty: int, price_e6: int) -> int:
        notional = qty * price_e6
        if is_buy:
            return notional + notional * self.fee_bps // 10_000
        return notional * self.collateral_bps // 10_000

    def check(self, is_buy: bool, qty: int, price_e6: int, free_balance: int, reference_e6: int) -> None:
        if qty > self.max_order_gpu_hours:
            raise RiskReject(f"order size {qty} exceeds limit {self.max_order_gpu_hours}")
        if abs(price_e6 - reference_e6) > reference_e6 * self.price_band:
            raise RiskReject(f"price {price_e6 / 1e6:.2f} is outside the band around {reference_e6 / 1e6:.2f}")
        needed = self.required_funds(is_buy, qty, price_e6)
        if needed > free_balance:
            raise RiskReject(f"needs {needed / 1e6:,.2f} tUSD, has {free_balance / 1e6:,.2f}")
