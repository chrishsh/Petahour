#!/usr/bin/env bash
# Rebuilds the zk artifacts: circuit, trusted setup, proving key and Solidity verifier.
#
# PoC ONLY: this runs a single-party ceremony on your machine, so whoever runs it could keep the
# toxic waste and forge proofs. Production needs a public multi-party ceremony.
#
# The repository ships with artifacts already built. Run this only after changing the circuit.
# It writes a NEW verifier: redeploy contracts afterwards, and regenerate test fixtures.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=circuits/build
POWER=13
mkdir -p "$BUILD"
SNARK="node node_modules/snarkjs/build/cli.cjs"

echo "==> Training and quantizing the SLA model"
python -m petahour.zk_model

echo "==> Compiling circuit"
npx circom2 circuits/delivery_score.circom --r1cs --wasm --sym --O2 -o "$BUILD" -l node_modules

echo "==> Phase 1: powers of tau (2^$POWER)"
$SNARK powersoftau new bn128 "$POWER" "$BUILD/pot_0.ptau"
$SNARK powersoftau contribute "$BUILD/pot_0.ptau" "$BUILD/pot_1.ptau" --name="petahour-poc" -e="$(openssl rand -hex 32)"
$SNARK powersoftau prepare phase2 "$BUILD/pot_1.ptau" "$BUILD/pot_final.ptau"

echo "==> Phase 2: circuit-specific setup"
$SNARK groth16 setup "$BUILD/delivery_score.r1cs" "$BUILD/pot_final.ptau" "$BUILD/delivery_score_0.zkey"
$SNARK zkey contribute "$BUILD/delivery_score_0.zkey" "$BUILD/delivery_score_final.zkey" --name="petahour-poc" -e="$(openssl rand -hex 32)"

echo "==> Exporting verification key and Solidity verifier"
$SNARK zkey export verificationkey "$BUILD/delivery_score_final.zkey" "$BUILD/verification_key.json"
$SNARK zkey export solidityverifier "$BUILD/delivery_score_final.zkey" contracts/zk/Groth16Verifier.sol

echo "==> Removing intermediate files"
rm -f "$BUILD"/pot_*.ptau "$BUILD/delivery_score_0.zkey"
ls -la "$BUILD"
