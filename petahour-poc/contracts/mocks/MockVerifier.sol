// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IGroth16Verifier} from "../interfaces/IPetahour.sol";

/// @notice Unit-test stand-in, so escrow logic can be tested apart from real proofs.
/// Never deployed outside tests. Real-proof coverage lives in test/zk.
contract MockVerifier is IGroth16Verifier {
    bool public result = true;

    function setResult(bool r) external {
        result = r;
    }

    function verifyProof(uint256[2] calldata, uint256[2][2] calldata, uint256[2] calldata, uint256[5] calldata)
        external
        view
        returns (bool)
    {
        return result;
    }
}
