"""Mutation check: injects one deliberate bug at a time and confirms the test suite notices.

A green test suite only proves the code passes the tests. This proves the tests can fail. Each
mutation removes a security control or breaks an amount. A mutant that survives means no test
protects that line, so the run fails. Mutants are applied to a throwaway copy of the repository.
"""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

MUTANTS = [
    ("core/DvPEscrow.sol", "buyer limit not enforced",
     "if (priceE6 > buy.limitPriceE6 || priceE6 < sell.limitPriceE6)", "if (priceE6 < sell.limitPriceE6)"),
    ("core/DvPEscrow.sol", "overfill not checked", "if (done > o.gpuHours) revert Overfill();", ""),
    ("core/DvPEscrow.sol", "order signature not checked",
     "if (err != ECDSA.RecoverError.NoError || signer != o.maker) revert BadSignature(o.maker);", "signer; err;"),
    ("core/DvPEscrow.sol", "TEE seal not checked",
     "if (!oracle.verifyTelemetrySeal(tradeId, t.passportId, telemetryRoot, featureCommitment, teeSig)) {",
     "if (false && !oracle.verifyTelemetrySeal(tradeId, t.passportId, telemetryRoot, featureCommitment, teeSig)) {"),
    ("core/DvPEscrow.sol", "zk proof not checked",
     "if (!adjudicator.verifyDelivery(tradeId, cl.featureCommitment, cl.uptimeBps, a, b, c)) revert InvalidProof();", ""),
    ("core/DvPEscrow.sol", "dispute window skipped",
     "if (block.timestamp < uint256(claims[tradeId].claimedAt) + params.disputeWindow) revert TooEarly();", ""),
    ("core/DvPEscrow.sol", "fee over-credited", "free[treasury] += buyerFeeDue + sellerFeeDue;",
     "free[treasury] += buyerFeeDue + sellerFeeDue + 1;"),
    ("core/DvPEscrow.sol", "seller fee not charged", "free[t.seller] += paid - sellerFeeDue + collateral - credit;",
     "free[t.seller] += paid + collateral - credit;"),
    ("core/DvPEscrow.sol", "seller fee not pro rata", "uint256 sellerFeeDue = t.sellerFee * uptime / BPS;",
     "uint256 sellerFeeDue = t.sellerFee;"),
    ("core/DvPEscrow.sol", "buyer fee not locked", "_lock(buyer, notional + buyerFee);", "_lock(buyer, notional);"),
    ("core/DvPEscrow.sol", "seller fee cap removed", "|| p.sellerFeeBps > 1_000", ""),
    ("core/DvPEscrow.sol", "lapsed passport can sell",
     "if (passports.paidUntil(sell.passportId) < end) revert PassportFeeDue();", ""),
    ("core/ComputePassport.sol", "passport fee not collected", "token.safeTransferFrom(payer, treasury, fee);", ""),
    ("core/ComputePassport.sol", "launch discount can be stockpiled",
     "if (paidUntil[id] > block.timestamp + TERM) revert PaidTooFarAhead();", ""),
    ("core/ComputePassport.sol", "renewal loses paid time", "if (start < block.timestamp) start = uint64(block.timestamp);",
     "start = uint64(block.timestamp);"),
    ("core/ComputePassport.sol", "discount above 100% accepted", "if (discountBps_ > BPS) revert InvalidFee();", ""),
    ("core/DvPEscrow.sol", "default fund cover dropped",
     "free[t.buyer] += refund + fromCollateral + fromFund;", "free[t.buyer] += refund + fromCollateral;"),
    ("core/Federation.sol", "duplicate signers accepted", "if (signer <= last) return false; // unsorted or duplicate", ""),
    ("core/CapacityPool.sol", "oversell guard removed", "if (used + gpus > cap) revert Oversold(h);", ""),
    ("core/CapacityPool.sol", "bit-packing shift broken",
     "uint256 shift = (h % HOURS_PER_SLOT) * BITS;", "uint256 shift = (h % HOURS_PER_SLOT);"),
    ("core/CapacityPool.sol", "16-bit lane overflow allowed", "if (cap > MASK) cap = MASK;", ""),
    ("core/ProofOfDeliveryOracle.sol", "attestation replay allowed", "if (nonceUsed[nonce]) revert NonceReused();", ""),
    ("zk/ZkDeliveryAdjudicator.sol", "proof not bound to trade",
     "uint256(claimedUptimeBps), tradeId];", "uint256(claimedUptimeBps), 1];"),
    ("core/TCPIOracle.sol", "deviation guard removed", "if (bps > maxDeviationBps) revert DeviationTooLarge(bps);", ""),
    ("core/TCPIOracle.sol", "audit hash not signed",
     "abi.encode(PUBLISH_TYPEHASH, indexId, day, answer, volumeGpuHours, methodologyHash, inputsHash, emergency)",
     "abi.encode(PUBLISH_TYPEHASH, indexId, day, answer, volumeGpuHours, methodologyHash, bytes32(0), emergency)"),
    ("labs/TCPIPriceAdapter.sol", "stale prices accepted", "if (age > maxStaleness) revert StalePrice(age);", ""),
    ("labs/GPUWarehouseReceipt.sol", "receipt transfer unrestricted",
     "if (to != address(0) && !labsAccess.isEligible(to)) revert NotEligible(to);", ""),
    ("labs/ComputeCreditVault.sol", "bad debt charged repeatedly", "badDebtBooked = badDebt; // a shortfall stays with the seniors; new capital never inherits it", ""),
    ("labs/IsolatedLendingMarket.sol", "origination fee not taken from the loan", "loanToken.safeTransfer(msg.sender, assets - fee);",
     "loanToken.safeTransfer(msg.sender, assets);"),
    ("labs/IsolatedLendingMarket.sol", "rollovers pay origination again", "feePaidUpTo[who] = balance;", ""),
    ("labs/IsolatedLendingMarket.sol", "licence clock loses time", "loanSecondsStored = loanSeconds();", ""),
    ("labs/ComputeCreditVault.sol", "a senior loss comes off the mark", "w.mark = highWater > w.absorbed ? highWater - w.absorbed : 0;",
     "w.mark = highWater > newLoss ? highWater - newLoss : 0;"),
    ("labs/ComputeCreditVault.sol", "a covered loss stays on the mark", "w.mark = highWater > w.absorbed ? highWater - w.absorbed : 0;", "w.mark = highWater;"),
    ("labs/ComputeCreditVault.sol", "the mark falls with the vault", "highWater = w.fee != 0 ? w.pool : w.mark;", "highWater = w.pool;"),
    ("labs/ComputeCreditVault.sol", "the curator is paid twice for one gain", "highWater = w.fee != 0 ? w.pool : w.mark;", "highWater = w.mark;"),
    ("labs/ComputeCreditVault.sol", "curator paid double", "* curatorFeeBps / BPS;", "* curatorFeeBps * 2 / BPS;"),
    ("labs/ComputeCreditVault.sol", "deposits counted as income", "super._deposit(caller, receiver, assets, shares);\n        highWater += assets;",
     "super._deposit(caller, receiver, assets, shares);"),
    ("labs/ComputeCreditVault.sol", "withdrawals not taken off the mark",
     "super._withdraw(caller, receiver, owner, assets, shares);\n        highWater -= assets < highWater ? assets : highWater;",
     "super._withdraw(caller, receiver, owner, assets, shares);"),
    ("labs/ComputeCreditVault.sol", "quoted value ignores the fee",
     "return shares.mulDiv(w.senior + 1, totalSupply() + _feeShares(w) + 10 ** _decimalsOffset(), rounding);",
     "return shares.mulDiv(w.senior + 1, totalSupply() + 10 ** _decimalsOffset(), rounding);"),
    ("labs/ComputeCreditVault.sol", "deposit price ignores the fee",
     "return assets.mulDiv(totalSupply() + _feeShares(w) + 10 ** _decimalsOffset(), w.senior + 1, rounding);",
     "return assets.mulDiv(totalSupply() + 10 ** _decimalsOffset(), w.senior + 1, rounding);"),
    ("labs/ComputeCreditVault.sol", "last lender leaves the fee behind", "_settle(); // otherwise the last lender out would leave the curator's fee behind", ""),
    ("labs/ComputeCreditVault.sol", "seniors earn without limit", "if (beforeExcess > cap) w.excess = beforeExcess - cap;", ""),
    ("labs/ComputeCreditVault.sol", "the curator's fee comes out of the seniors' yield", "mulDiv(hurdle(), WAD * offset) - 1 + w.fee;", "mulDiv(hurdle(), WAD * offset) - 1;"),
    ("labs/ComputeCreditVault.sol", "losses never reach first-loss capital", "w.absorbed = newLoss < capital ? newLoss : capital;", "w.absorbed = 0;"),
    ("labs/ComputeCreditVault.sol", "the excess vanishes", "w.firstLoss = capital + w.excess;", "w.firstLoss = capital;"),
    ("labs/ComputeCreditVault.sol", "senior value includes first-loss money", "return waterfall().senior;", "return waterfall().pool;"),
    ("labs/ComputeCreditVault.sol", "the yield hurdle never rises",
     "return hurdleIndex + hurdleIndex.mulDiv(seniorYieldBps * (block.timestamp - lastSettled), BPS * YEAR);", "return hurdleIndex;"),
    ("labs/ComputeCreditVault.sol", "settling loses the yield earned so far", "hurdleIndex = hurdle();\n        lastSettled = block.timestamp;", "lastSettled = block.timestamp;"),
    ("labs/ComputeCreditVault.sol", "settling counts the same days twice", "hurdleIndex = hurdle();\n        lastSettled = block.timestamp;", "hurdleIndex = hurdle();"),
    ("labs/ComputeCreditVault.sol", "dust stays owed to nobody", "uint256 capital = tranche.totalSupply() == 0 ? 0 : firstLossCapital;", "uint256 capital = firstLossCapital;"),
    ("labs/ComputeCreditVault.sol", "the hurdle ignores interest kept by seniors", "if (price > hurdleIndex) hurdleIndex = price;", ""),
    ("labs/ComputeCreditVault.sol", "the next senior inherits an old hurdle", "if (totalSupply() == 0) return WAD;", ""),
    ("labs/ComputeCreditVault.sol", "a deposit skips settlement", "_settle(); // restarts the hurdle if the last senior has left", ""),
    ("labs/ComputeCreditVault.sol", "a late investor catches past earnings", "vault.settle();\n        super._deposit(caller, receiver, assets, shares);", "super._deposit(caller, receiver, assets, shares);"),
    ("labs/ComputeCreditVault.sol", "anyone can draw first-loss money", "function releaseFirstLoss(uint256 assets) external onlyTranche nonReentrant {",
     "function releaseFirstLoss(uint256 assets) external nonReentrant {"),
    ("labs/ComputeCreditVault.sol", "anyone can book first-loss capital", "function fundFirstLoss(uint256 assets) external onlyTranche nonReentrant {",
     "function fundFirstLoss(uint256 assets) external nonReentrant {"),
    ("labs/ComputeCreditVault.sol", "first-loss capital not recorded", "firstLossCapital += assets;\n        highWater += assets;", "highWater += assets;"),
    ("labs/ComputeCreditVault.sol", "first-loss money counted as income", "firstLossCapital += assets;\n        highWater += assets;", "firstLossCapital += assets;"),
    ("labs/ComputeCreditVault.sol", "first-loss exit not recorded", "firstLossCapital -= assets;\n", "\n"),
    ("labs/ComputeCreditVault.sol", "first-loss exit stays on the mark",
     "firstLossCapital -= assets;\n        highWater -= assets < highWater ? assets : highWater;", "firstLossCapital -= assets;"),
    ("labs/ComputeCreditVault.sol", "first-loss can leave ahead of a loss", "_settle();\n        firstLossCapital -= assets;", "firstLossCapital -= assets;"),
    ("labs/ComputeCreditVault.sol", "first-loss exit raises no cash", "_raiseCash(assets);\n        IERC20(asset()).safeTransfer(msg.sender, assets);", "IERC20(asset()).safeTransfer(msg.sender, assets);"),
    ("labs/ComputeCreditVault.sol", "a shortfall follows new first-loss money", "badDebtBooked = badDebt; // a shortfall stays with the seniors; new capital never inherits it", "badDebtBooked += w.absorbed;"),
    ("labs/ComputeCreditVault.sol", "the tranche can be rebound", "if (address(vault) != address(0)) revert AlreadyBound();", ""),
    ("labs/ComputeCreditVault.sol", "anyone can bind the tranche", "function bind(ComputeCreditVault vault_) external onlyRole(DEFAULT_ADMIN_ROLE) {", "function bind(ComputeCreditVault vault_) external {"),
    ("labs/ComputeCreditVault.sol", "anyone can lend the pool", "function allocate(uint256 assets) external onlyRole(CURATOR_ROLE) {", "function allocate(uint256 assets) external {"),
    ("labs/ComputeCreditVault.sol", "anyone can pull the pool from the market", "function deallocate(uint256 assets) external onlyRole(CURATOR_ROLE) {", "function deallocate(uint256 assets) external {"),
    ("labs/ComputeCreditVault.sol", "anyone can burn valuable first-loss shares", "if (vault.firstLossClaim() != 0) revert StillHasValue();", ""),
    ("labs/ComputeCreditVault.sol", "clearing shares moves a loss onto seniors", "vault.settle();\n        if (vault.firstLossClaim() != 0) revert StillHasValue();", "if (vault.firstLossClaim() != 0) revert StillHasValue();"),
    ("labs/ComputeCreditVault.sol", "any senior yield accepted", "if (seniorYieldBps_ == 0 || seniorYieldBps_ > BPS) revert InvalidYield();", ""),
    ("labs/ComputeCreditVault.sol", "fee recipient can block depositors", "to != address(0) && to != feeRecipient && !labsAccess.isEligible(to)",
     "to != address(0) && !labsAccess.isEligible(to)"),
    ("labs/LabsTreasury.sol", "licence paid repeatedly", "licencePaid += paid;", ""),
    ("labs/LabsTreasury.sol", "Labs can withdraw ahead of the licence", "if (due != 0) revert LicenceUnpaid(due);", ""),
    ("labs/LabsTreasury.sol", "withdrawal skips the licence", "_clearLicence();\n        token.safeTransfer(to, amount);", "token.safeTransfer(to, amount);"),
    ("labs/LabsTreasury.sol", "Labs co-invests ahead of the licence", "_clearLicence();\n        FirstLossTranche tranche", "FirstLossTranche tranche"),
    ("labs/LabsTreasury.sol", "anyone can co-invest Labs' money", "function investFirstLoss(uint256 assets) external onlyRole(DEFAULT_ADMIN_ROLE) returns",
     "function investFirstLoss(uint256 assets) external returns"),
    ("labs/LabsTreasury.sol", "anyone can pull Labs' co-investment", "function redeemFirstLoss(uint256 shares) external onlyRole(DEFAULT_ADMIN_ROLE) returns",
     "function redeemFirstLoss(uint256 shares) external returns"),
    ("labs/LabsTreasury.sol", "anyone can withdraw Labs' money", "function withdraw(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {",
     "function withdraw(address to, uint256 amount) external {"),
    ("labs/LabsTreasury.sol", "treasury can be rebound", "if (address(market) != address(0)) revert AlreadyBound();", ""),
    ("labs/IsolatedLendingMarket.sol", "healthy positions liquidatable",
     "if (_isHealthy(borrower)) revert PositionHealthy();", ""),
    ("core/MemberRegistry.sol", "frozen wallets stay eligible", "&& !m.frozen", ""),
    ("core/ComputePassport.sol", "passport transferable",
     "if (from != address(0) && to != address(0)) revert NonTransferable();", "from;"),
]


def main() -> int:
    work = Path(tempfile.mkdtemp(prefix="petahour-mutants-"))
    for item in ["contracts", "test", "script", "foundry.toml", "remappings.txt"]:
        src = ROOT / item
        if src.is_dir():
            shutil.copytree(src, work / item)
        elif src.exists():
            shutil.copy(src, work / item)
    (work / "lib").symlink_to(ROOT / "lib")
    (work / "node_modules").symlink_to(ROOT / "node_modules")
    (work / "deployments").mkdir(exist_ok=True)
    (work / "reports").mkdir(exist_ok=True)

    # A mutant only counts as killed if the unmodified code passes. Without this baseline, one
    # already-failing test would make every mutant look caught.
    baseline = subprocess.run(["forge", "test"], cwd=work, capture_output=True, text=True)
    if baseline.returncode != 0:
        print("baseline is not green, so mutation results would mean nothing:")
        print(baseline.stdout[-1500:])
        return 2
    print("  baseline      all tests pass on unmodified code")

    results = []
    for rel, name, old, new in MUTANTS:
        path = work / "contracts" / rel
        original = path.read_text()
        if original.count(old) < 1:
            print(f"  MISSING  {name}: pattern not found in {rel}")
            results.append({"mutant": name, "file": rel, "result": "pattern-missing"})
            continue
        path.write_text(original.replace(old, new, 1))
        run = subprocess.run(["forge", "test"], cwd=work, capture_output=True, text=True)
        path.write_text(original)
        output = run.stdout + run.stderr
        if "Compiler run failed" in output or "Compilation failed" in output:
            verdict = "compile-error"
        else:
            verdict = "killed" if run.returncode != 0 else "SURVIVED"
        print(f"  {verdict:<13} {name}")
        results.append({"mutant": name, "file": rel, "result": verdict})

    shutil.rmtree(work, ignore_errors=True)
    killed = sum(r["result"] == "killed" for r in results)
    out = ROOT / "reports" / "mutation_results.json"
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps({"killed": killed, "total": len(results), "mutants": results}, indent=2))
    print(f"\nmutation score: {killed}/{len(results)}")
    return 0 if killed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
