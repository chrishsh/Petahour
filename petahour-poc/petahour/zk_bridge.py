"""Calls the Node zk helper (circuits/zk_cli.js) from Python."""
from __future__ import annotations

import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLI = ROOT / "circuits" / "zk_cli.js"
MODEL_PATH = ROOT / "circuits" / "model" / "model.json"


class ProofUnavailable(Exception):
    """The circuit has no valid witness: the private data cannot satisfy the public claim."""


def _call(request: dict) -> dict:
    done = subprocess.run(
        ["node", str(CLI)], input=json.dumps(request), capture_output=True, text=True, cwd=ROOT
    )
    if done.returncode != 0:
        raise ProofUnavailable(done.stderr.strip()[:300])
    return json.loads(done.stdout)


def model_json() -> dict:
    return json.loads(MODEL_PATH.read_text())


def commitment(features: list[int], salt: int) -> int:
    return int(_call({"cmd": "commit", "features": features, "salt": str(salt)})["commitment"])


def model_hash() -> int:
    return int(_call({"cmd": "modelhash", "model": model_json()})["modelHash"])


def prove(features: list[int], salt: int, claimed_uptime_bps: int, trade_id: int) -> dict:
    """Returns a Groth16 proof, or raises ProofUnavailable if the claim cannot be proven."""
    return _call(
        {
            "cmd": "prove",
            "features": features,
            "salt": str(salt),
            "model": model_json(),
            "claimedUptimeBps": claimed_uptime_bps,
            "tradeId": str(trade_id),
        }
    )
