// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {LabsBase} from "./Labs.t.sol";
import {IsolatedLendingMarket} from "../../contracts/labs/IsolatedLendingMarket.sol";
import {ComputeCreditVault} from "../../contracts/labs/ComputeCreditVault.sol";
import {LabsTreasury} from "../../contracts/labs/LabsTreasury.sol";
import {IMorphoOracle, IAccessList} from "../../contracts/interfaces/IPetahour.sol";

/// @notice The Labs fees in the financial model: a 10% curator fee on interest, a 0.5% origination
/// fee on new loans, and a 0.10% licence to Petahour on average loans.
contract LabsFeesTest is LabsBase {
    uint256 constant LOAN = 1_000e6;
    uint256 constant ORIGINATION = LOAN * 50 / 10_000;

    function _borrow(uint256 amount) internal {
        vm.prank(borrower);
        market.borrow(amount);
    }

    function _repayAll() internal {
        uint256 debt = market.debtOf(borrower);
        usd.mint(borrower, debt);
        vm.startPrank(borrower);
        usd.approve(address(market), type(uint256).max);
        market.repay(debt);
        vm.stopPrank();
    }

    function _curatorValue() internal view returns (uint256) {
        return vault.convertToAssets(vault.balanceOf(address(labsTreasury)));
    }

    function _lenderValue() internal view returns (uint256) {
        return vault.convertToAssets(vault.balanceOf(lender));
    }

    function _crash(uint256 amount) internal {
        _publish(P0 * 40 / 100, true);
        usd.mint(liquidator, 3_000e6);
        vm.startPrank(liquidator);
        usd.approve(address(market), type(uint256).max);
        market.liquidate(borrower, amount);
        vm.stopPrank();
    }

    // -------------------------------------------------------- origination fee

    function test_theBorrowerPaysOriginationOutOfTheAmountDrawn() public {
        _setupLending();
        _borrow(LOAN);
        assertEq(usd.balanceOf(borrower), LOAN - ORIGINATION);
        assertEq(usd.balanceOf(address(labsTreasury)), ORIGINATION);
        assertApproxEqAbs(market.debtOf(borrower), LOAN, 1, "still owes the full amount");
    }

    function test_originationComesFromTheBorrowerNotTheLenders() public {
        _setupLending();
        uint256 before = vault.totalAssets();
        _borrow(LOAN);
        assertEq(vault.totalAssets(), before);
    }

    function test_rollingALoanPaysNoSecondFee() public {
        _setupLending();
        _borrow(LOAN);
        _repayAll();
        _borrow(LOAN);
        assertEq(usd.balanceOf(address(labsTreasury)), ORIGINATION);
    }

    function test_onlyGrowthInTheLoanPaysOrigination() public {
        _setupLending();
        _borrow(LOAN);
        _repayAll();
        _borrow(LOAN + 200e6);
        assertApproxEqAbs(usd.balanceOf(address(labsTreasury)), ORIGINATION + 1e6, 1);
    }

    function test_anOriginationFeeAboveTheCapIsRefused() public {
        vm.expectRevert(IsolatedLendingMarket.InvalidFee.selector);
        new IsolatedLendingMarket(
            IERC20(address(usd)),
            IERC20(address(wrapper)),
            IMorphoOracle(address(adapter)),
            IAccessList(address(labs)),
            LLTV,
            0.12e18,
            INCENTIVE,
            501,
            address(labsTreasury)
        );
    }

    // ------------------------------------------------------------ curator fee

    function test_theCuratorEarnsTenPercentOfInterest() public {
        _setupLending();
        _borrow(LOAN);
        vm.warp(block.timestamp + 365 days); // 12% on 1,000 = 120 of interest
        vault.settle();
        assertApproxEqAbs(_curatorValue(), 12e6, 2);
        assertApproxEqAbs(_lenderValue(), 10_108e6, 2);
    }

    function test_quotedPricesAreAlreadyNetOfTheFee() public {
        _setupLending();
        _borrow(LOAN);
        vm.warp(block.timestamp + 365 days);
        uint256 quoted = _lenderValue();
        vault.settle();
        assertApproxEqAbs(quoted, _lenderValue(), 1);
        assertApproxEqAbs(quoted, 10_108e6, 2);
    }

    function test_aDepositIsNotAGain() public {
        _setupLending();
        usd.mint(junior, 5_000e6);
        vm.startPrank(junior);
        usd.approve(address(vault), type(uint256).max);
        vault.deposit(5_000e6, junior);
        vm.stopPrank();
        vault.settle();
        assertEq(vault.balanceOf(address(labsTreasury)), 0);
    }

    function test_aNewDepositorNeitherPaysNorSharesPastInterest() public {
        _setupLending();
        _borrow(LOAN);
        vm.warp(block.timestamp + 365 days);
        usd.mint(junior, 1_000e6);
        vm.startPrank(junior);
        usd.approve(address(vault), type(uint256).max);
        vault.deposit(1_000e6, junior);
        vm.stopPrank();
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(junior)), 1_000e6, 2);
        assertApproxEqAbs(_lenderValue(), 10_108e6, 3);
    }

    function test_aWithdrawalIsNotALoss() public {
        _setupLending();
        _borrow(LOAN);
        // Fixed times: via_ir treats block.timestamp as constant within a call, so it cannot pin a moment.
        vm.warp(START_TIME + 365 days / 2); // 60 of interest
        vm.prank(lender);
        vault.withdraw(1_000e6, lender, lender);
        assertApproxEqAbs(_curatorValue(), 6e6, 3);

        vm.warp(START_TIME + 365 days); // 12% on the 1,060 now owed, for half a year = 63.6
        vault.settle();
        // 6.00 from before, 6.36 of new fee, and 0.0379 earned by the first 6.00 of fee shares
        assertApproxEqAbs(_curatorValue(), 12_397_906, 5);
    }

    function test_theLastLenderOutCannotLeaveTheFeeBehind() public {
        _setupLending();
        _borrow(LOAN);
        vm.warp(block.timestamp + 365 days);
        _repayAll();
        uint256 shares = vault.balanceOf(lender);
        vm.prank(lender);
        vault.redeem(shares, lender, lender);
        assertApproxEqAbs(_curatorValue(), 12e6, 3);
        assertApproxEqAbs(usd.balanceOf(lender), 10_108e6, 3);
    }

    /// @notice A loss first-loss capital takes leaves the books with that capital, so it neither
    /// earns the curator anything nor costs it the fee on interest already made.
    function test_aCoveredLossNeitherPaysNorCostsTheCurator() public {
        uint256 amount = _setupLending();
        _borrow(1_932e6);
        vm.warp(block.timestamp + 30 days);
        uint256 interest = vault.totalAssets() - 10_000e6;
        _crash(amount);
        vault.settle();
        assertGt(vault.badDebtCovered(), 100e6, "a real loss, taken by first-loss capital");
        assertApproxEqAbs(_curatorValue(), interest / 10, 3, "fee on interest only");
        assertApproxEqAbs(_lenderValue(), 10_000e6 + interest - interest / 10, 3);
    }

    /// @notice The trap: interest that only makes back a senior loss is not income.
    function test_interestThatRefillsASeniorLossPaysNoFee() public {
        uint256 amount = _setupLending();
        _borrow(1_932e6);
        uint256 all = tranche.balanceOf(junior);
        vm.prank(junior);
        tranche.redeem(all, junior, junior); // no first-loss capital left
        _crash(amount);
        vault.settle();
        uint256 mark = vault.highWater();
        assertEq(mark, 10_000e6, "the loss does not lower the mark");

        // The lost money comes back as if earned: still below the mark, so still no fee.
        uint256 shortfall = mark - vault.totalAssets();
        usd.mint(address(vault), shortfall / 2);
        vault.settle();
        assertEq(vault.balanceOf(address(labsTreasury)), 0);

        // Only what rises above the mark counts.
        usd.mint(address(vault), shortfall / 2 + 100e6);
        vault.settle();
        assertApproxEqAbs(_curatorValue(), 10e6, 3);
    }

    function test_noFeeWhileTheVaultIsBelowItsMark() public {
        uint256 amount = _setupLending();
        _borrow(1_932e6);
        uint256 all = tranche.balanceOf(junior);
        vm.prank(junior);
        tranche.redeem(all, junior, junior); // no first-loss left to rescue anyone
        _crash(amount);
        vault.settle();
        assertLt(vault.totalAssets(), vault.highWater());
        vault.settle();
        assertEq(vault.balanceOf(address(labsTreasury)), 0);
    }

    function test_aFeeRecipientOffTheAllowListCannotBlockDepositors() public {
        _setupLending();
        assertFalse(labs.isEligible(address(labsTreasury)));
        _borrow(LOAN);
        vm.warp(block.timestamp + 365 days);
        vm.prank(lender);
        vault.withdraw(100e6, lender, lender);
        assertGt(vault.balanceOf(address(labsTreasury)), 0);
    }

    function test_aCuratorFeeAboveTheCapIsRefused() public {
        vm.expectRevert(ComputeCreditVault.InvalidFee.selector);
        new ComputeCreditVault(
            labsAdmin, IERC20(address(usd)), IAccessList(address(labs)), market, tranche, 5_001, 800, address(labsTreasury)
        );
    }

    /// @notice Whatever the loan and the time, the curator gets its share and no value appears.
    function testFuzz_theCuratorTakesExactlyItsShare(uint256 loan, uint256 elapsed) public {
        _setupLending();
        loan = bound(loan, 1e6, 1_900e6);
        elapsed = bound(elapsed, 1 hours, 730 days);
        _borrow(loan);
        vm.warp(block.timestamp + elapsed);
        uint256 gain = vault.totalAssets() - 10_000e6;
        vault.settle();
        assertApproxEqAbs(_curatorValue(), gain / 10, 3);
        assertApproxEqAbs(_curatorValue() + _lenderValue(), vault.totalAssets(), 3);
    }

    // ---------------------------------------------------------------- licence

    function test_theLicenceIsTenBasisPointsOfAverageLoans() public {
        _setupLending();
        _borrow(LOAN);
        vm.warp(block.timestamp + 365 days);
        assertEq(labsTreasury.licenceDue(), 1e6);
    }

    function test_theLicenceFollowsTheBalanceOverTime() public {
        _setupLending();
        _borrow(LOAN);
        vm.warp(START_TIME + 73 days); // a fifth of a year on 1,000 is 0.20
        _repayAll();
        vm.warp(START_TIME + 146 days); // time with no loans adds nothing
        assertEq(labsTreasury.licenceDue(), 200_000);

        _publish(P0, false); // the oracle has gone stale in the meantime
        _borrow(LOAN * 3 / 2);
        vm.warp(START_TIME + 219 days); // a fifth of a year on 1,500 adds 0.30
        assertApproxEqAbs(labsTreasury.licenceDue(), 500_000, 1);
    }

    function test_payingTheLicenceSendsCashToTce() public {
        _setupLending();
        _borrow(LOAN);
        vm.warp(block.timestamp + 365 days);
        uint256 before = usd.balanceOf(treasury);
        labsTreasury.payLicence();
        assertEq(usd.balanceOf(treasury), before + 1e6);
        assertEq(labsTreasury.licenceDue(), 0);
        labsTreasury.payLicence();
        assertEq(usd.balanceOf(treasury), before + 1e6, "not paid twice");
    }

    function test_anyoneCanTriggerTheLicencePayment() public {
        _setupLending();
        _borrow(LOAN);
        vm.warp(block.timestamp + 365 days);
        vm.prank(stranger);
        assertEq(labsTreasury.payLicence(), 1e6);
    }

    function test_theLicencePaysWhatCashAllowsAndTheRestStaysDue() public {
        _setupLending();
        _borrow(LOAN);
        vm.warp(block.timestamp + 6 * 365 days); // 6.00 due against 5.00 of origination cash
        assertEq(labsTreasury.payLicence(), ORIGINATION);
        assertEq(labsTreasury.licenceDue(), 1e6);
    }

    function test_labsCannotTakeMoneyOutAheadOfTheLicence() public {
        _setupLending();
        _borrow(LOAN);
        vm.warp(block.timestamp + 6 * 365 days);
        vm.prank(labsAdmin);
        vm.expectPartialRevert(LabsTreasury.LicenceUnpaid.selector);
        labsTreasury.withdraw(labsAdmin, 1);
    }

    function test_aWithdrawalPaysTheLicenceFirst() public {
        _setupLending();
        _borrow(LOAN);
        vm.warp(block.timestamp + 365 days);
        uint256 before = usd.balanceOf(treasury);
        vm.prank(labsAdmin);
        labsTreasury.withdraw(labsAdmin, 4e6);
        assertEq(usd.balanceOf(treasury), before + 1e6);
        assertEq(usd.balanceOf(labsAdmin), 4e6);
    }

    function test_onlyLabsAdminCanWithdraw() public {
        _setupLending();
        _borrow(LOAN);
        bytes32 role = labsTreasury.DEFAULT_ADMIN_ROLE();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        labsTreasury.withdraw(stranger, 1);
    }

    function test_curatorSharesTurnIntoCashForTheTreasury() public {
        _setupLending();
        _borrow(LOAN);
        vm.warp(block.timestamp + 365 days);
        vault.settle();
        uint256 cash = usd.balanceOf(address(labsTreasury));
        uint256 shares = vault.balanceOf(address(labsTreasury));
        labsTreasury.collectCuratorFees(shares);
        assertApproxEqAbs(usd.balanceOf(address(labsTreasury)), cash + 12e6, 2);
    }

    function test_theTreasuryCanOnlyBeBoundOnce() public {
        vm.prank(labsAdmin);
        vm.expectRevert(LabsTreasury.AlreadyBound.selector);
        labsTreasury.bind(market, vault);
    }

    function test_aLicenceAboveTheCapIsRefused() public {
        vm.expectRevert(LabsTreasury.InvalidLicence.selector);
        new LabsTreasury(labsAdmin, IERC20(address(usd)), treasury, 101);
    }

    function test_feesCreateNoRoleBetweenTheEntities() public view {
        assertFalse(labsTreasury.hasRole(labsTreasury.DEFAULT_ADMIN_ROLE(), treasury), "Petahour holds no role at Labs");
        assertFalse(labsTreasury.hasRole(labsTreasury.DEFAULT_ADMIN_ROLE(), admin), "nor does Petahour's admin");
        assertFalse(escrow.hasRole(escrow.DEFAULT_ADMIN_ROLE(), address(labsTreasury)), "Labs holds no role at Petahour");
    }
}
