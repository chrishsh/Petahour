// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IFederation} from "../interfaces/IPetahour.sol";

/// @title Verifier Federation
/// @notice M-of-N signer set shared by every oracle-style action in the protocol.
/// @dev Signatures must arrive sorted by ascending signer address. That single rule
///      makes duplicate-signature padding impossible without any storage writes.
contract Federation is AccessControl, IFederation {
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");

    mapping(address => bool) public isSigner;
    uint256 public signerCount;
    uint256 public threshold;

    event SignerAdded(address indexed signer);
    event SignerRemoved(address indexed signer);
    event ThresholdChanged(uint256 threshold);

    error InvalidThreshold();
    error AlreadySigner();
    error NotSigner();

    constructor(address admin, address[] memory signers, uint256 threshold_) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
        for (uint256 i; i < signers.length; ++i) {
            _addSigner(signers[i]);
        }
        _setThreshold(threshold_);
    }

    function addSigner(address signer) external onlyRole(GOVERNOR_ROLE) {
        _addSigner(signer);
    }

    function removeSigner(address signer) external onlyRole(GOVERNOR_ROLE) {
        if (!isSigner[signer]) revert NotSigner();
        if (signerCount - 1 < threshold) revert InvalidThreshold();
        isSigner[signer] = false;
        signerCount -= 1;
        emit SignerRemoved(signer);
    }

    function setThreshold(uint256 threshold_) external onlyRole(GOVERNOR_ROLE) {
        _setThreshold(threshold_);
    }

    /// @inheritdoc IFederation
    function verifyQuorum(bytes32 digest, bytes[] calldata sigs) external view returns (bool) {
        if (sigs.length < threshold) return false;
        address last;
        for (uint256 i; i < sigs.length; ++i) {
            (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, sigs[i]);
            if (err != ECDSA.RecoverError.NoError) return false;
            if (signer <= last) return false; // unsorted or duplicate
            if (!isSigner[signer]) return false;
            last = signer;
        }
        return true;
    }

    function _addSigner(address signer) internal {
        if (isSigner[signer]) revert AlreadySigner();
        isSigner[signer] = true;
        signerCount += 1;
        emit SignerAdded(signer);
    }

    function _setThreshold(uint256 threshold_) internal {
        if (threshold_ == 0 || threshold_ > signerCount) revert InvalidThreshold();
        threshold = threshold_;
        emit ThresholdChanged(threshold_);
    }
}
