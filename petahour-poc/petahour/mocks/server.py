"""Stand-ins for the external services the PoC cannot call for real.

  /v1/indices/*      vendor price index    protocol ASSUMED (Silicon Data's schema is not public)
  /v4/attest/gpu     NVIDIA NRAS           shaped like the real service (see petahour/tee.py)
  /v1/screen         KYC and export checks fictional list, illustrative country set

Every response is labelled simulated. Nothing here is a real compliance or attestation result.
"""
from __future__ import annotations

import base64
import hashlib
import json
import math
import threading
import time

import jwt
import uvicorn
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel

VENDOR_API_KEY = "petahour-poc-demo-key"
ISSUER = "https://mock-nras.petahour.local"
KID = "mock-nras-es384-1"

# Index levels anchored on report Table 3.2, then a deterministic daily walk.
INDEX_LEVELS = {"SDB200RT": 6.44, "SDH100RT": 2.95, "SDA100RT": 1.80}

# Fictional entities. Not real sanctions data.
DENIED_PARTIES = {"shadow compute trading ltd", "grey channel gpu brokers", "offshore relay hk ltd"}
# Illustrative subset, for demonstration only. A real system consumes the official lists.
EAR_RESTRICTED_COUNTRIES = {"CN", "RU", "IR", "KP", "SY", "CU", "BY", "MM", "VE"}

app = FastAPI(title="Petahour PoC mock external services")
_private_key = ec.generate_private_key(ec.SECP384R1())


def _index_value(ticker: str, day_offset: int = 0) -> float:
    day = int(time.time() // 86_400) - day_offset
    seed = int(hashlib.sha256(f"{ticker}:{day}".encode()).hexdigest(), 16) % 1000 / 1000
    return round(INDEX_LEVELS[ticker] * (1 + 0.03 * math.sin(day / 7) + 0.02 * (seed - 0.5)), 4)


def _check_key(key: str | None) -> None:
    if key != VENDOR_API_KEY:
        raise HTTPException(status_code=401, detail="invalid api key")


@app.get("/v1/indices/{ticker}/latest")
def index_latest(ticker: str, x_api_key: str | None = Header(default=None)):
    _check_key(x_api_key)
    if ticker not in INDEX_LEVELS:
        raise HTTPException(status_code=404, detail="unknown ticker")
    return {
        "ticker": ticker,
        "value": _index_value(ticker),
        "currency": "USD",
        "unit": "GPU-hour",
        "asOf": time.strftime("%Y-%m-%d", time.gmtime()),
        "simulated": True,
        "protocol": "ASSUMED - this is not Silicon Data's real API",
    }


@app.get("/v1/indices/{ticker}/history")
def index_history(ticker: str, days: int = 30, x_api_key: str | None = Header(default=None)):
    _check_key(x_api_key)
    if ticker not in INDEX_LEVELS:
        raise HTTPException(status_code=404, detail="unknown ticker")
    return {"ticker": ticker, "simulated": True, "points": [
        {"daysAgo": d, "value": _index_value(ticker, d)} for d in range(days - 1, -1, -1)
    ]}


class ScreeningRequest(BaseModel):
    legal_name: str
    country: str
    wallet: str
    entity_type: str = "company"


@app.post("/v1/screen")
def screen(req: ScreeningRequest):
    lists = []
    if req.legal_name.strip().lower() in DENIED_PARTIES:
        lists.append("DENIED_PARTY")
    if req.country.upper() in EAR_RESTRICTED_COUNTRIES:
        lists.append("EAR_COUNTRY_GROUP_D5")
    decision = "DENIED" if lists else "CLEAR"
    case = hashlib.sha256(f"{req.legal_name}|{req.wallet}".encode()).hexdigest()[:16]
    return {"decision": decision, "hits": lists, "caseRef": case, "simulated": True}


def _b64url(n: int, size: int) -> str:
    return base64.urlsafe_b64encode(n.to_bytes(size, "big")).rstrip(b"=").decode()


@app.get("/.well-known/jwks.json")
def jwks():
    pub = _private_key.public_key().public_numbers()
    return {"keys": [{"kty": "EC", "crv": "P-384", "kid": KID, "alg": "ES384",
                      "x": _b64url(pub.x, 48), "y": _b64url(pub.y, 48)}]}


class Evidence(BaseModel):
    evidence: str
    certificate: str


class AttestRequest(BaseModel):
    nonce: str
    arch: str
    claims_version: str = "3.0"
    evidence_list: list[Evidence]


@app.post("/v4/attest/gpu")
def attest(req: AttestRequest, authorization: str | None = Header(default=None)):
    """Returns a detached EAT bundle: [["JWT", overall], {"GPU-0": per-gpu, ...}]."""
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Bearer token required")
    now = int(time.time())
    base = {"iss": ISSUER, "iat": now, "nbf": now, "exp": now + 3600, "eat_nonce": req.nonce}
    all_ok = True
    gpu_tokens = {}
    for index, item in enumerate(req.evidence_list):
        doc = json.loads(base64.b64decode(item.evidence))
        genuine = doc.get("firmware_measurement") == "golden" and doc.get("nonce") == req.nonce
        cc_on = doc.get("cc_mode") == "on"
        ok = genuine and cc_on
        all_ok = all_ok and ok
        claims = {
            **base,
            "hwmodel": doc.get("hwmodel"),
            "ueid": doc.get("ueid"),
            "measres": "success" if genuine else "fail",
            "secboot": True,
            "dbgstat": "disabled" if cc_on else "enabled",
            "x-nvidia-gpu-driver-version": doc.get("driver"),
            "x-nvidia-ver": req.claims_version,
        }
        gpu_tokens[f"GPU-{index}"] = jwt.encode(claims, _private_key, algorithm="ES384", headers={"kid": KID})
    overall = {**base, "x-nvidia-overall-att-result": all_ok, "x-nvidia-ver": req.claims_version,
               "submods": {name: ["DIGEST", ["SHA-256", hashlib.sha256(tok.encode()).hexdigest()]]
                           for name, tok in gpu_tokens.items()}}
    return [["JWT", jwt.encode(overall, _private_key, algorithm="ES384", headers={"kid": KID})], gpu_tokens]


class MockServer:
    """Runs the mocks on a background thread for the length of a demo."""

    def __init__(self, port: int = 8799):
        self.port = port
        self.base_url = f"http://127.0.0.1:{port}"
        self._server = uvicorn.Server(uvicorn.Config(app, port=port, log_level="error"))
        self._thread = threading.Thread(target=self._server.run, daemon=True)

    def __enter__(self) -> "MockServer":
        self._thread.start()
        for _ in range(100):
            if self._server.started:
                return self
            time.sleep(0.05)
        raise RuntimeError("mock server did not start")

    def __exit__(self, *_) -> None:
        self._server.should_exit = True
        self._thread.join(timeout=5)


if __name__ == "__main__":
    uvicorn.run(app, port=8799)
