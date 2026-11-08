// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IsolatedLendingMarket} from "./IsolatedLendingMarket.sol";
import {IAccessList} from "../interfaces/IPetahour.sol";

/// @title First-Loss Tranche
/// @notice Junior capital, analogous to USD.AI's sCHIP. Deposits are lent alongside senior money
/// through the vault, which records what this tranche is owed. That claim earns the interest left
/// once senior depositors have their yield, and it shrinks first when a loan goes bad.
contract FirstLossTranche is ERC4626, AccessControl {
    using SafeERC20 for IERC20;

    IAccessList public immutable labsAccess;
    ComputeCreditVault public vault;

    event Bound(address vault);

    error NotEligible(address who);
    error AlreadyBound();
    error StillHasValue();

    constructor(address admin, IERC20 asset_, IAccessList labsAccess_)
        ERC20("Petahour Labs First-Loss Tranche", "phJR")
        ERC4626(asset_)
    {
        labsAccess = labsAccess_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice The vault needs this address at deployment, so it is bound here once.
    function bind(ComputeCreditVault vault_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(vault) != address(0)) revert AlreadyBound();
        vault = vault_;
        emit Bound(address(vault_));
    }

    function totalAssets() public view override returns (uint256) {
        return vault.firstLossClaim();
    }

    /// @notice After a total loss the old shares are worthless, yet each new deposit must mint vastly
    /// more to outweigh them, and repeated wipe-outs would overflow the supply. Anyone may clear them,
    /// so no holder can stop the tranche taking new capital. Settles first: with no shares left the
    /// waterfall sees no first-loss capital, so a loss not yet booked would fall back on the seniors.
    function clearWorthless(address[] calldata holders) external {
        vault.settle();
        if (vault.firstLossClaim() != 0) revert StillHasValue();
        for (uint256 i; i < holders.length; i++) {
            _burn(holders[i], balanceOf(holders[i]));
        }
    }

    /// @dev Settles before minting, so interest earned while nobody held this tranche stays with
    /// the seniors who earned it and cannot be caught by a late arrival.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        vault.settle();
        super._deposit(caller, receiver, assets, shares);
        IERC20(asset()).forceApprove(address(vault), assets);
        vault.fundFirstLoss(assets);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        vault.releaseFirstLoss(assets);
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (to != address(0) && !labsAccess.isEligible(to)) revert NotEligible(to);
        super._update(from, to, value);
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }
}

/// @title Compute Credit Vault
/// @notice Senior ERC-4626 vault that lends into the isolated market, in the style of a MetaMorpho
/// vault with a single allocation. Senior and first-loss money share one pool, and `waterfall`
/// splits it: credit losses fall on first-loss capital, the curator takes a share of gains above
/// its high-water mark, senior shares earn up to their yield, and first-loss capital keeps the rest.
contract ComputeCreditVault is ERC4626, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    bytes32 public constant CURATOR_ROLE = keccak256("CURATOR_ROLE");
    uint256 private constant BPS = 10_000;
    uint256 private constant WAD = 1e18;
    uint256 private constant YEAR = 365 days;
    uint256 private constant MAX_CURATOR_FEE_BPS = 5_000; // Morpho's cap

    IAccessList public immutable labsAccess;
    IsolatedLendingMarket public immutable market;
    FirstLossTranche public immutable tranche;
    uint256 public immutable curatorFeeBps;
    uint256 public immutable seniorYieldBps;
    address public immutable feeRecipient;

    uint256 public firstLossCapital; // what the tranche is owed, as of the last settlement
    uint256 public badDebtBooked; // market bad debt already split between the tranches
    uint256 public badDebtCovered; // the part of it that first-loss capital took
    uint256 public highWater; // assets the curator has already been paid on, adjusted for flows
    uint256 public hurdleIndex = WAD; // the senior share price its yield allows, 1e18 at launch
    uint256 public lastSettled;

    /// @notice One pass of the waterfall at today's balances.
    struct Waterfall {
        uint256 pool; // cash plus the market position
        uint256 absorbed; // new credit losses taken by first-loss capital
        uint256 mark; // high-water mark once those losses are written off
        uint256 fee; // curator's fee, in assets
        uint256 excess; // what senior shares earned above their yield
        uint256 firstLoss; // first-loss claim after all of the above
        uint256 senior; // senior shares' value, curator's fee included
    }

    event Allocated(uint256 assets);
    event Deallocated(uint256 assets);
    event BadDebtCovered(uint256 badDebt, uint256 recovered);
    event CuratorFeeAccrued(uint256 shares);
    event ExcessPaidToFirstLoss(uint256 assets);

    error NotEligible(address who);
    error NotTranche();
    error InvalidFee();
    error InvalidYield();

    constructor(
        address admin,
        IERC20 asset_,
        IAccessList labsAccess_,
        IsolatedLendingMarket market_,
        FirstLossTranche tranche_,
        uint256 curatorFeeBps_,
        uint256 seniorYieldBps_,
        address feeRecipient_
    )
        ERC20("Petahour Labs Compute Credit Vault", "phSR")
        ERC4626(asset_)
    {
        labsAccess = labsAccess_;
        market = market_;
        tranche = tranche_;
        if (curatorFeeBps_ > MAX_CURATOR_FEE_BPS || feeRecipient_ == address(0)) revert InvalidFee();
        if (seniorYieldBps_ == 0 || seniorYieldBps_ > BPS) revert InvalidYield();
        curatorFeeBps = curatorFeeBps_;
        seniorYieldBps = seniorYieldBps_;
        feeRecipient = feeRecipient_;
        lastSettled = block.timestamp;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CURATOR_ROLE, admin);
    }

    modifier onlyTranche() {
        if (msg.sender != address(tranche)) revert NotTranche();
        _;
    }

    /// @notice The whole split, worked out fresh on every read. A loss lands the moment the market
    /// records it, so nobody can trade on a price that has not caught up. `settle` only stores this.
    function waterfall() public view returns (Waterfall memory w) {
        w.pool = IERC20(asset()).balanceOf(address(this)) + market.supplyAssetsOf(address(this));

        // With no holders left, any rounding dust goes back to the seniors.
        uint256 capital = tranche.totalSupply() == 0 ? 0 : firstLossCapital;
        uint256 newLoss = market.badDebtTotal() - badDebtBooked;
        w.absorbed = newLoss < capital ? newLoss : capital;
        capital -= w.absorbed;

        // Absorbed losses leave with the capital that took them, so they come off the mark. A loss
        // the seniors bear stays on it: the curator earns nothing until that is made back.
        w.mark = highWater > w.absorbed ? highWater - w.absorbed : 0;
        if (w.pool > w.mark) w.fee = (w.pool - w.mark) * curatorFeeBps / BPS;

        uint256 beforeExcess = w.pool > capital ? w.pool - capital : 0;
        if (capital != 0) {
            uint256 offset = 10 ** _decimalsOffset();
            // Senior value at the hurdle price, in the ERC-4626 sums: (assets + 1) / (supply + offset).
            // Worked out afresh each time, so rounding costs seniors under one atom and never adds up.
            uint256 cap = (totalSupply() + offset).mulDiv(hurdle(), WAD * offset) - 1 + w.fee;
            if (beforeExcess > cap) w.excess = beforeExcess - cap;
        }
        w.firstLoss = capital + w.excess;
        w.senior = beforeExcess - w.excess;
    }

    /// @notice The senior share price their yield allows by now. The hurdle is cumulative: a period
    /// that earns less than the yield must be made up before first-loss capital earns anything.
    function hurdle() public view returns (uint256) {
        if (totalSupply() == 0) return WAD;
        return hurdleIndex + hurdleIndex.mulDiv(seniorYieldBps * (block.timestamp - lastSettled), BPS * YEAR);
    }

    /// @notice Senior shares' value. First-loss money in the same pool is not theirs.
    function totalAssets() public view override returns (uint256) {
        return waterfall().senior;
    }

    /// @notice What the first-loss tranche is owed today, net of losses and with its earnings.
    function firstLossClaim() external view returns (uint256) {
        return waterfall().firstLoss;
    }

    function allocate(uint256 assets) external onlyRole(CURATOR_ROLE) {
        IERC20(asset()).forceApprove(address(market), assets);
        market.supply(assets);
        emit Allocated(assets);
    }

    function deallocate(uint256 assets) external onlyRole(CURATOR_ROLE) {
        market.withdraw(assets);
        emit Deallocated(assets);
    }

    /// @notice Anyone may call. Records the waterfall and pays the curator. Prices already count all
    /// of it, so settling moves no one's money.
    function settle() external {
        _settle();
    }

    function _settle() private {
        Waterfall memory w = waterfall();
        uint256 feeShares = _feeShares(w);

        uint256 badDebt = market.badDebtTotal();
        if (badDebt != badDebtBooked) {
            emit BadDebtCovered(badDebt - badDebtBooked, w.absorbed);
            badDebtBooked = badDebt; // a shortfall stays with the seniors; new capital never inherits it
            badDebtCovered += w.absorbed;
        }
        if (w.excess != 0) emit ExcessPaidToFirstLoss(w.excess);

        firstLossCapital = w.firstLoss;
        highWater = w.fee != 0 ? w.pool : w.mark;
        hurdleIndex = hurdle();
        lastSettled = block.timestamp;

        if (feeShares != 0) {
            _mint(feeRecipient, feeShares);
            emit CuratorFeeAccrued(feeShares);
        }

        // Nobody to pay the excess to, so seniors keep it and the hurdle restarts from their price.
        if (w.firstLoss == 0) {
            uint256 offset = 10 ** _decimalsOffset();
            uint256 price = (w.senior + 1).mulDiv(WAD * offset, totalSupply() + offset);
            if (price > hurdleIndex) hurdleIndex = price;
        }
    }

    function fundFirstLoss(uint256 assets) external onlyTranche nonReentrant {
        firstLossCapital += assets;
        highWater += assets;
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
    }

    function releaseFirstLoss(uint256 assets) external onlyTranche nonReentrant {
        _settle();
        firstLossCapital -= assets;
        highWater -= assets < highWater ? assets : highWater;
        _raiseCash(assets);
        IERC20(asset()).safeTransfer(msg.sender, assets);
    }

    function _raiseCash(uint256 assets) private {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle < assets) market.withdraw(assets - idle);
    }

    /// @dev The shares that hand the curator its fee. Share conversions count them, so prices stay
    /// net of the fee between settlements.
    function _feeShares(Waterfall memory w) private view returns (uint256) {
        if (w.fee == 0) return 0;
        uint256 afterFee = w.senior > w.fee ? w.senior - w.fee : 0;
        return w.fee.mulDiv(totalSupply() + 10 ** _decimalsOffset(), afterFee + 1);
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        Waterfall memory w = waterfall();
        return assets.mulDiv(totalSupply() + _feeShares(w) + 10 ** _decimalsOffset(), w.senior + 1, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        Waterfall memory w = waterfall();
        return shares.mulDiv(w.senior + 1, totalSupply() + _feeShares(w) + 10 ** _decimalsOffset(), rounding);
    }

    /// @dev New money is not a gain. Share prices already count the pending fee, so a new depositor
    /// neither pays for past interest nor shares in it.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        _settle(); // restarts the hurdle if the last senior has left
        super._deposit(caller, receiver, assets, shares);
        highWater += assets;
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        _settle(); // otherwise the last lender out would leave the curator's fee behind
        _raiseCash(assets);
        super._withdraw(caller, receiver, owner, assets, shares);
        highWater -= assets < highWater ? assets : highWater;
    }

    /// @dev The fee recipient is exempt, so a lapsed allow-list entry can never block depositors.
    function _update(address from, address to, uint256 value) internal override {
        if (to != address(0) && to != feeRecipient && !labsAccess.isEligible(to)) revert NotEligible(to);
        super._update(from, to, value);
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }
}
