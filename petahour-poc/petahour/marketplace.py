"""The Petahour operator: the single place where off-chain services meet the contracts."""
from __future__ import annotations

import json
import secrets
from dataclasses import dataclass, field

import requests
from web3 import Web3

from . import tee, zk_bridge
from .chain import Chain, Rejected, actors, quorum, sign_typed
from .config import ANY_ZONE, GRID_ZONES, METHODOLOGY_VERSION, SKUS, tag
from .matching import Fill, Order
from .tcpi import SettledTrade
from .telemetry import HourRecord, features, merkle_root, simulate
from .zk_model import QuantizedModel

ORDER_FIELDS = [
    ("maker", "address"), ("isBuy", "bool"), ("sku", "bytes32"), ("passportId", "uint256"),
    ("gpuHours", "uint64"), ("limitPriceE6", "uint64"), ("deliveryStart", "uint64"), ("windowHours", "uint32"),
    ("minSlaBps", "uint16"), ("gridZone", "bytes32"), ("expiry", "uint64"), ("salt", "uint256"),
]
MINT_FIELDS = [
    ("to", "address"), ("hostIdHash", "bytes32"), ("teeKey", "address"), ("sku", "bytes32"), ("gpuCount", "uint32"),
    ("pueMilli", "uint16"), ("slaBps", "uint16"), ("gridZone", "bytes32"), ("topology", "bytes32"), ("metadataHash", "bytes32"),
]
ATTEST_FIELDS = [
    ("passportId", "uint256"), ("measurementHash", "bytes32"), ("eatHash", "bytes32"), ("nonce", "bytes32"), ("validUntil", "uint64"),
]
SEAL_FIELDS = [
    ("tradeId", "uint256"), ("passportId", "uint256"), ("telemetryRoot", "bytes32"), ("featureCommitment", "uint256"),
]
PUBLISH_FIELDS = [
    ("indexId", "bytes32"), ("day", "uint64"), ("answer", "int256"), ("volumeGpuHours", "uint128"),
    ("methodologyHash", "bytes32"), ("inputsHash", "bytes32"), ("emergency", "bool"),
]
RULING_FIELDS = [("tradeId", "uint256"), ("sellerAtFault", "bool"), ("evidenceHash", "bytes32")]

STATUS = ["None", "Open", "Claimed", "Challenged", "Settled", "Defaulted"]


class ComplianceReject(Exception):
    pass


@dataclass
class DeliveryPackage:
    """What the host produced for one trade. The seller keeps it; the buyer gets the records."""
    trade_id: int
    records: list[HourRecord]
    features: list[int]
    salt: int
    root: bytes
    commitment: int
    claimed_uptime_bps: int


@dataclass
class Verdict:
    honest: bool
    reasons: list[str] = field(default_factory=list)
    measured_uptime_bps: int = 0


class Marketplace:
    def __init__(self, chain: Chain, mock_url: str):
        self.chain = chain
        self.mock_url = mock_url
        self.a = actors()
        self.c = chain.c
        self.model = QuantizedModel.from_json(zk_bridge.model_json())
        self.federation = [self.a["fed_petahour"], self.a["fed_nchc"], self.a["fed_odm"]]
        self.hosts: dict[int, tee.SimulatedHost] = {}
        self.last_tcpi_day = 0

    # ------------------------------------------------------------- onboarding

    def screen(self, role: str, legal_name: str, country: str) -> dict:
        resp = requests.post(
            f"{self.mock_url}/v1/screen",
            json={"legal_name": legal_name, "country": country, "wallet": self.a[role].address},
            timeout=15,
        )
        resp.raise_for_status()
        return resp.json()

    def onboard(self, role: str, legal_name: str, country: str = "TW", days: int = 365) -> str:
        """KYC and export screening happen off-chain; only a pass/fail flag reaches the chain."""
        result = self.screen(role, legal_name, country)
        if result["decision"] != "CLEAR":
            raise ComplianceReject(f"{legal_name}: {', '.join(result['hits'])}")
        expiry = self.chain.now() + days * 86_400
        self.chain.send(
            self.c["MemberRegistry"].functions.enroll(self.a[role].address, 1, expiry, tag(result["caseRef"])),
            self.a["petahour_admin"], "enroll member",
        )
        return result["caseRef"]

    def labs_onboard(self, role: str, country: str, investor_class: str = "institutional", days: int = 365) -> str:
        """Petahour Labs runs its own allow-list: a Petahour member is not automatically a Labs member.

        The policy reflects the 5 Nov 2026 venue evaluation. Retail is refused outright. Taiwan
        institutions are admitted to the demo but flagged, because Taiwan's Virtual Asset Service
        Act (in force Q1 2027 at the earliest) has lending and custody licence types that may
        catch services offered to Taiwan users. That needs a legal opinion, not a code decision.
        """
        if investor_class != "institutional":
            raise ComplianceReject(f"{role}: Petahour Labs is institutional only")
        flag = "LEGAL-REVIEW: Taiwan user, Virtual Asset Service Act" if country == "TW" else "clear"
        expiry = self.chain.now() + days * 86_400
        self.chain.send(
            self.c["LabsRegistry"].functions.enroll(self.a[role].address, 1, expiry, tag(f"labs:{role}")),
            self.a["labs_admin"], "labs enroll",
        )
        return flag

    def fund(self, role: str, usd: float) -> None:
        amount = int(usd * 1e6)
        who = self.a[role]
        usd_c, escrow = self.c["MockUSD"], self.c["DvPEscrow"]
        self.chain.send(usd_c.functions.mint(who.address, amount), who, "mint tUSD")
        self.chain.send(usd_c.functions.approve(escrow.address, amount), who, "approve escrow")
        self.chain.send(escrow.functions.deposit(amount), who, "deposit")

    def free(self, role: str) -> int:
        address = self.a[role].address if role in self.a else role
        return self.c["DvPEscrow"].functions.free(address).call()

    # --------------------------------------------------------- asset registration

    def register_host(self, seller: str, host: tee.SimulatedHost, sku: str = "B200", zone: str = "north",
                      sla_bps: int = 9990, pue_milli: int = 1400) -> int:
        # Every field report section 4.1.1 requires. The full record stays off-chain; only its hash
        # and the fields the contracts enforce go on-chain.
        spec = {
            "host": host.host_id, "sku": SKUS[sku].code, "gpus": host.gpu_count, "vram_gb_per_gpu": 180,
            "interconnect": "NVLink5 + 800G InfiniBand", "site": f"Taiwan, {zone} region (simulated)", "grid_zone": zone,
            "sla_bps": sla_bps, "pue": pue_milli / 1000, "security": ["ISO 27001", "SOC 2 Type II", "TPM"],
            "power_source": "Taipower industrial tariff, no PPA (simulated)", "data_residency": "Taiwan (PDPA)",
            "export_clearance": "owner screened: US EAR; Taiwan controls per current law (simulated)",
        }
        metadata_hash = Web3.keccak(text=json.dumps(spec, sort_keys=True))
        p = {
            "hostIdHash": tag(host.host_id), "teeKey": host.tee_address, "sku": SKUS[sku].id, "gpuCount": host.gpu_count,
            "pueMilli": pue_milli, "slaBps": sla_bps, "gridZone": GRID_ZONES[zone], "topology": tag("NVLINK5"),
            "metadataHash": metadata_hash,
        }
        to = self.a[seller].address
        sigs = quorum(self.federation[:2], self.chain.domain("Petahour Compute Passport", "ComputePassport"),
                      "MintPassport", MINT_FIELDS, {"to": to, **p})
        passport = (p["hostIdHash"], p["teeKey"], p["sku"], p["gpuCount"], p["pueMilli"], p["slaBps"],
                    p["gridZone"], p["topology"], p["metadataHash"], False)
        # The seller pays the first year's fee from its wallet at mint.
        usd_c, passports = self.c["MockUSD"], self.c["ComputePassport"]
        fee = passports.functions.annualFee(host.gpu_count).call()
        self.chain.send(usd_c.functions.mint(to, fee), self.a[seller], "mint tUSD")
        self.chain.send(usd_c.functions.approve(passports.address, fee), self.a[seller], "approve passport fee")
        receipt = self.chain.send(self.c["ComputePassport"].functions.mintPassport(to, passport, sigs),
                                  self.a[seller], "mint passport")
        passport_id = self.chain.events("ComputePassport", "PassportMinted", receipt)[0]["args"]["id"]
        self.hosts[passport_id] = host
        return passport_id

    def attest(self, passport_id: int, days: int = 30) -> tee.AttestationResult:
        """Each federation node verifies the NRAS token itself before signing."""
        host = self.hosts[passport_id]
        bundle, nonce, random_part = tee.request_attestation(host, self.mock_url)
        result = None
        for _node in self.federation:
            result = tee.verify_eat(bundle, nonce, random_part, host.tee_address, self.mock_url)
        valid_until = self.chain.now() + days * 86_400
        message = {"passportId": passport_id, "measurementHash": result.measurement_hash, "eatHash": result.eat_hash,
                   "nonce": nonce, "validUntil": valid_until}
        sigs = quorum(self.federation[:2], self.chain.domain("Petahour Proof of Delivery", "ProofOfDeliveryOracle"),
                      "Attestation", ATTEST_FIELDS, message)
        self.chain.send(
            self.c["ProofOfDeliveryOracle"].functions.submitAttestation(
                passport_id, result.measurement_hash, result.eat_hash, nonce, valid_until, sigs),
            self.a["relay"], "record attestation",
        )
        return result

    def list_capacity(self, seller: str, passport_id: int, days: int = 30) -> int:
        now = self.chain.now()
        receipt = self.chain.send(
            self.c["CapacityPool"].functions.listCapacity(passport_id, now, now + days * 86_400),
            self.a[seller], "list capacity",
        )
        return self.chain.events("CapacityPool", "CapacityListed", receipt)[0]["args"]["listingId"]

    # ------------------------------------------------------------------- orders

    def next_delivery_start(self, hours_ahead: int = 2) -> int:
        return ((self.chain.now() // 3600) + hours_ahead) * 3600

    def sign_order(self, role: str, order: Order, sku: str = "B200") -> Order:
        """The client signs its own limits. This signature is what binds the matcher."""
        maker = self.a[role]
        message = {
            "maker": maker.address, "isBuy": order.is_buy, "sku": SKUS[sku].id, "passportId": order.passport_id,
            "gpuHours": order.gpu_hours, "limitPriceE6": order.limit_e6, "deliveryStart": order.start,
            "windowHours": order.window_hours, "minSlaBps": order.min_sla_bps, "gridZone": order.grid_zone,
            "expiry": order.start, "salt": secrets.randbits(128),
        }
        order.onchain = message
        order.signature = sign_typed(maker, self.chain.domain("Petahour DvP Escrow", "DvPEscrow"), "Order", ORDER_FIELDS, message)
        return order

    @staticmethod
    def _tuple(m: dict) -> tuple:
        return tuple(m[name] for name, _ in ORDER_FIELDS)

    def settle_fill(self, fill: Fill) -> int:
        receipt = self.chain.send(
            self.c["DvPEscrow"].functions.matchOrders(
                self._tuple(fill.buy.onchain), fill.buy.signature, self._tuple(fill.sell.onchain), fill.sell.signature,
                fill.qty, fill.price_e6, fill.sell.listing_id),
            self.a["matcher"], "match orders",
        )
        return self.chain.events("DvPEscrow", "TradeOpened", receipt)[0]["args"]["tradeId"]

    def trade(self, trade_id: int) -> dict:
        t = self.c["DvPEscrow"].functions.trades(trade_id).call()
        keys = ["buyer", "seller", "passportId", "sku", "gpuHours", "priceE6", "start", "end", "notional", "buyerFee",
                "sellerFee", "sellerCollateral", "status"]
        d = dict(zip(keys, t))
        d["statusName"] = STATUS[d["status"]]
        return d

    # ----------------------------------------------------------------- delivery

    def produce_telemetry(self, trade_id: int, profile: str = "healthy", seed: int = 0) -> DeliveryPackage:
        """The host measures and seals. This step is honest even when the seller is not."""
        t = self.trade(trade_id)
        hours = max(1, (t["end"] - t["start"]) // 3600)
        records = simulate(hours, profile, seed=seed)
        feats = features(records)
        salt = secrets.randbits(128)
        return DeliveryPackage(trade_id, records, feats, salt, merkle_root(records), zk_bridge.commitment(feats, salt), feats[0])

    def seal(self, package: DeliveryPackage, passport_id: int) -> bytes:
        domain = self.chain.domain("Petahour Proof of Delivery", "ProofOfDeliveryOracle")
        types = {"TelemetrySeal": [{"name": n, "type": t} for n, t in SEAL_FIELDS]}
        message = {"tradeId": package.trade_id, "passportId": passport_id, "telemetryRoot": package.root,
                   "featureCommitment": package.commitment}
        return bytes(self.hosts[passport_id].sign_typed(domain, types, message))

    def claim(self, seller: str, package: DeliveryPackage, claimed_uptime_bps: int | None = None) -> dict:
        """T+0. The seller asserts an uptime, which can differ from what the host measured."""
        t = self.trade(package.trade_id)
        if self.chain.now() < t["end"]:
            self.chain.advance(t["end"] - self.chain.now())
        uptime = package.features[0] if claimed_uptime_bps is None else claimed_uptime_bps
        package.claimed_uptime_bps = uptime
        return self.chain.send(
            self.c["DvPEscrow"].functions.claimDelivery(
                package.trade_id, uptime, package.root, package.commitment, self.seal(package, t["passportId"])),
            self.a[seller], "claim delivery",
        )

    def watchtower(self, package: DeliveryPackage) -> Verdict:
        """opML re-execution. The buyer holds its own hourly records, recomputes the commitments
        and re-runs the model. Any mismatch with the on-chain claim is grounds to challenge."""
        claim = self.c["DvPEscrow"].functions.claims(package.trade_id).call()
        claimed_uptime, on_chain_root = claim[0], claim[5]
        reasons = []
        if merkle_root(package.records) != on_chain_root:
            reasons.append("telemetry root does not match the on-chain claim")
        measured = features(package.records)
        if measured[0] < claimed_uptime:
            reasons.append(f"claimed uptime {claimed_uptime / 100:.2f}% exceeds measured {measured[0] / 100:.2f}%")
        if not self.model.passes(measured):
            reasons.append("SLA model fails on the measured telemetry")
        return Verdict(not reasons, reasons, measured[0])

    def challenge(self, role: str, trade_id: int) -> dict:
        return self.chain.send(self.c["DvPEscrow"].functions.challenge(trade_id), self.a[role], "challenge")

    def prove_and_respond(self, seller: str, package: DeliveryPackage) -> dict:
        """zkML response. Raises ProofUnavailable when the telemetry cannot support the claim."""
        proof = zk_bridge.prove(package.features, package.salt, package.claimed_uptime_bps, package.trade_id)
        a = [int(x) for x in proof["a"]]
        b = [[int(x) for x in row] for row in proof["b"]]
        c = [int(x) for x in proof["c"]]
        receipt = self.chain.send(
            self.c["DvPEscrow"].functions.respondWithProof(package.trade_id, a, b, c), self.a[seller], "respond with zk proof"
        )
        return {"receipt": receipt, "prover_ms": proof["ms"], "public_signals": proof["publicSignals"]}

    def finalize(self, trade_id: int) -> dict:
        return self.chain.send(self.c["DvPEscrow"].functions.finalize(trade_id), self.a["relay"], "finalize")

    def resolve_timeout(self, trade_id: int) -> dict:
        return self.chain.send(self.c["DvPEscrow"].functions.resolveTimeout(trade_id), self.a["relay"], "resolve timeout")

    def seed_default_fund(self, usd: float) -> None:
        amount = int(usd * 1e6)
        who = self.a["petahour_admin"]
        self.chain.send(self.c["MockUSD"].functions.mint(who.address, amount), who, "mint tUSD")
        self.chain.send(self.c["MockUSD"].functions.approve(self.c["DefaultFund"].address, amount), who, "approve fund")
        self.chain.send(self.c["DefaultFund"].functions.fundMutual(amount), who, "seed default fund")

    # -------------------------------------------------------------------- index

    def delivered_row(self, trade_id: int) -> SettledTrade:
        """Reads what was actually delivered from the chain, so index inputs need no trust."""
        t = self.trade(trade_id)
        uptime = self.c["DvPEscrow"].functions.claims(trade_id).call()[0]
        return SettledTrade("B200", t["gpuHours"] * uptime / 10_000, t["priceE6"] / 1e6, trade_id)

    def publish_tcpi(self, usd_per_gpu_hour: float, volume: int, emergency: bool = False,
                     inputs: bytes = tag("no-trade-inputs")) -> dict:
        day = max(self.chain.now() // 86_400, self.last_tcpi_day + 1)
        self.last_tcpi_day = day
        index_id = tag("TCPI-B200")
        answer = round(usd_per_gpu_hour * 1e8)
        methodology = tag(METHODOLOGY_VERSION)
        message = {"indexId": index_id, "day": day, "answer": answer, "volumeGpuHours": volume,
                   "methodologyHash": methodology, "inputsHash": inputs, "emergency": emergency}
        sigs = quorum(self.federation[:2], self.chain.domain("Petahour TCPI Oracle", "TCPIOracle"), "TCPIPublish", PUBLISH_FIELDS, message)
        return self.chain.send(
            self.c["TCPIOracle"].functions.publish(index_id, day, answer, volume, methodology, inputs, emergency, sigs),
            self.a["relay"], "publish TCPI",
        )
