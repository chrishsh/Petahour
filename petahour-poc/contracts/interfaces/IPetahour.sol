// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Anything that can answer "may this wallet touch the protocol?".
/// Implemented by MemberRegistry. Petahour core and Petahour Labs each deploy their OWN
/// instance with a different admin, which is how the legal separation between
/// the onshore venue and the offshore SPV shows up in code.
interface IAccessList {
    function isEligible(address who) external view returns (bool);
}

/// @notice M-of-N verifier federation (Petahour, NCHC, ODM partners, auditor).
interface IFederation {
    function verifyQuorum(bytes32 digest, bytes[] calldata sigs) external view returns (bool);
}

interface IComputePassport {
    struct Passport {
        bytes32 hostIdHash; // keccak of the physical host identifier
        address teeKey; // key sealed inside the attested confidential VM
        bytes32 sku; // e.g. keccak256("B200-180GB-SXM")
        uint32 gpuCount; // GPUs behind this passport
        uint16 pueMilli; // PUE x 1000 (1400 = 1.4)
        uint16 slaBps; // uptime SLA tier (9990 / 9995 / 9999)
        bytes32 gridZone; // Taipower grid zone
        bytes32 topology; // NVLink / InfiniBand / RoCE
        bytes32 metadataHash; // keccak of the full off-chain passport JSON
        bool suspended; // set when a delivery fault is proven
    }

    function getPassport(uint256 id) external view returns (Passport memory);
    function ownerOf(uint256 id) external view returns (address);
    function paidUntil(uint256 id) external view returns (uint64);
    function suspend(uint256 id, bytes32 reason) external;
}

interface IProofOfDeliveryOracle {
    function isAttested(uint256 passportId) external view returns (bool);
    function attestedUntil(uint256 passportId) external view returns (uint64);
    function verifyTelemetrySeal(
        uint256 tradeId,
        uint256 passportId,
        bytes32 telemetryRoot,
        uint256 featureCommitment,
        bytes calldata teeSig
    ) external view returns (bool);
}

interface ICapacityPool {
    function consume(uint256 listingId, uint256 passportId, uint64 gpuHours, uint64 start, uint32 windowHours)
        external;
}

interface IDefaultFund {
    function cover(address defaulter, uint256 amount) external returns (uint256 covered);
    function fundMutual(uint256 amount) external;
}

interface IZkDeliveryAdjudicator {
    function verifyDelivery(
        uint256 tradeId,
        uint256 featureCommitment,
        uint32 claimedUptimeBps,
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c
    ) external view returns (bool);
}

/// @notice Signature of the verifier contract that snarkjs generates.
interface IGroth16Verifier {
    function verifyProof(
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256[5] calldata pubSignals
    ) external view returns (bool);
}

/// @notice Chainlink-compatible read interface, so any DeFi consumer can use TCPI unchanged.
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);
    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80, int256, uint256, uint256, uint80);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @notice Morpho Blue oracle interface: price of 1 collateral atom in loan atoms, scaled 1e36.
interface IMorphoOracle {
    function price() external view returns (uint256);
}
