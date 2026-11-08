// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Base} from "../Base.t.sol";
import {DvPEscrow} from "../../contracts/core/DvPEscrow.sol";
import {ComputePassport} from "../../contracts/core/ComputePassport.sol";
import {MemberRegistry} from "../../contracts/core/MemberRegistry.sol";
import {IComputePassport} from "../../contracts/interfaces/IPetahour.sol";

/// @notice The fees in the 6 November financial model: a 2.5% combined take rate in 2027, split
/// evenly between buyer and seller, and a Passport at US$60 per GPU a year, half price in 2027.
contract FeesTest is Base {
    uint64 constant QTY = 192;
    uint64 constant PRICE = 3_680_000;
    uint256 constant NOTIONAL = uint256(QTY) * PRICE;
    uint256 constant SIDE_FEE = NOTIONAL * 125 / 10_000;
    uint256 constant COLLATERAL = NOTIONAL * 2_000 / 10_000;
    uint256 constant LAUNCH_FEE_8_GPUS = 8 * 30e6;

    function _settle(uint256 id, uint32 uptime) internal {
        _claim(id, uptime);
        vm.warp(block.timestamp + 1 days);
        escrow.finalize(id);
    }

    function _setFees(uint16 buyerBps, uint16 sellerBps) internal {
        DvPEscrow.Params memory p = _params();
        p.buyerFeeBps = buyerBps;
        p.sellerFeeBps = sellerBps;
        vm.prank(admin);
        escrow.setParams(p);
    }

    // ------------------------------------------------------------ marketplace fee

    function test_bothSidesPayAndTheCombinedRateIs250Bps() public {
        uint256 buyer0 = escrow.free(buyer);
        uint256 seller0 = escrow.free(seller);
        _settle(_open(QTY, PRICE), 10_000);
        assertEq(escrow.free(treasury), NOTIONAL * 250 / 10_000, "combined take rate");
        assertEq(escrow.free(buyer), buyer0 - NOTIONAL - SIDE_FEE, "buyer pays on top");
        assertEq(escrow.free(seller), seller0 + NOTIONAL - SIDE_FEE, "seller pays from proceeds");
    }

    function test_sellerFeeIsNotLockedUpFront() public {
        uint256 seller0 = escrow.free(seller);
        _open(QTY, PRICE);
        assertEq(escrow.free(seller), seller0 - COLLATERAL);
        assertEq(escrow.totalLocked(), NOTIONAL + SIDE_FEE + COLLATERAL);
    }

    function test_bothFeesScaleWithDeliveredValue() public {
        _settle(_open(QTY, PRICE), 9_995);
        assertEq(escrow.free(treasury), SIDE_FEE * 9_995 / 10_000 * 2);
    }

    function test_noFeeFromEitherSideOnADefault() public {
        uint256 id = _open(QTY, PRICE);
        (,,,,,,, uint64 end,,,,,) = escrow.trades(id);
        vm.warp(end + 6 hours + 1);
        escrow.failUndelivered(id);
        assertEq(escrow.free(treasury), 0);
    }

    function test_aRateChangeLeavesOpenTradesAlone() public {
        uint256 first = _open(QTY, PRICE);
        _setFees(113, 112); // the model's 2028 rate: 2.25% combined

        _settle(first, 10_000);
        assertEq(escrow.free(treasury), SIDE_FEE * 2, "first trade keeps the rate it opened at");

        _settle(_open(QTY, PRICE), 10_000);
        uint256 secondFees = NOTIONAL * 113 / 10_000 + NOTIONAL * 112 / 10_000;
        assertEq(escrow.free(treasury), SIDE_FEE * 2 + secondFees, "second trade pays the new rate");
    }

    function test_eitherFeeAboveTheCapIsRefused() public {
        DvPEscrow.Params memory p = _params();
        p.buyerFeeBps = 1_001;
        vm.prank(admin);
        vm.expectRevert(DvPEscrow.InvalidParams.selector);
        escrow.setParams(p);

        p = _params();
        p.sellerFeeBps = 1_001;
        vm.prank(admin);
        vm.expectRevert(DvPEscrow.InvalidParams.selector);
        escrow.setParams(p);
    }

    function test_onlyParamRoleCanChangeFees() public {
        DvPEscrow.Params memory p = _params();
        bytes32 role = escrow.PARAM_ROLE(); // read first: vm.prank applies to the next external call
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        escrow.setParams(p);
    }

    /// @notice Whatever the rates and uptime, fees move value between accounts and never create it.
    function testFuzz_feesConserveValue(uint16 buyerBps, uint16 sellerBps, uint32 uptime) public {
        buyerBps = uint16(bound(buyerBps, 0, 1_000));
        sellerBps = uint16(bound(sellerBps, 0, 1_000));
        uptime = uint32(bound(uptime, 1, 10_000));
        _setFees(buyerBps, sellerBps);

        uint256 total = escrow.free(buyer) + escrow.free(seller) + escrow.free(treasury);
        _settle(_open(QTY, PRICE), uptime);

        assertEq(escrow.free(buyer) + escrow.free(seller) + escrow.free(treasury), total);
        assertEq(escrow.totalLocked(), 0);
    }

    // ------------------------------------------------------------ Passport fee

    function test_mintChargesTheSellerTheLaunchPrice() public view {
        assertEq(usd.balanceOf(treasury), LAUNCH_FEE_8_GPUS);
        assertEq(passports.annualFee(8), LAUNCH_FEE_8_GPUS);
        assertEq(passports.paidUntil(passportId), block.timestamp + 365 days);
    }

    function test_fullPriceIs60UsdPerGpuAYear() public {
        vm.prank(admin);
        passports.setFee(60e6, 0);
        assertEq(passports.annualFee(8), 480e6);
    }

    function test_mintFailsIfTheSellerHasNotApprovedTheFee() public {
        address unpaid = makeAddr("unpaid");
        vm.prank(admin);
        registry.enroll(unpaid, MemberRegistry.Tier.Participant, uint64(block.timestamp + 365 days), "unpaid-case");

        IComputePassport.Passport memory p = _passport(makeAddr("tee-unpaid"), 8, "host-unpaid");
        bytes[] memory sigs = _quorum(_mintDigest(unpaid, p));
        vm.expectRevert();
        passports.mintPassport(unpaid, p, sigs);
    }

    function test_renewalExtendsFromTheExpiryNotFromToday() public {
        uint64 until = passports.paidUntil(passportId);
        vm.warp(block.timestamp + 100 days);
        _renew();
        assertEq(passports.paidUntil(passportId), until + 365 days);
    }

    function test_renewalAfterALapseStartsFromToday() public {
        vm.warp(block.timestamp + 500 days);
        _renew();
        assertEq(passports.paidUntil(passportId), block.timestamp + 365 days);
    }

    function test_anyoneMayPayButTheTermBelongsToThePassport() public {
        uint64 until = passports.paidUntil(passportId);
        usd.mint(stranger, LAUNCH_FEE_8_GPUS);
        vm.startPrank(stranger);
        usd.approve(address(passports), LAUNCH_FEE_8_GPUS);
        passports.renew(passportId);
        vm.stopPrank();
        assertEq(passports.paidUntil(passportId), until + 365 days);
        assertEq(usd.balanceOf(stranger), 0);
    }

    function test_aLaunchDiscountCannotBeStockpiled() public {
        _renew(); // two years held, the most allowed
        usd.mint(seller, LAUNCH_FEE_8_GPUS);
        vm.prank(seller);
        vm.expectRevert(ComputePassport.PaidTooFarAhead.selector);
        passports.renew(passportId);
    }

    function test_renewingAnUnknownPassportFails() public {
        vm.expectRevert();
        passports.renew(999);
    }

    function test_aPassportCannotSellDeliveryBeyondItsPaidTerm() public {
        uint64 start = passports.paidUntil(passportId) - 1 hours; // the 24-hour window overruns the term
        _expectMatchRevert(start, abi.encodeWithSelector(DvPEscrow.PassportFeeDue.selector));
    }

    function test_renewingRestoresTheRightToSell() public {
        uint64 start = passports.paidUntil(passportId) - 1 hours;
        _renew();
        // The fee check now passes, so the next check in line is the one that stops this order.
        _expectMatchRevert(start, abi.encodeWithSelector(DvPEscrow.NotAttestedForWindow.selector));
    }

    function test_onlyAdminCanSetThePassportFee() public {
        bytes32 role = passports.DEFAULT_ADMIN_ROLE();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        passports.setFee(60e6, 0);
    }

    function test_aDiscountAbove100PercentIsRefused() public {
        vm.prank(admin);
        vm.expectRevert(ComputePassport.InvalidFee.selector);
        passports.setFee(60e6, 10_001);
    }

    function testFuzz_theFeeNeverExceedsFullPrice(uint32 gpus, uint16 discount) public {
        gpus = uint32(bound(gpus, 1, 1_000_000));
        discount = uint16(bound(discount, 0, 10_000));
        vm.prank(admin);
        passports.setFee(60e6, discount);
        assertLe(passports.annualFee(gpus), uint256(gpus) * 60e6);
    }

    function _renew() internal {
        usd.mint(seller, passports.annualFee(8));
        vm.prank(seller);
        passports.renew(passportId);
    }

    function _expectMatchRevert(uint64 start, bytes memory reason) internal {
        DvPEscrow.Order memory b = _order(buyer, true, QTY, PRICE, start);
        DvPEscrow.Order memory s = _order(seller, false, QTY, PRICE, start);
        bytes memory bs = _sign(buyerKey, escrow.hashOrder(b));
        bytes memory ss = _sign(sellerKey, escrow.hashOrder(s));
        vm.prank(matcher);
        vm.expectRevert(reason);
        escrow.matchOrders(b, bs, s, ss, QTY, PRICE, listingId);
    }
}
