// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Base} from "../Base.t.sol";
import {DvPEscrow} from "../../contracts/core/DvPEscrow.sol";
import {MemberRegistry} from "../../contracts/core/MemberRegistry.sol";
import {ComputePassport} from "../../contracts/core/ComputePassport.sol";

/// @notice Drives the escrow with random lifecycle actions.
contract EscrowHandler is Base {
    DvPEscrow internal target;
    uint256[] public tradeIds;
    // Ghost counters: a try/catch handler can pass while doing nothing, so count real progress.
    uint256 public opened;
    uint256 public claimed;
    uint256 public challenged;
    uint256 public settled;
    uint256 public defaulted;
    ComputePassport internal passportsRef;
    address internal adminRef;

    function bind(
        DvPEscrow escrow_,
        address buyer_,
        uint256 buyerKey_,
        address seller_,
        uint256 sellerKey_,
        uint256 teeKey_,
        address matcher_,
        address watcher_,
        uint256 passportId_,
        uint256 listingId_,
        address oracleAddr_,
        ComputePassport passports_,
        address admin_
    ) external {
        passportsRef = passports_;
        adminRef = admin_;
        target = escrow_;
        buyer = buyer_;
        buyerKey = buyerKey_;
        seller = seller_;
        sellerKey = sellerKey_;
        teeKey = teeKey_;
        matcher = matcher_;
        watcher = watcher_;
        passportId = passportId_;
        listingId = listingId_;
        oracleAddr = oracleAddr_;
    }

    address internal oracleAddr;

    function open(uint64 qty, uint64 price) external {
        qty = uint64(bound(qty, 1, 8));
        price = uint64(bound(price, 1, 10_000_000));
        uint64 start = uint64(block.timestamp + 1 hours);
        DvPEscrow.Order memory b = _mk(buyer, true, qty, price, start);
        DvPEscrow.Order memory s = _mk(seller, false, qty, price, start);
        bytes memory bs = _sign(buyerKey, target.hashOrder(b));
        bytes memory ss = _sign(sellerKey, target.hashOrder(s));
        vm.prank(matcher);
        try target.matchOrders(b, bs, s, ss, qty, price, listingId) returns (uint256 id) {
            tradeIds.push(id);
            opened++;
        } catch {}
    }

    function _mk(address maker, bool isBuy, uint64 qty, uint64 limit, uint64 start)
        internal
        returns (DvPEscrow.Order memory o)
    {
        o = DvPEscrow.Order({
            maker: maker,
            isBuy: isBuy,
            sku: SKU,
            passportId: isBuy ? 0 : passportId,
            gpuHours: qty,
            limitPriceE6: limit,
            deliveryStart: start,
            windowHours: 1,
            minSlaBps: 0,
            gridZone: bytes32(0),
            expiry: start,
            salt: ++salt
        });
    }

    /// @dev A default suspends the host. Reinstate it, or the run could never open another trade.
    function _reinstate() internal {
        vm.prank(adminRef);
        passportsRef.reinstate(passportId);
    }

    function _pick(uint256 i) internal view returns (uint256) {
        return tradeIds[i % tradeIds.length];
    }

    function claim(uint256 i, uint32 uptime) external {
        if (tradeIds.length == 0) return;
        uint256 id = _pick(i);
        (,,,,,,, uint64 end,,,,,) = target.trades(id);
        if (block.timestamp < end) vm.warp(end);
        bytes32 structHash = keccak256(
            abi.encode(keccak256("TelemetrySeal(uint256 tradeId,uint256 passportId,bytes32 telemetryRoot,uint256 featureCommitment)"), id, passportId, bytes32("r"), uint256(1))
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Petahour Proof of Delivery")),
                keccak256(bytes("1")),
                block.chainid,
                oracleAddr
            )
        );
        bytes memory sig = _sign(teeKey, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        vm.prank(seller);
        try target.claimDelivery(id, uint32(bound(uptime, 0, 10_000)), "r", 1, sig) {
            claimed++;
        } catch {}
    }

    function challenge(uint256 i) external {
        if (tradeIds.length == 0) return;
        vm.prank(watcher);
        try target.challenge(_pick(i)) {
            challenged++;
        } catch {}
    }

    function prove(uint256 i) external {
        if (tradeIds.length == 0) return;
        (uint256[2] memory a, uint256[2][2] memory b, uint256[2] memory c) = _proof();
        try target.respondWithProof(_pick(i), a, b, c) {
            settled++;
        } catch {}
    }

    function timeout(uint256 i) external {
        if (tradeIds.length == 0) return;
        try target.resolveTimeout(_pick(i)) {
            defaulted++;
            _reinstate();
        } catch {}
    }

    function finalize(uint256 i) external {
        if (tradeIds.length == 0) return;
        try target.finalize(_pick(i)) {
            settled++;
        } catch {}
    }

    function failUndelivered(uint256 i) external {
        if (tradeIds.length == 0) return;
        try target.failUndelivered(_pick(i)) {
            defaulted++;
            _reinstate();
        } catch {}
    }

    function skip(uint32 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 8 hours));
    }

    function withdrawSome(uint96 amount) external {
        uint256 bal = target.free(buyer);
        if (bal == 0) return;
        vm.prank(buyer);
        try target.withdraw(bound(amount, 0, bal)) {} catch {}
    }
}

contract EscrowInvariantTest is Base {
    EscrowHandler handler;

    function setUp() public override {
        super.setUp();
        // Keep the host attested and members valid for the whole run.
        _attest(passportId, uint64(START_TIME + 3650 days));
        vm.prank(seller);
        listingId = pool.listCapacity(passportId, uint64(START_TIME), uint64(START_TIME + 3650 days));
        vm.startPrank(admin);
        uint64 far = uint64(START_TIME + 3650 days);
        registry.enroll(buyer, MemberRegistry.Tier.Participant, far, "b");
        registry.enroll(seller, MemberRegistry.Tier.Participant, far, "s");
        registry.enroll(watcher, MemberRegistry.Tier.Participant, far, "w");
        vm.stopPrank();

        handler = new EscrowHandler();
        handler.bind(escrow, buyer, buyerKey, seller, sellerKey, teeKey, matcher, watcher, passportId, listingId, address(oracle), passports, admin);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.open.selector;
        selectors[1] = handler.claim.selector;
        selectors[2] = handler.challenge.selector;
        selectors[3] = handler.prove.selector;
        selectors[4] = handler.timeout.selector;
        selectors[5] = handler.finalize.selector;
        selectors[6] = handler.failUndelivered.selector;
        selectors[7] = handler.skip.selector;
        selectors[8] = handler.withdrawSome.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice Forge resets state between runs, so each run appends its counters to a file.
    /// scripts/invariant_coverage.py sums them and fails if any settlement path was never reached.
    function afterInvariant() public {
        vm.writeLine(
            "reports/invariant_runs.csv",
            string.concat(
                vm.toString(handler.opened()), ",",
                vm.toString(handler.claimed()), ",",
                vm.toString(handler.challenged()), ",",
                vm.toString(handler.settled()), ",",
                vm.toString(handler.defaulted())
            )
        );
    }

    /// @notice The escrow must always hold exactly what its ledger says it owes.
    function invariant_escrowIsFullyBacked() public view {
        uint256 ledger = escrow.free(buyer) + escrow.free(seller) + escrow.free(watcher) + escrow.free(treasury)
            + escrow.totalLocked();
        assertEq(usd.balanceOf(address(escrow)), ledger);
    }
}
