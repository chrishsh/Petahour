// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test stablecoin. Simulated value only: anyone can mint, it is worth nothing.
contract MockUSD is ERC20 {
    constructor() ERC20("Petahour Test USD (simulated)", "tUSD") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
