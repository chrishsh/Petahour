// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AggregatorV3Interface, IMorphoOracle} from "../interfaces/IPetahour.sol";

/// @title Composable Price Feed Adapter
/// @notice Converts the Chainlink-shaped TCPI feed into the Morpho Blue oracle shape, and fails
/// closed: a stale or non-positive print reverts, which halts new borrowing against old data.
/// Morpho's IOracle returns the price of one collateral atom in loan atoms, scaled by 1e36.
contract TCPIPriceAdapter is IMorphoOracle {
    AggregatorV3Interface public immutable feed;
    uint256 public immutable maxStaleness;
    uint256 public immutable haircutBps;
    uint256 private immutable _scale;

    error StalePrice(uint256 age);
    error BadPrice();

    /// @param haircutBps_ share of TCPI value the oracle counts. GPU-hours are perishable, and what is
    /// counted is also what a liquidator pays, so a lower share means a larger loss in a crash.
    constructor(
        AggregatorV3Interface feed_,
        uint256 maxStaleness_,
        uint256 haircutBps_,
        uint8 collateralDecimals,
        uint8 loanDecimals
    ) {
        feed = feed_;
        maxStaleness = maxStaleness_;
        haircutBps = haircutBps_;
        // 1e36 * loanAtoms / (collateralAtoms * feedUnit)
        _scale = 10 ** (36 + uint256(loanDecimals) - uint256(collateralDecimals) - uint256(feed_.decimals()));
    }

    function price() external view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0) revert BadPrice();
        uint256 age = block.timestamp - updatedAt;
        if (age > maxStaleness) revert StalePrice(age);
        return uint256(answer) * _scale * haircutBps / 10_000;
    }
}
