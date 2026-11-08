// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAccessList, IComputePassport, IProofOfDeliveryOracle} from "../interfaces/IPetahour.sol";

/// @title GPU Warehouse Receipt
/// @notice Petahour Labs (offshore SPV) issues one ERC-721 per block of verified capacity held under
/// a bailment agreement. It reads Petahour core's passport and attestation data but never writes to
/// the onshore Taiwan venue's contracts. Every holder must pass the Labs allow-list.
contract GPUWarehouseReceipt is ERC721, AccessControl {
    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");

    struct Receipt {
        uint256 passportId;
        bytes32 sku;
        uint64 gpuHours;
        uint64 expiry;
        bytes32 bailmentHash; // hash of the off-chain UCC Article 7 bailment document
    }

    IAccessList public immutable labsAccess;
    IComputePassport public immutable passports;
    IProofOfDeliveryOracle public immutable oracle;

    uint256 public nextId = 1;
    mapping(uint256 => Receipt) private _receipts;
    mapping(uint256 => uint256) public encumberedHours;

    event ReceiptMinted(uint256 indexed id, address indexed to, uint256 indexed passportId, uint64 gpuHours, uint64 expiry);

    error NotEligible(address who);
    error NotAttested();
    error SkuMismatch();
    error BadExpiry();
    error ExceedsPhysicalCapacity(uint256 requested, uint256 available);

    constructor(address admin, IAccessList labsAccess_, IComputePassport passports_, IProofOfDeliveryOracle oracle_)
        ERC721("Petahour Labs GPU Warehouse Receipt", "GWR")
    {
        labsAccess = labsAccess_;
        passports = passports_;
        oracle = oracle_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ISSUER_ROLE, admin);
    }

    function mintReceipt(address to, Receipt calldata r) external onlyRole(ISSUER_ROLE) returns (uint256 id) {
        if (r.expiry <= block.timestamp) revert BadExpiry();
        if (!oracle.isAttested(r.passportId)) revert NotAttested();
        IComputePassport.Passport memory p = passports.getPassport(r.passportId);
        if (p.sku != r.sku) revert SkuMismatch();

        // A receipt cannot claim more GPU-hours than the host can physically produce by expiry.
        uint256 physical = uint256(p.gpuCount) * (r.expiry - block.timestamp) / 1 hours;
        uint256 used = encumberedHours[r.passportId];
        uint256 available = physical > used ? physical - used : 0;
        if (r.gpuHours > available) revert ExceedsPhysicalCapacity(r.gpuHours, available);

        encumberedHours[r.passportId] = used + r.gpuHours;
        id = nextId++;
        _receipts[id] = r;
        _mint(to, id);
        emit ReceiptMinted(id, to, r.passportId, r.gpuHours, r.expiry);
    }

    function getReceipt(uint256 id) external view returns (Receipt memory) {
        return _receipts[id];
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (to != address(0) && !labsAccess.isEligible(to)) revert NotEligible(to);
        return super._update(to, tokenId, auth);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
