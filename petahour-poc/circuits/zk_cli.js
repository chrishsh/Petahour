#!/usr/bin/env node
// Bridge between the Python services and the JavaScript zk stack.
// Reads one JSON request on stdin, writes one JSON response on stdout.
//   {"cmd":"commit","features":[...],"salt":"123"}             -> {"commitment":"..."}
//   {"cmd":"modelhash","model":{...}}                          -> {"modelHash":"..."}
//   {"cmd":"prove","features":[...],"salt":"..","model":{..},
//    "claimedUptimeBps":9950,"tradeId":"1"}                     -> {"a":[..],"b":[[..]],"c":[..],"publicSignals":[..],"ms":N}
const path = require("path");
const fs = require("fs");
const { buildPoseidon } = require("circomlibjs");
const snarkjs = require("snarkjs");

const BUILD = path.join(__dirname, "build");
const WASM = path.join(BUILD, "delivery_score_js", "delivery_score.wasm");
const ZKEY = path.join(BUILD, "delivery_score_final.zkey");
const VKEY = path.join(BUILD, "verification_key.json");

// BN254 scalar field. Negative weights are represented as p - |w|.
const P = 21888242871839275222246405745257275088548364400416034343698204186575808495617n;
const field = (x) => ((BigInt(x) % P) + P) % P;

function flatParams(model) {
  return [...model.w1.flat(), ...model.b1, ...model.w2, model.b2].map(field);
}

function modelHash(poseidon, model) {
  const flat = flatParams(model);
  const h0 = poseidon(flat.slice(0, 16));
  const h1 = poseidon(flat.slice(16, 32));
  const out = poseidon([h0, h1, flat[32]]);
  return poseidon.F.toString(out);
}

function commitment(poseidon, features, salt) {
  return poseidon.F.toString(poseidon([...features.map(field), field(salt)]));
}

async function prove(poseidon, req) {
  const started = Date.now();
  const m = req.model;
  const input = {
    featureCommitment: commitment(poseidon, req.features, req.salt),
    modelHash: modelHash(poseidon, m),
    threshold: field(m.threshold).toString(),
    claimedUptimeBps: String(req.claimedUptimeBps),
    claimBinding: String(req.tradeId),
    features: req.features.map(String),
    salt: field(req.salt).toString(),
    w1: m.w1.map((row) => row.map((w) => field(w).toString())),
    b1: m.b1.map((b) => field(b).toString()),
    w2: m.w2.map((w) => field(w).toString()),
    b2: field(m.b2).toString(),
  };
  const { proof, publicSignals } = await snarkjs.groth16.fullProve(input, WASM, ZKEY);
  return {
    // Solidity expects each G2 coordinate pair in reversed order.
    a: [proof.pi_a[0], proof.pi_a[1]],
    b: [
      [proof.pi_b[0][1], proof.pi_b[0][0]],
      [proof.pi_b[1][1], proof.pi_b[1][0]],
    ],
    c: [proof.pi_c[0], proof.pi_c[1]],
    publicSignals,
    raw: proof,
    ms: Date.now() - started,
  };
}

async function main() {
  const req = JSON.parse(fs.readFileSync(0, "utf8"));
  const poseidon = await buildPoseidon();
  let res;
  switch (req.cmd) {
    case "commit":
      res = { commitment: commitment(poseidon, req.features, req.salt) };
      break;
    case "modelhash":
      res = { modelHash: modelHash(poseidon, req.model) };
      break;
    case "prove":
      res = await prove(poseidon, req);
      break;
    case "verify":
      res = { ok: await snarkjs.groth16.verify(JSON.parse(fs.readFileSync(VKEY)), req.publicSignals, req.proof) };
      break;
    default:
      throw new Error(`unknown command ${req.cmd}`);
  }
  process.stdout.write(JSON.stringify(res));
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    process.stderr.write(String(e && e.message ? e.message : e));
    process.exit(1);
  });
