// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IDefaultFund} from "../interfaces/IPetahour.sol";

/// @title Mutualized Default Fund
/// @notice CCP-style waterfall for delivery failures that exceed a seller's posted collateral:
/// the defaulter's own contribution is consumed first, then the mutual pool.
contract DefaultFund is AccessControl, IDefaultFund {
    using SafeERC20 for IERC20;

    bytes32 public constant ESCROW_ROLE = keccak256("ESCROW_ROLE");

    IERC20 public immutable token;
    mapping(address => uint256) public contributions;
    uint256 public mutualPool;

    event Contributed(address indexed member, uint256 amount);
    event MutualFunded(address indexed from, uint256 amount);
    event Covered(address indexed defaulter, uint256 fromMember, uint256 fromMutual);

    constructor(address admin, IERC20 token_) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        token = token_;
    }

    function contribute(uint256 amount) external {
        token.safeTransferFrom(msg.sender, address(this), amount);
        contributions[msg.sender] += amount;
        emit Contributed(msg.sender, amount);
    }

    /// @notice Adds to the mutual pool. Slashed collateral arrives through this function.
    function fundMutual(uint256 amount) external {
        token.safeTransferFrom(msg.sender, address(this), amount);
        mutualPool += amount;
        emit MutualFunded(msg.sender, amount);
    }

    /// @inheritdoc IDefaultFund
    function cover(address defaulter, uint256 amount) external onlyRole(ESCROW_ROLE) returns (uint256 covered) {
        uint256 own = contributions[defaulter];
        uint256 fromMember = amount < own ? amount : own;
        contributions[defaulter] = own - fromMember;

        uint256 remaining = amount - fromMember;
        uint256 fromMutual = remaining < mutualPool ? remaining : mutualPool;
        mutualPool -= fromMutual;

        covered = fromMember + fromMutual;
        if (covered != 0) token.safeTransfer(msg.sender, covered);
        emit Covered(defaulter, fromMember, fromMutual);
    }
}
