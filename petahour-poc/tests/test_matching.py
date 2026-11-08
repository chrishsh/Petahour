import pytest

from petahour.gateway import GatewayReject, NewOrder, decode, encode, simulate_flow
from petahour.matching import ANY_ZONE, Order, OrderBook, clearing_price, compatible, run_day_ahead_auction
from petahour.risk import PreTradeRisk, RiskReject, margin_rate
from petahour.pricing import pantera_reconciliation
from petahour.tcpi import SettledTrade, TcpiEngine, basis_report, composite, inputs_hash, weighted_median, winsorized_vwap


def bid(price, qty=100, **kw):
    return Order("b", True, "B200", qty, price, 1000, 24, **kw)


def ask(price, qty=100, **kw):
    kw.setdefault("host_sla_bps", 9990)
    return Order("s", False, "B200", qty, price, 1000, 24, **kw)


def test_auction_clears_at_a_single_price():
    fills, price = run_day_ahead_auction([bid(110), bid(105), ask(95), ask(100)])
    assert price is not None
    assert {f.price_e6 for f in fills} == {price}
    assert sum(f.qty for f in fills) == 200


def test_auction_respects_every_limit():
    fills, price = run_day_ahead_auction([bid(100), ask(90), ask(120)])
    assert all(f.buy.limit_e6 >= f.price_e6 >= f.sell.limit_e6 for f in fills)


def test_no_cross_means_no_trade():
    fills, price = run_day_ahead_auction([bid(90), ask(100)])
    assert fills == [] and price is None


def test_price_maximises_volume():
    price, volume = clearing_price([bid(105, 300)], [ask(100, 100), ask(104, 100), ask(110, 500)])
    assert volume == 200 and 104 <= price <= 105


def test_auction_never_overfills():
    bids = [bid(120, 50), bid(115, 80)]
    asks = [ask(90, 60), ask(95, 40)]
    fills, _ = run_day_ahead_auction(bids + asks)
    for o in bids + asks:
        assert sum(f.qty for f in fills if o in (f.buy, f.sell)) <= o.gpu_hours


def test_sla_constraint_blocks_a_match():
    assert not compatible(bid(100, min_sla_bps=9999), ask(90, host_sla_bps=9990))
    fills, _ = run_day_ahead_auction([bid(100, min_sla_bps=9999), ask(90, host_sla_bps=9990)])
    assert fills == []


def test_grid_zone_constraint_blocks_a_match():
    assert not compatible(bid(100, grid_zone=b"\x01" * 32), ask(90, host_zone=b"\x02" * 32))
    assert compatible(bid(100, grid_zone=b"\x01" * 32), ask(90, host_zone=b"\x01" * 32))
    assert compatible(bid(100, grid_zone=ANY_ZONE), ask(90, host_zone=b"\x02" * 32))


def test_book_price_time_priority():
    book = OrderBook()
    first, second = ask(100, 50), ask(100, 50)
    cheaper = ask(99, 50)
    for o in (first, second, cheaper):
        book.submit(o)
    fills = book.submit(bid(100, 120))
    assert [f.sell for f in fills] == [cheaper, first, second]
    assert [f.qty for f in fills] == [50, 50, 20]


def test_resting_order_sets_the_price():
    book = OrderBook()
    book.submit(ask(95))
    fills = book.submit(bid(100))
    assert fills[0].price_e6 == 95


def test_unfilled_remainder_rests():
    book = OrderBook()
    book.submit(ask(95, 40))
    book.submit(bid(100, 100))
    assert book.best_bid() == 100
    assert book.depth()["bids"] == [(100, 60)]


def test_incompatible_resting_order_is_skipped_not_lost():
    book = OrderBook()
    book.submit(ask(95, 50, host_sla_bps=9000))
    fills = book.submit(bid(100, 50, min_sla_bps=9990))
    assert fills == []
    assert book.best_ask() == 95 and book.best_bid() == 100


def test_cancel_removes_from_book():
    book = OrderBook()
    o = ask(95)
    book.submit(o)
    assert book.cancel(o) and book.best_ask() is None
    assert not book.cancel(o)


def test_fix_round_trip():
    o = NewOrder("C1", "alpha", "B200", True, 96, 3.72, 24, 9990)
    assert decode(encode(o)) == o


@pytest.mark.parametrize("msg", ["35=D|55=B200", "35=8|11=x", "35=D|11=x|49=y|55=B200|54=1|38=-1|44=3.0", "garbage"])
def test_gateway_rejects_bad_messages(msg):
    with pytest.raises(GatewayReject):
        decode(msg)


def test_simulated_flow_is_reproducible():
    assert simulate_flow(3.68, ["a"], ["b"], seed=3) == simulate_flow(3.68, ["a"], ["b"], seed=3)


def test_risk_rejects_size_band_and_funds():
    r = PreTradeRisk()
    ref = 3_680_000
    with pytest.raises(RiskReject, match="exceeds limit"):
        r.check(True, 5_000, ref, 10**12, ref)
    with pytest.raises(RiskReject, match="outside the band"):
        r.check(True, 10, ref * 2, 10**12, ref)
    with pytest.raises(RiskReject, match="needs"):
        r.check(True, 100, ref, 1, ref)
    r.check(True, 100, ref, 10**12, ref)


def test_margin_rate_grows_with_volatility_and_has_a_floor():
    calm = margin_rate([100, 100.1, 100.0, 100.1, 100.0])
    wild = margin_rate([100, 120, 90, 130, 80])
    assert calm == pytest.approx(0.05)
    assert wild > 0.5


def test_tcpi_seeds_from_cost_model_below_threshold():
    p = TcpiEngine("B200").daily_print([SettledTrade("B200", 100, 4.0)], cost_seed_usd=3.68)
    assert p.basis == "COST-MODEL-SEED" and p.usd_per_gpu_hour == 3.68


def test_tcpi_switches_to_vwap_at_threshold():
    trades = [SettledTrade("B200", 300, 3.5), SettledTrade("B200", 300, 3.9)]
    p = TcpiEngine("B200").daily_print(trades, cost_seed_usd=3.68)
    assert p.basis == "VWAP" and p.usd_per_gpu_hour == pytest.approx(3.7)
    assert p.usd_per_pflop_hour == pytest.approx(3.7 / 2.7, rel=1e-4)


def test_vwap_weights_by_volume_not_by_trade():
    p = TcpiEngine("B200").daily_print([SettledTrade("B200", 900, 3.0), SettledTrade("B200", 100, 3.2)], 3.68)
    assert p.usd_per_gpu_hour == pytest.approx(3.02)


def test_winsorizing_stops_one_wash_trade_moving_the_print():
    honest = [SettledTrade("B200", 500, 3.70), SettledTrade("B200", 400, 3.72)]
    wash = SettledTrade("B200", 100, 11.00)   # 3x the market, 10% of the volume
    plain = (500 * 3.70 + 400 * 3.72 + 100 * 11.00) / 1000
    assert plain > 4.4                                         # an unprotected VWAP jumps 20%
    assert winsorized_vwap(honest + [wash]) == pytest.approx(3.746, abs=0.01)


def test_winsorizing_leaves_normal_prices_untouched():
    rows = [SettledTrade("B200", 300, 3.60), SettledTrade("B200", 300, 3.70), SettledTrade("B200", 300, 3.80)]
    assert winsorized_vwap(rows) == pytest.approx(3.70)


def test_weighted_median_follows_volume():
    assert weighted_median([SettledTrade("B200", 900, 3.0), SettledTrade("B200", 100, 9.0)]) == 3.0


def test_weighted_median_of_an_even_split_is_the_midpoint():
    assert weighted_median([SettledTrade("B200", 300, 3.5), SettledTrade("B200", 300, 3.9)]) == pytest.approx(3.7)


def test_inputs_hash_is_order_independent_and_tamper_evident():
    a, b = SettledTrade("B200", 100, 3.7, 1), SettledTrade("B200", 200, 3.8, 2)
    assert inputs_hash([a, b]) == inputs_hash([b, a])
    assert inputs_hash([a, b]) != inputs_hash([a, SettledTrade("B200", 200, 3.81, 2)])


def test_basis_report_sizes_to_the_730_hour_contract():
    r = basis_report(3.70, 6.50)
    assert r["basis_usd"] == pytest.approx(-2.80)
    assert r["basis_per_contract_usd"] == pytest.approx(-2.80 * 730)
    assert "basis_usd" not in basis_report(3.70, None)


def test_pantera_reconciliation_matches_the_c2_memo():
    r = pantera_reconciliation()
    assert r["pantera_calendar_usd"] == pytest.approx(1.41, abs=0.005)
    assert r["pantera_at_petahour_utilization_usd"] == pytest.approx(1.88, abs=0.005)
    assert r["petahour_amortization_usd"] == pytest.approx(1.90, abs=0.005)
    assert r["direct_gap_usd"] == pytest.approx(0.27, abs=0.005)


def test_print_uses_only_that_days_trades():
    e = TcpiEngine("B200")
    e.daily_print([SettledTrade("B200", 600, 3.0)], 3.68)
    p = e.daily_print([SettledTrade("B200", 10, 5.0)], 3.68)
    assert p.usd_per_gpu_hour == pytest.approx(5.0)


def test_old_volume_rolls_out_of_the_trailing_window():
    e = TcpiEngine("B200", window_days=30)
    e.daily_print([SettledTrade("B200", 300, 3.5)], 3.68)
    for _ in range(30):
        e.daily_print([], 3.68)                     # day one's volume has now left the window
    assert e.daily_print([SettledTrade("B200", 300, 3.5)], 3.68).basis == "COST-MODEL-SEED"


def test_sunset_is_one_way():
    e = TcpiEngine("B200", window_days=3)
    e.daily_print([SettledTrade("B200", 600, 3.0)], 3.68)
    for _ in range(5):
        e.daily_print([], 3.68)                     # trailing volume falls back to zero
    assert e.daily_print([SettledTrade("B200", 1, 3.2)], 3.68).basis == "VWAP"


def test_quiet_day_carries_the_last_print_forward():
    e = TcpiEngine("B200")
    e.daily_print([SettledTrade("B200", 600, 3.4)], 3.68)
    p = e.daily_print([], 3.68)
    assert p.basis == "CARRIED-FORWARD" and p.usd_per_gpu_hour == pytest.approx(3.4)


def test_volume_accumulates_across_days_toward_the_sunset():
    e = TcpiEngine("B200")
    assert e.daily_print([SettledTrade("B200", 300, 3.4)], 3.68).basis == "COST-MODEL-SEED"
    assert e.daily_print([SettledTrade("B200", 300, 3.6)], 3.68).basis == "VWAP"


def test_other_skus_do_not_leak_into_a_sub_index():
    p = TcpiEngine("B200").daily_print([SettledTrade("H200", 900, 9.9), SettledTrade("B200", 600, 3.5)], 3.68)
    assert p.usd_per_gpu_hour == pytest.approx(3.5)


def test_composite_is_comparable_across_skus():
    b = TcpiEngine("B200").daily_print([SettledTrade("B200", 600, 3.7)], 3.68)
    h = TcpiEngine("H200").daily_print([SettledTrade("H200", 600, 2.5)], 2.4)
    c = composite([b, h])
    assert min(b.usd_per_pflop_hour, h.usd_per_pflop_hour) < c < max(b.usd_per_pflop_hour, h.usd_per_pflop_hour)


def test_a_buyer_must_hold_the_notional_and_its_fee():
    """The pre-trade check has to agree with what the escrow locks, or orders fail on-chain."""
    from petahour.config import BUYER_FEE_BPS

    notional = 100 * 4_000_000
    assert PreTradeRisk().required_funds(True, 100, 4_000_000) == notional + notional * BUYER_FEE_BPS // 10_000
    assert BUYER_FEE_BPS == 125
