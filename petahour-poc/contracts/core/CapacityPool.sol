// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ICapacityPool, IComputePassport, IProofOfDeliveryOracle} from "../interfaces/IPetahour.sol";

/// @title Verified Inventory Pool
/// @notice Holds availability windows for attested hosts and enforces the one physical rule of
/// this market: the same GPU-hour cannot be sold twice. A GPU-hour is perishable, so allocation
/// is tracked per clock hour, sixteen hours packed into each storage slot.
contract CapacityPool is AccessControl, ICapacityPool {
    bytes32 public constant ESCROW_ROLE = keccak256("ESCROW_ROLE");
    uint256 private constant HOURS_PER_SLOT = 16;
    uint256 private constant BITS = 16;
    uint256 private constant MASK = 0xFFFF;

    struct Listing {
        uint256 passportId;
        uint64 availableFrom;
        uint64 availableTo;
    }

    IComputePassport public immutable passports;
    IProofOfDeliveryOracle public immutable oracle;

    uint256 public nextListingId = 1;
    mapping(uint256 => Listing) public listings;
    /// passportId => slot index (hourIndex / 16) => sixteen packed uint16 GPU counts
    mapping(uint256 => mapping(uint256 => uint256)) private _allocated;

    event CapacityListed(uint256 indexed listingId, uint256 indexed passportId, uint64 availableFrom, uint64 availableTo);
    event CapacityConsumed(uint256 indexed listingId, uint256 indexed passportId, uint64 gpuHours, uint64 start, uint32 windowHours);

    error NotPassportOwner();
    error NotAttested();
    error BadWindow();
    error ListingMismatch();
    error OutsideListing();
    error Oversold(uint256 hourIndex);

    constructor(address admin, IComputePassport passports_, IProofOfDeliveryOracle oracle_) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        passports = passports_;
        oracle = oracle_;
    }

    function listCapacity(uint256 passportId, uint64 availableFrom, uint64 availableTo)
        external
        returns (uint256 listingId)
    {
        if (passports.ownerOf(passportId) != msg.sender) revert NotPassportOwner();
        if (!oracle.isAttested(passportId)) revert NotAttested();
        if (availableTo <= availableFrom) revert BadWindow();
        listingId = nextListingId++;
        listings[listingId] = Listing(passportId, availableFrom, availableTo);
        emit CapacityListed(listingId, passportId, availableFrom, availableTo);
    }

    /// @inheritdoc ICapacityPool
    function consume(uint256 listingId, uint256 passportId, uint64 gpuHours, uint64 start, uint32 windowHours)
        external
        onlyRole(ESCROW_ROLE)
    {
        Listing memory l = listings[listingId];
        if (l.passportId != passportId || passportId == 0) revert ListingMismatch();
        if (windowHours == 0 || gpuHours == 0) revert BadWindow();
        uint256 end = uint256(start) + uint256(windowHours) * 1 hours;
        if (start < l.availableFrom || end > l.availableTo) revert OutsideListing();

        // GPUs held in every hour of the window, rounded up.
        uint256 gpus = (uint256(gpuHours) + windowHours - 1) / windowHours;
        uint256 cap = passports.getPassport(passportId).gpuCount;
        if (cap > MASK) cap = MASK; // each hour is a 16-bit lane and must never carry into the next
        uint256 firstHour = uint256(start) / 1 hours;

        // Walk the window slot by slot, so a 24-hour trade touches 2-3 slots rather than 24.
        uint256 h = firstHour;
        uint256 stop = firstHour + windowHours;
        while (h < stop) {
            uint256 slotIndex = h / HOURS_PER_SLOT;
            uint256 packed = _allocated[passportId][slotIndex];
            uint256 slotEnd = (slotIndex + 1) * HOURS_PER_SLOT;
            uint256 limit = stop < slotEnd ? stop : slotEnd;
            for (; h < limit; ++h) {
                uint256 shift = (h % HOURS_PER_SLOT) * BITS;
                uint256 used = (packed >> shift) & MASK;
                if (used + gpus > cap) revert Oversold(h);
                packed = (packed & ~(MASK << shift)) | ((used + gpus) << shift);
            }
            _allocated[passportId][slotIndex] = packed;
        }
        emit CapacityConsumed(listingId, passportId, gpuHours, start, windowHours);
    }

    /// @notice GPUs already sold for the given clock hour.
    function allocatedAt(uint256 passportId, uint256 hourIndex) external view returns (uint256) {
        uint256 packed = _allocated[passportId][hourIndex / HOURS_PER_SLOT];
        return (packed >> ((hourIndex % HOURS_PER_SLOT) * BITS)) & MASK;
    }
}
