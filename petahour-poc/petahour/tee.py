"""Simulated confidential GPU host and the attestation flow around it.

What is real here: the EAT tokens are genuine ES384 JWTs checked against a JWKS endpoint, with
the claim names NVIDIA uses, and the seal is a genuine secp256k1 EIP-712 signature checked
on-chain. What is simulated: there is no GPU. A host's "evidence" is a JSON document, and the
sealed key is an ordinary key held in this process.

Key binding: the nonce sent for attestation is keccak(teeAddress || random), so a token can only
vouch for the key it was requested for. Production needs more than this: a GPU report shows a
genuine CC-mode GPU is reachable, not that it is bound to a given confidential VM, so a CPU TEE
quote (TDX or SEV-SNP) must carry the key and the GPU nonce together.
"""
from __future__ import annotations

import base64
import json
import secrets
import time
from dataclasses import dataclass

import jwt
import requests
from eth_account import Account
from eth_account.signers.local import LocalAccount
from web3 import Web3


@dataclass
class AttestationResult:
    nonce: bytes
    eat_hash: bytes
    measurement_hash: bytes
    overall: dict
    gpus: dict
    token: str


class SimulatedHost:
    """A host whose secp256k1 key is generated 'inside' the confidential VM."""

    def __init__(self, host_id: str, hwmodel: str = "GB100", gpu_count: int = 8, compromised: bool = False):
        self.host_id = host_id
        self.hwmodel = hwmodel
        self.gpu_count = gpu_count
        self.compromised = compromised
        self._key: LocalAccount = Account.create(secrets.token_hex(32))

    @property
    def tee_address(self) -> str:
        return self._key.address

    def new_nonce(self) -> tuple[bytes, bytes]:
        """The random part goes to the verifier, so it can recompute and check the binding."""
        random_part = secrets.token_bytes(32)
        return Web3.keccak(bytes.fromhex(self.tee_address[2:]) + random_part), random_part

    def evidence(self, nonce_hex: str) -> list[dict]:
        out = []
        for index in range(self.gpu_count):
            doc = {
                "nonce": nonce_hex,
                "hwmodel": self.hwmodel,
                "ueid": f"{self.host_id}-gpu{index}",
                "driver": "595.71",
                "cc_mode": "off" if self.compromised else "on",
                "firmware_measurement": "tampered" if self.compromised else "golden",
            }
            out.append({"evidence": base64.b64encode(json.dumps(doc).encode()).decode(), "certificate": "mock-cert-chain"})
        return out

    def sign_typed(self, domain: dict, types: dict, message: dict) -> bytes:
        """Only this sealed key can produce the telemetry seal the contract checks."""
        return Account.sign_typed_data(self._key.key, domain, types, message).signature


class AttestationError(Exception):
    pass


def request_attestation(host: SimulatedHost, nras_url: str) -> tuple[list, bytes, bytes]:
    nonce, random_part = host.new_nonce()
    resp = requests.post(
        f"{nras_url}/v4/attest/gpu",
        json={"nonce": nonce.hex(), "arch": "BLACKWELL", "claims_version": "3.0", "evidence_list": host.evidence(nonce.hex())},
        headers={"Authorization": "Bearer mock-service-key"},
        timeout=15,
    )
    resp.raise_for_status()
    return resp.json(), nonce, random_part


def verify_eat(bundle: list, nonce: bytes, random_part: bytes, tee_address: str, nras_url: str) -> AttestationResult:
    """The check each federation node runs independently, off-chain.

    NRAS signs with P-384. The EVM has no P-384 precompile, so this cannot run in a contract.
    """
    jwks = requests.get(f"{nras_url}/.well-known/jwks.json", timeout=15).json()
    keys = {k["kid"]: jwt.algorithms.ECAlgorithm.from_jwk(json.dumps(k)) for k in jwks["keys"]}

    def decode(token: str) -> dict:
        header = jwt.get_unverified_header(token)
        return jwt.decode(token, keys[header["kid"]], algorithms=["ES384"], options={"verify_aud": False})

    overall_token = bundle[0][1]
    overall = decode(overall_token)
    gpus = {name: decode(tok) for name, tok in bundle[1].items()}

    if overall.get("eat_nonce") != nonce.hex():
        raise AttestationError("nonce mismatch: token is not fresh")
    if Web3.keccak(bytes.fromhex(tee_address[2:]) + random_part) != nonce:
        raise AttestationError("nonce is not bound to the TEE key")
    if overall.get("x-nvidia-overall-att-result") is not True:
        raise AttestationError("overall attestation result is false")
    for name, claims in gpus.items():
        if claims.get("measres") != "success":
            raise AttestationError(f"{name}: measurement mismatch")
        if claims.get("dbgstat") != "disabled" or claims.get("secboot") is not True:
            raise AttestationError(f"{name}: not in a production confidential-computing state")

    measurement = Web3.keccak(text=json.dumps(sorted((c["hwmodel"], c["x-nvidia-gpu-driver-version"]) for c in gpus.values())))
    return AttestationResult(nonce, Web3.keccak(text=overall_token), measurement, overall, gpus, overall_token)


def validity_window(now: int, days: int = 30) -> int:
    return now + days * 86_400
