// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Base} from "../Base.t.sol";
import {DvPEscrow} from "../../contracts/core/DvPEscrow.sol";
import {CapacityPool} from "../../contracts/core/CapacityPool.sol";
import {IComputePassport} from "../../contracts/interfaces/IPetahour.sol";

contract DvPEscrowTest is Base {
    uint64 constant QTY = 192;
    uint64 constant PRICE = 3_680_000; // US$3.68 per GPU-hour, the report's reference price
    uint256 constant NOTIONAL = uint256(QTY) * PRICE;
    uint256 constant FEE = NOTIONAL * 125 / 10_000; // buyer's side
    uint256 constant SELLER_FEE = NOTIONAL * 125 / 10_000;
    uint256 constant COLLATERAL = NOTIONAL * 2_000 / 10_000;

    // ------------------------------------------------------------- happy path

    function test_happyPath_paysSellerAndFeeExactly() public {
        uint256 buyer0 = escrow.free(buyer);
        uint256 seller0 = escrow.free(seller);

        uint256 id = _open(QTY, PRICE);
        assertEq(escrow.free(buyer), buyer0 - NOTIONAL - FEE, "buyer locked");
        assertEq(escrow.free(seller), seller0 - COLLATERAL, "seller collateral locked");
        assertEq(escrow.totalLocked(), NOTIONAL + FEE + COLLATERAL);

        _claim(id, 10_000);
        assertEq(uint8(_status(id)), uint8(DvPEscrow.Status.Claimed));

        vm.warp(block.timestamp + 1 days);
        escrow.finalize(id);

        assertEq(uint8(_status(id)), uint8(DvPEscrow.Status.Settled));
        assertEq(escrow.free(buyer), buyer0 - NOTIONAL - FEE);
        assertEq(escrow.free(seller), seller0 + NOTIONAL - SELLER_FEE);
        assertEq(escrow.free(treasury), FEE + SELLER_FEE);
        assertEq(escrow.totalLocked(), 0);
    }

    function test_buyerCanWaiveWindow() public {
        uint256 id = _open(QTY, PRICE);
        _claim(id, 10_000);
        vm.prank(buyer);
        escrow.acceptDelivery(id);
        assertEq(uint8(_status(id)), uint8(DvPEscrow.Status.Settled));
    }

    function test_onlyBuyerCanWaiveWindow() public {
        uint256 id = _open(QTY, PRICE);
        _claim(id, 10_000);
        vm.prank(stranger);
        vm.expectRevert(DvPEscrow.NotAuthorized.selector);
        escrow.acceptDelivery(id);
    }

    function test_partialDelivery_paysProRataAndSlaCredit() public {
        uint256 buyer0 = escrow.free(buyer);
        uint256 seller0 = escrow.free(seller);
        uint256 id = _open(QTY, PRICE);
        _claim(id, 9_000); // 90% delivered, below the 99.90% SLA tier

        vm.warp(block.timestamp + 1 days);
        escrow.finalize(id);

        uint256 paid = NOTIONAL * 9_000 / 10_000;
        uint256 feeDue = FEE * 9_000 / 10_000;
        uint256 sellerFeeDue = SELLER_FEE * 9_000 / 10_000;
        uint256 credit = (NOTIONAL - paid) * 5_000 / 10_000;
        assertEq(escrow.free(seller), seller0 + paid - sellerFeeDue - credit);
        assertEq(escrow.free(buyer), buyer0 - paid - feeDue + credit);
        assertEq(escrow.free(treasury), feeDue + sellerFeeDue);
    }

    function test_partialDeliveryAboveSla_paysNoCredit() public {
        uint256 seller0 = escrow.free(seller);
        uint256 id = _open(QTY, PRICE);
        _claim(id, 9_995); // above 99.90%
        vm.warp(block.timestamp + 1 days);
        escrow.finalize(id);
        assertEq(escrow.free(seller), seller0 + NOTIONAL * 9_995 / 10_000 - SELLER_FEE * 9_995 / 10_000);
    }

    // ------------------------------------------------- the matcher cannot cheat

    function _sigs(DvPEscrow.Order memory b, DvPEscrow.Order memory s)
        internal
        view
        returns (bytes memory, bytes memory)
    {
        return (_sign(buyerKey, escrow.hashOrder(b)), _sign(sellerKey, escrow.hashOrder(s)));
    }

    function test_matcherCannotChargeAboveBuyerLimit() public {
        uint64 start = uint64(block.timestamp + 1 hours);
        DvPEscrow.Order memory b = _order(buyer, true, QTY, PRICE, start);
        DvPEscrow.Order memory s = _order(seller, false, QTY, PRICE, start);
        (bytes memory bs, bytes memory ss) = _sigs(b, s);
        vm.prank(matcher);
        vm.expectRevert(DvPEscrow.PriceOutsideLimits.selector);
        escrow.matchOrders(b, bs, s, ss, QTY, PRICE + 1, listingId);
    }

    function test_matcherCannotPayBelowSellerLimit() public {
        uint64 start = uint64(block.timestamp + 1 hours);
        DvPEscrow.Order memory b = _order(buyer, true, QTY, PRICE, start);
        DvPEscrow.Order memory s = _order(seller, false, QTY, PRICE, start);
        (bytes memory bs, bytes memory ss) = _sigs(b, s);
        vm.prank(matcher);
        vm.expectRevert(DvPEscrow.PriceOutsideLimits.selector);
        escrow.matchOrders(b, bs, s, ss, QTY, PRICE - 1, listingId);
    }

    function test_matcherCannotForgeBuyerSignature() public {
        uint64 start = uint64(block.timestamp + 1 hours);
        DvPEscrow.Order memory b = _order(buyer, true, QTY, PRICE, start);
        DvPEscrow.Order memory s = _order(seller, false, QTY, PRICE, start);
        bytes memory forged = _sign(sellerKey, escrow.hashOrder(b));
        bytes memory ss = _sign(sellerKey, escrow.hashOrder(s));
        vm.prank(matcher);
        vm.expectRevert(abi.encodeWithSelector(DvPEscrow.BadSignature.selector, buyer));
        escrow.matchOrders(b, forged, s, ss, QTY, PRICE, listingId);
    }

    function test_alteredOrderInvalidatesSignature() public {
        uint64 start = uint64(block.timestamp + 1 hours);
        DvPEscrow.Order memory b = _order(buyer, true, 10, PRICE, start);
        DvPEscrow.Order memory s = _order(seller, false, QTY, PRICE, start);
        (bytes memory bs, bytes memory ss) = _sigs(b, s);
        b.gpuHours = QTY; // matcher inflates the quantity after the buyer signed
        vm.prank(matcher);
        vm.expectRevert(abi.encodeWithSelector(DvPEscrow.BadSignature.selector, buyer));
        escrow.matchOrders(b, bs, s, ss, QTY, PRICE, listingId);
    }

    function test_replayedOrderOverfillReverts() public {
        uint64 start = uint64(block.timestamp + 1 hours);
        DvPEscrow.Order memory b = _order(buyer, true, 100, PRICE, start);
        DvPEscrow.Order memory s = _order(seller, false, 100, PRICE, start);
        (bytes memory bs, bytes memory ss) = _sigs(b, s);
        vm.startPrank(matcher);
        escrow.matchOrders(b, bs, s, ss, 60, PRICE, listingId);
        vm.expectRevert(DvPEscrow.Overfill.selector);
        escrow.matchOrders(b, bs, s, ss, 60, PRICE, listingId);
        escrow.matchOrders(b, bs, s, ss, 40, PRICE, listingId); // the unfilled remainder is fine
        vm.stopPrank();
    }

    function test_cancelledOrderCannotMatch() public {
        uint64 start = uint64(block.timestamp + 1 hours);
        DvPEscrow.Order memory b = _order(buyer, true, QTY, PRICE, start);
        DvPEscrow.Order memory s = _order(seller, false, QTY, PRICE, start);
        (bytes memory bs, bytes memory ss) = _sigs(b, s);
        vm.prank(buyer);
        escrow.cancelOrder(b);
        vm.prank(matcher);
        vm.expectRevert(DvPEscrow.OrderCancelledAlready.selector);
        escrow.matchOrders(b, bs, s, ss, QTY, PRICE, listingId);
    }

    function test_onlyMakerCanCancel() public {
        DvPEscrow.Order memory b = _order(buyer, true, QTY, PRICE, uint64(block.timestamp + 1 hours));
        vm.prank(stranger);
        vm.expectRevert(DvPEscrow.NotAuthorized.selector);
        escrow.cancelOrder(b);
    }

    function test_expiredOrderReverts() public {
        uint64 start = uint64(block.timestamp + 2 hours);
        DvPEscrow.Order memory b = _order(buyer, true, QTY, PRICE, start);
        b.expiry = uint64(block.timestamp + 1 hours);
        DvPEscrow.Order memory s = _order(seller, false, QTY, PRICE, start);
        (bytes memory bs, bytes memory ss) = _sigs(b, s);
        vm.warp(block.timestamp + 90 minutes);
        vm.prank(matcher);
        vm.expectRevert(DvPEscrow.OrderExpired.selector);
        escrow.matchOrders(b, bs, s, ss, QTY, PRICE, listingId);
    }

    function test_swappedSidesRevert() public {
        uint64 start = uint64(block.timestamp + 1 hours);
        DvPEscrow.Order memory b = _order(buyer, true, QTY, PRICE, start);
        DvPEscrow.Order memory s = _order(seller, false, QTY, PRICE, start);
        (bytes memory bs, bytes memory ss) = _sigs(b, s);
        vm.prank(matcher);
        vm.expectRevert(DvPEscrow.BadSides.selector);
        escrow.matchOrders(s, ss, b, bs, QTY, PRICE, listingId);
    }

    function test_onlyMatcherRoleCanMatch() public {
        uint64 start = uint64(block.timestamp + 1 hours);
        DvPEscrow.Order memory b = _order(buyer, true, QTY, PRICE, start);
        DvPEscrow.Order memory s = _order(seller, false, QTY, PRICE, start);
        (bytes memory bs, bytes memory ss) = _sigs(b, s);
        vm.prank(stranger);
        vm.expectRevert();
        escrow.matchOrders(b, bs, s, ss, QTY, PRICE, listingId);
    }

    // --------------------------------------------------- compliance and capacity

    function test_frozenBuyerCannotTrade() public {
        vm.prank(admin);
        registry.freeze(buyer, "denied-party-hit");
        uint64 start = uint64(block.timestamp + 1 hours);
        DvPEscrow.Order memory b = _order(buyer, true, QTY, PRICE, start);
        DvPEscrow.Order memory s = _order(seller, false, QTY, PRICE, start);
        (bytes memory bs, bytes memory ss) = _sigs(b, s);
        vm.prank(matcher);
        vm.expectRevert(abi.encodeWithSelector(DvPEscrow.NotEligible.selector, buyer));
        escrow.matchOrders(b, bs, s, ss, QTY, PRICE, listingId);
    }

    function test_frozenWalletCannotWithdraw() public {
        vm.prank(admin);
        registry.freeze(buyer, "denied-party-hit");
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(DvPEscrow.NotEligible.selector, buyer));
        escrow.withdraw(1);
    }

    function test_nonMemberCannotDeposit() public {
        usd.mint(stranger, 100);
        vm.startPrank(stranger);
        usd.approve(address(escrow), 100);
        vm.expectRevert(abi.encodeWithSelector(DvPEscrow.NotEligible.selector, stranger));
        escrow.deposit(100);
        vm.stopPrank();
    }

    function test_expiredKycCannotTrade() public {
        vm.warp(START_TIME + 366 days);
        _attest(passportId, uint64(block.timestamp + 30 days));
        uint64 start = uint64(block.timestamp + 1 hours);
        DvPEscrow.Order memory b = _order(buyer, true, QTY, PRICE, start);
        DvPEscrow.Order memory s = _order(seller, false, QTY, PRICE, start);
        (bytes memory bs, bytes memory ss) = _sigs(b, s);
        vm.prank(matcher);
        vm.expectRevert(abi.encodeWithSelector(DvPEscrow.NotEligible.selector, buyer));
        escrow.matchOrders(b, bs, s, ss, QTY, PRICE, listingId);
    }

    function test_sameGpuHourCannotBeSoldTwice() public {
        _open(QTY, PRICE); // all 8 GPUs for the window
        uint64 start = uint64(block.timestamp + 1 hours);
        DvPEscrow.Order memory b = _order(buyer, true, 24, PRICE, start);
        DvPEscrow.Order memory s = _order(seller, false, 24, PRICE, start);
        (bytes memory bs, bytes memory ss) = _sigs(b, s);
        vm.prank(matcher);
        vm.expectRevert(abi.encodeWithSelector(CapacityPool.Oversold.selector, uint256(start) / 1 hours));
        escrow.matchOrders(b, bs, s, ss, 24, PRICE, listingId);
    }

    function test_sellingMoreThanTheHostHasReverts() public {
        uint64 start = uint64(block.timestamp + 1 hours);
        DvPEscrow.Order memory b = _order(buyer, true, 193, PRICE, start);
        DvPEscrow.Order memory s = _order(seller, false, 193, PRICE, start);
        (bytes memory bs, bytes memory ss) = _sigs(b, s);
        vm.prank(matcher);
        vm.expectPartialRevert(CapacityPool.Oversold.selector);
        escrow.matchOrders(b, bs, s, ss, 193, PRICE, listingId);
    }

    function test_sellerCannotSellSomeoneElsesPassport() public {
        uint64 start = uint64(block.timestamp + 1 hours);
        DvPEscrow.Order memory b = _order(buyer, true, QTY, PRICE, start);
        DvPEscrow.Order memory s = _order(buyer, false, QTY, PRICE, start); // buyer pretends to sell
        bytes memory bs = _sign(buyerKey, escrow.hashOrder(b));
        bytes memory ss = _sign(buyerKey, escrow.hashOrder(s));
        vm.prank(matcher);
        vm.expectRevert(DvPEscrow.PassportConstraint.selector);
        escrow.matchOrders(b, bs, s, ss, QTY, PRICE, listingId);
    }

    function test_buyerSlaAndZoneConstraintsAreEnforced() public {
        uint64 start = uint64(block.timestamp + 1 hours);
        DvPEscrow.Order memory b = _order(buyer, true, QTY, PRICE, start);
        b.minSlaBps = 9999; // host offers 99.90%
        DvPEscrow.Order memory s = _order(seller, false, QTY, PRICE, start);
        (bytes memory bs, bytes memory ss) = _sigs(b, s);
        vm.prank(matcher);
        vm.expectRevert(DvPEscrow.PassportConstraint.selector);
        escrow.matchOrders(b, bs, s, ss, QTY, PRICE, listingId);

        b.minSlaBps = 0;
        b.gridZone = keccak256("TPC-SOUTH");
        (bs, ss) = _sigs(b, s);
        vm.prank(matcher);
        vm.expectRevert(DvPEscrow.PassportConstraint.selector);
        escrow.matchOrders(b, bs, s, ss, QTY, PRICE, listingId);
    }

    function test_attestationMustCoverDeliveryWindow() public {
        _attest(passportId, uint64(block.timestamp + 2 hours)); // lapses mid-delivery
        uint64 start = uint64(block.timestamp + 1 hours);
        DvPEscrow.Order memory b = _order(buyer, true, QTY, PRICE, start);
        DvPEscrow.Order memory s = _order(seller, false, QTY, PRICE, start);
        (bytes memory bs, bytes memory ss) = _sigs(b, s);
        vm.prank(matcher);
        vm.expectRevert(DvPEscrow.NotAttestedForWindow.selector);
        escrow.matchOrders(b, bs, s, ss, QTY, PRICE, listingId);
    }

    function test_insufficientBuyerFundsReverts() public {
        uint256 all = escrow.free(buyer);
        vm.prank(buyer);
        escrow.withdraw(all);
        uint64 start = uint64(block.timestamp + 1 hours);
        DvPEscrow.Order memory b = _order(buyer, true, QTY, PRICE, start);
        DvPEscrow.Order memory s = _order(seller, false, QTY, PRICE, start);
        (bytes memory bs, bytes memory ss) = _sigs(b, s);
        vm.prank(matcher);
        vm.expectPartialRevert(DvPEscrow.InsufficientFree.selector);
        escrow.matchOrders(b, bs, s, ss, QTY, PRICE, listingId);
    }

    // ------------------------------------------------------------ delivery claim

    function test_claimNeedsTeeSignature() public {
        uint256 id = _open(QTY, PRICE);
        (,,,,,,, uint64 end,,,,,) = escrow.trades(id);
        vm.warp(end);
        bytes memory wrong = _sign(sellerKey, _sealDigest(id, passportId, "root", 999));
        vm.prank(seller);
        vm.expectRevert(DvPEscrow.InvalidSeal.selector);
        escrow.claimDelivery(id, 10_000, "root", 999, wrong);
    }

    function test_sealForAnotherTradeIsRejected() public {
        uint256 id = _open(96, PRICE);
        uint256 other = _open(96, PRICE);
        (,,,,,,, uint64 end,,,,,) = escrow.trades(other);
        vm.warp(end);
        bytes memory sig = _sign(teeKey, _sealDigest(id, passportId, "root", 999));
        vm.prank(seller);
        vm.expectRevert(DvPEscrow.InvalidSeal.selector);
        escrow.claimDelivery(other, 10_000, "root", 999, sig);
    }

    function test_claimBeforeDeliveryEndsReverts() public {
        uint256 id = _open(QTY, PRICE);
        bytes memory sig = _sign(teeKey, _sealDigest(id, passportId, "root", 999));
        vm.prank(seller);
        vm.expectRevert(DvPEscrow.TooEarly.selector);
        escrow.claimDelivery(id, 10_000, "root", 999, sig);
    }

    function test_claimAfterGraceReverts() public {
        uint256 id = _open(QTY, PRICE);
        (,,,,,,, uint64 end,,,,,) = escrow.trades(id);
        vm.warp(uint256(end) + 6 hours + 1);
        bytes memory sig = _sign(teeKey, _sealDigest(id, passportId, "root", 999));
        vm.prank(seller);
        vm.expectRevert(DvPEscrow.TooLate.selector);
        escrow.claimDelivery(id, 10_000, "root", 999, sig);
    }

    function test_strangerCannotClaim() public {
        uint256 id = _open(QTY, PRICE);
        (,,,,,,, uint64 end,,,,,) = escrow.trades(id);
        vm.warp(end);
        bytes memory sig = _sign(teeKey, _sealDigest(id, passportId, "root", 999));
        vm.prank(stranger);
        vm.expectRevert(DvPEscrow.NotAuthorized.selector);
        escrow.claimDelivery(id, 10_000, "root", 999, sig);
    }

    function test_uptimeAbove100PercentReverts() public {
        uint256 id = _open(QTY, PRICE);
        (,,,,,,, uint64 end,,,,,) = escrow.trades(id);
        vm.warp(end);
        bytes memory sig = _sign(teeKey, _sealDigest(id, passportId, "root", 999));
        vm.prank(seller);
        vm.expectRevert(DvPEscrow.InvalidUptime.selector);
        escrow.claimDelivery(id, 10_001, "root", 999, sig);
    }

    function test_finalizeBeforeWindowCloses() public {
        uint256 id = _open(QTY, PRICE);
        _claim(id, 10_000);
        vm.warp(block.timestamp + 1 days - 1);
        vm.expectRevert(DvPEscrow.TooEarly.selector);
        escrow.finalize(id);
    }

    function test_finalizeTwiceReverts() public {
        uint256 id = _open(QTY, PRICE);
        _claim(id, 10_000);
        vm.warp(block.timestamp + 1 days);
        escrow.finalize(id);
        vm.expectRevert(abi.encodeWithSelector(DvPEscrow.WrongStatus.selector, DvPEscrow.Status.Settled));
        escrow.finalize(id);
    }

    // ----------------------------------------------------------------- disputes

    function test_falseChallenge_sellerProvesAndTakesBond() public {
        uint256 seller0 = escrow.free(seller);
        uint256 watcher0 = escrow.free(watcher);
        uint256 id = _open(QTY, PRICE);
        _claim(id, 10_000);

        vm.prank(watcher);
        escrow.challenge(id);
        assertEq(uint8(_status(id)), uint8(DvPEscrow.Status.Challenged));

        (uint256[2] memory a, uint256[2][2] memory b, uint256[2] memory c) = _proof();
        escrow.respondWithProof(id, a, b, c);

        assertEq(uint8(_status(id)), uint8(DvPEscrow.Status.Settled));
        assertEq(escrow.free(seller), seller0 + NOTIONAL - SELLER_FEE + 100e6);
        assertEq(escrow.free(watcher), watcher0 - 100e6);
        assertEq(escrow.totalLocked(), 0);
    }

    function test_invalidProofReverts() public {
        uint256 id = _open(QTY, PRICE);
        _claim(id, 10_000);
        vm.prank(watcher);
        escrow.challenge(id);
        verifier.setResult(false);
        (uint256[2] memory a, uint256[2][2] memory b, uint256[2] memory c) = _proof();
        vm.expectRevert(DvPEscrow.InvalidProof.selector);
        escrow.respondWithProof(id, a, b, c);
    }

    function test_proofAfterDeadlineReverts() public {
        uint256 id = _open(QTY, PRICE);
        _claim(id, 10_000);
        vm.prank(watcher);
        escrow.challenge(id);
        vm.warp(block.timestamp + 6 hours + 1);
        (uint256[2] memory a, uint256[2][2] memory b, uint256[2] memory c) = _proof();
        vm.expectRevert(DvPEscrow.TooLate.selector);
        escrow.respondWithProof(id, a, b, c);
    }

    function test_provenFraud_runsTheFullWaterfall() public {
        usd.mint(address(this), 10_000e6);
        usd.approve(address(fund), 10_000e6);
        fund.fundMutual(10_000e6);

        uint256 buyer0 = escrow.free(buyer);
        uint256 seller0 = escrow.free(seller);
        uint256 watcher0 = escrow.free(watcher);

        uint256 id = _open(QTY, PRICE);
        _claim(id, 10_000);
        vm.prank(watcher);
        escrow.challenge(id);
        vm.warp(block.timestamp + 6 hours + 1);
        escrow.resolveTimeout(id);

        uint256 reward = COLLATERAL * 1_000 / 10_000;
        uint256 penalty = NOTIONAL * 2_500 / 10_000;
        uint256 fromCollateral = COLLATERAL - reward; // collateral runs out before the penalty does
        uint256 fromFund = penalty - fromCollateral;

        assertEq(uint8(_status(id)), uint8(DvPEscrow.Status.Defaulted));
        assertEq(escrow.free(buyer), buyer0 + penalty, "buyer whole plus penalty");
        assertEq(escrow.free(seller), seller0 - COLLATERAL, "seller loses collateral");
        assertEq(escrow.free(watcher), watcher0 + reward, "challenger rewarded, bond back");
        assertEq(fund.mutualPool(), 10_000e6 - fromFund, "fund covered the shortfall");
        assertEq(escrow.totalLocked(), 0);
        assertTrue(passports.getPassport(passportId).suspended, "host suspended");
        assertFalse(oracle.isAttested(passportId));
    }

    function test_fundedShortfallIsCappedByFundSize() public {
        uint256 buyer0 = escrow.free(buyer);
        uint256 id = _open(QTY, PRICE);
        _claim(id, 10_000);
        vm.prank(watcher);
        escrow.challenge(id);
        vm.warp(block.timestamp + 6 hours + 1);
        escrow.resolveTimeout(id); // the fund is empty

        uint256 reward = COLLATERAL * 1_000 / 10_000;
        assertEq(escrow.free(buyer), buyer0 + COLLATERAL - reward, "buyer whole, penalty only from collateral");
    }

    function test_defaulterContributionIsUsedBeforeMutualPool() public {
        usd.mint(seller, 1e6);
        vm.startPrank(seller);
        usd.approve(address(fund), 1e6);
        fund.contribute(1e6);
        vm.stopPrank();
        usd.mint(address(this), 10_000e6);
        usd.approve(address(fund), 10_000e6);
        fund.fundMutual(10_000e6);

        uint256 id = _open(QTY, PRICE);
        _claim(id, 10_000);
        vm.prank(watcher);
        escrow.challenge(id);
        vm.warp(block.timestamp + 6 hours + 1);
        escrow.resolveTimeout(id);

        uint256 fromCollateral = COLLATERAL - COLLATERAL * 1_000 / 10_000;
        uint256 shortfall = NOTIONAL * 2_500 / 10_000 - fromCollateral;
        assertEq(fund.contributions(seller), 0);
        assertEq(fund.mutualPool(), 10_000e6 - (shortfall - 1e6));
    }

    function test_leftoverCollateralIsSlashedToMutualPool() public {
        DvPEscrow.Params memory p = _params();
        p.penaltyBps = 500;
        vm.prank(admin);
        escrow.setParams(p);

        uint256 id = _open(QTY, PRICE);
        _claim(id, 10_000);
        vm.prank(watcher);
        escrow.challenge(id);
        vm.warp(block.timestamp + 6 hours + 1);
        escrow.resolveTimeout(id);

        uint256 reward = COLLATERAL * 1_000 / 10_000;
        uint256 penalty = NOTIONAL * 500 / 10_000;
        assertEq(fund.mutualPool(), COLLATERAL - reward - penalty);
    }

    function test_undeliveredTradeDefaultsAfterGrace() public {
        uint256 buyer0 = escrow.free(buyer);
        uint256 id = _open(QTY, PRICE);
        (,,,,,,, uint64 end,,,,,) = escrow.trades(id);
        vm.warp(uint256(end) + 6 hours);
        vm.expectRevert(DvPEscrow.TooEarly.selector);
        escrow.failUndelivered(id);
        vm.warp(uint256(end) + 6 hours + 1);
        escrow.failUndelivered(id);
        assertEq(uint8(_status(id)), uint8(DvPEscrow.Status.Defaulted));
        assertEq(escrow.free(buyer), buyer0 + COLLATERAL, "no challenger, so all collateral to buyer");
    }

    function test_challengeAfterWindowReverts() public {
        uint256 id = _open(QTY, PRICE);
        _claim(id, 10_000);
        vm.warp(block.timestamp + 1 days);
        vm.prank(watcher);
        vm.expectRevert(DvPEscrow.TooLate.selector);
        escrow.challenge(id);
    }

    function test_nonMemberCannotChallenge() public {
        uint256 id = _open(QTY, PRICE);
        _claim(id, 10_000);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(DvPEscrow.NotEligible.selector, stranger));
        escrow.challenge(id);
    }

    function test_cannotFinalizeWhileChallenged() public {
        uint256 id = _open(QTY, PRICE);
        _claim(id, 10_000);
        vm.prank(watcher);
        escrow.challenge(id);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(abi.encodeWithSelector(DvPEscrow.WrongStatus.selector, DvPEscrow.Status.Challenged));
        escrow.finalize(id);
    }

    function _rulingDigest(uint256 id, bool fault) internal view returns (bytes32) {
        return _digest(
            "Petahour DvP Escrow",
            address(escrow),
            keccak256(abi.encode(escrow.RULING_TYPEHASH(), id, fault, bytes32("evidence")))
        );
    }

    function test_federationRulingForSeller() public {
        uint256 id = _open(QTY, PRICE);
        _claim(id, 10_000);
        vm.prank(watcher);
        escrow.challenge(id);
        escrow.federationResolve(id, false, "evidence", _quorum(_rulingDigest(id, false)));
        assertEq(uint8(_status(id)), uint8(DvPEscrow.Status.Settled));
    }

    function test_federationRulingAgainstSeller() public {
        uint256 id = _open(QTY, PRICE);
        _claim(id, 10_000);
        vm.prank(watcher);
        escrow.challenge(id);
        escrow.federationResolve(id, true, "evidence", _quorum(_rulingDigest(id, true)));
        assertEq(uint8(_status(id)), uint8(DvPEscrow.Status.Defaulted));
    }

    function test_rulingCannotBeFlipped() public {
        uint256 id = _open(QTY, PRICE);
        _claim(id, 10_000);
        vm.prank(watcher);
        escrow.challenge(id);
        bytes[] memory sigs = _quorum(_rulingDigest(id, true));
        vm.expectRevert(DvPEscrow.QuorumNotMet.selector);
        escrow.federationResolve(id, false, "evidence", sigs);
    }

    // --------------------------------------------------------------------- fuzz

    /// @notice Every settlement path conserves value, for any size, price and uptime.
    function testFuzz_valueIsConserved(uint64 qty, uint64 price, uint32 uptime, uint8 path) public {
        qty = uint64(bound(qty, 1, QTY));
        price = uint64(bound(price, 1, 10_000_000));
        uptime = uint32(bound(uptime, 0, 10_000));

        uint256 id = _open(qty, price);
        _claim(id, uptime);

        uint256 p = path % 3;
        if (p == 0) {
            vm.warp(block.timestamp + 1 days);
            escrow.finalize(id);
        } else if (p == 1) {
            vm.prank(watcher);
            escrow.challenge(id);
            (uint256[2] memory a, uint256[2][2] memory b, uint256[2] memory c) = _proof();
            escrow.respondWithProof(id, a, b, c);
        } else {
            vm.prank(watcher);
            escrow.challenge(id);
            vm.warp(block.timestamp + 6 hours + 1);
            escrow.resolveTimeout(id);
        }

        assertEq(escrow.totalLocked(), 0, "nothing left locked");
        uint256 ledger = escrow.free(buyer) + escrow.free(seller) + escrow.free(watcher) + escrow.free(treasury);
        assertEq(usd.balanceOf(address(escrow)), ledger, "ledger equals tokens held");
    }
}
