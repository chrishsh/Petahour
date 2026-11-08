// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {AggregatorV3Interface, IFederation} from "../interfaces/IPetahour.sol";

/// @title Traded Compute Price Index Oracle
/// @notice Stores the daily VWAP that Petahour computes off-chain. Publication needs a federation
/// quorum, and a move beyond maxDeviationBps must be explicitly flagged as an emergency by that
/// same quorum, so a single compromised node can never walk the index away.
/// Each print also anchors inputsHash, a commitment to the exact settled trades behind it. The
/// trades are on-chain too, so anyone can recompute a print and check it: the audit trail a
/// futures regulator or index licensee will ask for.
contract TCPIOracle is EIP712, AccessControl {
    bytes32 public constant PARAM_ROLE = keccak256("PARAM_ROLE");
    bytes32 public constant PUBLISH_TYPEHASH = keccak256(
        "TCPIPublish(bytes32 indexId,uint64 day,int256 answer,uint128 volumeGpuHours,bytes32 methodologyHash,bytes32 inputsHash,bool emergency)"
    );
    uint8 public constant DECIMALS = 8;
    uint256 private constant BPS = 10_000;

    struct Round {
        int256 answer; // USD per unit, 8 decimals
        uint128 volumeGpuHours; // settled volume behind the print
        uint64 day; // days since the Unix epoch
        uint64 publishedAt;
        bytes32 methodologyHash; // binds the print to a published methodology version
        bytes32 inputsHash; // commits to the settled trades behind the print
    }

    IFederation public immutable federation;
    uint16 public maxDeviationBps;
    mapping(bytes32 => Round[]) private _rounds;

    event IndexPublished(bytes32 indexed indexId, uint64 indexed day, int256 answer, uint128 volumeGpuHours, bool emergency);

    error QuorumNotMet();
    error NonPositive();
    error DayNotIncreasing();
    error DeviationTooLarge(uint256 bps);
    error NoData();

    constructor(address admin, IFederation federation_, uint16 maxDeviationBps_) EIP712("Petahour TCPI Oracle", "1") {
        federation = federation_;
        maxDeviationBps = maxDeviationBps_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PARAM_ROLE, admin);
    }

    function publish(
        bytes32 indexId,
        uint64 day,
        int256 answer,
        uint128 volumeGpuHours,
        bytes32 methodologyHash,
        bytes32 inputsHash,
        bool emergency,
        bytes[] calldata sigs
    ) external {
        if (answer <= 0) revert NonPositive();
        Round[] storage rounds = _rounds[indexId];
        uint256 n = rounds.length;
        if (n != 0) {
            Round storage last = rounds[n - 1];
            if (day <= last.day) revert DayNotIncreasing();
            if (!emergency) {
                int256 prev = last.answer;
                uint256 diff = uint256(answer > prev ? answer - prev : prev - answer);
                uint256 bps = diff * BPS / uint256(prev);
                if (bps > maxDeviationBps) revert DeviationTooLarge(bps);
            }
        }
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(PUBLISH_TYPEHASH, indexId, day, answer, volumeGpuHours, methodologyHash, inputsHash, emergency)
            )
        );
        if (!federation.verifyQuorum(digest, sigs)) revert QuorumNotMet();

        rounds.push(Round(answer, volumeGpuHours, day, uint64(block.timestamp), methodologyHash, inputsHash));
        emit IndexPublished(indexId, day, answer, volumeGpuHours, emergency);
    }

    function setMaxDeviationBps(uint16 maxDeviationBps_) external onlyRole(PARAM_ROLE) {
        maxDeviationBps = maxDeviationBps_;
    }

    function roundCount(bytes32 indexId) external view returns (uint256) {
        return _rounds[indexId].length;
    }

    function roundAt(bytes32 indexId, uint256 i) external view returns (Round memory) {
        if (i >= _rounds[indexId].length) revert NoData();
        return _rounds[indexId][i];
    }

    function latest(bytes32 indexId) external view returns (Round memory) {
        uint256 n = _rounds[indexId].length;
        if (n == 0) revert NoData();
        return _rounds[indexId][n - 1];
    }
}

/// @title TCPI Feed
/// @notice Chainlink-shaped read view of one index, so standard DeFi consumers need no changes.
contract TCPIFeed is AggregatorV3Interface {
    TCPIOracle public immutable oracle;
    bytes32 public immutable indexId;
    string private _description;

    constructor(TCPIOracle oracle_, bytes32 indexId_, string memory description_) {
        oracle = oracle_;
        indexId = indexId_;
        _description = description_;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external view returns (string memory) {
        return _description;
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80 roundId) public view returns (uint80, int256, uint256, uint256, uint80) {
        TCPIOracle.Round memory r = oracle.roundAt(indexId, uint256(roundId) - 1);
        return (roundId, r.answer, r.publishedAt, r.publishedAt, roundId);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return getRoundData(uint80(oracle.roundCount(indexId)));
    }
}
