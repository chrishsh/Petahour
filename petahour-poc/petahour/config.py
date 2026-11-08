"""Shared constants. Figures marked [Report] come from the 2026-11-03 Petahour research report."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from web3 import Web3

ROOT = Path(__file__).resolve().parent.parent
REPORTS = ROOT / "reports"
DEPLOYMENTS = ROOT / "deployments"
ABI_DIR = ROOT / "out"

# Anvil's well-known development mnemonic. Local chain only: these keys are public.
DEV_MNEMONIC = "test test test test test test test test test test test junk"
LOCAL_RPC = "http://127.0.0.1:8545"

NETWORKS = {
    "local": {"chain_id": 31337, "rpc": LOCAL_RPC},
    "arbitrum-sepolia": {"chain_id": 421614, "rpc": "https://sepolia-rollup.arbitrum.io/rpc"},
    "base-sepolia": {"chain_id": 84532, "rpc": "https://sepolia.base.org"},
}


@dataclass(frozen=True)
class Sku:
    code: str
    label: str
    pflops_fp8: float  # dense FP8 peak per GPU
    tier: int  # liquidity tier of Table 3.5
    vast_names: tuple[str, ...]
    vendor_ticker: str | None  # Silicon Data ticker, where one is public
    report_spot_usd: float  # [Report] Table 3.2

    @property
    def id(self) -> bytes:
        return Web3.keccak(text=self.code)


SKUS = {
    # [Report] section 3.3.1 gives 4.5 PFLOPS for B200. The others are public vendor specs.
    "B200": Sku("B200-180GB-SXM", "NVIDIA B200 180GB", 4.5, 1, ("B200",), "SDB200RT", 6.44),
    "H200": Sku("H200-141GB-SXM", "NVIDIA H200 141GB", 1.979, 2, ("H200",), None, 4.28),
    "H100": Sku("H100-80GB-SXM", "NVIDIA H100 80GB", 1.979, 2, ("H100 SXM",), "SDH100RT", 2.95),
    "A100": Sku("A100-80GB-SXM", "NVIDIA A100 80GB", 0.624, 2, ("A100 SXM4",), "SDA100RT", 1.80),
    "MI300X": Sku("MI300X-192GB", "AMD MI300X 192GB", 2.615, 3, ("MI300X",), None, 2.60),
}

MLPERF_EFFICIENCY = 0.60  # [Report] 55-65% of theoretical peak, mid-point


def pflop_hours_per_gpu_hour(sku: Sku) -> float:
    """[Report] 1 PFLOP-Hour = published FP8 peak x MLPerf efficiency discount."""
    return sku.pflops_fp8 * MLPERF_EFFICIENCY


def tag(text: str) -> bytes:
    """Hashes a label into the bytes32 form used on-chain."""
    return Web3.keccak(text=text)


GRID_ZONES = {"north": tag("TPC-NORTH"), "central": tag("TPC-CENTRAL"), "south": tag("TPC-SOUTH")}
ANY_ZONE = b"\x00" * 32

# Delivery rules, mirroring what Deploy.s.sol sets on-chain.
SELLER_COLLATERAL_BPS = 2_000
PENALTY_BPS = 2_500
CHALLENGE_BOND = 100_000_000  # 100 tUSD

# Fees from Petahour_GTM_Financial_Model_v5.xlsx, Inputs sheet. The take rate is the combined buyer and
# seller rate on delivered value. It steps down each year through setParams; open trades keep
# the rate they opened at.
LAUNCH_YEAR = 2027
TAKE_RATE_BPS = {2027: 250, 2028: 225, 2029: 175, 2030: 150, 2031: 125}
PASSPORT_FEE_USD_PER_GPU_YEAR = 60
PASSPORT_DISCOUNT_BPS = {2027: 5_000, 2028: 0, 2029: 0, 2030: 0, 2031: 0}  # half-price launch offer

# Petahour Labs fees, from the same model. The licence is what Labs pays Petahour.
LABS_CURATOR_FEE_BPS = 1_000  # of interest
LABS_ORIGINATION_FEE_BPS = 50  # of new loans
LABS_LICENCE_BPS = 10  # of average loans a year
LABS_LOAN_RATE_BPS = 1_200  # what borrowers pay
LABS_SENIOR_YIELD_BPS = 800  # a year on senior capital, ahead of first-loss holders
LABS_FIRST_LOSS_BPS = 1_300  # of loans; senior capital funds the rest
LABS_CO_INVEST_BPS = 2_500  # Labs' own share of first-loss capital
LABS_ORACLE_VALUE_BPS = 8_400  # share of TCPI the oracle counts
LABS_LLTV_BPS = 6_250  # of oracle value, so the advance is 52.5% of TCPI

# Real Morpho allows only these LLTVs, and sets the liquidation incentive from the LLTV.
MORPHO_APPROVED_LLTV_BPS = (3_850, 6_250, 7_700, 8_600, 9_150, 9_450, 9_650, 9_800)


def morpho_incentive(lltv_bps: int) -> float:
    """Morpho's liquidation incentive factor: min(1.15, 1 / (0.3 x LLTV + 0.7))."""
    return min(1.15, 1 / (0.3 * lltv_bps / 10_000 + 0.7))


def first_loss_return(credit_loss_rate: float) -> float:
    """The model's return on first-loss capital, on a fully lent book of one dollar of loans.

    Interest pays the curator, then credit losses, then senior yield. First-loss holders keep the
    rest. The vault's waterfall does the same on-chain.
    """
    first_loss = LABS_FIRST_LOSS_BPS / 10_000
    interest = LABS_LOAN_RATE_BPS / 10_000
    curator = interest * LABS_CURATOR_FEE_BPS / 10_000
    senior_yield = (1 - first_loss) * LABS_SENIOR_YIELD_BPS / 10_000
    return (interest - curator - credit_loss_rate - senior_yield) / first_loss


def fee_split(year: int = LAUNCH_YEAR) -> tuple[int, int]:
    """Buyer and seller basis points. The model gives one combined rate, based on 1.25% per broker,
    so it is split evenly. The on-chain rate is a whole number, so an odd point falls on the buyer."""
    combined = TAKE_RATE_BPS[year]
    buyer = (combined + 1) // 2
    return buyer, combined - buyer


def fee_schedule() -> dict:
    return {
        str(year): {
            "combined_take_rate_pct": combined / 100,
            "buyer_bps": fee_split(year)[0],
            "seller_bps": fee_split(year)[1],
            "passport_usd_per_gpu_year": PASSPORT_FEE_USD_PER_GPU_YEAR * (10_000 - PASSPORT_DISCOUNT_BPS[year]) / 10_000,
        }
        for year, combined in TAKE_RATE_BPS.items()
    }


BUYER_FEE_BPS, SELLER_FEE_BPS = fee_split()

# Cost-model sunset [C3 section 1.2]: pre-announced and volume-triggered, on TRAILING 30-day
# settled volume, following the Dated Brent precedent. The threshold is PoC-scale so a demo can
# cross it; a real one would be set by the index committee.
TCPI_VOLUME_THRESHOLD_GPU_HOURS = 500
TCPI_SUNSET_WINDOW_DAYS = 30
# Outlier filtering [C6 Index Governance Committee; C5 on Ornn's winsorized mean]. Trades priced
# more than this far from the volume-weighted median are clamped to the band edge.
TCPI_WINSOR_BAND = 0.10
METHODOLOGY_VERSION = "TCPI-v0.2-PoC"

# CME GPU1 (H100) and GPU2 (B200) contract size [TW-SG evaluation]. CFTC review was still pending
# on 5 Nov 2026, so treat this as a filed spec, not a live contract. A TCPI future licensed to
# SGX would mirror this unit so that spreads and EFPs line up.
CME_CONTRACT_GPU_HOURS = 730
