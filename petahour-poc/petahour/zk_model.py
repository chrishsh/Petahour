"""The SLA-scoring model behind the zkML dispute path.

A deliberately small network (6 inputs, 4 hidden ReLU units, 1 output) is trained on simulated
telemetry and converted to exact integers. It judges delivery QUALITY only. Uptime is proven
separately, by comparing the measured value with the claim inside the circuit. Keeping the two
apart matters: a seller who honestly reports 87% uptime after an outage must still be able to
prove that claim and be paid pro rata, instead of failing a model that expects 99%. Exact integers matter: a SNARK proves arithmetic, so
Python and the circuit must agree on every bit. The network here is illustrative. It shows the
mechanism, and its accuracy says nothing about real GPU fleets.

Integer forward pass, with S = SCALE and features in basis points (0..10000):
    H_j = sum_i W1[j][i] * f[i] + B1[j]            ~= S * 10000 * h_j
    O   = sum_j W2[j] * relu(H_j) + B2             ~= S^2 * 10000 * logit
A logit of 0 is the decision boundary. B2 carries a positive OFFSET so that the public threshold
is a non-zero value governance can raise, and no division is ever needed.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from sklearn.neural_network import MLPClassifier

FEATURES = ["uptime_bps", "sm_util_bps", "power_bps", "throttle_bps", "ecc_bps", "link_err_bps"]
N_FEATURES = len(FEATURES)
N_HIDDEN = 4
SCALE = 1024
OFFSET = 1 << 40
MAX_FEATURE = (1 << 14) - 1  # the circuit range-checks each feature to 14 bits


@dataclass(frozen=True)
class QuantizedModel:
    w1: list[list[int]]
    b1: list[int]
    w2: list[int]
    b2: int
    threshold: int

    def score(self, features: list[int]) -> int:
        hidden = [
            max(0, sum(w * f for w, f in zip(row, features)) + b) for row, b in zip(self.w1, self.b1)
        ]
        return sum(w * h for w, h in zip(self.w2, hidden)) + self.b2

    def passes(self, features: list[int]) -> bool:
        return self.score(features) >= self.threshold

    def flat_params(self) -> list[int]:
        """Parameter order used by the circuit's model hash."""
        return [w for row in self.w1 for w in row] + self.b1 + self.w2 + [self.b2]

    def to_json(self) -> dict:
        return {
            "features": FEATURES,
            "scale": SCALE,
            "w1": [[str(w) for w in row] for row in self.w1],
            "b1": [str(b) for b in self.b1],
            "w2": [str(w) for w in self.w2],
            "b2": str(self.b2),
            "threshold": str(self.threshold),
        }

    @classmethod
    def from_json(cls, d: dict) -> "QuantizedModel":
        return cls(
            w1=[[int(w) for w in row] for row in d["w1"]],
            b1=[int(b) for b in d["b1"]],
            w2=[int(w) for w in d["w2"]],
            b2=int(d["b2"]),
            threshold=int(d["threshold"]),
        )

    @classmethod
    def load(cls, path: str | Path) -> "QuantizedModel":
        return cls.from_json(json.loads(Path(path).read_text()))


def label(x: np.ndarray) -> np.ndarray:
    """Ground-truth quality rule the network learns: powered, cool, clean memory and links."""
    return ((x[:, 2] >= 3000) & (x[:, 3] <= 500) & (x[:, 4] <= 200) & (x[:, 5] <= 300)).astype(int)


def make_dataset(n: int = 40_000, seed: int = 7) -> tuple[np.ndarray, np.ndarray]:
    rng = np.random.default_rng(seed)
    healthy = np.column_stack(
        [
            rng.integers(5000, 10001, n),  # uptime varies freely, so the model learns to ignore it
            rng.integers(3000, 10001, n),
            rng.integers(3300, 10001, n),
            rng.integers(0, 400, n),
            rng.integers(0, 150, n),
            rng.integers(0, 250, n),
        ]
    )
    degraded = healthy.copy()
    fault = rng.integers(0, 4, n)
    rows = np.arange(n)
    degraded[rows[fault == 0], 2] = rng.integers(200, 2800, (fault == 0).sum())
    degraded[rows[fault == 1], 3] = rng.integers(700, 6000, (fault == 1).sum())
    degraded[rows[fault == 2], 4] = rng.integers(300, 5000, (fault == 2).sum())
    degraded[rows[fault == 3], 5] = rng.integers(400, 6000, (fault == 3).sum())
    x = np.vstack([healthy, degraded])
    y = label(x)
    order = rng.permutation(len(x))
    return x[order], y[order]


def train(seed: int = 7) -> tuple[QuantizedModel, dict]:
    x, y = make_dataset(seed=seed)
    split = int(len(x) * 0.8)
    xs = x / 10_000.0
    clf = MLPClassifier(
        hidden_layer_sizes=(N_HIDDEN,),
        activation="relu",
        solver="adam",
        alpha=1e-4,
        learning_rate_init=0.01,
        max_iter=400,
        random_state=seed,
    )
    clf.fit(xs[:split], y[:split])

    w1 = np.rint(clf.coefs_[0].T * SCALE).astype(np.int64).tolist()
    b1 = np.rint(clf.intercepts_[0] * SCALE * 10_000).astype(np.int64).tolist()
    w2 = np.rint(clf.coefs_[1][:, 0] * SCALE).astype(np.int64).tolist()
    b2 = int(round(float(clf.intercepts_[1][0]) * SCALE * SCALE * 10_000)) + OFFSET
    model = QuantizedModel(w1, b1, w2, b2, OFFSET)

    test_x, test_y = x[split:], y[split:]
    quant = np.array([model.passes([int(v) for v in row]) for row in test_x], dtype=int)
    metrics = {
        "train_samples": split,
        "test_samples": len(test_y),
        "float_accuracy": float(clf.score(xs[split:], test_y)),
        "quantized_accuracy": float((quant == test_y).mean()),
        "false_pass_rate": float(((quant == 1) & (test_y == 0)).sum() / max(1, (test_y == 0).sum())),
        "false_fail_rate": float(((quant == 0) & (test_y == 1)).sum() / max(1, (test_y == 1).sum())),
    }
    return model, metrics


if __name__ == "__main__":
    out = Path(__file__).resolve().parent.parent / "circuits" / "model"
    model, metrics = train()
    (out / "model.json").write_text(json.dumps({**model.to_json(), "metrics": metrics}, indent=2))
    print(json.dumps(metrics, indent=2))
