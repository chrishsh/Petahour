"""Off-chain price discovery: a day-ahead uniform-price auction and an intraday CLOB.

This is where the speed lives. Orders match in memory in microseconds, and the chain only sees
the result. Attribute matching (grid zone, SLA tier) is the differentiator the report calls out:
a generic financial engine does not model these. Every limit is re-checked on-chain, so a bug or
a dishonest operator here can fail to match but cannot trade outside what a client signed.
"""
from __future__ import annotations

import itertools
from collections import deque
from dataclasses import dataclass, field
from typing import Iterable

ANY_ZONE = b"\x00" * 32
_ids = itertools.count(1)


@dataclass
class Order:
    actor: str
    is_buy: bool
    sku: str
    gpu_hours: int
    limit_e6: int
    start: int
    window_hours: int
    min_sla_bps: int = 0
    grid_zone: bytes = ANY_ZONE
    # Seller-side attributes come from the passport.
    passport_id: int = 0
    listing_id: int = 0
    host_sla_bps: int = 0
    host_zone: bytes = ANY_ZONE
    # Client signature material.
    onchain: dict | None = None
    signature: bytes = b""
    id: int = field(default_factory=lambda: next(_ids))
    remaining: int = -1

    def __post_init__(self) -> None:
        if self.remaining < 0:
            self.remaining = self.gpu_hours


@dataclass(frozen=True)
class Fill:
    buy: Order
    sell: Order
    qty: int
    price_e6: int


def compatible(buy: Order, sell: Order) -> bool:
    return (
        buy.sku == sell.sku
        and buy.start == sell.start
        and buy.window_hours == sell.window_hours
        and sell.host_sla_bps >= buy.min_sla_bps
        and (buy.grid_zone == ANY_ZONE or buy.grid_zone == sell.host_zone)
        and (buy.passport_id == 0 or buy.passport_id == sell.passport_id)
    )


def clearing_price(bids: list[Order], asks: list[Order]) -> tuple[int | None, int]:
    """Uniform price that maximises matched volume. Ties take the mid of the tied range."""
    prices = sorted({o.limit_e6 for o in bids + asks})
    best_volume, tied = 0, []
    for p in prices:
        demand = sum(o.remaining for o in bids if o.limit_e6 >= p)
        supply = sum(o.remaining for o in asks if o.limit_e6 <= p)
        volume = min(demand, supply)
        if volume > best_volume:
            best_volume, tied = volume, [p]
        elif volume == best_volume and volume > 0:
            tied.append(p)
    if not tied:
        return None, 0
    return (tied[0] + tied[-1]) // 2, best_volume


def run_day_ahead_auction(orders: Iterable[Order]) -> tuple[list[Fill], int | None]:
    """Everyone trades at one price. Price priority decides who, then submission time."""
    orders = list(orders)
    bids = sorted((o for o in orders if o.is_buy), key=lambda o: (-o.limit_e6, o.id))
    asks = sorted((o for o in orders if not o.is_buy), key=lambda o: (o.limit_e6, o.id))
    price, _ = clearing_price(bids, asks)
    if price is None:
        return [], None

    fills: list[Fill] = []
    for bid in (b for b in bids if b.limit_e6 >= price):
        for ask in (a for a in asks if a.limit_e6 <= price):
            if bid.remaining == 0:
                break
            if ask.remaining == 0 or not compatible(bid, ask):
                continue
            qty = min(bid.remaining, ask.remaining)
            bid.remaining -= qty
            ask.remaining -= qty
            fills.append(Fill(bid, ask, qty, price))
    return fills, price


class OrderBook:
    """Continuous price-time priority book for one SKU and delivery window."""

    def __init__(self) -> None:
        self.bids: dict[int, deque[Order]] = {}
        self.asks: dict[int, deque[Order]] = {}

    def submit(self, order: Order) -> list[Fill]:
        fills: list[Fill] = []
        opposite = self.asks if order.is_buy else self.bids
        levels = sorted(opposite, reverse=not order.is_buy)
        for level in levels:
            crosses = level <= order.limit_e6 if order.is_buy else level >= order.limit_e6
            if not crosses or order.remaining == 0:
                break
            queue = opposite[level]
            for resting in list(queue):
                if order.remaining == 0:
                    break
                buy, sell = (order, resting) if order.is_buy else (resting, order)
                if not compatible(buy, sell):
                    continue
                qty = min(order.remaining, resting.remaining)
                order.remaining -= qty
                resting.remaining -= qty
                fills.append(Fill(buy, sell, qty, level))  # the resting order sets the price
                if resting.remaining == 0:
                    queue.remove(resting)
            if not queue:
                del opposite[level]
        if order.remaining > 0:
            side = self.bids if order.is_buy else self.asks
            side.setdefault(order.limit_e6, deque()).append(order)
        return fills

    def cancel(self, order: Order) -> bool:
        side = self.bids if order.is_buy else self.asks
        queue = side.get(order.limit_e6)
        if queue and order in queue:
            queue.remove(order)
            if not queue:
                del side[order.limit_e6]
            return True
        return False

    def best_bid(self) -> int | None:
        return max(self.bids) if self.bids else None

    def best_ask(self) -> int | None:
        return min(self.asks) if self.asks else None

    def depth(self) -> dict:
        return {
            "bids": [(p, sum(o.remaining for o in q)) for p, q in sorted(self.bids.items(), reverse=True)],
            "asks": [(p, sum(o.remaining for o in q)) for p, q in sorted(self.asks.items())],
        }
