// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IsolatedLendingMarket} from "./IsolatedLendingMarket.sol";
import {ComputeCreditVault, FirstLossTranche} from "./ComputeCreditVault.sol";

/// @title Labs Treasury
/// @notice Receives Labs' origination and curator fees, and owes Petahour a data licence on average
/// loans. Anyone may trigger the licence payment, so Petahour needs no role here and Labs needs none
/// at Petahour. Labs cannot take money out, or co-invest it, while the licence is unpaid.
contract LabsTreasury is AccessControl {
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;
    uint256 private constant YEAR = 365 days;
    uint256 private constant MAX_LICENCE_BPS = 100;

    IERC20 public immutable token;
    address public immutable petahourTreasury;
    uint256 public immutable licenceBps;

    IsolatedLendingMarket public market;
    ComputeCreditVault public vault;
    uint256 public licencePaid;

    event Bound(address market, address vault);
    event LicencePaid(uint256 amount);
    event CuratorFeesCollected(uint256 shares, uint256 assets);
    event FirstLossInvested(uint256 assets, uint256 shares);
    event FirstLossRedeemed(uint256 shares, uint256 assets);
    event Withdrawn(address indexed to, uint256 amount);

    error AlreadyBound();
    error InvalidLicence();
    error LicenceUnpaid(uint256 due);

    constructor(address admin, IERC20 token_, address petahourTreasury_, uint256 licenceBps_) {
        if (petahourTreasury_ == address(0) || licenceBps_ > MAX_LICENCE_BPS) revert InvalidLicence();
        token = token_;
        petahourTreasury = petahourTreasury_;
        licenceBps = licenceBps_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice The market and vault need this address at deployment, so they are bound here once.
    function bind(IsolatedLendingMarket market_, ComputeCreditVault vault_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(market) != address(0)) revert AlreadyBound();
        market = market_;
        vault = vault_;
        emit Bound(address(market_), address(vault_));
    }

    /// @notice Licence rate on the time-weighted loan balance, less what has been paid.
    function licenceDue() public view returns (uint256) {
        uint256 accrued = market.loanSeconds() * licenceBps / (BPS * YEAR);
        return accrued > licencePaid ? accrued - licencePaid : 0;
    }

    /// @notice Pays as much of the licence as cash allows. Anyone may call, including Petahour.
    function payLicence() public returns (uint256 paid) {
        uint256 due = licenceDue();
        uint256 cash = token.balanceOf(address(this));
        paid = due < cash ? due : cash;
        if (paid == 0) return 0;
        licencePaid += paid;
        token.safeTransfer(petahourTreasury, paid);
        emit LicencePaid(paid);
    }

    /// @notice Turns curator fee shares into cash here. Anyone may call: the money stays in this
    /// contract. It fails if the market has no spare liquidity, so the amount is the caller's choice.
    function collectCuratorFees(uint256 shares) external returns (uint256 assets) {
        assets = vault.redeem(shares, address(this), address(this));
        emit CuratorFeesCollected(shares, assets);
    }

    /// @notice Labs' own co-investment in the first-loss tranche, an ordinary holding of it.
    function investFirstLoss(uint256 assets) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256 shares) {
        _clearLicence();
        FirstLossTranche tranche = vault.tranche();
        token.forceApprove(address(tranche), assets);
        shares = tranche.deposit(assets, address(this));
        emit FirstLossInvested(assets, shares);
    }

    /// @notice The money comes back here, where the licence still ranks ahead of any withdrawal.
    function redeemFirstLoss(uint256 shares) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256 assets) {
        assets = vault.tranche().redeem(shares, address(this), address(this));
        emit FirstLossRedeemed(shares, assets);
    }

    function withdraw(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _clearLicence();
        token.safeTransfer(to, amount);
        emit Withdrawn(to, amount);
    }

    function _clearLicence() private {
        payLicence();
        uint256 due = licenceDue();
        if (due != 0) revert LicenceUnpaid(due);
    }
}
