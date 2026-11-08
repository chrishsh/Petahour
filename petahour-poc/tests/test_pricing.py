"""The cost model must reproduce the report's published numbers (Table 3.4, section 3.3.3)."""
import pytest

from petahour.pricing import CostInputs, build_up, fx_sensitivity, quote, three_year_case


def test_reproduces_table_3_4_line_by_line():
    s = build_up()
    assert s.amortization_ntd == pytest.approx(58.98, abs=0.01)
    assert s.power_ntd == pytest.approx(8.76, abs=0.01)
    assert s.subtotal_ntd == pytest.approx(78.74, abs=0.01)
    assert s.margin_ntd == pytest.approx(15.75, abs=0.01)
    assert s.pre_vat_ntd == pytest.approx(94.49, abs=0.01)
    assert s.vat_ntd == pytest.approx(4.72, abs=0.01)
    assert s.domestic_base_ntd == pytest.approx(99.21, abs=0.01)
    assert s.reference_ntd == pytest.approx(114.10, abs=0.02)
    assert s.reference_usd == pytest.approx(3.68, abs=0.005)


def test_three_year_case_matches_section_3_3_3():
    s = three_year_case()
    assert s.reference_usd == pytest.approx(4.60, abs=0.005)
    assert s.reference_ntd == pytest.approx(142.60, abs=0.05)


def test_reference_sits_inside_the_term_benchmark_range():
    assert 3.42 <= build_up().reference_usd <= 4.32


def test_weaker_ntd_raises_ntd_price_and_lowers_usd_price():
    r = fx_sensitivity(33.05)
    assert r["live_ntd"] > r["report_ntd"]
    assert r["live_usd"] < r["report_usd"]


def test_spreads_stay_inside_table_3_5_bands():
    for tier, (low, high) in {1: (0.02, 0.05), 2: (0.05, 0.08), 3: (0.08, 0.15)}.items():
        for liquidity in (0, 0.5, 1):
            bid, ask = quote(100, tier, liquidity)
            assert low - 1e-9 <= (ask - bid) / 100 <= high + 1e-9


def test_higher_utilization_lowers_the_floor():
    assert build_up(CostInputs(utilization=0.9)).reference_usd < build_up().reference_usd


def test_fees_match_the_financial_model():
    from petahour.config import PASSPORT_DISCOUNT_BPS, PASSPORT_FEE_USD_PER_GPU_YEAR, TAKE_RATE_BPS, fee_schedule, fee_split

    assert TAKE_RATE_BPS == {2027: 250, 2028: 225, 2029: 175, 2030: 150, 2031: 125}
    assert PASSPORT_FEE_USD_PER_GPU_YEAR == 60
    assert PASSPORT_DISCOUNT_BPS[2027] == 5_000 and PASSPORT_DISCOUNT_BPS[2028] == 0
    assert all(sum(fee_split(year)) == combined for year, combined in TAKE_RATE_BPS.items())
    assert fee_split(2027) == (125, 125)
    assert fee_split(2028) == (113, 112)  # an odd point falls on the buyer
    assert fee_schedule()["2027"]["passport_usd_per_gpu_year"] == 30
    assert fee_schedule()["2031"]["combined_take_rate_pct"] == 1.25


def test_labs_fees_match_the_financial_model():
    from petahour.config import LABS_CURATOR_FEE_BPS, LABS_LICENCE_BPS, LABS_ORIGINATION_FEE_BPS

    assert (LABS_CURATOR_FEE_BPS, LABS_ORIGINATION_FEE_BPS, LABS_LICENCE_BPS) == (1_000, 50, 10)


def test_lending_settings_are_ones_real_morpho_allows():
    from petahour.config import LABS_LLTV_BPS, LABS_ORACLE_VALUE_BPS, MORPHO_APPROVED_LLTV_BPS, morpho_incentive

    assert LABS_LLTV_BPS in MORPHO_APPROVED_LLTV_BPS
    assert LABS_ORACLE_VALUE_BPS * LABS_LLTV_BPS == 5_250 * 10_000  # the advance stays at 52.5%
    assert round(morpho_incentive(LABS_LLTV_BPS), 4) == 1.1268
    assert morpho_incentive(3_850) == 1.15  # capped


def test_first_loss_return_matches_the_financial_model():
    from petahour.config import first_loss_return

    assert round(first_loss_return(0.01) * 100, 1) == 21.8  # base
    assert round(first_loss_return(0.03) * 100, 1) == 6.5  # bear: losses x 3
    assert round(first_loss_return(0.005) * 100, 1) == 25.7  # bull: losses x 0.5
