// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAccessList, IMorphoOracle} from "../interfaces/IPetahour.sol";

/// @title Isolated Lending Market
/// @notice A deliberately small local stand-in shaped like one Morpho Blue market: one loan
/// token, one collateral token, one oracle, one LLTV, and bad debt socialised to suppliers.
/// On a live network this contract is replaced by a real Morpho Blue market; the oracle and the
/// wrapped collateral already use Morpho's interfaces. It uses a fixed rate in place of an IRM.
contract IsolatedLendingMarket is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 private constant WAD = 1e18;
    uint256 private constant ORACLE_SCALE = 1e36;
    uint256 private constant VIRTUAL_SHARES = 1e6;
    uint256 private constant VIRTUAL_ASSETS = 1;
    uint256 private constant YEAR = 365 days;
    uint256 private constant BPS = 10_000;
    uint256 private constant MAX_ORIGINATION_BPS = 500;

    IERC20 public immutable loanToken;
    IERC20 public immutable collateralToken;
    IMorphoOracle public immutable oracle;
    IAccessList public immutable labsAccess;
    uint256 public immutable lltv; // liquidation loan-to-value, WAD
    uint256 public immutable aprWad; // fixed borrow rate, WAD per year
    uint256 public immutable liquidationIncentive; // WAD, as Morpho sets it from the LLTV
    uint256 public immutable originationFeeBps; // on new borrowing, taken from the amount drawn
    address public immutable feeRecipient;

    uint256 public totalSupplyAssets;
    uint256 public totalSupplyShares;
    uint256 public totalBorrowAssets;
    uint256 public totalBorrowShares;
    uint256 public lastAccrual;
    uint256 public badDebtTotal; // cumulative, read by the vault to trigger first-loss cover
    uint256 public loanSecondsStored; // loan balance x seconds, summed. Drives Petahour's data licence

    mapping(address => uint256) public supplyShares;
    mapping(address => uint256) public borrowShares;
    mapping(address => uint256) public collateral;
    mapping(address => uint256) public feePaidUpTo; // balance a borrower has paid origination on

    event Supplied(address indexed who, uint256 assets, uint256 shares);
    event WithdrawnSupply(address indexed who, uint256 assets, uint256 shares);
    event CollateralSupplied(address indexed who, uint256 assets);
    event CollateralWithdrawn(address indexed who, uint256 assets);
    event Borrowed(address indexed who, uint256 assets, uint256 shares, uint256 originationFee);
    event Repaid(address indexed who, uint256 assets, uint256 shares);
    event Liquidated(address indexed borrower, address indexed liquidator, uint256 repaid, uint256 seized, uint256 badDebt);

    error NotEligible(address who);
    error ZeroAmount();
    error InsufficientLiquidity();
    error InsufficientCollateral();
    error PositionHealthy();
    error InvalidFee();

    constructor(
        IERC20 loanToken_,
        IERC20 collateralToken_,
        IMorphoOracle oracle_,
        IAccessList labsAccess_,
        uint256 lltv_,
        uint256 aprWad_,
        uint256 liquidationIncentive_,
        uint256 originationFeeBps_,
        address feeRecipient_
    ) {
        if (originationFeeBps_ > MAX_ORIGINATION_BPS || feeRecipient_ == address(0)) revert InvalidFee();
        loanToken = loanToken_;
        collateralToken = collateralToken_;
        oracle = oracle_;
        labsAccess = labsAccess_;
        lltv = lltv_;
        aprWad = aprWad_;
        liquidationIncentive = liquidationIncentive_;
        originationFeeBps = originationFeeBps_;
        feeRecipient = feeRecipient_;
        lastAccrual = block.timestamp;
    }

    modifier onlyEligible() {
        if (!labsAccess.isEligible(msg.sender)) revert NotEligible(msg.sender);
        _;
    }

    // ---------------------------------------------------------------- lenders

    function supply(uint256 assets) external nonReentrant onlyEligible returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        _accrue();
        shares = assets.mulDiv(totalSupplyShares + VIRTUAL_SHARES, totalSupplyAssets + VIRTUAL_ASSETS);
        supplyShares[msg.sender] += shares;
        totalSupplyShares += shares;
        totalSupplyAssets += assets;
        loanToken.safeTransferFrom(msg.sender, address(this), assets);
        emit Supplied(msg.sender, assets, shares);
    }

    function withdraw(uint256 assets) external nonReentrant returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        _accrue();
        shares = assets.mulDiv(totalSupplyShares + VIRTUAL_SHARES, totalSupplyAssets + VIRTUAL_ASSETS, Math.Rounding.Ceil);
        supplyShares[msg.sender] -= shares;
        totalSupplyShares -= shares;
        totalSupplyAssets -= assets;
        if (totalBorrowAssets > totalSupplyAssets) revert InsufficientLiquidity();
        loanToken.safeTransfer(msg.sender, assets);
        emit WithdrawnSupply(msg.sender, assets, shares);
    }

    function supplyAssetsOf(address who) public view returns (uint256) {
        (uint256 supplyAssets,) = _accrued();
        return supplyShares[who].mulDiv(supplyAssets + VIRTUAL_ASSETS, totalSupplyShares + VIRTUAL_SHARES);
    }

    // -------------------------------------------------------------- borrowers

    function supplyCollateral(uint256 assets) external nonReentrant onlyEligible {
        if (assets == 0) revert ZeroAmount();
        collateral[msg.sender] += assets;
        collateralToken.safeTransferFrom(msg.sender, address(this), assets);
        emit CollateralSupplied(msg.sender, assets);
    }

    function withdrawCollateral(uint256 assets) external nonReentrant {
        if (assets == 0) revert ZeroAmount();
        _accrue();
        collateral[msg.sender] -= assets;
        if (!_isHealthy(msg.sender)) revert InsufficientCollateral();
        collateralToken.safeTransfer(msg.sender, assets);
        emit CollateralWithdrawn(msg.sender, assets);
    }

    function borrow(uint256 assets) external nonReentrant onlyEligible returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        _accrue();
        shares = assets.mulDiv(totalBorrowShares + VIRTUAL_SHARES, totalBorrowAssets + VIRTUAL_ASSETS, Math.Rounding.Ceil);
        borrowShares[msg.sender] += shares;
        totalBorrowShares += shares;
        totalBorrowAssets += assets;
        if (totalBorrowAssets > totalSupplyAssets) revert InsufficientLiquidity();
        if (!_isHealthy(msg.sender)) revert InsufficientCollateral();
        uint256 fee = _originationFee(msg.sender, assets);
        loanToken.safeTransfer(msg.sender, assets - fee);
        if (fee != 0) loanToken.safeTransfer(feeRecipient, fee);
        emit Borrowed(msg.sender, assets, shares, fee);
    }

    /// @dev Only growth pays. A borrower rolling a loan back up to a balance it has already paid
    /// on pays nothing, which suits rolling 12-month receipts.
    function _originationFee(address who, uint256 assets) private returns (uint256) {
        uint256 balance = debtOf(who);
        uint256 paidOn = feePaidUpTo[who];
        if (balance <= paidOn) return 0;
        feePaidUpTo[who] = balance;
        uint256 growth = balance - paidOn;
        return (growth < assets ? growth : assets) * originationFeeBps / BPS;
    }

    /// @notice Repays up to `assets`, capped at the caller's debt.
    function repay(uint256 assets) external nonReentrant returns (uint256 paid) {
        if (assets == 0) revert ZeroAmount();
        _accrue();
        uint256 debt = debtOf(msg.sender);
        paid = assets < debt ? assets : debt;
        uint256 shares = paid == debt
            ? borrowShares[msg.sender]
            : paid.mulDiv(totalBorrowShares + VIRTUAL_SHARES, totalBorrowAssets + VIRTUAL_ASSETS);
        borrowShares[msg.sender] -= shares;
        totalBorrowShares -= shares;
        totalBorrowAssets -= paid > totalBorrowAssets ? totalBorrowAssets : paid;
        loanToken.safeTransferFrom(msg.sender, address(this), paid);
        emit Repaid(msg.sender, paid, shares);
    }

    function debtOf(address who) public view returns (uint256) {
        (, uint256 borrowAssets) = _accrued();
        return borrowShares[who].mulDiv(borrowAssets + VIRTUAL_ASSETS, totalBorrowShares + VIRTUAL_SHARES, Math.Rounding.Ceil);
    }

    /// @notice Loan balance x seconds, summed since launch. Dividing by elapsed time gives average loans.
    function loanSeconds() public view returns (uint256) {
        return loanSecondsStored + totalBorrowAssets * (block.timestamp - lastAccrual);
    }

    function isHealthy(address who) external view returns (bool) {
        return _isHealthy(who);
    }

    /// @notice Largest debt the collateral supports at the current oracle price.
    function maxBorrow(address who) public view returns (uint256) {
        return collateral[who].mulDiv(oracle.price(), ORACLE_SCALE).mulDiv(lltv, WAD);
    }

    // ------------------------------------------------------------- liquidation

    /// @notice Seizes collateral from an unhealthy position at a discount. If the position's
    /// collateral runs out with debt remaining, that debt is written off against suppliers.
    function liquidate(address borrower, uint256 seizeAssets) external nonReentrant onlyEligible returns (uint256 repaid) {
        _accrue();
        if (_isHealthy(borrower)) revert PositionHealthy();

        uint256 price = oracle.price();
        uint256 debt = debtOf(borrower);
        uint256 held = collateral[borrower];
        uint256 seized = seizeAssets < held ? seizeAssets : held;

        repaid = seized.mulDiv(price, ORACLE_SCALE, Math.Rounding.Ceil).mulDiv(WAD, liquidationIncentive, Math.Rounding.Ceil);
        if (repaid > debt) {
            repaid = debt;
            uint256 needed = debt.mulDiv(liquidationIncentive, WAD).mulDiv(ORACLE_SCALE, price);
            seized = needed < held ? needed : held;
        }

        collateral[borrower] = held - seized;

        uint256 remaining = debt - repaid;
        uint256 badDebt;
        if (collateral[borrower] == 0 && remaining != 0) {
            badDebt = remaining;
            remaining = 0;
            totalSupplyAssets -= badDebt > totalSupplyAssets ? totalSupplyAssets : badDebt;
            badDebtTotal += badDebt;
        }

        uint256 oldShares = borrowShares[borrower];
        uint256 newShares = remaining == 0 ? 0 : oldShares.mulDiv(remaining, debt);
        borrowShares[borrower] = newShares;
        totalBorrowShares -= oldShares - newShares;
        uint256 reduction = repaid + badDebt;
        totalBorrowAssets -= reduction > totalBorrowAssets ? totalBorrowAssets : reduction;

        loanToken.safeTransferFrom(msg.sender, address(this), repaid);
        collateralToken.safeTransfer(msg.sender, seized);
        emit Liquidated(borrower, msg.sender, repaid, seized, badDebt);
    }

    // ---------------------------------------------------------------- internals

    function _isHealthy(address who) private view returns (bool) {
        if (borrowShares[who] == 0) return true;
        return debtOf(who) <= maxBorrow(who);
    }

    function _accrued() private view returns (uint256 supplyAssets, uint256 borrowAssets) {
        uint256 interest = totalBorrowAssets.mulDiv(aprWad * (block.timestamp - lastAccrual), WAD * YEAR);
        return (totalSupplyAssets + interest, totalBorrowAssets + interest);
    }

    function _accrue() private {
        loanSecondsStored = loanSeconds();
        (totalSupplyAssets, totalBorrowAssets) = _accrued();
        lastAccrual = block.timestamp;
    }
}
