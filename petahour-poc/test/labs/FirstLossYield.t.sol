// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {LabsBase} from "./Labs.t.sol";
import {MemberRegistry} from "../../contracts/core/MemberRegistry.sol";
import {GPUWarehouseReceipt} from "../../contracts/labs/GPUWarehouseReceipt.sol";
import {IsolatedLendingMarket} from "../../contracts/labs/IsolatedLendingMarket.sol";
import {ComputeCreditVault, FirstLossTranche} from "../../contracts/labs/ComputeCreditVault.sol";
import {LabsTreasury} from "../../contracts/labs/LabsTreasury.sol";
import {IAccessList} from "../../contracts/interfaces/IPetahour.sol";

/// @notice The waterfall in the financial model: interest pays the curator, then credit losses,
/// then senior investors' 8%, and first-loss holders keep what is left. Loans are funded 87% senior
/// and 13% first-loss, so these tests lend the whole pool, as the model does.
contract FirstLossYieldTest is LabsBase {
    uint256 constant LOANS = 10_000e6;
    uint256 constant SENIOR = 8_700e6;
    uint256 constant FIRST_LOSS = 1_300e6;
    uint256 constant INTEREST = 1_200e6; // 12% on the loans
    uint256 constant CURATOR = 120e6; // 10% of interest
    uint256 constant SENIOR_YIELD = 696e6; // 8% on senior capital
    uint64 constant GPU_HOURS = 6_500;

    address newcomer = makeAddr("newcomer");

    function setUp() public override {
        super.setUp();
        uint64 far = uint64(START_TIME + 2_000 days); // these tests run for years
        vm.startPrank(labsAdmin);
        labs.enroll(borrower, MemberRegistry.Tier.Participant, far, "x");
        labs.enroll(lender, MemberRegistry.Tier.Participant, far, "x");
        labs.enroll(junior, MemberRegistry.Tier.Participant, far, "x");
        labs.enroll(newcomer, MemberRegistry.Tier.Participant, far, "x");
        labs.enroll(liquidator, MemberRegistry.Tier.Participant, far, "x");
        labs.enroll(address(wrapper), MemberRegistry.Tier.Participant, far, "protocol");
        labs.enroll(address(market), MemberRegistry.Tier.Participant, far, "protocol");
        labs.enroll(address(vault), MemberRegistry.Tier.Participant, far, "protocol");
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- helpers

    function _depositSenior(address who, uint256 assets) internal {
        usd.mint(who, assets);
        vm.startPrank(who);
        usd.approve(address(vault), type(uint256).max);
        vault.deposit(assets, who);
        vm.stopPrank();
    }

    function _depositFirstLoss(address who, uint256 assets) internal {
        usd.mint(who, assets);
        vm.startPrank(who);
        usd.approve(address(tranche), type(uint256).max);
        tranche.deposit(assets, who);
        vm.stopPrank();
    }

    function _postCollateral(uint64 gpuHours) internal returns (uint256 amount) {
        GPUWarehouseReceipt.Receipt memory r = GPUWarehouseReceipt.Receipt({
            passportId: passportId,
            sku: SKU,
            gpuHours: gpuHours,
            expiry: uint64(START_TIME + 1_500 days),
            bailmentHash: keccak256("bailment")
        });
        vm.prank(labsAdmin);
        uint256 id = receipts.mintReceipt(borrower, r);
        vm.startPrank(borrower);
        receipts.approve(address(wrapper), id);
        amount = wrapper.wrap(id);
        wrapper.approve(address(market), type(uint256).max);
        market.supplyCollateral(amount);
        vm.stopPrank();
    }

    /// @dev The model's book: 87% senior, 13% first-loss, every dollar lent.
    function _lendTheWholePool() internal returns (uint256 amount) {
        _depositSenior(lender, SENIOR);
        _depositFirstLoss(junior, FIRST_LOSS);
        vm.prank(labsAdmin);
        vault.allocate(LOANS);
        amount = _postCollateral(GPU_HOURS);
        vm.prank(borrower);
        market.borrow(LOANS);
    }

    /// @dev Prices the collateral so a liquidation leaves `loss` unpaid: repaid = hours x TCPI x 84% / incentive.
    function _loseOnLiquidation(uint256 amount, uint256 loss) internal {
        uint256 answer = (market.debtOf(borrower) - loss) * 100 * INCENTIVE / 1e18 * 10_000 / ORACLE_BPS / GPU_HOURS;
        _publish(int256(answer), true);
        usd.mint(liquidator, 20_000e6);
        vm.startPrank(liquidator);
        usd.approve(address(market), type(uint256).max);
        market.liquidate(borrower, amount);
        vm.stopPrank();
    }

    function _repayAll() internal {
        uint256 debt = market.debtOf(borrower);
        usd.mint(borrower, debt);
        vm.startPrank(borrower);
        usd.approve(address(market), type(uint256).max);
        market.repay(debt);
        vm.stopPrank();
    }

    function _lenderValue() internal view returns (uint256) {
        return vault.convertToAssets(vault.balanceOf(lender));
    }

    function _curatorValue() internal view returns (uint256) {
        return vault.convertToAssets(vault.balanceOf(address(labsTreasury)));
    }

    function _firstLossValue(address who) internal view returns (uint256) {
        return tranche.convertToAssets(tranche.balanceOf(who));
    }

    // --------------------------------------------------- the financial model

    /// @dev Left for first-loss = interest - curator fee - credit losses - senior yield.
    function _checkModel(uint256 lossBps, uint256 returnBps) internal {
        uint256 amount = _lendTheWholePool();
        vm.warp(START_TIME + 365 days);
        _loseOnLiquidation(amount, LOANS * lossBps / 10_000);
        uint256 losses = market.badDebtTotal();
        assertApproxEqAbs(losses, LOANS * lossBps / 10_000, 0.01e6, "the loss the case calls for");

        vault.settle();

        uint256 left = INTEREST - CURATOR - losses - SENIOR_YIELD;
        assertApproxEqAbs(_curatorValue(), CURATOR, 3, "curator");
        assertApproxEqAbs(_lenderValue(), SENIOR + SENIOR_YIELD, 3, "senior");
        assertApproxEqAbs(vault.firstLossClaim(), FIRST_LOSS + left, 3, "first-loss");
        assertApproxEqAbs(left * 10_000 / FIRST_LOSS, returnBps, 1, "return on first-loss capital");
    }

    function test_theModelsBaseCase() public {
        _checkModel(100, 2_185); // 1% losses: 21.8% on first-loss capital
    }

    function test_theModelsBearCase() public {
        _checkModel(300, 646); // 3% losses: 6.5%
    }

    function test_theModelsBullCase() public {
        _checkModel(50, 2_569); // 0.5% losses: 25.7%
    }

    function test_theModelWithNoLossesAtAll() public {
        _lendTheWholePool();
        vm.warp(START_TIME + 365 days);
        assertApproxEqAbs(_lenderValue(), SENIOR + SENIOR_YIELD, 3);
        assertApproxEqAbs(vault.firstLossClaim(), FIRST_LOSS + 384e6, 3);
    }

    function test_firstLossMoneyIsLentAndTheTrancheHoldsNone() public {
        _lendTheWholePool();
        assertEq(usd.balanceOf(address(tranche)), 0);
        assertEq(usd.balanceOf(address(vault)), 0);
        assertEq(market.totalBorrowAssets(), LOANS);
    }

    function test_seniorsNeverOutrunTheirYield() public {
        _lendTheWholePool();
        vm.warp(START_TIME + 73 days); // a fifth of a year
        assertApproxEqAbs(_lenderValue(), SENIOR + SENIOR_YIELD / 5, 3);
        vault.settle();
        vm.warp(START_TIME + 146 days);
        assertApproxEqAbs(_lenderValue(), (SENIOR + SENIOR_YIELD / 5) * 10_160 / 10_000, 3, "compounds at settlement");
    }

    // ---------------------------------------------------------- below the hurdle

    function test_firstLossEarnsNothingBelowTheHurdle() public {
        _setupLending();
        vm.prank(borrower);
        market.borrow(1_000e6);
        vm.warp(START_TIME + 365 days);
        assertEq(vault.firstLossClaim(), 2_000e6, "residual holders are paid last");
        assertApproxEqAbs(vault.totalAssets(), 10_120e6, 2, "seniors keep what was earned");
    }

    function test_aThinYearIsMadeUpBeforeFirstLossEarns() public {
        _depositSenior(lender, SENIOR);
        _depositFirstLoss(junior, FIRST_LOSS);
        vm.prank(labsAdmin);
        vault.allocate(LOANS);
        _postCollateral(GPU_HOURS);
        vm.prank(borrower);
        market.borrow(5_000e6); // half lent: 540 net against a yield of 696

        vm.warp(START_TIME + 365 days);
        vault.settle();
        assertEq(vault.firstLossClaim(), FIRST_LOSS, "year one: nothing for first-loss");

        _publish(P0, false);
        vm.prank(borrower);
        market.borrow(4_400e6); // fully lent again

        vm.warp(START_TIME + 365 days + 30 days);
        assertEq(vault.firstLossClaim(), FIRST_LOSS, "the shortfall comes first");

        vm.warp(START_TIME + 730 days);
        assertGt(vault.firstLossClaim(), FIRST_LOSS, "year two pays once it is made up");
        assertApproxEqAbs(_lenderValue(), SENIOR * 11_664 / 10_000, 3, "seniors hold two years of 8%");
    }

    /// @notice Settling is the waterfall's payment date. Excess not yet settled can still go to
    /// make up a thin period, and excess already settled is final.
    function test_settledEarningsAreFinalAndUnsettledOnesAreNot() public {
        _lendTheWholePool();
        vm.warp(START_TIME + 30 days);
        uint256 quoted = vault.firstLossClaim();
        assertGt(quoted, FIRST_LOSS);
        _repayAll();

        uint256 snapshot = vm.snapshotState();
        vm.warp(START_TIME + 60 days); // nothing lent, so the seniors' yield catches up
        assertLt(vault.firstLossClaim(), quoted, "not yet final");

        vm.revertToState(snapshot);
        vault.settle();
        vm.warp(START_TIME + 60 days);
        assertApproxEqAbs(vault.firstLossClaim(), quoted, 3, "final once settled");
    }

    // ----------------------------------------------------------------- losses

    function test_aLossLandsTheMomentTheMarketRecordsIt() public {
        uint256 amount = _lendTheWholePool();
        uint256 before = _lenderValue();
        _loseOnLiquidation(amount, 500e6);
        assertApproxEqAbs(_lenderValue(), before, 3, "seniors never see it");
        assertApproxEqAbs(vault.firstLossClaim(), FIRST_LOSS - 500e6, 0.01e6, "first-loss is down already");
    }

    function test_firstLossCannotRunAheadOfALoss() public {
        uint256 amount = _lendTheWholePool();
        _loseOnLiquidation(amount, 500e6);
        uint256 shares = tranche.balanceOf(junior);
        vm.prank(junior);
        tranche.redeem(shares, junior, junior); // the liquidator's cash makes this possible
        assertApproxEqAbs(usd.balanceOf(junior), FIRST_LOSS - 500e6, 0.01e6);
        assertApproxEqAbs(_lenderValue(), SENIOR, 3, "and the seniors did not pay for the exit");
    }

    function test_nobodyCanBuySeniorSharesAtADiscountAfterALoss() public {
        uint256 amount = _lendTheWholePool();
        _loseOnLiquidation(amount, 500e6);
        _depositSenior(newcomer, 1_000e6);
        vault.settle();
        uint256 shares = vault.balanceOf(newcomer);
        vm.prank(newcomer);
        vault.redeem(shares, newcomer, newcomer);
        assertLe(usd.balanceOf(newcomer), 1_000e6);
    }

    function test_aLossBeyondFirstLossReachesSeniors() public {
        uint256 amount = _lendTheWholePool();
        _loseOnLiquidation(amount, 2_000e6);
        assertEq(vault.firstLossClaim(), 0);
        assertApproxEqAbs(_lenderValue(), SENIOR - 700e6, 0.01e6);
        vault.settle();
        assertEq(vault.badDebtCovered(), FIRST_LOSS);
    }

    function test_newFirstLossMoneyDoesNotInheritAnOldLoss() public {
        uint256 amount = _lendTheWholePool();
        _loseOnLiquidation(amount, 2_000e6);
        _depositFirstLoss(newcomer, 500e6);
        assertApproxEqAbs(_firstLossValue(newcomer), 500e6, 1, "the old loss stays where it fell");
        assertEq(_firstLossValue(junior), 0, "the wiped-out holders stay wiped out");
    }

    function _holders() internal view returns (address[] memory list) {
        list = new address[](1);
        list[0] = junior;
    }

    function test_anyoneCanClearSharesThatAreWorthNothing() public {
        uint256 amount = _lendTheWholePool();
        _loseOnLiquidation(amount, 2_000e6);
        vm.prank(stranger);
        tranche.clearWorthless(_holders());
        assertEq(tranche.totalSupply(), 0);

        _depositFirstLoss(newcomer, 500e6);
        assertEq(tranche.balanceOf(newcomer), 500e6 * 1e6, "new money starts at the launch price");
        assertApproxEqAbs(_firstLossValue(newcomer), 500e6, 1);
    }

    function test_sharesWithValueCannotBeCleared() public {
        _lendTheWholePool();
        vm.prank(stranger);
        vm.expectRevert(FirstLossTranche.StillHasValue.selector);
        tranche.clearWorthless(_holders());
        assertEq(tranche.balanceOf(junior) > 0, true);
    }

    /// @notice The trap: with no shares left, the waterfall sees no first-loss capital, so clearing
    /// before the loss is booked would hand the part first-loss capital took back to the seniors.
    function test_clearingCannotMoveALossBackOntoSeniors() public {
        uint256 amount = _lendTheWholePool();
        _loseOnLiquidation(amount, 2_000e6);
        uint256 before = _lenderValue();
        assertApproxEqAbs(before, SENIOR - 700e6, 0.01e6, "seniors bear only what first-loss could not");

        tranche.clearWorthless(_holders()); // nobody has settled yet
        assertApproxEqAbs(_lenderValue(), before, 3, "and clearing changes nothing");
        assertEq(vault.badDebtCovered(), FIRST_LOSS);
    }

    function test_nothingForFirstLossUntilSeniorsRecoverALossTheyTook() public {
        uint256 amount = _lendTheWholePool();
        _loseOnLiquidation(amount, 2_000e6);
        _depositFirstLoss(newcomer, 500e6);
        usd.mint(address(vault), 100e6); // far short of the 700 the seniors lost
        assertApproxEqAbs(vault.firstLossClaim(), 500e6, 1);
    }

    function _crashAFullBook(int256 keepPct) internal {
        _depositSenior(lender, SENIOR);
        _depositFirstLoss(junior, FIRST_LOSS);
        vm.prank(labsAdmin);
        vault.allocate(LOANS);
        uint256 amount = _postCollateral(5_282); // the loan is 98% of the limit, as in S6
        vm.prank(borrower);
        market.borrow(LOANS);

        _publish(P0 * keepPct / 100, true);
        usd.mint(liquidator, 20_000e6);
        vm.startPrank(liquidator);
        usd.approve(address(market), type(uint256).max);
        market.liquidate(borrower, amount);
        vm.stopPrank();
    }

    /// @notice The design crash: at the model's 13%, a 40% fall on a full book is all but covered.
    function test_atTheModelsRatioAFortyPercentCrashIsAllButCovered() public {
        _crashAFullBook(60);
        uint256 loss = market.badDebtTotal();
        assertApproxEqRel(loss, LOANS * 1_306 / 10_000, 0.002e18, "13.06% of the loan is lost");
        assertEq(vault.firstLossClaim(), 0, "first-loss capital is used up");
        assertApproxEqAbs(_lenderValue(), SENIOR - (loss - FIRST_LOSS), 3, "seniors lose only the last sliver");
        assertLt(SENIOR - _lenderValue(), SENIOR / 1_000, "under 0.1% of senior capital");
    }

    /// @notice At the model's 13%, the S6 crash is too big for first-loss capital. The demo's senior
    /// depositors are whole only because its one loan is small against the pool.
    function test_atTheModelsRatioASixtyPercentCrashReachesSeniors() public {
        _crashAFullBook(40);
        uint256 loss = market.badDebtTotal();
        assertApproxEqRel(loss, LOANS * 420 / 1_000, 0.002e18, "about 42% of the loan is lost");
        assertEq(vault.firstLossClaim(), 0, "first-loss capital is gone");
        assertApproxEqAbs(_lenderValue(), SENIOR - (loss - FIRST_LOSS), 3, "seniors lose the rest");
    }

    /// @notice Real Morpho sets the incentive from the LLTV, so the market must be built the same way.
    function test_theIncentiveFollowsMorphosFormula() public view {
        uint256 lltv = market.lltv();
        uint256 factor = uint256(1e36) / (lltv * 3 / 10 + 0.7e18);
        assertEq(market.liquidationIncentive(), factor < 1.15e18 ? factor : 1.15e18);
    }

    function test_theAdvanceIsUnchangedByTheSplit() public view {
        assertEq(adapter.haircutBps() * market.lltv() / 1e18, 5_250, "84% x 62.5% = 52.5% of TCPI");
    }

    // ---------------------------------------------------------- getting in and out

    function test_aLateFirstLossInvestorCannotCatchPastEarnings() public {
        _lendTheWholePool();
        vm.warp(START_TIME + 182 days);
        uint256 earned = _firstLossValue(junior);
        assertGt(earned, FIRST_LOSS);
        _depositFirstLoss(newcomer, 1_000e6);
        assertApproxEqAbs(_firstLossValue(newcomer), 1_000e6, 2);
        assertApproxEqAbs(_firstLossValue(junior), earned, 2);
    }

    function test_interestEarnedWithNoFirstLossStaysWithSeniors() public {
        _depositSenior(lender, LOANS);
        vm.prank(labsAdmin);
        vault.allocate(LOANS);
        _postCollateral(GPU_HOURS);
        vm.prank(borrower);
        market.borrow(LOANS);

        vm.warp(START_TIME + 365 days);
        uint256 lenderValue = _lenderValue();
        assertApproxEqAbs(lenderValue, 11_080e6, 3, "12% less the curator, with no one to pay above 8%");

        _depositFirstLoss(junior, FIRST_LOSS);
        assertApproxEqAbs(_lenderValue(), lenderValue, 3, "a new tranche takes nothing from them");
        assertApproxEqAbs(_firstLossValue(junior), FIRST_LOSS, 2);
    }

    function test_whenFirstLossLeavesSeniorsKeepEverything() public {
        _setupLending();
        uint256 shares = tranche.balanceOf(junior);
        vm.prank(junior);
        tranche.redeem(shares, junior, junior);
        vault.settle();
        assertEq(vault.firstLossCapital(), 0, "no dust is left owing to nobody");
        assertEq(vault.firstLossClaim(), 0);
    }

    /// @notice Rounding leaves a few atoms owing after the last holder goes. That dust must not
    /// go on collecting the excess for nobody, ready for the next arrival to scoop up.
    function test_dustLeftByTheLastHolderCollectsNothing() public {
        _lendTheWholePool();
        vm.warp(START_TIME + 365 days);
        _repayAll();
        vault.settle();
        uint256 shares = tranche.balanceOf(junior);
        vm.prank(junior);
        tranche.redeem(shares, junior, junior);
        assertGt(vault.firstLossCapital(), 0, "rounding did leave dust");
        assertEq(vault.firstLossClaim(), 0, "but nobody is owed it");
        vault.settle();
        assertEq(vault.firstLossCapital(), 0, "and it goes back to the seniors");
    }

    function test_firstLossWaitsForLiquidityLikeAnyLender() public {
        _lendTheWholePool();
        vm.prank(junior);
        vm.expectRevert(IsolatedLendingMarket.InsufficientLiquidity.selector);
        tranche.withdraw(1e6, junior, junior);
    }

    function test_firstLossGetsItsEarningsOutOnceLoansAreRepaid() public {
        _lendTheWholePool();
        vm.warp(START_TIME + 365 days);
        _repayAll();
        uint256 shares = tranche.balanceOf(junior);
        vm.prank(junior);
        tranche.redeem(shares, junior, junior);
        assertApproxEqAbs(usd.balanceOf(junior), FIRST_LOSS + 384e6, 3);
        shares = vault.balanceOf(lender);
        vm.prank(lender);
        vault.redeem(shares, lender, lender);
        assertApproxEqAbs(usd.balanceOf(lender), SENIOR + SENIOR_YIELD, 3);
    }

    /// @notice If the seniors all leave, the next senior starts at the launch price, neither taxed
    /// by the hurdle nor able to take what first-loss holders had earned.
    function test_theNextSeniorAfterTheLastOneLeftStartsClean() public {
        _lendTheWholePool();
        vm.warp(START_TIME + 365 days);
        _repayAll();
        uint256 shares = vault.balanceOf(lender);
        vm.prank(lender);
        vault.redeem(shares, lender, lender);
        shares = vault.balanceOf(address(labsTreasury));
        labsTreasury.collectCuratorFees(shares);
        assertEq(vault.totalSupply(), 0);

        uint256 claim = vault.firstLossClaim();
        _depositSenior(newcomer, 1_000e6);
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(newcomer)), 1_000e6, 2);
        assertApproxEqAbs(vault.firstLossClaim(), claim, 2);
        assertEq(vault.hurdleIndex(), 1e18);
    }

    // ------------------------------------------------------------------ settling

    function testFuzz_settlingMovesNobodysMoney(uint256 loan, uint256 elapsed, uint256 loss) public {
        uint256 amount = _lendTheWholePoolAt(bound(loan, 1_000e6, LOANS));
        vm.warp(START_TIME + bound(elapsed, 1 hours, 1_000 days));
        loss = bound(loss, 0, market.debtOf(borrower) / 2);
        if (loss != 0) _loseOnLiquidation(amount, loss);

        uint256 lenderBefore = _lenderValue();
        uint256 firstLossBefore = vault.firstLossClaim();
        uint256 seniorBefore = vault.totalAssets();
        vault.settle();
        assertApproxEqAbs(_lenderValue(), lenderBefore, 3, "lender");
        assertApproxEqAbs(vault.firstLossClaim(), firstLossBefore, 3, "first-loss");
        assertApproxEqAbs(vault.totalAssets(), seniorBefore, 3, "senior");
        vault.settle(); // and doing it twice changes nothing more
        assertApproxEqAbs(vault.firstLossClaim(), firstLossBefore, 3);
    }

    function testFuzz_theTranchesAlwaysAddUpToThePool(uint256 loan, uint256 elapsed, uint256 loss, bool settleFirst)
        public
    {
        uint256 amount = _lendTheWholePoolAt(bound(loan, 1_000e6, LOANS));
        vm.warp(START_TIME + bound(elapsed, 1 hours, 1_000 days));
        if (settleFirst) vault.settle();
        loss = bound(loss, 0, market.debtOf(borrower) / 2);
        if (loss != 0) _loseOnLiquidation(amount, loss);
        ComputeCreditVault.Waterfall memory w = vault.waterfall();
        assertEq(w.senior + w.firstLoss, w.pool);
    }

    function _lendTheWholePoolAt(uint256 loan) internal returns (uint256 amount) {
        _depositSenior(lender, SENIOR);
        _depositFirstLoss(junior, FIRST_LOSS);
        vm.prank(labsAdmin);
        vault.allocate(LOANS);
        amount = _postCollateral(GPU_HOURS);
        vm.prank(borrower);
        market.borrow(loan);
    }

    // ---------------------------------------------------------------- set-up rules

    function test_theTrancheCanOnlyBeBoundOnce() public {
        vm.prank(labsAdmin);
        vm.expectRevert(FirstLossTranche.AlreadyBound.selector);
        tranche.bind(vault);
    }

    function test_onlyTheAdminCanBindTheTranche() public {
        FirstLossTranche fresh = new FirstLossTranche(labsAdmin, IERC20(address(usd)), IAccessList(address(labs)));
        bytes32 role = fresh.DEFAULT_ADMIN_ROLE();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        fresh.bind(vault);
    }

    function test_aSeniorYieldOutsideTheRangeIsRefused() public {
        vm.expectRevert(ComputeCreditVault.InvalidYield.selector);
        new ComputeCreditVault(
            labsAdmin, IERC20(address(usd)), IAccessList(address(labs)), market, tranche, 1_000, 0, address(labsTreasury)
        );
        vm.expectRevert(ComputeCreditVault.InvalidYield.selector);
        new ComputeCreditVault(
            labsAdmin, IERC20(address(usd)), IAccessList(address(labs)), market, tranche, 1_000, 10_001, address(labsTreasury)
        );
    }

    // ------------------------------------------------------- Labs' co-investment

    function _labsInvests(uint256 assets) internal {
        vm.prank(labsAdmin);
        labs.enroll(address(labsTreasury), MemberRegistry.Tier.Participant, uint64(START_TIME + 2_000 days), "protocol");
        usd.mint(address(labsTreasury), assets);
        vm.prank(labsAdmin);
        labsTreasury.investFirstLoss(assets);
    }

    function test_labsEarnsItsShareOfTheFirstLossReturn() public {
        _depositSenior(lender, SENIOR);
        _depositFirstLoss(junior, FIRST_LOSS * 3 / 4);
        _labsInvests(FIRST_LOSS / 4); // the model's 25%
        vm.prank(labsAdmin);
        vault.allocate(LOANS);
        _postCollateral(GPU_HOURS);
        vm.prank(borrower);
        market.borrow(LOANS);

        vm.warp(START_TIME + 365 days);
        assertApproxEqAbs(_firstLossValue(address(labsTreasury)), FIRST_LOSS / 4 + 96e6, 3, "a quarter of the 384");
        assertApproxEqAbs(_firstLossValue(junior), FIRST_LOSS * 3 / 4 + 288e6, 3);
    }

    function test_labsTakesItsShareOfALossToo() public {
        _depositSenior(lender, SENIOR);
        _depositFirstLoss(junior, FIRST_LOSS * 3 / 4);
        _labsInvests(FIRST_LOSS / 4);
        vm.prank(labsAdmin);
        vault.allocate(LOANS);
        uint256 amount = _postCollateral(GPU_HOURS);
        vm.prank(borrower);
        market.borrow(LOANS);
        _loseOnLiquidation(amount, 400e6);
        assertApproxEqAbs(_firstLossValue(address(labsTreasury)), FIRST_LOSS / 4 - 100e6, 0.01e6);
    }

    function test_labsCannotCoInvestAheadOfTheLicence() public {
        _setupLending();
        vm.prank(borrower);
        market.borrow(1_000e6);
        vm.startPrank(labsAdmin);
        labs.enroll(address(labsTreasury), MemberRegistry.Tier.Participant, uint64(START_TIME + 2_000 days), "protocol");
        labsTreasury.withdraw(labsAdmin, 5e6); // the origination fee was Labs' only cash
        vm.warp(START_TIME + 365 days);
        vm.expectRevert(abi.encodeWithSelector(LabsTreasury.LicenceUnpaid.selector, 1e6));
        labsTreasury.investFirstLoss(1e6);
        vm.stopPrank();
    }

    function test_onlyLabsCanMoveItsCoInvestment() public {
        bytes32 role = labsTreasury.DEFAULT_ADMIN_ROLE();
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        labsTreasury.investFirstLoss(1);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        labsTreasury.redeemFirstLoss(1);
        vm.stopPrank();
    }

    function test_coInvestedMoneyComesBackToTheTreasury() public {
        _depositSenior(lender, SENIOR);
        _labsInvests(1_000e6);
        uint256 shares = tranche.balanceOf(address(labsTreasury));
        vm.prank(labsAdmin);
        labsTreasury.redeemFirstLoss(shares);
        assertApproxEqAbs(usd.balanceOf(address(labsTreasury)), 1_000e6, 1);
    }
}
