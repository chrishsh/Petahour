"""The on-chain/off-chain boundary: web3 access, typed signing, readable reverts and simulated time."""
from __future__ import annotations

import json
import os
import signal
import socket
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

from eth_abi import decode as abi_decode
from eth_account import Account
from eth_account.signers.local import LocalAccount
from web3 import Web3
from web3.exceptions import ContractCustomError, ContractLogicError, Web3RPCError

from . import zk_bridge
from .config import (ABI_DIR, BUYER_FEE_BPS, DEPLOYMENTS, DEV_MNEMONIC, LABS_CURATOR_FEE_BPS, LABS_LICENCE_BPS,
                     LABS_ORIGINATION_FEE_BPS, LAUNCH_YEAR, NETWORKS, PASSPORT_DISCOUNT_BPS,
                     PASSPORT_FEE_USD_PER_GPU_YEAR, REPORTS, ROOT, SELLER_FEE_BPS)
from .zk_model import QuantizedModel

Account.enable_unaudited_hdwallet_features()

ABI_FILES = {
    "MockUSD": "MockUSD",
    "Federation": "Federation",
    "MemberRegistry": "MemberRegistry",
    "LabsRegistry": ("MemberRegistry", "MemberRegistry"),
    "ComputePassport": "ComputePassport",
    "ProofOfDeliveryOracle": "ProofOfDeliveryOracle",
    "CapacityPool": "CapacityPool",
    "DefaultFund": "DefaultFund",
    "Groth16Verifier": "Groth16Verifier",
    "ZkDeliveryAdjudicator": "ZkDeliveryAdjudicator",
    "DvPEscrow": "DvPEscrow",
    "TCPIOracle": "TCPIOracle",
    "TCPIFeed": ("TCPIOracle", "TCPIFeed"),
    "GPUWarehouseReceipt": "GPUWarehouseReceipt",
    "GPUReceiptWrapper": "GPUReceiptWrapper",
    "TCPIPriceAdapter": "TCPIPriceAdapter",
    "IsolatedLendingMarket": "IsolatedLendingMarket",
    "ComputeCreditVault": "ComputeCreditVault",
    "LabsTreasury": "LabsTreasury",
    "FirstLossTranche": ("ComputeCreditVault", "FirstLossTranche"),
}

# Wallet roles by derivation index. Petahour and Petahour Labs admins are deliberately separate keys.
ROLES = [
    "petahour_admin", "matcher", "relay", "treasury", "labs_admin",
    "fed_petahour", "fed_nchc", "fed_odm",
    "seller_a", "seller_b", "seller_c", "buyer_alpha", "buyer_beta", "buyer_gamma",
    "watcher", "denied", "lender", "junior", "liquidator", "seller_d", "seller_e",
]


class Rejected(Exception):
    """A contract refused a transaction. `reason` is the decoded custom error."""

    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


def load_abi(name: str) -> list:
    entry = ABI_FILES[name]
    file, contract = entry if isinstance(entry, tuple) else (entry, entry)
    return json.loads((ABI_DIR / f"{file}.sol" / f"{contract}.json").read_text())["abi"]


def _error_table() -> dict[str, tuple[str, list[str]]]:
    table = {}
    for name in ABI_FILES:
        for item in load_abi(name):
            if item["type"] == "error":
                types = [i["type"] for i in item["inputs"]]
                sig = f"{item['name']}({','.join(types)})"
                table[Web3.keccak(text=sig)[:4].hex()] = (item["name"], types)
    return table


def actors(mnemonic: str = DEV_MNEMONIC) -> dict[str, LocalAccount]:
    return {
        role: Account.from_mnemonic(mnemonic, account_path=f"m/44'/60'/0'/0/{i}") for i, role in enumerate(ROLES)
    }


@dataclass
class Tx:
    label: str
    gas: int
    hash: str


class Chain:
    def __init__(self, rpc_url: str, chain_id: int, simulated_time: bool = True):
        self.w3 = Web3(Web3.HTTPProvider(rpc_url, request_kwargs={"timeout": 60}))
        self.chain_id = chain_id
        self.simulated_time = simulated_time
        self.addresses = json.loads((DEPLOYMENTS / f"{chain_id}.json").read_text())
        self.c = {
            name: self.w3.eth.contract(address=self.addresses[name], abi=load_abi(name))
            for name in ABI_FILES
            if name in self.addresses or name == "MemberRegistry"
        }
        self.errors = _error_table()
        self.gas_log: list[Tx] = []

    def now(self) -> int:
        return self.w3.eth.get_block("latest")["timestamp"]

    def advance(self, seconds: int) -> None:
        """Moves chain time on a local node. On a live testnet this simply waits."""
        if self.simulated_time:
            self.w3.provider.make_request("evm_increaseTime", [seconds])
            self.w3.provider.make_request("evm_mine", [])
        else:
            time.sleep(seconds)

    def _decode(self, data: str | None, fallback: str) -> str:
        if not data or len(data) < 10:
            return fallback
        selector = data[2:10]
        if selector in self.errors:
            name, types = self.errors[selector]
            try:
                args = abi_decode(types, bytes.fromhex(data[10:]))
            except Exception:
                args = ()
            shown = ", ".join(
                (f"{a.hex()[:12]}.." if isinstance(a, bytes) else str(a)) for a in args
            )
            return f"{name}({shown})"
        return fallback

    def send(self, fn, sender: LocalAccount, label: str = "") -> dict:
        """Dry-runs first, so a refusal surfaces as a readable Rejected and costs nothing."""
        try:
            gas = fn.estimate_gas({"from": sender.address})
        except ContractCustomError as exc:
            raise Rejected(self._decode(exc.data if isinstance(exc.data, str) else exc.message, str(exc))) from exc
        except ContractLogicError as exc:
            data = exc.data if isinstance(exc.data, str) else None
            raise Rejected(self._decode(data, str(exc))) from exc
        except Web3RPCError as exc:
            raise Rejected(str(exc)) from exc

        tx = fn.build_transaction(
            {
                "from": sender.address,
                "nonce": self.w3.eth.get_transaction_count(sender.address, "pending"),
                "gas": int(gas * 1.25) + 20_000,
                "chainId": self.chain_id,
            }
        )
        signed = sender.sign_transaction(tx)
        receipt = self.w3.eth.wait_for_transaction_receipt(self.w3.eth.send_raw_transaction(signed.raw_transaction))
        if receipt["status"] != 1:
            raise Rejected(f"transaction reverted: {label}")
        self.gas_log.append(Tx(label or fn.fn_name, receipt["gasUsed"], receipt["transactionHash"].hex()))
        return receipt

    def events(self, contract: str, event: str, receipt: dict) -> list[dict]:
        return list(getattr(self.c[contract].events, event)().process_receipt(receipt, errors=_DISCARD))

    def domain(self, name: str, contract: str) -> dict:
        return {
            "name": name,
            "version": "1",
            "chainId": self.chain_id,
            "verifyingContract": self.addresses[contract],
        }


try:
    from web3.logs import DISCARD as _DISCARD
except ImportError:  # pragma: no cover
    _DISCARD = "discard"


def sign_typed(account: LocalAccount, domain: dict, primary: str, fields: list[tuple[str, str]], message: dict) -> bytes:
    types = {primary: [{"name": n, "type": t} for n, t in fields]}
    return bytes(Account.sign_typed_data(account.key, domain, types, message).signature)


def quorum(signers: list[LocalAccount], domain: dict, primary: str, fields: list, message: dict) -> list[bytes]:
    """Federation signatures in ascending signer order, the form the contract requires."""
    ordered = sorted(signers, key=lambda a: int(a.address, 16))
    return [sign_typed(s, domain, primary, fields, message) for s in ordered]


# ------------------------------------------------------------------- local node


class ChainBusy(RuntimeError):
    """A chain is already listening on the port this run needs."""


def _port_open(port: int) -> bool:
    with socket.socket() as s:
        s.settimeout(0.3)
        return s.connect_ex(("127.0.0.1", port)) == 0


class LocalNode:
    """Starts Anvil, optionally forking a live testnet so its real state and chain id apply."""

    def __init__(self, fork: str | None = None, port: int = 8545):
        self.fork = fork
        self.port = port
        self.proc: subprocess.Popen | None = None
        self.chain_id = NETWORKS[fork]["chain_id"] if fork else NETWORKS["local"]["chain_id"]
        self.rpc = f"http://127.0.0.1:{port}"

    def start(self) -> "LocalNode":
        if _port_open(self.port):
            raise ChainBusy(f"port {self.port} is busy: another chain is running. "
                            f"Press Ctrl+C in its terminal, or run: lsof -ti:{self.port} | xargs kill")
        cmd = ["anvil", "--port", str(self.port), "--accounts", str(len(ROLES)), "--balance", "100000", "--silent",
               "--code-size-limit", "24576"]
        if self.fork:
            cmd += ["--fork-url", NETWORKS[self.fork]["rpc"]]
        self.proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        for _ in range(300):
            if _port_open(self.port):
                return self
            time.sleep(0.1)
        raise RuntimeError("anvil did not start")

    def stop(self) -> None:
        if self.proc and self.proc.poll() is None:
            os.killpg(self.proc.pid, signal.SIGTERM)
            self.proc.wait(timeout=10)

    def fund_actors(self) -> None:
        """A forked node keeps real account state, so give the demo wallets ETH explicitly."""
        w3 = Web3(Web3.HTTPProvider(self.rpc))
        for account in actors().values():
            w3.provider.make_request("anvil_setBalance", [account.address, hex(10**23)])


def deploy(rpc_url: str, chain_id: int, mnemonic: str = DEV_MNEMONIC, windows: dict | None = None) -> dict:
    """Runs the Foundry deployment with both entity keys and the approved zk model."""
    a = actors(mnemonic)
    model = QuantizedModel.from_json(zk_bridge.model_json())
    env = {
        **os.environ,
        "PETAHOUR_ADMIN_KEY": "0x" + bytes(a["petahour_admin"].key).hex(),
        "LABS_ADMIN_KEY": "0x" + bytes(a["labs_admin"].key).hex(),
        "FED_SIGNER_1": a["fed_petahour"].address,
        "FED_SIGNER_2": a["fed_nchc"].address,
        "FED_SIGNER_3": a["fed_odm"].address,
        "TREASURY": a["treasury"].address,
        "MATCHER": a["matcher"].address,
        "RELAY": a["relay"].address,
        "ZK_MODEL_HASH": str(zk_bridge.model_hash()),
        "ZK_THRESHOLD": str(model.threshold),
        "BUYER_FEE_BPS": str(BUYER_FEE_BPS),
        "SELLER_FEE_BPS": str(SELLER_FEE_BPS),
        "PASSPORT_FEE_PER_GPU_YEAR": str(PASSPORT_FEE_USD_PER_GPU_YEAR * 1_000_000),
        "PASSPORT_DISCOUNT_BPS": str(PASSPORT_DISCOUNT_BPS[LAUNCH_YEAR]),
        "LABS_CURATOR_FEE_BPS": str(LABS_CURATOR_FEE_BPS),
        "LABS_ORIGINATION_FEE_BPS": str(LABS_ORIGINATION_FEE_BPS),
        "LABS_LICENCE_BPS": str(LABS_LICENCE_BPS),
        **{k: str(v) for k, v in (windows or {}).items()},
    }
    DEPLOYMENTS.mkdir(exist_ok=True)
    REPORTS.mkdir(exist_ok=True)
    done = subprocess.run(
        ["forge", "script", "script/Deploy.s.sol:Deploy", "--rpc-url", rpc_url, "--broadcast", "--skip-simulation", "--slow"],
        cwd=ROOT, env=env, capture_output=True, text=True,
    )
    if done.returncode != 0:
        raise RuntimeError(f"deployment failed:\n{done.stdout[-1500:]}\n{done.stderr[-800:]}")
    return json.loads((DEPLOYMENTS / f"{chain_id}.json").read_text())
