// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Base} from "../Base.t.sol";
import {MemberRegistry} from "../../contracts/core/MemberRegistry.sol";
import {TCPIOracle, TCPIFeed} from "../../contracts/core/TCPIOracle.sol";
import {GPUWarehouseReceipt} from "../../contracts/labs/GPUWarehouseReceipt.sol";
import {GPUReceiptWrapper} from "../../contracts/labs/GPUReceiptWrapper.sol";
import {TCPIPriceAdapter} from "../../contracts/labs/TCPIPriceAdapter.sol";
import {IsolatedLendingMarket} from "../../contracts/labs/IsolatedLendingMarket.sol";
import {ComputeCreditVault, FirstLossTranche} from "../../contracts/labs/ComputeCreditVault.sol";
import {LabsTreasury} from "../../contracts/labs/LabsTreasury.sol";
import {
    AggregatorV3Interface,
    IAccessList,
    IComputePassport,
    IFederation,
    IMorphoOracle,
    IProofOfDeliveryOracle
} from "../../contracts/interfaces/IPetahour.sol";

abstract contract LabsBase is Base {
    bytes32 constant INDEX = keccak256("TCPI-B200");
    int256 constant P0 = 3_68000000; // US$3.68 with 8 decimals
    uint256 constant ORACLE_BPS = 8_400; // share of TCPI the oracle counts
    uint256 constant LLTV = 0.625e18; // an approved Morpho value
    uint256 constant INCENTIVE = 1_126_760_563_380_281_690; // Morpho's formula at that LLTV

    address labsAdmin = makeAddr("labsAdmin");
    address borrower = makeAddr("borrower");
    address lender = makeAddr("lender");
    address junior = makeAddr("junior");
    address liquidator = makeAddr("liquidator");

    MemberRegistry labs;
    TCPIOracle tcpi;
    TCPIFeed feed;
    GPUWarehouseReceipt receipts;
    GPUReceiptWrapper wrapper;
    TCPIPriceAdapter adapter;
    IsolatedLendingMarket market;
    FirstLossTranche tranche;
    ComputeCreditVault vault;
    LabsTreasury labsTreasury;
    uint64 day;

    function setUp() public virtual override {
        super.setUp();
        labs = new MemberRegistry(labsAdmin);
        tcpi = new TCPIOracle(admin, IFederation(address(federation)), 2_500);
        feed = new TCPIFeed(tcpi, INDEX, "TCPI-B200 / USD per GPU-hour");
        day = uint64(block.timestamp / 1 days);
        _publish(P0, false);

        receipts = new GPUWarehouseReceipt(
            labsAdmin,
            IAccessList(address(labs)),
            IComputePassport(address(passports)),
            IProofOfDeliveryOracle(address(oracle))
        );
        wrapper = new GPUReceiptWrapper(receipts, IAccessList(address(labs)), SKU, "Wrapped GPU Receipt B200", "wGWR-B200");
        adapter = new TCPIPriceAdapter(AggregatorV3Interface(address(feed)), 2 days, ORACLE_BPS, 18, 6);
        labsTreasury = new LabsTreasury(labsAdmin, IERC20(address(usd)), treasury, 10);
        market = new IsolatedLendingMarket(
            IERC20(address(usd)),
            IERC20(address(wrapper)),
            IMorphoOracle(address(adapter)),
            IAccessList(address(labs)),
            LLTV,
            0.12e18,
            INCENTIVE,
            50,
            address(labsTreasury)
        );
        tranche = new FirstLossTranche(labsAdmin, IERC20(address(usd)), IAccessList(address(labs)));
        vault = new ComputeCreditVault(
            labsAdmin, IERC20(address(usd)), IAccessList(address(labs)), market, tranche, 1_000, 800, address(labsTreasury)
        );

        vm.startPrank(labsAdmin);
        labsTreasury.bind(market, vault);
        tranche.bind(vault);
        uint64 exp = uint64(START_TIME + 365 days);
        labs.enroll(seller, MemberRegistry.Tier.Participant, exp, "x");
        labs.enroll(borrower, MemberRegistry.Tier.Participant, exp, "x");
        labs.enroll(lender, MemberRegistry.Tier.Participant, exp, "x");
        labs.enroll(junior, MemberRegistry.Tier.Participant, exp, "x");
        labs.enroll(liquidator, MemberRegistry.Tier.Participant, exp, "x");
        labs.enroll(address(wrapper), MemberRegistry.Tier.Participant, exp, "protocol");
        labs.enroll(address(market), MemberRegistry.Tier.Participant, exp, "protocol");
        labs.enroll(address(vault), MemberRegistry.Tier.Participant, exp, "protocol");
        vm.stopPrank();
    }

    function _publishDigest(int256 answer, bool emergency, uint64 d) internal view returns (bytes32) {
        return _digest(
            "Petahour TCPI Oracle",
            address(tcpi),
            keccak256(
                abi.encode(tcpi.PUBLISH_TYPEHASH(), INDEX, d, answer, uint128(1000), bytes32("v1"), bytes32("inputs"), emergency)
            )
        );
    }

    function _publish(int256 answer, bool emergency) internal {
        uint64 d = day++;
        tcpi.publish(INDEX, d, answer, 1000, "v1", "inputs", emergency, _quorum(_publishDigest(answer, emergency, d)));
    }

    function _receipt(address to, uint64 hours_) internal returns (uint256) {
        GPUWarehouseReceipt.Receipt memory r = GPUWarehouseReceipt.Receipt({
            passportId: passportId,
            sku: SKU,
            gpuHours: hours_,
            expiry: uint64(block.timestamp + 30 days),
            bailmentHash: keccak256("bailment")
        });
        vm.prank(labsAdmin);
        return receipts.mintReceipt(to, r);
    }

    /// @dev Senior 10,000 and first-loss 2,000 tUSD, all in the market. Borrower holds 1,000 GPU-hours.
    function _setupLending() internal returns (uint256 collateralAmount) {
        usd.mint(lender, 10_000e6);
        usd.mint(junior, 2_000e6);
        vm.startPrank(lender);
        usd.approve(address(vault), type(uint256).max);
        vault.deposit(10_000e6, lender);
        vm.stopPrank();
        vm.startPrank(junior);
        usd.approve(address(tranche), type(uint256).max);
        tranche.deposit(2_000e6, junior);
        vm.stopPrank();
        vm.prank(labsAdmin);
        vault.allocate(12_000e6);

        uint256 id = _receipt(borrower, 1_000);
        vm.startPrank(borrower);
        receipts.approve(address(wrapper), id);
        collateralAmount = wrapper.wrap(id);
        wrapper.approve(address(market), type(uint256).max);
        market.supplyCollateral(collateralAmount);
        vm.stopPrank();
    }
}

contract TCPITest is LabsBase {
    function test_feedMatchesChainlinkShape() public view {
        (uint80 round, int256 answer,, uint256 updatedAt, uint80 answeredIn) = feed.latestRoundData();
        assertEq(round, 1);
        assertEq(answer, P0);
        assertEq(updatedAt, block.timestamp);
        assertEq(answeredIn, 1);
        assertEq(feed.decimals(), 8);
    }

    function test_publishNeedsQuorum() public {
        bytes[] memory one = new bytes[](1);
        one[0] = _sign(fedKeys[0], _publishDigest(P0, false, day));
        vm.expectRevert(TCPIOracle.QuorumNotMet.selector);
        tcpi.publish(INDEX, day, P0, 1000, "v1", "inputs", false, one);
    }

    function test_inputsHashIsSignedAndStored() public {
        assertEq(tcpi.latest(INDEX).inputsHash, bytes32("inputs"));
        // Swapping the audit-trail hash after the quorum signed must invalidate the print.
        bytes[] memory sigs = _quorum(_publishDigest(P0, false, day));
        vm.expectRevert(TCPIOracle.QuorumNotMet.selector);
        tcpi.publish(INDEX, day, P0, 1000, "v1", "other-inputs", false, sigs);
    }

    function test_dayMustIncrease() public {
        uint64 old = day - 1;
        bytes[] memory sigs = _quorum(_publishDigest(P0, false, old));
        vm.expectRevert(TCPIOracle.DayNotIncreasing.selector);
        tcpi.publish(INDEX, old, P0, 1000, "v1", "inputs", false, sigs);
    }

    function test_largeMoveBlockedUnlessEmergency() public {
        int256 crash = P0 / 2;
        bytes[] memory sigs = _quorum(_publishDigest(crash, false, day));
        vm.expectPartialRevert(TCPIOracle.DeviationTooLarge.selector);
        tcpi.publish(INDEX, day, crash, 1000, "v1", "inputs", false, sigs);
        _publish(crash, true);
        (, int256 answer,,,) = feed.latestRoundData();
        assertEq(answer, crash);
    }

    function test_nonPositiveRejected() public {
        vm.expectRevert(TCPIOracle.NonPositive.selector);
        tcpi.publish(INDEX, day, 0, 1000, "v1", "inputs", false, new bytes[](0));
    }

    function test_adapterPriceScaling() public view {
        // 1e18 collateral atoms = 1 GPU-hour = $3.68 x 84% = $3.0912 = 3_091_200 loan atoms.
        assertEq(adapter.price() * 1e18 / 1e36, 3_091_200);
    }

    function test_adapterFailsClosedWhenStale() public {
        vm.warp(block.timestamp + 2 days + 1);
        vm.expectPartialRevert(TCPIPriceAdapter.StalePrice.selector);
        adapter.price();
    }
}

contract ReceiptTest is LabsBase {
    function test_mintAndWrap() public {
        uint256 id = _receipt(borrower, 100);
        vm.startPrank(borrower);
        receipts.approve(address(wrapper), id);
        uint256 amount = wrapper.wrap(id);
        vm.stopPrank();
        assertEq(amount, 100e18);
        assertEq(wrapper.balanceOf(borrower), 100e18);
        assertEq(receipts.ownerOf(id), address(wrapper));
    }

    function test_unwrapReturnsReceipt() public {
        uint256 id = _receipt(borrower, 100);
        vm.startPrank(borrower);
        receipts.approve(address(wrapper), id);
        wrapper.wrap(id);
        wrapper.unwrap(id);
        vm.stopPrank();
        assertEq(receipts.ownerOf(id), borrower);
        assertEq(wrapper.totalSupply(), 0);
    }

    function test_mintToNonAllowlistedReverts() public {
        GPUWarehouseReceipt.Receipt memory r =
            GPUWarehouseReceipt.Receipt(passportId, SKU, 100, uint64(block.timestamp + 1 days), "b");
        vm.prank(labsAdmin);
        vm.expectRevert(abi.encodeWithSelector(GPUWarehouseReceipt.NotEligible.selector, stranger));
        receipts.mintReceipt(stranger, r);
    }

    function test_transferToNonAllowlistedReverts() public {
        uint256 id = _receipt(borrower, 100);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(GPUWarehouseReceipt.NotEligible.selector, stranger));
        receipts.transferFrom(borrower, stranger, id);
    }

    function test_wrappedTokenStaysRestricted() public {
        uint256 id = _receipt(borrower, 100);
        vm.startPrank(borrower);
        receipts.approve(address(wrapper), id);
        wrapper.wrap(id);
        vm.expectRevert(abi.encodeWithSelector(GPUReceiptWrapper.NotEligible.selector, stranger));
        wrapper.transfer(stranger, 1e18);
        vm.stopPrank();
    }

    function test_coreMemberIsNotAutomaticallyLabsMember() public {
        assertTrue(registry.isEligible(buyer));
        assertFalse(labs.isEligible(buyer));
    }

    function test_cannotClaimMoreHoursThanPhysicallyExist() public {
        // 8 GPUs for 10 hours = 80 GPU-hours at most.
        GPUWarehouseReceipt.Receipt memory r =
            GPUWarehouseReceipt.Receipt(passportId, SKU, 81, uint64(block.timestamp + 10 hours), "b");
        vm.prank(labsAdmin);
        vm.expectPartialRevert(GPUWarehouseReceipt.ExceedsPhysicalCapacity.selector);
        receipts.mintReceipt(borrower, r);
    }

    function test_cumulativeReceiptsCannotExceedCapacity() public {
        GPUWarehouseReceipt.Receipt memory r =
            GPUWarehouseReceipt.Receipt(passportId, SKU, 50, uint64(block.timestamp + 10 hours), "b");
        vm.startPrank(labsAdmin);
        receipts.mintReceipt(borrower, r);
        vm.expectPartialRevert(GPUWarehouseReceipt.ExceedsPhysicalCapacity.selector);
        receipts.mintReceipt(borrower, r);
        vm.stopPrank();
    }

    function test_cannotIssueAgainstSuspendedHost() public {
        bytes32 role = passports.SUSPENDER_ROLE();
        vm.startPrank(admin);
        passports.grantRole(role, admin);
        passports.suspend(passportId, "fault");
        vm.stopPrank();
        GPUWarehouseReceipt.Receipt memory r =
            GPUWarehouseReceipt.Receipt(passportId, SKU, 10, uint64(block.timestamp + 1 days), "b");
        vm.prank(labsAdmin);
        vm.expectRevert(GPUWarehouseReceipt.NotAttested.selector);
        receipts.mintReceipt(borrower, r);
    }

    function test_cannotWrapExpiredReceipt() public {
        uint256 id = _receipt(borrower, 100);
        vm.warp(block.timestamp + 31 days);
        vm.startPrank(borrower);
        receipts.approve(address(wrapper), id);
        vm.expectRevert(GPUReceiptWrapper.ReceiptExpired.selector);
        wrapper.wrap(id);
        vm.stopPrank();
    }
}

contract LendingTest is LabsBase {
    function test_borrowUpToLltv() public {
        _setupLending();
        // 1,000 GPU-hours x $3.0912 collateral value x 62.5% LLTV = $1,932
        assertEq(market.maxBorrow(borrower), 1_932e6);
        vm.prank(borrower);
        market.borrow(1_932e6);
        assertEq(usd.balanceOf(borrower), 1_932e6 - 1_932e6 * 50 / 10_000, "less the origination fee");
    }

    function test_cannotBorrowAboveLltv() public {
        _setupLending();
        vm.prank(borrower);
        vm.expectRevert(IsolatedLendingMarket.InsufficientCollateral.selector);
        market.borrow(1_932e6 + 1);
    }

    function test_interestAccruesToSeniorVault() public {
        _setupLending();
        vm.prank(borrower);
        market.borrow(1_000e6);
        vm.warp(block.timestamp + 365 days);
        // 12% on 1,000 = 120, allow for share rounding
        assertApproxEqAbs(vault.totalAssets(), 10_120e6, 2);
        assertApproxEqAbs(market.debtOf(borrower), 1_120e6, 2);
    }

    function test_repayAndWithdrawCollateral() public {
        uint256 amount = _setupLending();
        usd.mint(borrower, 5e6); // the origination fee came out of the amount drawn
        vm.startPrank(borrower);
        market.borrow(1_000e6);
        usd.approve(address(market), type(uint256).max);
        market.repay(1_000e6);
        assertEq(market.debtOf(borrower), 0);
        market.withdrawCollateral(amount);
        vm.stopPrank();
        assertEq(wrapper.balanceOf(borrower), amount);
    }

    function test_cannotWithdrawCollateralBackingDebt() public {
        uint256 amount = _setupLending();
        vm.startPrank(borrower);
        market.borrow(1_000e6);
        vm.expectRevert(IsolatedLendingMarket.InsufficientCollateral.selector);
        market.withdrawCollateral(amount);
        vm.stopPrank();
    }

    function test_healthyPositionCannotBeLiquidated() public {
        uint256 amount = _setupLending();
        vm.prank(borrower);
        market.borrow(1_000e6);
        vm.prank(liquidator);
        vm.expectRevert(IsolatedLendingMarket.PositionHealthy.selector);
        market.liquidate(borrower, amount);
    }

    function test_borrowFailsClosedOnStaleOracle() public {
        _setupLending();
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(borrower);
        vm.expectPartialRevert(TCPIPriceAdapter.StalePrice.selector);
        market.borrow(1);
    }

    function test_nonAllowlistedCannotSupplyOrLiquidate() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IsolatedLendingMarket.NotEligible.selector, stranger));
        market.supply(1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IsolatedLendingMarket.NotEligible.selector, stranger));
        market.liquidate(borrower, 1);
    }

    function test_partialLiquidationRestoresSolvencyPath() public {
        uint256 amount = _setupLending();
        vm.prank(borrower);
        market.borrow(1_900e6);
        _publish(P0 * 80 / 100, false); // TCPI -20%

        usd.mint(liquidator, 2_000e6);
        vm.startPrank(liquidator);
        usd.approve(address(market), type(uint256).max);
        uint256 repaid = market.liquidate(borrower, amount / 2);
        vm.stopPrank();

        assertGt(repaid, 0);
        assertEq(wrapper.balanceOf(liquidator), amount / 2);
        assertEq(market.badDebtTotal(), 0);
    }

    /// @notice The headline stress: index crash, liquidation, junior absorbs the loss, senior unhurt.
    function test_crash_firstLossProtectsSeniorDepositors() public {
        uint256 amount = _setupLending();
        vm.prank(borrower);
        market.borrow(1_932e6);

        uint256 seniorBefore = vault.convertToAssets(vault.balanceOf(lender));
        uint256 juniorBefore = tranche.convertToAssets(tranche.balanceOf(junior));

        _publish(P0 * 40 / 100, true); // TCPI -60%, emergency print

        usd.mint(liquidator, 2_000e6);
        vm.startPrank(liquidator);
        usd.approve(address(market), type(uint256).max);
        market.liquidate(borrower, amount);
        vm.stopPrank();

        uint256 badDebt = market.badDebtTotal();
        assertGt(badDebt, 0, "collateral fell short of the debt");

        // No one has to act: both prices already reflect the loss, and settling only records it.
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(lender)), seniorBefore, 2, "senior unhurt");
        assertApproxEqAbs(tranche.convertToAssets(tranche.balanceOf(junior)), juniorBefore - badDebt, 2, "junior took it");

        vault.settle();

        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(lender)), seniorBefore, 2, "still whole");
        assertApproxEqAbs(tranche.convertToAssets(tranche.balanceOf(junior)), juniorBefore - badDebt, 2, "still charged");
        assertEq(vault.badDebtCovered(), badDebt);
    }

    function test_lossBeyondTrancheReachesSenior() public {
        uint256 amount = _setupLending();
        vm.prank(borrower);
        market.borrow(1_932e6);
        vm.prank(junior);
        tranche.withdraw(1_900e6, junior, junior); // junior capital almost gone

        _publish(P0 * 10 / 100, true);
        usd.mint(liquidator, 2_000e6);
        vm.startPrank(liquidator);
        usd.approve(address(market), type(uint256).max);
        market.liquidate(borrower, amount);
        vm.stopPrank();

        vault.settle();
        assertEq(vault.badDebtCovered(), 100e6, "only what the tranche holds");
        assertLt(vault.totalAssets(), 10_000e6, "the remaining loss lands on senior");
    }

    function test_coverIsIdempotent() public {
        uint256 amount = _setupLending();
        vm.prank(borrower);
        market.borrow(1_932e6);
        _publish(P0 * 40 / 100, true);
        usd.mint(liquidator, 2_000e6);
        vm.startPrank(liquidator);
        usd.approve(address(market), type(uint256).max);
        market.liquidate(borrower, amount);
        vm.stopPrank();
        vault.settle();
        uint256 covered = vault.badDebtCovered();
        uint256 claim = vault.firstLossClaim();
        vault.settle();
        assertEq(vault.badDebtCovered(), covered);
        assertEq(vault.firstLossClaim(), claim);
    }

    function test_vaultWithdrawPullsFromMarket() public {
        _setupLending();
        vm.prank(lender);
        vault.withdraw(5_000e6, lender, lender);
        assertEq(usd.balanceOf(lender), 5_000e6);
    }

    function test_theCuratorCanBringMoneyBackFromTheMarket() public {
        _setupLending();
        vm.prank(labsAdmin);
        vault.deallocate(3_000e6);
        assertEq(usd.balanceOf(address(vault)), 3_000e6);
        assertEq(vault.totalAssets(), 10_000e6, "moving cash changes nobody's value");
        assertEq(vault.firstLossClaim(), 2_000e6);
    }

    function test_onlyTheCuratorMovesMoneyToAndFromTheMarket() public {
        _setupLending();
        bytes32 role = vault.CURATOR_ROLE();
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        vault.allocate(1);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        vault.deallocate(1);
        vm.stopPrank();
    }

    function test_vaultSharesAreRestricted() public {
        _setupLending();
        vm.prank(lender);
        vm.expectRevert(abi.encodeWithSelector(ComputeCreditVault.NotEligible.selector, stranger));
        vault.transfer(stranger, 1);
    }

    function test_onlyTheTrancheCanMoveFirstLossMoney() public {
        vm.startPrank(stranger);
        vm.expectRevert(ComputeCreditVault.NotTranche.selector);
        vault.fundFirstLoss(1);
        vm.expectRevert(ComputeCreditVault.NotTranche.selector);
        vault.releaseFirstLoss(1);
        vm.stopPrank();
    }
}
