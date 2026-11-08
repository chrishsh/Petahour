"""Six end-to-end scenarios. Each one asserts its outcome, so a demo run is also a test run."""
from __future__ import annotations

import json
import time

from rich.console import Console
from rich.table import Table

from . import tee, zk_bridge
from .chain import Rejected
from .clearing import write_reports
from .config import (ANY_ZONE, GRID_ZONES, LABS_CO_INVEST_BPS, LABS_CURATOR_FEE_BPS, LABS_FIRST_LOSS_BPS, LABS_LICENCE_BPS, LABS_LLTV_BPS, LABS_ORACLE_VALUE_BPS, LABS_ORIGINATION_FEE_BPS, LABS_SENIOR_YIELD_BPS, MORPHO_APPROVED_LLTV_BPS, morpho_incentive, LAUNCH_YEAR, PASSPORT_DISCOUNT_BPS, PASSPORT_FEE_USD_PER_GPU_YEAR, REPORTS, SKUS,
                     TAKE_RATE_BPS, TCPI_SUNSET_WINDOW_DAYS, TCPI_VOLUME_THRESHOLD_GPU_HOURS, tag)
from .marketplace import Marketplace, ComplianceReject, ORDER_FIELDS, ATTEST_FIELDS, SEAL_FIELDS
from .chain import quorum, sign_typed
from .gateway import decode, encode, simulate_flow
from .marketdata import MarketSnapshot, SiliconDataClient
from .matching import Order, run_day_ahead_auction
from .pricing import CostInputs, build_up, fx_sensitivity, pantera_reconciliation
from .risk import PreTradeRisk, margin_rate
from .tcpi import SettledTrade, TcpiEngine, basis_report, inputs_hash, winsorized_vwap

ONE_HOUR = 3_600
ONE_DAY = 86_400


def usd(atoms: int) -> str:
    return f"{atoms / 1e6:,.2f}"


class Demo:
    def __init__(self, ex: Marketplace, snapshot: MarketSnapshot, vendor: SiliconDataClient, console: Console | None = None):
        self.ex = ex
        self.snap = snapshot
        self.vendor = vendor
        self.out = console or Console()
        self.report: dict = {"scenarios": {}, "network": ex.chain.chain_id, "market_mode": snapshot.mode}
        self.unprinted: list[int] = []  # trades settled since the last print
        self.tcpi = TcpiEngine("B200")
        self.audit_trail: list[dict] = []
        self.trade_ids: list[int] = []
        self.host_of: dict[str, int] = {}
        self.listing_of: dict[str, int] = {}
        self.reference_usd = build_up(CostInputs(fx_ntd_per_usd=snapshot.fx_ntd_per_usd)).reference_usd
        self.tcpi_usd = self.reference_usd

    # ------------------------------------------------------------------ helpers

    def title(self, text: str) -> None:
        self.out.rule(f"[bold]{text}")

    def step(self, where: str, text: str) -> None:
        color = {"on-chain": "cyan", "off-chain": "yellow", "live": "green", "mock": "magenta"}.get(where, "white")
        self.out.print(f"  [{color}]\\[{where}][/] {text}")

    def check(self, condition: bool, label: str, bucket: dict) -> None:
        bucket.setdefault("checks", []).append({"check": label, "passed": bool(condition)})
        self.out.print(f"  [{'green' if condition else 'red'}]{'PASS' if condition else 'FAIL'}[/] {label}")
        if not condition:
            raise AssertionError(label)

    def expect_rejected(self, fn, expected: str, label: str, bucket: dict) -> None:
        """An attack must be refused, for the right reason."""
        try:
            fn()
        except Rejected as exc:
            self.check(exc.reason.startswith(expected), f"{label} -> {exc.reason}", bucket)
            return
        self.check(False, f"{label}: expected {expected}, but it went through", bucket)

    def print_tcpi(self):
        """Builds the day's print from what the chain says settled, then publishes it.

        Index inputs are read back from the chain, not taken from this process's memory, and the
        print commits to them. That is what makes the audit in verify_print possible.
        """
        rows = [self.ex.delivered_row(t) for t in self.unprinted if self.ex.trade(t)["statusName"] == "Settled"]
        tcpi = self.tcpi.daily_print(rows, self.reference_usd)
        commitment = inputs_hash(rows)
        self.ex.publish_tcpi(tcpi.usd_per_gpu_hour, int(tcpi.volume_gpu_hours), inputs=commitment)
        self.audit_trail.append({"round": len(self.audit_trail) + 1, "basis": tcpi.basis, "print_usd": tcpi.usd_per_gpu_hour,
                                 "inputs_hash": "0x" + commitment.hex(), "trade_ids": sorted(t.trade_id for t in rows)})
        self.unprinted = []
        self.tcpi_usd = tcpi.usd_per_gpu_hour
        return tcpi

    def verify_print(self, entry: dict) -> tuple[float, bool]:
        """An independent auditor's check: rebuild a print from on-chain trades alone."""
        rows = [self.ex.delivered_row(t) for t in entry["trade_ids"]]
        round_data = self.ex.c["TCPIOracle"].functions.roundAt(tag("TCPI-B200"), entry["round"] - 1).call()
        anchored = "0x" + bytes(round_data[5]).hex()
        return round(winsorized_vwap(rows), 6), inputs_hash(rows).hex() == anchored[2:]

    def new_host(self, role: str, name: str, zone: str = "north", gpus: int = 8) -> None:
        host = tee.SimulatedHost(name, gpu_count=gpus)
        pid = self.ex.register_host(role, host, zone=zone)
        self.ex.attest(pid)
        self.host_of[role] = pid
        self.listing_of[role] = self.ex.list_capacity(role, pid)

    def bilateral_trade(self, buyer: str, seller: str, qty: int, price: float) -> int:
        start = self.ex.next_delivery_start()
        price_e6 = int(price * 1e6)
        pid = self.host_of[seller]
        bid = self.ex.sign_order(buyer, Order(buyer, True, "B200", qty, price_e6, start, 24))
        ask = self.ex.sign_order(
            seller, Order(seller, False, "B200", qty, price_e6, start, 24, passport_id=pid, listing_id=self.listing_of[seller], host_sla_bps=9990)
        )
        fills, _ = run_day_ahead_auction([bid, ask])
        tid = self.ex.settle_fill(fills[0])
        self.trade_ids.append(tid)
        return tid

    # ---------------------------------------------------------------- bootstrap

    def bootstrap(self) -> None:
        self.title("Setup: market data, members and the default fund")
        s = self.snap
        self.step("live" if s.mode == "live" else "mock", f"USD/TWD {s.fx_ntd_per_usd} from {s.fx_source}")
        for key, q in s.quotes.items():
            self.step("live" if "live" in q.source else "mock",
                      f"{key}: median ask US${q.median_usd}/GPU-hr over {q.offers} offers ({q.source})")
        self.step("mock", f"Silicon Data index (assumed protocol): {s.vendor_index}")
        stack = build_up(CostInputs(fx_ntd_per_usd=s.fx_ntd_per_usd))
        fx = fx_sensitivity(s.fx_ntd_per_usd)
        self.step("off-chain", f"Cost-model reference: NT${stack.reference_ntd:.2f} = US${stack.reference_usd:.2f}/GPU-hr at live FX "
                               f"(report: NT${fx['report_ntd']:.2f} at {fx['report_fx']}, a {fx['ntd_change_pct']:+.2f}% NT$ move)")
        history = [p["value"] for p in self.vendor.history("SDB200RT", 30)]
        rate = margin_rate(history)
        self.step("off-chain", f"SPAN-style margin on 30 days of the mock index: {rate:.1%} of notional (on-chain rate is 20%)")
        pantera = pantera_reconciliation()
        self.step("off-chain", f"Pantera cross-check: US${pantera['pantera_at_petahour_utilization_usd']:.2f}/hr at Petahour's utilization "
                               f"vs US${pantera['petahour_amortization_usd']:.2f} here; direct floor gap US${pantera['direct_gap_usd']:.2f}")
        self.report["market"] = {**s.to_json(), "cost_model": stack.as_dict(), "fx_sensitivity": fx, "span_margin_rate": round(rate, 4),
                                 "pantera_reconciliation": pantera}

        members = {
            "seller_a": "Taoyuan ODM Rack Capacity (sim)", "seller_b": "Hsinchu University HPC (sim)",
            "seller_c": "Tainan Colocation (sim)", "seller_d": "Kaohsiung GPU Host (sim)", "seller_e": "Taichung GPU Host (sim)",
            "buyer_alpha": "Alpha AI Startup (sim)", "buyer_beta": "Beta Quant Fund (sim)", "buyer_gamma": "Gamma Research Lab (sim)",
            "watcher": "Independent Watchtower (sim)",
        }
        for role, name in members.items():
            self.ex.onboard(role, name)
        self.step("on-chain", f"{len(members)} members passed screening and were enrolled (wallet flags only, no personal data)")
        for role in ("seller_a", "seller_b", "seller_c", "seller_d", "seller_e", "watcher"):
            self.ex.fund(role, 50_000)
        for role in ("buyer_alpha", "buyer_beta", "buyer_gamma"):
            self.ex.fund(role, 100_000)
        self.ex.seed_default_fund(25_000)
        self.step("on-chain", "Members funded in simulated tUSD; default fund seeded with 25,000 tUSD")

    # ------------------------------------------------------- S1: full happy path

    def s1_happy_path(self) -> None:
        r: dict = {}
        self.title("S1  Happy path: passport to T+1 settlement to TCPI")
        hosts = [("seller_a", "tw-taoyuan-rack-01", "north"), ("seller_b", "tw-hsinchu-hpc-07", "north"), ("seller_c", "tw-tainan-colo-12", "south")]
        for role, name, zone in hosts:
            self.new_host(role, name, zone)
        self.step("mock", "NRAS issued ES384 EAT tokens; each federation node verified them off-chain")
        self.step("on-chain", "3 Compute Passports minted by federation quorum; attestations anchored; capacity listed")
        gpus = 3 * 8
        per_gpu = PASSPORT_FEE_USD_PER_GPU_YEAR * 1_000_000 * (10_000 - PASSPORT_DISCOUNT_BPS[LAUNCH_YEAR]) // 10_000
        collected = self.ex.c["MockUSD"].functions.balanceOf(self.ex.a["treasury"].address).call()
        self.check(collected == gpus * per_gpu,
                   f"Passport fee paid by sellers: {usd(collected)} tUSD for {gpus} GPUs at the {LAUNCH_YEAR} launch price of {usd(per_gpu)} per GPU", r)

        mid = self.reference_usd
        start = self.ex.next_delivery_start()
        risk = PreTradeRisk()
        ref_e6 = int(mid * 1e6)
        orders = []
        for new in simulate_flow(mid, ["buyer_alpha", "buyer_beta", "buyer_gamma"], ["seller_a", "seller_b", "seller_c"], seed=11):
            parsed = decode(encode(new))  # through the FIX-style gateway
            limit = int(parsed.price * 1e6)
            risk.check(parsed.is_buy, parsed.qty, limit, self.ex.free(parsed.client), ref_e6)
            o = Order(parsed.client, parsed.is_buy, "B200", parsed.qty, limit, start, parsed.delivery_hours, min_sla_bps=parsed.min_sla_bps)
            if not parsed.is_buy:
                o.passport_id = self.host_of[parsed.client]
                o.listing_id = self.listing_of[parsed.client]
                o.host_sla_bps = 9990
                o.host_zone = GRID_ZONES[dict((h[0], h[2]) for h in hosts)[parsed.client]]
            orders.append(self.ex.sign_order(parsed.client, o))
        self.step("off-chain", f"{len(orders)} simulated client orders passed the FIX gateway and pre-trade risk, each EIP-712 signed by its client")

        started = time.perf_counter()
        fills, price = run_day_ahead_auction(orders)
        micros = (time.perf_counter() - started) * 1e6
        self.step("off-chain", f"Day-ahead auction cleared {sum(f.qty for f in fills)} GPU-hours at US${price / 1e6:.4f} in {micros:.0f} microseconds")
        trade_ids = [self.ex.settle_fill(f) for f in fills]
        self.trade_ids += trade_ids
        self.step("on-chain", f"{len(trade_ids)} trades settled into DvP escrow; both signatures and all limits re-checked by the contract")

        locked_before = self.ex.c["DvPEscrow"].functions.totalLocked().call()
        packages = {}
        for i, tid in enumerate(trade_ids):
            t = self.ex.trade(tid)
            seller = next(role for role, pid in self.host_of.items() if pid == t["passportId"])
            pkg = self.ex.produce_telemetry(tid, "healthy", seed=100 + i)
            self.ex.claim(seller, pkg)
            packages[tid] = pkg
        self.step("on-chain", "T+0: hosts sealed telemetry; sellers claimed delivery (Merkle root and Poseidon commitment stored)")

        for tid, pkg in packages.items():
            self.check(self.ex.watchtower(pkg).honest, f"opML watchtower re-executed trade {tid}: claim matches telemetry", r)

        treasury_before = self.ex.free("treasury")
        self.ex.chain.advance(ONE_DAY)
        for tid in trade_ids:
            self.ex.finalize(tid)
        self.step("on-chain", "T+1: dispute window closed unchallenged; escrow released")

        settled = {t: self.ex.trade(t) for t in trade_ids}
        uptime = {t: packages[t].features[0] for t in trade_ids}
        delivered = sum(settled[t]["notional"] * uptime[t] // 10_000 for t in trade_ids)
        buyer_fee = sum(settled[t]["buyerFee"] * uptime[t] // 10_000 for t in trade_ids)
        seller_fee = sum(settled[t]["sellerFee"] * uptime[t] // 10_000 for t in trade_ids)
        fee = self.ex.free("treasury") - treasury_before
        self.unprinted += trade_ids
        self.check(all(self.ex.trade(t)["statusName"] == "Settled" for t in trade_ids), "all trades Settled", r)
        self.check(self.ex.c["DvPEscrow"].functions.totalLocked().call() == 0 and locked_before > 0, "escrow locks fully released", r)
        self.check(fee == buyer_fee + seller_fee and round(fee * 10_000 / delivered) == TAKE_RATE_BPS[LAUNCH_YEAR],
                   f"marketplace fee from both sides: {usd(buyer_fee)} buyer + {usd(seller_fee)} seller = {fee / delivered:.2%} of {usd(delivered)} tUSD delivered", r)

        tcpi = self.print_tcpi()
        latest = self.ex.c["TCPIFeed"].functions.latestRoundData().call()
        self.step("on-chain", f"TCPI-B200 = US${latest[1] / 1e8:.4f}/GPU-hr ({tcpi.basis}, {tcpi.volume_gpu_hours:.0f} GPU-hours, "
                              f"US${tcpi.usd_per_pflop_hour:.4f}/PFLOP-hr), published by federation quorum")
        self.check(latest[1] == tcpi.answer_e8, "Chainlink-shaped feed returns the published print", r)
        recomputed, hash_ok = self.verify_print(self.audit_trail[-1])
        self.check(hash_ok, "audit: the on-chain inputs hash matches the settled trades", r)
        if tcpi.basis == "VWAP":
            self.check(abs(recomputed - tcpi.usd_per_gpu_hour) < 1e-6, f"audit: print recomputed from on-chain trades alone: US${recomputed:.4f}", r)
        else:
            self.check(abs(self.reference_usd - tcpi.usd_per_gpu_hour) < 1e-6,
                       f"audit: below the volume threshold, the print stays on the cost-model reference: US${tcpi.usd_per_gpu_hour:.4f}", r)
        basis = basis_report(tcpi.usd_per_gpu_hour, self.snap.vendor_index.get("SDB200RT"))
        self.report["tcpi_basis"] = basis
        if "basis_usd" in basis:
            self.step("mock", f"Published basis vs vendor index: US${basis['basis_usd']:+.2f}/GPU-hr, or US${basis['basis_per_contract_usd']:+,.0f} "
                              f"per {basis['contract_gpu_hours']} GPU-hour contract (reporting only, never an input)")
        r.update(clearing_price_usd=price / 1e6, trades=len(trade_ids), gpu_hours=sum(f.qty for f in fills), tcpi=tcpi.usd_per_gpu_hour,
                 tcpi_basis=tcpi.basis, auction_microseconds=round(micros))
        self.report["scenarios"]["S1"] = r

    # --------------------------------------------------- S2: seller fraud, slashed

    def s2_seller_fraud(self) -> None:
        r: dict = {}
        self.title("S2  Seller over-claims: challenged, cannot prove, slashed")
        self.new_host("seller_d", "tw-kaohsiung-dc-03", "south")
        buyer0, seller0 = self.ex.free("buyer_alpha"), self.ex.free("seller_d")
        fund0 = self.ex.c["DefaultFund"].functions.mutualPool().call()

        tid = self.bilateral_trade("buyer_alpha", "seller_d", 192, self.reference_usd)
        t = self.ex.trade(tid)
        pkg = self.ex.produce_telemetry(tid, "degraded", seed=7)
        self.step("off-chain", f"Host measured {pkg.features[0] / 100:.2f}% uptime with thermal throttling and ECC errors")
        self.ex.claim("seller_d", pkg, claimed_uptime_bps=10_000)
        self.step("on-chain", "Seller claimed 100.00% uptime. The telemetry seal is valid: the host told the truth, the seller did not")

        verdict = self.ex.watchtower(pkg)
        self.check(not verdict.honest, "opML watchtower detected the mismatch: " + "; ".join(verdict.reasons), r)
        self.ex.challenge("buyer_alpha", tid)
        self.step("on-chain", "Buyer posted a 100 tUSD bond and challenged inside the T+1 window")

        proved = True
        try:
            self.ex.prove_and_respond("seller_d", pkg)
        except zk_bridge.ProofUnavailable:
            proved = False
        self.check(not proved, "zkML prover could not build a proof: no valid witness exists for a false claim", r)

        self.ex.chain.advance(6 * ONE_HOUR + 1)
        receipt = self.ex.resolve_timeout(tid)
        ev = self.ex.chain.events("DvPEscrow", "TradeDefaulted", receipt)[0]["args"]
        penalty = t["notional"] * 2_500 // 10_000
        self.step("on-chain", f"Waterfall: buyer refunded {usd(ev['buyerRefund'])}; {usd(ev['fromCollateral'])} from collateral; "
                              f"{usd(ev['fromDefaultFund'])} from default fund; challenger reward {usd(ev['challengerReward'])}")
        self.check(self.ex.trade(tid)["statusName"] == "Defaulted", "trade Defaulted", r)
        self.check(self.ex.free("buyer_alpha") == buyer0 + penalty + ev["challengerReward"], "buyer whole, plus penalty and challenger reward", r)
        self.check(self.ex.free("seller_d") == seller0 - t["sellerCollateral"], "seller lost its full collateral", r)
        self.check(self.ex.c["DefaultFund"].functions.mutualPool().call() == fund0 - ev["fromDefaultFund"], "default fund paid the shortfall", r)
        self.check(not self.ex.c["ProofOfDeliveryOracle"].functions.isAttested(self.host_of["seller_d"]).call(), "host suspended: it can no longer sell", r)
        r.update(measured_uptime_pct=pkg.features[0] / 100, claimed_uptime_pct=100.0, default_fund_paid_usd=ev["fromDefaultFund"] / 1e6)
        self.report["scenarios"]["S2"] = r

    # ------------------------------------------- S3: false challenge, beaten by zkML

    def s3_false_challenge(self) -> None:
        r: dict = {}
        self.title("S3  False challenge: seller proves delivery with zkML, telemetry stays private")
        self.new_host("seller_e", "tw-taichung-dc-09", "central")
        beta0, seller0 = self.ex.free("buyer_beta"), self.ex.free("seller_e")
        tid = self.bilateral_trade("buyer_beta", "seller_e", 192, self.reference_usd)
        t = self.ex.trade(tid)
        pkg = self.ex.produce_telemetry(tid, "healthy", seed=21)
        self.ex.claim("seller_e", pkg)
        self.ex.challenge("buyer_beta", tid)
        self.step("on-chain", "Buyer challenged an honest delivery, hoping for a free ride")

        result = self.ex.prove_and_respond("seller_e", pkg)
        gas = result["receipt"]["gasUsed"]
        self.step("off-chain", f"Groth16 proof generated in {result['prover_ms']} ms (2,259 constraints)")
        self.step("on-chain", f"Verified on-chain for {gas:,} gas, which also settled the trade")
        public = result["public_signals"]
        self.step("on-chain", f"Public inputs were only: commitment, model hash, threshold, claimed uptime {public[3]} bps, trade id {public[4]}")
        self.check(all(str(f) not in public[:3] for f in pkg.features), "no raw telemetry value appears in the public inputs", r)
        self.check(self.ex.trade(tid)["statusName"] == "Settled", "trade Settled without any human ruling", r)
        fee_due = t["buyerFee"] * pkg.features[0] // 10_000
        seller_fee_due = t["sellerFee"] * pkg.features[0] // 10_000
        paid = t["notional"] * pkg.features[0] // 10_000
        self.check(self.ex.free("seller_e") == seller0 + paid - seller_fee_due + 100_000_000, "seller paid, less its fee, and took the challenger's 100 tUSD bond", r)
        self.check(self.ex.free("buyer_beta") == beta0 - paid - fee_due - 100_000_000, "false challenger lost the bond", r)
        self.unprinted.append(tid)
        r.update(prover_ms=result["prover_ms"], verify_and_settle_gas=gas)

        self.step("off-chain", "Now an honest partial delivery: 3 real outage hours, reported truthfully")
        tid2 = self.bilateral_trade("buyer_gamma", "seller_e", 192, self.reference_usd)
        t2 = self.ex.trade(tid2)
        pkg2 = self.ex.produce_telemetry(tid2, "partial", seed=22)
        seller1 = self.ex.free("seller_e")
        self.ex.claim("seller_e", pkg2)
        self.check(self.ex.watchtower(pkg2).honest, f"watchtower accepts an honest claim of {pkg2.features[0] / 100:.2f}% uptime", r)
        self.ex.challenge("buyer_gamma", tid2)
        result2 = self.ex.prove_and_respond("seller_e", pkg2)
        share = pkg2.features[0]
        paid2 = t2["notional"] * share // 10_000
        credit = (t2["notional"] - paid2) * 5_000 // 10_000
        seller_fee2 = t2["sellerFee"] * share // 10_000
        self.step("on-chain", f"Paid pro rata {usd(paid2)} of {usd(t2['notional'])}, less a {usd(seller_fee2)} fee and a {usd(credit)} SLA credit to the buyer")
        self.check(self.ex.trade(tid2)["statusName"] == "Settled", "an honest seller is never slashed for reporting an outage", r)
        self.check(self.ex.free("seller_e") == seller1 + paid2 - seller_fee2 + t2["sellerCollateral"] - credit + 100_000_000,
                   "seller receives pro-rata payment and its collateral, less its fee and the SLA credit, plus the bond", r)
        self.unprinted.append(tid2)
        self.report["scenarios"]["S3"] = r

    # ------------------------------------------------------- S4: compliance gates

    def s4_compliance(self) -> None:
        r: dict = {}
        self.title("S4  Compliance: denied party, restricted country, freeze")
        for name, country, role in [("Shadow Compute Trading Ltd", "TW", "denied"), ("Ordinary Trading Co (sim)", "KP", "denied")]:
            try:
                self.ex.onboard(role, name, country)
                self.check(False, f"{name} should have been refused", r)
            except ComplianceReject as exc:
                self.check(True, f"screening refused onboarding: {exc}", r)
        wallet = self.ex.a["denied"].address
        self.check(not self.ex.c["MemberRegistry"].functions.isEligible(wallet).call(), "refused wallet was never enrolled", r)
        self.expect_rejected(lambda: self.ex.fund("denied", 100), "NotEligible", "unscreened wallet tries to deposit", r)

        self.ex.chain.send(self.ex.c["MemberRegistry"].functions.freeze(self.ex.a["buyer_gamma"].address, tag("list-update")),
                           self.ex.a["petahour_admin"], "freeze member")
        self.step("on-chain", "Compliance froze a member after a list update, with immediate effect")
        pid = self.host_of["seller_b"]
        start = self.ex.next_delivery_start()
        bid = self.ex.sign_order("buyer_gamma", Order("buyer_gamma", True, "B200", 24, 4_000_000, start, 24))
        ask = self.ex.sign_order("seller_b", Order("seller_b", False, "B200", 24, 4_000_000, start, 24, passport_id=pid,
                                                   listing_id=self.listing_of["seller_b"], host_sla_bps=9990))
        fills, _ = run_day_ahead_auction([bid, ask])
        self.expect_rejected(lambda: self.ex.settle_fill(fills[0]), "NotEligible", "frozen member's order reaches settlement", r)
        self.expect_rejected(
            lambda: self.ex.chain.send(self.ex.c["DvPEscrow"].functions.withdraw(1), self.ex.a["buyer_gamma"], "withdraw"),
            "NotEligible", "frozen member tries to withdraw", r)
        self.ex.chain.send(self.ex.c["MemberRegistry"].functions.unfreeze(self.ex.a["buyer_gamma"].address), self.ex.a["petahour_admin"], "unfreeze")
        self.report["scenarios"]["S4"] = r

    # ---------------------------------------------------------- S5: attack gallery

    def s5_attacks(self) -> None:
        r: dict = {}
        self.title("S5  Attacks: every one must be refused, for the right reason")
        ex, role = self.ex, "seller_c"
        pid, listing = self.host_of[role], self.listing_of[role]
        start = ex.next_delivery_start()

        def pair(qty=24, price=3_700_000):
            b = ex.sign_order("buyer_beta", Order("buyer_beta", True, "B200", qty, price, start, 24))
            s = ex.sign_order(role, Order(role, False, "B200", qty, price, start, 24, passport_id=pid, listing_id=listing, host_sla_bps=9990))
            return b, s

        escrow = ex.c["DvPEscrow"].functions
        b, s = pair()
        self.expect_rejected(
            lambda: ex.chain.send(escrow.matchOrders(ex._tuple(b.onchain), b.signature, ex._tuple(s.onchain), s.signature, 24, 3_700_001, listing), ex.a["matcher"]),
            "PriceOutsideLimits", "compromised matcher overcharges the buyer by 0.0001%", r)

        forged = sign_typed(ex.a["seller_c"], ex.chain.domain("Petahour DvP Escrow", "DvPEscrow"), "Order", ORDER_FIELDS, b.onchain)
        self.expect_rejected(
            lambda: ex.chain.send(escrow.matchOrders(ex._tuple(b.onchain), forged, ex._tuple(s.onchain), s.signature, 24, 3_700_000, listing), ex.a["matcher"]),
            "BadSignature", "matcher forges the buyer's signature", r)

        b1, s1 = pair(qty=192)
        tid = ex.chain.send(escrow.matchOrders(ex._tuple(b1.onchain), b1.signature, ex._tuple(s1.onchain), s1.signature, 192, 3_700_000, listing), ex.a["matcher"], "match orders")
        b2, s2 = pair(qty=24)
        self.expect_rejected(
            lambda: ex.chain.send(escrow.matchOrders(ex._tuple(b2.onchain), b2.signature, ex._tuple(s2.onchain), s2.signature, 24, 3_700_000, listing), ex.a["matcher"]),
            "Oversold", "seller sells GPU-hours it already sold", r)

        open_id = ex.chain.events("DvPEscrow", "TradeOpened", tid)[0]["args"]["tradeId"]
        self.trade_ids.append(open_id)
        t = ex.trade(open_id)
        ex.chain.advance(t["end"] - ex.chain.now())
        pkg = ex.produce_telemetry(open_id, "healthy", seed=33)
        domain = ex.chain.domain("Petahour Proof of Delivery", "ProofOfDeliveryOracle")
        fake_seal = sign_typed(ex.a[role], domain, "TelemetrySeal", SEAL_FIELDS,
                               {"tradeId": open_id, "passportId": pid, "telemetryRoot": pkg.root, "featureCommitment": pkg.commitment})
        self.expect_rejected(
            lambda: ex.chain.send(escrow.claimDelivery(open_id, 10_000, pkg.root, pkg.commitment, fake_seal), ex.a[role]),
            "InvalidSeal", "seller forges telemetry without the sealed TEE key", r)
        ex.claim(role, pkg)
        ex.chain.advance(ONE_DAY)
        ex.finalize(open_id)
        self.unprinted.append(open_id)

        host = tee.SimulatedHost("tw-rogue-01", compromised=True)
        bundle, nonce, random_part = tee.request_attestation(host, ex.mock_url)
        try:
            tee.verify_eat(bundle, nonce, random_part, host.tee_address, ex.mock_url)
            self.check(False, "compromised host passed attestation", r)
        except tee.AttestationError as exc:
            self.check(True, f"host with tampered firmware refused by federation: {exc}", r)

        valid_until = ex.chain.now() + ONE_DAY
        message = {"passportId": pid, "measurementHash": tag("rim"), "eatHash": tag("eat"), "nonce": tag("n"), "validUntil": valid_until}
        lone = quorum(ex.federation[:1], domain, "Attestation", ATTEST_FIELDS, message)
        self.expect_rejected(
            lambda: ex.chain.send(ex.c["ProofOfDeliveryOracle"].functions.submitAttestation(pid, tag("rim"), tag("eat"), tag("n"), valid_until, lone), ex.a["relay"]),
            "QuorumNotMet", "one rogue federation node acts alone", r)
        self.expect_rejected(lambda: ex.publish_tcpi(self.tcpi_usd * 3, 1000), "DeviationTooLarge", "TCPI pushed 3x in one print", r)
        self.report["scenarios"]["S5"] = r

    # --------------------------------------------------- S6: Petahour Labs under stress

    def s6_labs(self) -> None:
        r: dict = {}
        self.title("S6  Petahour Labs: receipts, lending and a TCPI crash")
        ex = self.ex
        c = ex.c
        admin = ex.a["labs_admin"]
        self.step("on-chain", "Petahour Labs is a separate deployer with its own allow-list; it only reads the onshore venue's contracts")
        self.check(c["GPUWarehouseReceipt"].functions.hasRole(b"\x00" * 32, admin.address).call()
                   and not c["DvPEscrow"].functions.hasRole(b"\x00" * 32, admin.address).call(),
                   "Labs admin controls Labs contracts and holds no role on Petahour core", r)

        # A fresh print, so the feed is not stale. The defaulted S2 trade is excluded: no delivery.
        tcpi = self.print_tcpi()
        self.step("on-chain", f"TCPI-B200 now US${self.tcpi_usd:.4f} ({tcpi.basis}, {tcpi.volume_gpu_hours:.0f} GPU-hours settled since "
                              f"the last print; trailing {TCPI_SUNSET_WINDOW_DAYS}-day volume {self.tcpi.trailing_volume:.0f} vs a "
                              f"{TCPI_VOLUME_THRESHOLD_GPU_HOURS} threshold)")
        recomputed, hash_ok = self.verify_print(self.audit_trail[-1])
        self.check(hash_ok and abs(recomputed - self.tcpi_usd) < 1e-6, f"audit: print recomputed from on-chain trades alone: US${recomputed:.4f}", r)

        try:
            ex.labs_onboard("denied", "TW", investor_class="retail")
            self.check(False, "retail must be refused by Petahour Labs", r)
        except ComplianceReject as exc:
            self.check(True, f"Labs onboarding policy refuses retail: {exc}", r)
        flag = ex.labs_onboard("seller_a", "TW")
        self.step("off-chain", f"Taiwan supplier onboarded with a flag: {flag}")
        self.check(flag.startswith("LEGAL-REVIEW"), "Taiwan users are flagged for a Virtual Asset Service Act opinion", r)
        for role in ("lender", "junior", "liquidator"):
            ex.labs_onboard(role, "CH")
        ex.labs_onboard("seller_c", "TW")
        borrower = ex.a["seller_a"]
        pid = self.host_of["seller_a"]
        expiry = ex.chain.now() + 20 * ONE_DAY
        receipt_tuple = (pid, SKUS["B200"].id, 1_000, expiry, tag("bailment-agreement-001"))
        rec = ex.chain.send(c["GPUWarehouseReceipt"].functions.mintReceipt(borrower.address, receipt_tuple), admin, "mint warehouse receipt")
        rid = ex.chain.events("GPUWarehouseReceipt", "ReceiptMinted", rec)[0]["args"]["id"]
        self.step("on-chain", f"Receipt #{rid}: 1,000 GPU-hours against passport #{pid}, under a bailment hash")

        self.expect_rejected(
            lambda: ex.chain.send(c["GPUWarehouseReceipt"].functions.transferFrom(borrower.address, ex.a["denied"].address, rid), borrower),
            "NotEligible", "receipt transfer to a wallet outside the allow-list", r)

        ex.chain.send(c["GPUWarehouseReceipt"].functions.approve(c["GPUReceiptWrapper"].address, rid), borrower, "approve wrapper")
        ex.chain.send(c["GPUReceiptWrapper"].functions.wrap(rid), borrower, "wrap receipt")
        amount = c["GPUReceiptWrapper"].functions.balanceOf(borrower.address).call()
        market = c["IsolatedLendingMarket"]
        ex.chain.send(c["GPUReceiptWrapper"].functions.approve(market.address, amount), borrower, "approve market")
        ex.chain.send(market.functions.supplyCollateral(amount), borrower, "post collateral")
        self.step("on-chain", "Receipt wrapped to restricted ERC-20 (Morpho Blue accepts ERC-20 collateral only) and posted")

        senior, first_loss = 20_000_000_000, 3_000_000_000
        labs_stake = first_loss * LABS_CO_INVEST_BPS // 10_000
        vault, tranche, usd_c = c["ComputeCreditVault"], c["FirstLossTranche"], c["MockUSD"]
        labs_treasury = c["LabsTreasury"]
        for who, target, amount_usd in ((ex.a["lender"], vault, senior), (ex.a["junior"], tranche, first_loss - labs_stake)):
            ex.chain.send(usd_c.functions.mint(who.address, amount_usd), who, "mint tUSD")
            ex.chain.send(usd_c.functions.approve(target.address, amount_usd), who, "approve vault")
            ex.chain.send(target.functions.deposit(amount_usd, who.address), who, "vault deposit")
        ex.chain.send(usd_c.functions.mint(labs_treasury.address, labs_stake), admin, "fund Labs from its own raise")
        ex.chain.send(labs_treasury.functions.investFirstLoss(labs_stake), admin, "Labs co-invests in first-loss")
        ex.chain.send(vault.functions.allocate(senior + first_loss), admin, "allocate to market")
        self.check(usd_c.functions.balanceOf(tranche.address).call() == 0 and market.functions.totalSupplyAssets().call() == senior + first_loss,
                   f"senior and first-loss money both lent: {usd(senior)} and {usd(first_loss)} tUSD in one pool, {LABS_CO_INVEST_BPS / 100:.0f}% of first-loss from Labs", r)

        limit = market.functions.maxBorrow(borrower.address).call()
        borrow = limit * 98 // 100
        ex.chain.send(market.functions.borrow(borrow), borrower, "borrow")
        self.step("on-chain", f"Borrowed {usd(borrow)} tUSD (limit {usd(limit)}): 1,000 GPU-hours x TCPI x {LABS_ORACLE_VALUE_BPS / 100:.0f}% oracle value x {LABS_LLTV_BPS / 100:.1f}% LLTV")
        lltv_bps = market.functions.lltv().call() * 10_000 // 10**18
        oracle_bps = c["TCPIPriceAdapter"].functions.haircutBps().call()
        incentive = market.functions.liquidationIncentive().call() / 1e18
        self.check(lltv_bps in MORPHO_APPROVED_LLTV_BPS and abs(incentive - morpho_incentive(lltv_bps)) < 1e-9 and oracle_bps * lltv_bps == 5_250 * 10_000,
                   f"settings real Morpho could run: {lltv_bps / 100:.1f}% is an approved LLTV, the {incentive - 1:.2%} incentive follows its formula, and the advance is 52.5%", r)
        origination = borrow * LABS_ORIGINATION_FEE_BPS // 10_000
        self.check(usd_c.functions.balanceOf(labs_treasury.address).call() == origination,
                   f"origination fee: {usd(origination)} tUSD to Labs, {LABS_ORIGINATION_FEE_BPS / 100:.2f}% of the loan, out of what the borrower drew", r)

        # A second borrower fills the book for a day. First-loss capital only earns once enough of
        # the pool is lent to pay the seniors' yield, as it is in the financial model.
        second = ex.a["seller_c"]
        rec = ex.chain.send(c["GPUWarehouseReceipt"].functions.mintReceipt(
            second.address, (self.host_of["seller_c"], SKUS["B200"].id, 10_000, ex.chain.now() + 60 * ONE_DAY, tag("bailment-agreement-002"))),
            admin, "mint warehouse receipt")
        rid2 = ex.chain.events("GPUWarehouseReceipt", "ReceiptMinted", rec)[0]["args"]["id"]
        ex.chain.send(c["GPUWarehouseReceipt"].functions.approve(c["GPUReceiptWrapper"].address, rid2), second, "approve wrapper")
        ex.chain.send(c["GPUReceiptWrapper"].functions.wrap(rid2), second, "wrap receipt")
        amount2 = c["GPUReceiptWrapper"].functions.balanceOf(second.address).call()
        ex.chain.send(c["GPUReceiptWrapper"].functions.approve(market.address, amount2), second, "approve market")
        ex.chain.send(market.functions.supplyCollateral(amount2), second, "post collateral")
        room = senior + first_loss - borrow
        borrow2 = min(market.functions.maxBorrow(second.address).call() * 98 // 100, room * 98 // 100)
        ex.chain.send(market.functions.borrow(borrow2), second, "borrow")
        lent = borrow + borrow2
        self.step("on-chain", f"Second borrower draws {usd(borrow2)} tUSD, so {lent / (senior + first_loss):.0%} of the pool is lent")

        ex.chain.advance(ONE_DAY)  # a day of interest on a nearly full book
        ex.chain.send(vault.functions.settle(), ex.a["relay"], "settle the waterfall")
        pool = vault.functions.waterfall().call()[0]
        interest = pool - senior - first_loss
        curator = vault.functions.convertToAssets(vault.functions.balanceOf(labs_treasury.address).call()).call()
        self.check(abs(curator - interest * LABS_CURATOR_FEE_BPS // 10_000) <= interest // 1_000 + 2,
                   f"curator fee: {curator / 1e6:.4f} tUSD to Labs, {LABS_CURATOR_FEE_BPS / 100:.0f}% of {interest / 1e6:.4f} tUSD of interest", r)

        lender_shares = vault.functions.balanceOf(ex.a["lender"].address).call()
        senior_earned = vault.functions.convertToAssets(lender_shares).call() - senior
        one_day_yield = senior * LABS_SENIOR_YIELD_BPS // 10_000 // 365
        self.check(abs(senior_earned - one_day_yield) <= one_day_yield // 100 + 2,
                   f"senior yield: {senior_earned / 1e6:.4f} tUSD, stopped at {LABS_SENIOR_YIELD_BPS / 100:.0f}% a year", r)

        earned = tranche.functions.totalAssets().call() - first_loss
        left = interest - curator - senior_earned
        yearly = earned * 365 / first_loss
        self.check(earned > 0 and abs(earned - left) <= 3,
                   f"first-loss earned {earned / 1e6:.4f} tUSD, all that was left: {yearly:.1%} a year on its capital, before any losses", r)
        labs_shares = tranche.functions.balanceOf(labs_treasury.address).call()
        labs_earned = tranche.functions.convertToAssets(labs_shares).call() - labs_stake
        self.check(abs(labs_earned - earned * LABS_CO_INVEST_BPS // 10_000) <= 2,
                   f"Labs' co-investment earned {labs_earned / 1e6:.4f} tUSD, its {LABS_CO_INVEST_BPS / 100:.0f}% share", r)

        petahour_wallet = ex.a["treasury"]
        petahour_before = usd_c.functions.balanceOf(petahour_wallet.address).call()
        ex.chain.send(labs_treasury.functions.payLicence(), petahour_wallet, "collect data licence")
        licence = usd_c.functions.balanceOf(petahour_wallet.address).call() - petahour_before
        one_day = lent * LABS_LICENCE_BPS // 10_000 // 365
        self.check(abs(licence - one_day) <= one_day // 100 + 1,
                   f"data licence: Petahour collected {licence / 1e6:.4f} tUSD, {LABS_LICENCE_BPS / 100:.2f}% a year on the loans, with no role at Labs", r)

        debt = market.functions.debtOf(second.address).call() * 2  # repay caps at what is owed
        ex.chain.send(usd_c.functions.mint(second.address, debt), second, "mint tUSD")
        ex.chain.send(usd_c.functions.approve(market.address, debt), second, "approve market")
        ex.chain.send(market.functions.repay(debt), second, "repay")
        self.step("on-chain", "Second borrower repays in full, leaving one small loan")

        # Settling is the waterfall's payment date: what first-loss has earned so far is now final.
        ex.chain.send(vault.functions.settle(), ex.a["relay"], "settle the waterfall")
        claim_full_book = tranche.functions.totalAssets().call()
        ex.chain.advance(ONE_DAY)  # a thin day: interest on one small loan does not cover the yield
        self.check(tranche.functions.totalAssets().call() == claim_full_book,
                   "with the book thin, seniors take all the interest and first-loss earns nothing", r)

        junior_shares = tranche.functions.balanceOf(ex.a["junior"].address).call()
        senior_before = vault.functions.convertToAssets(lender_shares).call()
        junior_before = tranche.functions.totalAssets().call()
        labs_before = tranche.functions.convertToAssets(labs_shares).call()

        crash = self.tcpi_usd * 0.40
        self.expect_rejected(lambda: ex.publish_tcpi(crash, 1000), "DeviationTooLarge", "60% fall without an emergency flag", r)
        ex.publish_tcpi(crash, 1000, emergency=True)
        self.step("on-chain", f"Emergency print by federation quorum: TCPI falls 60% to US${crash:.4f}")
        self.check(not market.functions.isHealthy(borrower.address).call(), "position is now under water", r)

        liq = ex.a["liquidator"]
        ex.chain.send(usd_c.functions.mint(liq.address, 5_000_000_000), liq, "mint tUSD")
        ex.chain.send(usd_c.functions.approve(market.address, 5_000_000_000), liq, "approve market")
        receipt = ex.chain.send(market.functions.liquidate(borrower.address, amount), liq, "liquidate")
        ev = ex.chain.events("IsolatedLendingMarket", "Liquidated", receipt)[0]["args"]
        self.step("on-chain", f"Liquidated: repaid {usd(ev['repaid'])}, seized all collateral, bad debt {usd(ev['badDebt'])} tUSD")
        self.check(ev["badDebt"] > 0, "collateral fell short of the debt", r)
        at_loss = vault.functions.convertToAssets(lender_shares).call()
        drop = tranche.functions.totalAssets().call()
        self.check(abs(at_loss - senior_before) <= senior_before // 1_000_000 + 2 and drop < junior_before,
                   f"the loss lands at once, with nobody calling anything: first-loss {usd(junior_before)} to {usd(drop)} tUSD", r)

        ex.chain.send(vault.functions.settle(), ex.a["relay"], "settle the waterfall")
        senior_after = vault.functions.convertToAssets(lender_shares).call()
        junior_after = tranche.functions.totalAssets().call()
        labs_after = tranche.functions.convertToAssets(labs_shares).call()
        self.check(abs(senior_after - senior_before) <= senior_before // 1_000_000 + 2, f"senior depositors whole: {usd(senior_after)} tUSD", r)
        self.check(abs(junior_before - junior_after - ev["badDebt"]) <= junior_before // 1_000_000 + 2,
                   f"first-loss tranche absorbed it: {usd(junior_before)} to {usd(junior_after)} tUSD", r)
        self.check(abs((labs_before - labs_after) - ev["badDebt"] * LABS_CO_INVEST_BPS // 10_000) <= 3,
                   f"Labs took its {LABS_CO_INVEST_BPS / 100:.0f}% of the loss: {usd(labs_before - labs_after)} tUSD", r)
        loss_pct = ev["badDebt"] / (ev["badDebt"] + ev["repaid"]) * 100
        self.check(loss_pct > LABS_FIRST_LOSS_BPS / 100,
                   f"the crash cost {loss_pct:.0f}% of the loan, more than the model's {LABS_FIRST_LOSS_BPS / 100:.0f}% first-loss ratio: seniors are whole here only because this loan is small against the pool", r)
        r.update(bad_debt_usd=ev["badDebt"] / 1e6, senior_before_usd=senior_before / 1e6, senior_after_usd=senior_after / 1e6,
                 junior_before_usd=junior_before / 1e6, junior_after_usd=junior_after / 1e6, first_loss_earned_usd=earned / 1e6,
                 first_loss_yearly_pct=yearly * 100, pool_lent_pct=lent / (senior + first_loss) * 100, loss_on_loan_pct=loss_pct)
        self.report["scenarios"]["S6"] = r

    # ------------------------------------------------------------------- closing

    def close(self) -> dict:
        self.title("Reconciliation and reports")
        ex = self.ex
        roles = ["seller_a", "seller_b", "seller_c", "seller_d", "seller_e", "buyer_alpha", "buyer_beta", "buyer_gamma", "watcher", "treasury"]
        ledger = sum(ex.free(r) for r in roles) + ex.c["DvPEscrow"].functions.totalLocked().call()
        held = ex.c["MockUSD"].functions.balanceOf(ex.c["DvPEscrow"].address).call()
        r: dict = {}
        self.check(ledger == held, f"escrow holds exactly what its ledger owes: {usd(held)} tUSD", r)
        self.report["reconciliation"] = r

        daily = write_reports(ex, sorted(set(self.trade_ids)), self.snap.fx_ntd_per_usd)
        self.step("off-chain", f"Simulated regulatory report and 5% VAT invoices written: {daily['trades']} trades, "
                               f"NT${daily['vat_ntd_total']:,.0f} VAT, statuses {daily['by_status']}")

        gas: dict[str, list[int]] = {}
        for tx in ex.chain.gas_log:
            gas.setdefault(tx.label, []).append(tx.gas)
        table = Table(title="Gas by operation (real, from receipts)")
        table.add_column("operation")
        table.add_column("count", justify="right")
        table.add_column("avg gas", justify="right")
        keep = ["match orders", "claim delivery", "finalize", "challenge", "respond with zk proof", "resolve timeout",
                "mint passport", "record attestation", "publish TCPI", "mint warehouse receipt", "borrow", "liquidate"]
        for label in keep:
            if label in gas:
                table.add_row(label, str(len(gas[label])), f"{sum(gas[label]) // len(gas[label]):,}")
        self.out.print(table)
        self.report["gas"] = {k: {"count": len(v), "avg": sum(v) // len(v)} for k, v in gas.items()}
        self.report["transactions"] = len(ex.chain.gas_log)
        (REPORTS / "tcpi_audit_trail.json").write_text(json.dumps(self.audit_trail, indent=2))
        checks = [c for s in self.report["scenarios"].values() for c in s.get("checks", [])] + r["checks"]
        self.report["checks_passed"] = sum(c["passed"] for c in checks)
        self.report["checks_total"] = len(checks)
        (REPORTS / "e2e_report.json").write_text(json.dumps(self.report, indent=2, default=str))
        self.out.rule(f"[bold green]{self.report['checks_passed']}/{self.report['checks_total']} checks passed across "
                      f"{self.report['transactions']} transactions")
        return self.report

    def run_all(self) -> dict:
        self.bootstrap()
        self.s1_happy_path()
        self.s2_seller_fraud()
        self.s3_false_challenge()
        self.s4_compliance()
        self.s5_attacks()
        self.s6_labs()
        return self.close()
