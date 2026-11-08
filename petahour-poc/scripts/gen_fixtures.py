"""Generates the real Groth16 proof that the Foundry zk tests verify on-chain."""
import json
from pathlib import Path

from petahour import zk_bridge
from petahour.zk_model import QuantizedModel

features = [9975, 7800, 7100, 120, 40, 60]  # a healthy delivery
salt = 123456789
trade_id = 1
claimed = 9975

model = QuantizedModel.from_json(zk_bridge.model_json())
assert model.passes(features)
proof = zk_bridge.prove(features, salt, claimed, trade_id)
out = {
    "features": features,
    "salt": str(salt),
    "tradeId": trade_id,
    "claimedUptimeBps": claimed,
    "commitment": str(zk_bridge.commitment(features, salt)),
    "modelHash": str(zk_bridge.model_hash()),
    "threshold": str(model.threshold),
    "a": proof["a"],
    "b": proof["b"],
    "c": proof["c"],
    "publicSignals": proof["publicSignals"],
}
Path("test/fixtures/proof.json").write_text(json.dumps(out, indent=2))
print(f"proof generated in {proof['ms']} ms; public signals: {proof['publicSignals']}")
