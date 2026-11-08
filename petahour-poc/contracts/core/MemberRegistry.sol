// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAccessList} from "../interfaces/IPetahour.sol";

/// @title Member Registry (KYC / export-control allow-list)
/// @notice "Decentralized execution, permissioned access": the contracts run on a public
/// L2, but only wallets that passed off-chain KYC and export-control screening (US EAR today;
/// the Taiwan Foreign Trade Act amendment is still a pending bill) can hold or move anything. No personal data is stored here, only an opaque case reference.
contract MemberRegistry is AccessControl, IAccessList {
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");

    enum Tier {
        None,
        Participant,
        ClearingMember,
        MarketMaker
    }

    struct Member {
        Tier tier;
        uint64 kycExpiry;
        bool frozen;
        bytes32 caseRef; // pointer to the off-chain compliance file
    }

    mapping(address => Member) public members;

    event Enrolled(address indexed who, Tier tier, uint64 kycExpiry, bytes32 caseRef);
    event Frozen(address indexed who, bytes32 reasonRef);
    event Unfrozen(address indexed who);

    error InvalidMember();

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(COMPLIANCE_ROLE, admin);
    }

    function enroll(address who, Tier tier, uint64 kycExpiry, bytes32 caseRef) external onlyRole(COMPLIANCE_ROLE) {
        if (who == address(0) || tier == Tier.None) revert InvalidMember();
        Member storage m = members[who];
        m.tier = tier;
        m.kycExpiry = kycExpiry;
        m.caseRef = caseRef;
        emit Enrolled(who, tier, kycExpiry, caseRef);
    }

    /// @notice Immediate stop, e.g. when a member lands on a denied-party list.
    function freeze(address who, bytes32 reasonRef) external onlyRole(COMPLIANCE_ROLE) {
        members[who].frozen = true;
        emit Frozen(who, reasonRef);
    }

    function unfreeze(address who) external onlyRole(COMPLIANCE_ROLE) {
        members[who].frozen = false;
        emit Unfrozen(who);
    }

    /// @inheritdoc IAccessList
    function isEligible(address who) public view returns (bool) {
        Member storage m = members[who];
        return m.tier != Tier.None && !m.frozen && m.kycExpiry >= block.timestamp;
    }
}
