"""Simulated client order flow and the FIX-style gateway that receives it.

Clients are simulated because the marketplace has none yet. Messages use a small FIX 4.4 subset
(35=D NewOrderSingle), which is what institutional desks would connect with.
"""
from __future__ import annotations

import random
from dataclasses import dataclass

SOH = "|"
SIDE = {"1": True, "2": False}  # FIX tag 54: 1 = buy, 2 = sell


class GatewayReject(Exception):
    pass


@dataclass(frozen=True)
class NewOrder:
    cl_ord_id: str
    client: str
    symbol: str
    is_buy: bool
    qty: int
    price: float
    delivery_hours: int
    min_sla_bps: int


def encode(o: NewOrder) -> str:
    fields = [
        ("8", "FIX.4.4"), ("35", "D"), ("11", o.cl_ord_id), ("49", o.client), ("55", o.symbol),
        ("54", "1" if o.is_buy else "2"), ("38", str(o.qty)), ("44", f"{o.price:.4f}"),
        ("40", "2"), ("20001", str(o.delivery_hours)), ("20002", str(o.min_sla_bps)),
    ]
    return SOH.join(f"{k}={v}" for k, v in fields)


def decode(message: str) -> NewOrder:
    try:
        tags = dict(part.split("=", 1) for part in message.split(SOH) if part)
        if tags["35"] != "D":
            raise GatewayReject(f"unsupported MsgType {tags['35']}")
        qty, price = int(tags["38"]), float(tags["44"])
        if qty <= 0 or price <= 0:
            raise GatewayReject("quantity and price must be positive")
        return NewOrder(
            tags["11"], tags["49"], tags["55"], SIDE[tags["54"]], qty, price,
            int(tags.get("20001", 24)), int(tags.get("20002", 0)),
        )
    except (KeyError, ValueError) as exc:
        raise GatewayReject(f"malformed message: {exc}") from exc


def simulate_flow(mid: float, buyers: list[str], sellers: list[str], seed: int = 1) -> list[NewOrder]:
    """Buyers bid around mid and sellers offer around mid, inside the Tier 1 spread band."""
    rng = random.Random(seed)
    orders = []
    for i, name in enumerate(sellers):
        orders.append(NewOrder(f"S{i}", name, "B200", False, 192, round(mid * rng.uniform(0.975, 1.005), 2), 24, 0))
    for i, name in enumerate(buyers):
        orders.append(
            NewOrder(f"B{i}", name, "B200", True, rng.choice([96, 144, 192]), round(mid * rng.uniform(0.995, 1.03), 2), 24, 9990)
        )
    return orders
