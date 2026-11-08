pragma circom 2.1.6;

include "circomlib/circuits/poseidon.circom";
include "circomlib/circuits/bitify.circom";

// ReLU for a signed value in [-2^n, 2^n).
// Adding 2^n shifts the value to be non-negative, and bit n is then 1 exactly when in >= 0.
// Num2Bits also acts as the range check: an out-of-range value has no valid decomposition.
template SignedReLU(n) {
    signal input in;
    signal output out;
    component bits = Num2Bits(n + 1);
    bits.in <== in + (1 << n);
    out <== in * bits.out[n];
}

// Proves, without revealing telemetry or weights, that:
//   1. the private features open the commitment the TEE signed,
//   2. the private weights open the governance-approved model hash,
//   3. that model scores those features at or above the public threshold,
//   4. the measured uptime supports the uptime the seller claimed.
template DeliveryScore() {
    var NF = 6;
    var NH = 4;

    // Public: order here is the order of pubSignals in the Solidity verifier.
    signal input featureCommitment;
    signal input modelHash;
    signal input threshold;
    signal input claimedUptimeBps;
    signal input claimBinding;

    // Private.
    signal input features[NF];
    signal input salt;
    signal input w1[NH][NF];
    signal input b1[NH];
    signal input w2[NH];
    signal input b2;

    // Every feature fits in 14 bits, so the signed arithmetic below cannot wrap the field.
    component range[NF];
    for (var i = 0; i < NF; i++) {
        range[i] = Num2Bits(14);
        range[i].in <== features[i];
    }

    // (1) Open the telemetry commitment.
    component commit = Poseidon(NF + 1);
    for (var i = 0; i < NF; i++) {
        commit.inputs[i] <== features[i];
    }
    commit.inputs[NF] <== salt;
    commit.out === featureCommitment;

    // (2) Open the model hash. Poseidon takes at most 16 inputs, so 33 parameters go in chunks.
    component h0 = Poseidon(16);
    component h1 = Poseidon(16);
    component h2 = Poseidon(3);
    for (var k = 0; k < 16; k++) {
        h0.inputs[k] <== w1[k \ NF][k % NF];
    }
    for (var k = 16; k < 24; k++) {
        h1.inputs[k - 16] <== w1[k \ NF][k % NF];
    }
    for (var j = 0; j < NH; j++) {
        h1.inputs[8 + j] <== b1[j];
        h1.inputs[12 + j] <== w2[j];
    }
    h2.inputs[0] <== h0.out;
    h2.inputs[1] <== h1.out;
    h2.inputs[2] <== b2;
    h2.out === modelHash;

    // (3) Forward pass in exact integers.
    component relu[NH];
    signal products[NH][NF];
    signal partial[NH][NF + 1];
    signal outTerms[NH];
    signal running[NH + 1];
    running[0] <== b2;
    for (var j = 0; j < NH; j++) {
        partial[j][0] <== b1[j];
        for (var i = 0; i < NF; i++) {
            products[j][i] <== w1[j][i] * features[i];
            partial[j][i + 1] <== partial[j][i] + products[j][i];
        }
        relu[j] = SignedReLU(48);
        relu[j].in <== partial[j][NF];
        outTerms[j] <== w2[j] * relu[j].out;
        running[j + 1] <== running[j] + outTerms[j];
    }

    // score >= threshold. If the difference were negative it would wrap to a huge field element
    // with no 72-bit decomposition, so no proof could exist.
    component passes = Num2Bits(72);
    passes.in <== running[NH] - threshold;

    // (4) Measured uptime (feature 0) must be at least the claimed uptime.
    component uptimeOk = Num2Bits(14);
    uptimeOk.in <== features[0] - claimedUptimeBps;

    // (5) Bind the proof to one trade: it cannot be replayed on another claim.
    signal bindingSquare;
    bindingSquare <== claimBinding * claimBinding;
}

component main {public [featureCommitment, modelHash, threshold, claimedUptimeBps, claimBinding]} = DeliveryScore();
