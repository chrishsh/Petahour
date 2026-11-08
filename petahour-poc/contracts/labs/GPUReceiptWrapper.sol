// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {GPUWarehouseReceipt} from "./GPUWarehouseReceipt.sol";
import {IAccessList} from "../interfaces/IPetahour.sol";

/// @title Wrapped GPU Receipt
/// @notice Morpho Blue accepts ERC-20 collateral only, so an ERC-721 receipt cannot be posted
/// directly. This wrapper turns receipts of one SKU into a transfer-restricted ERC-20 where
/// 1e18 units equal one GPU-hour. The allow-list still applies to every transfer.
contract GPUReceiptWrapper is ERC20, IERC721Receiver {
    GPUWarehouseReceipt public immutable receipts;
    IAccessList public immutable labsAccess;
    bytes32 public immutable sku;

    mapping(uint256 => bool) public wrapped;

    event Wrapped(uint256 indexed receiptId, address indexed by, uint256 amount);
    event Unwrapped(uint256 indexed receiptId, address indexed by, uint256 amount);

    error NotEligible(address who);
    error WrongSku();
    error ReceiptExpired();
    error NotWrapped();

    constructor(GPUWarehouseReceipt receipts_, IAccessList labsAccess_, bytes32 sku_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
    {
        receipts = receipts_;
        labsAccess = labsAccess_;
        sku = sku_;
    }

    function wrap(uint256 receiptId) external returns (uint256 amount) {
        GPUWarehouseReceipt.Receipt memory r = receipts.getReceipt(receiptId);
        if (r.sku != sku) revert WrongSku();
        if (r.expiry <= block.timestamp) revert ReceiptExpired();
        wrapped[receiptId] = true;
        amount = uint256(r.gpuHours) * 1e18;
        receipts.transferFrom(msg.sender, address(this), receiptId);
        _mint(msg.sender, amount);
        emit Wrapped(receiptId, msg.sender, amount);
    }

    function unwrap(uint256 receiptId) external returns (uint256 amount) {
        if (!wrapped[receiptId]) revert NotWrapped();
        wrapped[receiptId] = false;
        amount = uint256(receipts.getReceipt(receiptId).gpuHours) * 1e18;
        _burn(msg.sender, amount);
        receipts.transferFrom(address(this), msg.sender, receiptId);
        emit Unwrapped(receiptId, msg.sender, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (to != address(0) && !labsAccess.isEligible(to)) revert NotEligible(to);
        super._update(from, to, value);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
