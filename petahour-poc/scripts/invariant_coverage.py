"""Sums the invariant handlers' per-run counters and fails if a path was never hit.

An invariant test that swallows reverts can pass while doing nothing, so this checks that the
random runs really reached the code they claim to exercise.
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOGS = {
    "invariant_runs.csv": ["opened", "claimed", "challenged", "settled", "defaulted"],
    "vault_runs.csv": ["losses", "seniorLosses", "excessPaid", "seniorExits", "firstLossExits"],
}

totals: dict[str, int] = {}
for log, names in LOGS.items():
    rows = [list(map(int, line.split(","))) for line in (ROOT / "reports" / log).read_text().split()]
    totals.update(zip(names, map(sum, zip(*rows))))
    totals[f"{log.removesuffix('_runs.csv')}Runs"] = len(rows)
(ROOT / "reports" / "invariant_coverage.json").write_text(json.dumps(totals, indent=2))
print(totals)
missing = [n for names in LOGS.values() for n in names if totals[n] == 0]
if missing:
    print(f"never reached: {missing}")
    sys.exit(1)
