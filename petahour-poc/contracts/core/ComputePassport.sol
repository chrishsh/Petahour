// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAccessList, IComputePassport, IFederation} from "../interfaces/IPetahour.sol";

/// @title Compute Passport
/// @notice The compute-market equivalent of a bill of lading: one non-transferable ERC-721 per
/// verified host. Minting needs a federation quorum, so a seller cannot self-certify hardware.
/// The seller pays a yearly fee per GPU, and a Passport that has lapsed cannot sell.
contract ComputePassport is ERC721, AccessControl, EIP712, IComputePassport {
    using SafeERC20 for IERC20;

    bytes32 public constant SUSPENDER_ROLE = keccak256("SUSPENDER_ROLE");
    bytes32 public constant MINT_TYPEHASH = keccak256(
        "MintPassport(address to,bytes32 hostIdHash,address teeKey,bytes32 sku,uint32 gpuCount,uint16 pueMilli,uint16 slaBps,bytes32 gridZone,bytes32 topology,bytes32 metadataHash)"
    );

    uint64 public constant TERM = 365 days;
    uint256 private constant BPS = 10_000;

    IFederation public immutable federation;
    IAccessList public immutable access;
    IERC20 public immutable token;
    address public immutable treasury;

    uint64 public feePerGpuYear; // in token units
    uint16 public discountBps; // 5,000 is the half-price launch offer

    uint256 public nextId = 1;
    mapping(uint256 => uint64) public paidUntil;
    mapping(uint256 => Passport) private _passports;
    mapping(bytes32 => bool) public hostRegistered;
    mapping(address => bool) public teeKeyRegistered;

    event PassportMinted(uint256 indexed id, address indexed owner, bytes32 sku, uint32 gpuCount, address teeKey);
    event PassportSuspended(uint256 indexed id, bytes32 reason);
    event PassportReinstated(uint256 indexed id);
    event PassportFeePaid(uint256 indexed id, address indexed payer, uint256 amount, uint64 paidUntil);
    event FeeChanged(uint64 feePerGpuYear, uint16 discountBps);

    error QuorumNotMet();
    error NotEligible(address who);
    error HostAlreadyRegistered();
    error TeeKeyAlreadyRegistered();
    error InvalidPassport();
    error NonTransferable();
    error InvalidFee();
    error PaidTooFarAhead();

    constructor(
        address admin,
        IFederation federation_,
        IAccessList access_,
        IERC20 token_,
        address treasury_,
        uint64 feePerGpuYear_,
        uint16 discountBps_
    )
        ERC721("Petahour Compute Passport", "PHPP")
        EIP712("Petahour Compute Passport", "1")
    {
        federation = federation_;
        access = access_;
        token = token_;
        treasury = treasury_;
        _setFee(feePerGpuYear_, discountBps_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function mintPassport(address to, Passport calldata p, bytes[] calldata sigs) external returns (uint256 id) {
        if (!access.isEligible(to)) revert NotEligible(to);
        if (p.teeKey == address(0) || p.gpuCount == 0 || p.suspended) revert InvalidPassport();
        if (hostRegistered[p.hostIdHash]) revert HostAlreadyRegistered();
        if (teeKeyRegistered[p.teeKey]) revert TeeKeyAlreadyRegistered();

        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    MINT_TYPEHASH,
                    to,
                    p.hostIdHash,
                    p.teeKey,
                    p.sku,
                    p.gpuCount,
                    p.pueMilli,
                    p.slaBps,
                    p.gridZone,
                    p.topology,
                    p.metadataHash
                )
            )
        );
        if (!federation.verifyQuorum(digest, sigs)) revert QuorumNotMet();

        hostRegistered[p.hostIdHash] = true;
        teeKeyRegistered[p.teeKey] = true;
        id = nextId++;
        _passports[id] = p;
        _mint(to, id);
        emit PassportMinted(id, to, p.sku, p.gpuCount, p.teeKey);
        _payTerm(id, to, p.gpuCount);
    }

    /// @notice Buys one more year. Anyone may pay, but no more than two years can be held at once,
    /// so a launch discount cannot be stockpiled.
    function renew(uint256 id) external {
        _requireOwned(id);
        if (paidUntil[id] > block.timestamp + TERM) revert PaidTooFarAhead();
        _payTerm(id, msg.sender, _passports[id].gpuCount);
    }

    function annualFee(uint32 gpuCount) public view returns (uint256) {
        return uint256(gpuCount) * feePerGpuYear * (BPS - discountBps) / BPS;
    }

    function setFee(uint64 feePerGpuYear_, uint16 discountBps_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setFee(feePerGpuYear_, discountBps_);
    }

    function _setFee(uint64 feePerGpuYear_, uint16 discountBps_) private {
        if (discountBps_ > BPS) revert InvalidFee();
        feePerGpuYear = feePerGpuYear_;
        discountBps = discountBps_;
        emit FeeChanged(feePerGpuYear_, discountBps_);
    }

    function _payTerm(uint256 id, address payer, uint32 gpus) private {
        uint64 start = paidUntil[id];
        if (start < block.timestamp) start = uint64(block.timestamp);
        uint64 until = start + TERM;
        paidUntil[id] = until;
        uint256 fee = annualFee(gpus);
        token.safeTransferFrom(payer, treasury, fee);
        emit PassportFeePaid(id, payer, fee, until);
    }

    function getPassport(uint256 id) external view returns (Passport memory) {
        return _passports[id];
    }

    function suspend(uint256 id, bytes32 reason) external onlyRole(SUSPENDER_ROLE) {
        _passports[id].suspended = true;
        emit PassportSuspended(id, reason);
    }

    function reinstate(uint256 id) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _passports[id].suspended = false;
        emit PassportReinstated(id);
    }

    function ownerOf(uint256 id) public view override(ERC721, IComputePassport) returns (address) {
        return super.ownerOf(id);
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) revert NonTransferable();
        return super._update(to, tokenId, auth);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
