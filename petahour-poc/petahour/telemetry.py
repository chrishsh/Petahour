"""DCGM-style hourly telemetry, its Merkle commitment and the features the SLA model reads.

Two commitments are made over the same data, each for a different verifier:
  keccak Merkle root   cheap on the EVM; the buyer re-executes from disclosed hourly records (opML)
  Poseidon commitment  cheap inside a SNARK; lets the seller prove without disclosure (zkML)
"""
from __future__ import annotations

import json
import random
from dataclasses import asdict, dataclass

from web3 import Web3


@dataclass(frozen=True)
class HourRecord:
    hour: int
    available: float  # share of the hour the GPUs were reachable in CC mode
    sm_util: float
    power_frac: float
    throttle_frac: float
    ecc_errors: int
    link_errors: int

    def leaf(self) -> bytes:
        return Web3.keccak(text=json.dumps(asdict(self), sort_keys=True, separators=(",", ":")))


PROFILES = {
    "healthy": dict(outage_hours=0, throttle=(0.0, 0.02), ecc=(0, 1), link=(0, 2), power=(0.62, 0.86)),
    # Real outages, but what was delivered ran cleanly. An honest seller reports this and is paid pro rata.
    "partial": dict(outage_hours=3, throttle=(0.0, 0.02), ecc=(0, 1), link=(0, 2), power=(0.62, 0.86)),
    "degraded": dict(outage_hours=3, throttle=(0.10, 0.30), ecc=(2, 9), link=(4, 12), power=(0.55, 0.8)),
    "idle-fraud": dict(outage_hours=0, throttle=(0.0, 0.01), ecc=(0, 1), link=(0, 1), power=(0.08, 0.14)),
}


def simulate(hours: int, profile: str = "healthy", seed: int = 0) -> list[HourRecord]:
    rng = random.Random(seed)
    p = PROFILES[profile]
    down = set(rng.sample(range(hours), p["outage_hours"]))
    records = []
    for h in range(hours):
        available = 0.0 if h in down else 1.0 - rng.uniform(0, 0.001)
        records.append(
            HourRecord(
                hour=h,
                available=round(available, 5),
                sm_util=round(rng.uniform(0.6, 0.95) * available, 4),
                power_frac=round(rng.uniform(*p["power"]) * available, 4),
                throttle_frac=round(rng.uniform(*p["throttle"]), 4),
                ecc_errors=rng.randint(*p["ecc"]),
                link_errors=rng.randint(*p["link"]),
            )
        )
    return records


def merkle_root(records: list[HourRecord]) -> bytes:
    """Sorted-pair keccak tree, the convention OpenZeppelin's MerkleProof verifies."""
    layer = [r.leaf() for r in records]
    while len(layer) > 1:
        nxt = []
        for i in range(0, len(layer), 2):
            a = layer[i]
            b = layer[i + 1] if i + 1 < len(layer) else a
            nxt.append(Web3.keccak(min(a, b) + max(a, b)))
        layer = nxt
    return layer[0]


def features(records: list[HourRecord]) -> list[int]:
    """Aggregates records into the model's six integer features, all in basis points."""
    n = len(records)

    def bps(value: float) -> int:
        return min(10_000, max(0, round(value * 10_000)))

    return [
        bps(sum(r.available for r in records) / n),
        bps(sum(r.sm_util for r in records) / n),
        bps(sum(r.power_frac for r in records) / n),
        bps(sum(r.throttle_frac for r in records) / n),
        min(10_000, round(sum(r.ecc_errors for r in records) / n * 100)),
        min(10_000, round(sum(r.link_errors for r in records) / n * 100)),
    ]
