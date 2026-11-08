// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IGroth16Verifier, IZkDeliveryAdjudicator} from "../interfaces/IPetahour.sol";

/// @title zkML Delivery Adjudicator
/// @notice Wraps the generated Groth16 verifier and pins what a proof must be about.
/// The caller supplies only the proof: the commitment and claimed uptime come from the escrow's
/// own storage, and the model and threshold come from here, so a proof made for a different
/// trade, a different model or a lower bar cannot verify.
/// @dev zkML sits on the dispute path only, and only over a tiny scoring model. It never meters
/// GPU-hours, which the report rules out on overhead grounds (1,000x-10,000x).
contract ZkDeliveryAdjudicator is AccessControl, IZkDeliveryAdjudicator {
    bytes32 public constant MODEL_ROLE = keccak256("MODEL_ROLE");

    IGroth16Verifier public immutable verifier;
    uint256 public modelHash;
    uint256 public threshold;

    event ModelChanged(uint256 modelHash, uint256 threshold);

    constructor(address admin, IGroth16Verifier verifier_, uint256 modelHash_, uint256 threshold_) {
        verifier = verifier_;
        modelHash = modelHash_;
        threshold = threshold_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MODEL_ROLE, admin);
    }

    /// @notice Weights are private circuit inputs bound by this hash, so a retrained model
    /// needs only this call, not a new trusted setup.
    function setModel(uint256 modelHash_, uint256 threshold_) external onlyRole(MODEL_ROLE) {
        modelHash = modelHash_;
        threshold = threshold_;
        emit ModelChanged(modelHash_, threshold_);
    }

    /// @inheritdoc IZkDeliveryAdjudicator
    function verifyDelivery(
        uint256 tradeId,
        uint256 featureCommitment,
        uint32 claimedUptimeBps,
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c
    ) external view returns (bool) {
        uint256[5] memory pub = [featureCommitment, modelHash, threshold, uint256(claimedUptimeBps), tradeId];
        return verifier.verifyProof(a, b, c, pub);
    }
}
