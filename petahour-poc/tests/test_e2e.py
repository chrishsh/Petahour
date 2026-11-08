"""Runs all six scenarios on a real local EVM. Needs anvil, forge and node on PATH."""
import json

from petahour import cli
from petahour.config import REPORTS


def test_all_scenarios_pass_on_a_local_chain():
    assert cli.run_demo(fork=None, offline=True, keep=False, only="all") == 0
    report = json.loads((REPORTS / "e2e_report.json").read_text())
    assert report["checks_total"] > 30
    assert report["checks_passed"] == report["checks_total"]
    assert set(report["scenarios"]) == {"S1", "S2", "S3", "S4", "S5", "S6"}


def test_a_busy_port_stops_the_demo_with_a_clear_message(monkeypatch, capsys):
    """Leaving `make demo-keep` open and starting another demo must not end in a traceback."""
    from petahour import chain as chain_mod, cli

    monkeypatch.setattr(chain_mod, "_port_open", lambda port: True)
    assert cli.run_demo(None, True, False, "all") == 1
    assert "is busy" in capsys.readouterr().out
