// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "../Base.t.sol";
import {Federation} from "../../contracts/core/Federation.sol";
import {MemberRegistry} from "../../contracts/core/MemberRegistry.sol";
import {ComputePassport} from "../../contracts/core/ComputePassport.sol";
import {ProofOfDeliveryOracle} from "../../contracts/core/ProofOfDeliveryOracle.sol";
import {CapacityPool} from "../../contracts/core/CapacityPool.sol";
import {IComputePassport} from "../../contracts/interfaces/IPetahour.sol";

contract FederationTest is Base {
    function test_quorumAcceptsSortedSigners() public view {
        bytes32 d = keccak256("msg");
        assertTrue(federation.verifyQuorum(d, _quorum(d)));
    }

    function test_rejectsDuplicateSignerPadding() public view {
        bytes32 d = keccak256("msg");
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(fedKeys[0], d);
        sigs[1] = _sign(fedKeys[0], d);
        assertFalse(federation.verifyQuorum(d, sigs));
    }

    function test_rejectsUnsortedSigners() public view {
        bytes32 d = keccak256("msg");
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(fedKeys[1], d);
        sigs[1] = _sign(fedKeys[0], d);
        assertFalse(federation.verifyQuorum(d, sigs));
    }

    function test_rejectsOutsider() public view {
        bytes32 d = keccak256("msg");
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(fedKeys[0], d);
        sigs[1] = _sign(0xBAD, d);
        assertFalse(federation.verifyQuorum(d, sigs));
    }

    function test_rejectsBelowThreshold() public view {
        bytes32 d = keccak256("msg");
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(fedKeys[0], d);
        assertFalse(federation.verifyQuorum(d, sigs));
    }

    function test_rejectsMalformedSignature() public view {
        bytes32 d = keccak256("msg");
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = hex"1234";
        sigs[1] = _sign(fedKeys[1], d);
        assertFalse(federation.verifyQuorum(d, sigs));
    }

    function test_cannotRemoveBelowThreshold() public {
        vm.startPrank(admin);
        federation.removeSigner(fedAddrs[0]); // 3 -> 2, threshold 2 still reachable
        vm.expectRevert(Federation.InvalidThreshold.selector);
        federation.removeSigner(fedAddrs[1]);
        vm.stopPrank();
    }

    function test_thresholdCannotExceedSigners() public {
        vm.prank(admin);
        vm.expectRevert(Federation.InvalidThreshold.selector);
        federation.setThreshold(4);
    }

    function test_onlyGovernorChangesSigners() public {
        vm.prank(stranger);
        vm.expectRevert();
        federation.addSigner(stranger);
    }
}

contract PassportTest is Base {
    function test_mintNeedsQuorum() public {
        IComputePassport.Passport memory p = _passport(makeAddr("tee2"), 8, "host-2");
        bytes32 d = _mintDigest(seller, p);
        bytes[] memory one = new bytes[](1);
        one[0] = _sign(fedKeys[0], d);
        vm.expectRevert(ComputePassport.QuorumNotMet.selector);
        passports.mintPassport(seller, p, one);
    }

    function test_sellerCannotAlterFederationApprovedSpec() public {
        IComputePassport.Passport memory p = _passport(makeAddr("tee2"), 8, "host-2");
        bytes[] memory sigs = _quorum(_mintDigest(seller, p));
        p.gpuCount = 800; // the seller inflates the GPU count
        vm.expectRevert(ComputePassport.QuorumNotMet.selector);
        passports.mintPassport(seller, p, sigs);
    }

    function test_hostCannotRegisterTwice() public {
        IComputePassport.Passport memory p = _passport(makeAddr("tee2"), 8, "host-1");
        bytes[] memory sigs = _quorum(_mintDigest(seller, p));
        vm.expectRevert(ComputePassport.HostAlreadyRegistered.selector);
        passports.mintPassport(seller, p, sigs);
    }

    function test_teeKeyCannotBackTwoHosts() public {
        IComputePassport.Passport memory p = _passport(teeAddr, 8, "host-2");
        bytes[] memory sigs = _quorum(_mintDigest(seller, p));
        vm.expectRevert(ComputePassport.TeeKeyAlreadyRegistered.selector);
        passports.mintPassport(seller, p, sigs);
    }

    function test_nonMemberCannotReceivePassport() public {
        IComputePassport.Passport memory p = _passport(makeAddr("tee2"), 8, "host-2");
        bytes[] memory sigs = _quorum(_mintDigest(stranger, p));
        vm.expectRevert(abi.encodeWithSelector(ComputePassport.NotEligible.selector, stranger));
        passports.mintPassport(stranger, p, sigs);
    }

    function test_passportIsNonTransferable() public {
        vm.prank(seller);
        vm.expectRevert(ComputePassport.NonTransferable.selector);
        passports.transferFrom(seller, buyer, passportId);
    }

    function test_onlySuspenderCanSuspend() public {
        vm.prank(stranger);
        vm.expectRevert();
        passports.suspend(passportId, "x");
    }

    function test_adminCanReinstate() public {
        bytes32 role = passports.SUSPENDER_ROLE();
        vm.startPrank(admin);
        passports.grantRole(role, admin);
        passports.suspend(passportId, "maintenance");
        assertFalse(oracle.isAttested(passportId));
        passports.reinstate(passportId);
        vm.stopPrank();
        assertTrue(oracle.isAttested(passportId));
    }
}

contract OracleTest is Base {
    function test_attestationNeedsQuorum() public {
        uint64 until = uint64(block.timestamp + 1 days);
        bytes32 d = _attestDigest(passportId, "n1", until);
        bytes[] memory one = new bytes[](1);
        one[0] = _sign(fedKeys[0], d);
        vm.expectRevert(ProofOfDeliveryOracle.QuorumNotMet.selector);
        oracle.submitAttestation(passportId, "rim", "eat", "n1", until, one);
    }

    function test_attestationNonceCannotBeReplayed() public {
        uint64 until = uint64(block.timestamp + 1 days);
        bytes[] memory sigs = _quorum(_attestDigest(passportId, "n1", until));
        oracle.submitAttestation(passportId, "rim", "eat", "n1", until, sigs);
        vm.expectRevert(ProofOfDeliveryOracle.NonceReused.selector);
        oracle.submitAttestation(passportId, "rim", "eat", "n1", until, sigs);
    }

    function test_attestationExpires() public {
        assertTrue(oracle.isAttested(passportId));
        vm.warp(START_TIME + 30 days + 1);
        assertFalse(oracle.isAttested(passportId));
    }

    function test_cannotAttestInThePast() public {
        uint64 until = uint64(block.timestamp);
        bytes[] memory sigs = _quorum(_attestDigest(passportId, "n1", until));
        vm.expectRevert(ProofOfDeliveryOracle.AlreadyExpired.selector);
        oracle.submitAttestation(passportId, "rim", "eat", "n1", until, sigs);
    }

    function test_sealVerifiesOnlyForTeeKey() public view {
        bytes32 d = _sealDigest(1, passportId, "root", 42);
        assertTrue(oracle.verifyTelemetrySeal(1, passportId, "root", 42, _sign(teeKey, d)));
        assertFalse(oracle.verifyTelemetrySeal(1, passportId, "root", 42, _sign(sellerKey, d)));
        assertFalse(oracle.verifyTelemetrySeal(1, passportId, "tampered", 42, _sign(teeKey, d)));
    }
}

contract CapacityPoolTest is Base {
    function test_onlyOwnerCanList() public {
        vm.prank(stranger);
        vm.expectRevert(CapacityPool.NotPassportOwner.selector);
        pool.listCapacity(passportId, uint64(block.timestamp), uint64(block.timestamp + 1 days));
    }

    function test_cannotListUnattestedHost() public {
        uint256 id = _mintPassport(seller, makeAddr("tee2"), 8, "host-2");
        vm.prank(seller);
        vm.expectRevert(CapacityPool.NotAttested.selector);
        pool.listCapacity(id, uint64(block.timestamp), uint64(block.timestamp + 1 days));
    }

    function test_onlyEscrowCanConsume() public {
        vm.prank(stranger);
        vm.expectRevert();
        pool.consume(listingId, passportId, 8, uint64(block.timestamp), 1);
    }

    function test_consumeOutsideListingReverts() public {
        vm.prank(address(escrow));
        vm.expectRevert(CapacityPool.OutsideListing.selector);
        pool.consume(listingId, passportId, 8, uint64(START_TIME + 30 days), 1);
    }

    function test_listingMustMatchPassport() public {
        vm.prank(address(escrow));
        vm.expectRevert(CapacityPool.ListingMismatch.selector);
        pool.consume(listingId, passportId + 1, 8, uint64(block.timestamp), 1);
    }

    /// @notice Regression: a host above 65,535 GPUs must not overflow its hour into the next one.
    function test_hugeHostCannotOverflowIntoNextHour() public {
        uint256 big = _mintPassport(seller, makeAddr("tee-big"), 70_000, "host-big");
        _attest(big, uint64(START_TIME + 30 days));
        vm.prank(seller);
        uint256 bigListing = pool.listCapacity(big, uint64(START_TIME), uint64(START_TIME + 30 days));
        uint64 start = uint64((block.timestamp / 1 hours + 1) * 1 hours);

        vm.startPrank(address(escrow));
        vm.expectPartialRevert(CapacityPool.Oversold.selector);
        pool.consume(bigListing, big, 66_000, start, 1);
        pool.consume(bigListing, big, 65_535, start, 1); // exactly the lane limit is fine
        vm.stopPrank();

        assertEq(pool.allocatedAt(big, uint256(start) / 1 hours), 65_535);
        assertEq(pool.allocatedAt(big, uint256(start) / 1 hours + 1), 0, "next hour untouched");
    }

    /// @notice The packed bit-twiddling must agree with a naive per-hour model for any pattern.
    function testFuzz_packedAllocationMatchesNaiveModel(uint8[12] memory gpus, uint8[12] memory offsets, uint8[12] memory lens)
        public
    {
        uint256 baseHour = uint256(block.timestamp) / 1 hours + 1;
        uint256[] memory model = new uint256[](80);
        for (uint256 i; i < 12; ++i) {
            uint256 g = bound(gpus[i], 1, 8);
            uint256 off = bound(offsets[i], 0, 50);
            uint256 len = bound(lens[i], 1, 24);
            bool fits = true;
            for (uint256 h = off; h < off + len; ++h) {
                if (model[h] + g > 8) fits = false;
            }
            vm.prank(address(escrow));
            if (!fits) vm.expectPartialRevert(CapacityPool.Oversold.selector);
            pool.consume(listingId, passportId, uint64(g * len), uint64((baseHour + off) * 1 hours), uint32(len));
            if (fits) {
                for (uint256 h = off; h < off + len; ++h) {
                    model[h] += g;
                }
            }
        }
        for (uint256 h; h < 80; ++h) {
            assertEq(pool.allocatedAt(passportId, baseHour + h), model[h]);
        }
    }
}

contract MemberRegistryTest is Base {
    function test_lifecycle() public {
        assertTrue(registry.isEligible(buyer));
        vm.prank(admin);
        registry.freeze(buyer, "hit");
        assertFalse(registry.isEligible(buyer));
        vm.prank(admin);
        registry.unfreeze(buyer);
        assertTrue(registry.isEligible(buyer));
        vm.warp(START_TIME + 366 days);
        assertFalse(registry.isEligible(buyer));
    }

    function test_onlyComplianceCanEnroll() public {
        vm.prank(stranger);
        vm.expectRevert();
        registry.enroll(stranger, MemberRegistry.Tier.Participant, uint64(block.timestamp + 1), "x");
    }

    function test_cannotEnrollTierNone() public {
        vm.prank(admin);
        vm.expectRevert(MemberRegistry.InvalidMember.selector);
        registry.enroll(stranger, MemberRegistry.Tier.None, uint64(block.timestamp + 1), "x");
    }
}
