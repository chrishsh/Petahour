// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {stdJson} from "forge-std/StdJson.sol";
import {Base} from "../Base.t.sol";
import {DvPEscrow} from "../../contracts/core/DvPEscrow.sol";
import {Groth16Verifier} from "../../contracts/zk/Groth16Verifier.sol";
import {IGroth16Verifier} from "../../contracts/interfaces/IPetahour.sol";

/// @notice No mocks here: a real Groth16 proof from snarkjs, checked by the generated verifier.
contract RealProofTest is Base {
    using stdJson for string;

    uint256 commitment;
    uint32 claimed;
    uint256[2] a;
    uint256[2][2] b;
    uint256[2] c;

    function _verifierForEscrow() internal override returns (IGroth16Verifier) {
        return IGroth16Verifier(address(new Groth16Verifier()));
    }

    function setUp() public override {
        super.setUp();
        string memory j = vm.readFile("test/fixtures/proof.json");
        commitment = vm.parseUint(j.readString(".commitment"));
        claimed = uint32(j.readUint(".claimedUptimeBps"));
        a = [vm.parseUint(j.readString(".a[0]")), vm.parseUint(j.readString(".a[1]"))];
        b = [
            [vm.parseUint(j.readString(".b[0][0]")), vm.parseUint(j.readString(".b[0][1]"))],
            [vm.parseUint(j.readString(".b[1][0]")), vm.parseUint(j.readString(".b[1][1]"))]
        ];
        c = [vm.parseUint(j.readString(".c[0]")), vm.parseUint(j.readString(".c[1]"))];
        uint256 modelHash = vm.parseUint(j.readString(".modelHash"));
        uint256 threshold = vm.parseUint(j.readString(".threshold"));
        vm.prank(admin);
        adjudicator.setModel(modelHash, threshold);
    }

    function _challenged(uint32 uptime, uint256 commit) internal returns (uint256 id) {
        id = _open(192, 3_680_000);
        _claimWith(id, uptime, commit);
        vm.prank(watcher);
        escrow.challenge(id);
    }

    function test_realProofSettlesDisputeOnChain() public {
        uint256 id = _challenged(claimed, commitment);
        assertEq(id, 1, "fixture is bound to trade 1");
        uint256 gasBefore = gasleft();
        escrow.respondWithProof(id, a, b, c);
        emit log_named_uint("gas: respondWithProof with real Groth16 verification", gasBefore - gasleft());
        assertEq(uint8(_status(id)), uint8(DvPEscrow.Status.Settled));
    }

    function test_tamperedProofFails() public {
        uint256 id = _challenged(claimed, commitment);
        uint256[2] memory bad = [a[0] + 1, a[1]];
        vm.expectRevert(DvPEscrow.InvalidProof.selector);
        escrow.respondWithProof(id, bad, b, c);
    }

    function test_proofForOtherCommitmentFails() public {
        uint256 id = _challenged(claimed, commitment + 1);
        vm.expectRevert(DvPEscrow.InvalidProof.selector);
        escrow.respondWithProof(id, a, b, c);
    }

    function test_proofCannotSupportHigherClaim() public {
        // The seller claims 100% uptime but the proof only covers 99.75%.
        uint256 id = _challenged(10_000, commitment);
        vm.expectRevert(DvPEscrow.InvalidProof.selector);
        escrow.respondWithProof(id, a, b, c);
    }

    function test_proofCannotBeReplayedOnAnotherTrade() public {
        uint256 first = _open(96, 3_680_000);
        uint256 second = _open(96, 3_680_000);
        assertEq(first, 1);
        _claimWith(second, claimed, commitment);
        vm.prank(watcher);
        escrow.challenge(second);
        vm.expectRevert(DvPEscrow.InvalidProof.selector);
        escrow.respondWithProof(second, a, b, c); // proof was made for trade 1
    }

    function test_proofFailsAfterModelRotation() public {
        uint256 id = _challenged(claimed, commitment);
        uint256 current = adjudicator.modelHash();
        uint256 threshold = adjudicator.threshold();
        vm.prank(admin);
        adjudicator.setModel(current + 1, threshold);
        vm.expectRevert(DvPEscrow.InvalidProof.selector);
        escrow.respondWithProof(id, a, b, c);
    }

    function test_proofFailsWhenThresholdRaised() public {
        uint256 id = _challenged(claimed, commitment);
        uint256 current = adjudicator.modelHash();
        uint256 threshold = adjudicator.threshold();
        vm.prank(admin);
        adjudicator.setModel(current, threshold + 1);
        vm.expectRevert(DvPEscrow.InvalidProof.selector);
        escrow.respondWithProof(id, a, b, c);
    }
}
