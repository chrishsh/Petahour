// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IComputePassport, IFederation, IProofOfDeliveryOracle} from "../interfaces/IPetahour.sol";

/// @title Proof-of-Delivery Oracle Relay
/// @notice Two facts reach the chain through this contract:
///   1. Attestation. A federation quorum states that the host passed NVIDIA remote attestation.
///      NRAS tokens are ES384 (P-384) JWTs and the EVM has no P-384 precompile, so the token is
///      verified off-chain by each federation node and only its hash is anchored here.
///   2. Telemetry seal. The key sealed inside the attested confidential VM signs the telemetry
///      commitments for a trade. That secp256k1 signature IS checked on-chain, on every claim.
contract ProofOfDeliveryOracle is EIP712, IProofOfDeliveryOracle {
    bytes32 public constant ATTESTATION_TYPEHASH = keccak256(
        "Attestation(uint256 passportId,bytes32 measurementHash,bytes32 eatHash,bytes32 nonce,uint64 validUntil)"
    );
    bytes32 public constant SEAL_TYPEHASH =
        keccak256("TelemetrySeal(uint256 tradeId,uint256 passportId,bytes32 telemetryRoot,uint256 featureCommitment)");

    struct Attestation {
        bytes32 measurementHash; // golden measurement / RIM digest
        bytes32 eatHash; // hash of the NRAS EAT token that was verified off-chain
        uint64 attestedAt;
        uint64 validUntil;
    }

    IFederation public immutable federation;
    IComputePassport public immutable passports;

    mapping(uint256 => Attestation) public attestations;
    mapping(bytes32 => bool) public nonceUsed;

    event AttestationRecorded(uint256 indexed passportId, bytes32 measurementHash, bytes32 eatHash, uint64 validUntil);

    error QuorumNotMet();
    error NonceReused();
    error AlreadyExpired();

    constructor(IFederation federation_, IComputePassport passports_) EIP712("Petahour Proof of Delivery", "1") {
        federation = federation_;
        passports = passports_;
    }

    function submitAttestation(
        uint256 passportId,
        bytes32 measurementHash,
        bytes32 eatHash,
        bytes32 nonce,
        uint64 validUntil,
        bytes[] calldata sigs
    ) external {
        if (nonceUsed[nonce]) revert NonceReused();
        if (validUntil <= block.timestamp) revert AlreadyExpired();
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(ATTESTATION_TYPEHASH, passportId, measurementHash, eatHash, nonce, validUntil))
        );
        if (!federation.verifyQuorum(digest, sigs)) revert QuorumNotMet();

        nonceUsed[nonce] = true;
        attestations[passportId] = Attestation(measurementHash, eatHash, uint64(block.timestamp), validUntil);
        emit AttestationRecorded(passportId, measurementHash, eatHash, validUntil);
    }

    /// @inheritdoc IProofOfDeliveryOracle
    function isAttested(uint256 passportId) public view returns (bool) {
        return attestations[passportId].validUntil >= block.timestamp && !passports.getPassport(passportId).suspended;
    }

    /// @inheritdoc IProofOfDeliveryOracle
    function attestedUntil(uint256 passportId) external view returns (uint64) {
        return attestations[passportId].validUntil;
    }

    /// @inheritdoc IProofOfDeliveryOracle
    function verifyTelemetrySeal(
        uint256 tradeId,
        uint256 passportId,
        bytes32 telemetryRoot,
        uint256 featureCommitment,
        bytes calldata teeSig
    ) external view returns (bool) {
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(SEAL_TYPEHASH, tradeId, passportId, telemetryRoot, featureCommitment))
        );
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, teeSig);
        return err == ECDSA.RecoverError.NoError && signer == passports.getPassport(passportId).teeKey;
    }
}
