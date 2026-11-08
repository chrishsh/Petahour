// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {
    IAccessList,
    ICapacityPool,
    IComputePassport,
    IDefaultFund,
    IFederation,
    IProofOfDeliveryOracle,
    IZkDeliveryAdjudicator
} from "../interfaces/IPetahour.sol";

/// @title Delivery-versus-Payment Escrow
/// @notice Settlement core. Lifecycle of one trade:
///
///   matchOrders -> Open -> claimDelivery -> Claimed --(T+1 window passes)--> finalize -> Settled
///                                              |
///                                         challenge -> Challenged
///                                              |-- respondWithProof (zkML) -> Settled, challenger loses bond
///                                              |-- no proof in time        -> Defaulted, seller slashed
///                                              '-- federation ruling       -> either outcome
///
/// The off-chain engine discovers the price, but it cannot move funds on its own: every trade
/// needs an EIP-712 order signed by both the buyer and the seller, and this contract checks
/// those limits itself.
contract DvPEscrow is AccessControl, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    bytes32 public constant MATCHER_ROLE = keccak256("MATCHER_ROLE");
    bytes32 public constant RELAY_ROLE = keccak256("RELAY_ROLE");
    bytes32 public constant PARAM_ROLE = keccak256("PARAM_ROLE");

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(address maker,bool isBuy,bytes32 sku,uint256 passportId,uint64 gpuHours,uint64 limitPriceE6,uint64 deliveryStart,uint32 windowHours,uint16 minSlaBps,bytes32 gridZone,uint64 expiry,uint256 salt)"
    );
    bytes32 public constant RULING_TYPEHASH =
        keccak256("FederationRuling(uint256 tradeId,bool sellerAtFault,bytes32 evidenceHash)");

    uint256 private constant BPS = 10_000;

    struct Order {
        address maker;
        bool isBuy;
        bytes32 sku;
        uint256 passportId; // seller: the host sold. buyer: 0 means any qualifying host
        uint64 gpuHours;
        uint64 limitPriceE6; // USD per GPU-hour, 6 decimals
        uint64 deliveryStart;
        uint32 windowHours;
        uint16 minSlaBps; // buyer constraint, checked against the passport
        bytes32 gridZone; // buyer constraint, 0 means any zone
        uint64 expiry;
        uint256 salt;
    }

    enum Status {
        None,
        Open,
        Claimed,
        Challenged,
        Settled,
        Defaulted
    }

    struct Trade {
        address buyer;
        address seller;
        uint256 passportId;
        bytes32 sku;
        uint64 gpuHours;
        uint64 priceE6;
        uint64 start;
        uint64 end;
        uint128 notional;
        uint128 buyerFee;
        uint128 sellerFee;
        uint128 sellerCollateral;
        Status status;
    }

    struct Claim {
        uint32 uptimeBps;
        uint64 claimedAt;
        uint64 responseDeadline;
        address challenger;
        uint128 bond;
        bytes32 telemetryRoot; // Merkle root of hourly telemetry, for opML re-execution
        uint256 featureCommitment; // Poseidon commitment, for the zkML proof
    }

    struct Params {
        uint32 disputeWindow; // the T+1 window, in seconds
        uint32 responseWindow; // how long a seller has to answer a challenge
        uint32 claimGrace; // how long after delivery ends a claim may be posted
        uint16 buyerFeeBps; // marketplace fee on delivered value, locked with the buyer's funds
        uint16 sellerFeeBps; // marketplace fee on delivered value, taken from the seller's proceeds
        uint16 sellerCollateralBps; // delivery-SLA collateral, as a share of notional
        uint16 penaltyBps; // compensation owed to the buyer on a proven fault
        uint16 challengerRewardBps; // share of seller collateral paid to a successful challenger
        uint16 slaCreditBps; // service credit on undelivered value when uptime misses the SLA
        uint128 challengeBond; // posted by a challenger, lost on a false challenge
    }

    IERC20 public immutable token;
    IAccessList public immutable access;
    IComputePassport public immutable passports;
    IProofOfDeliveryOracle public immutable oracle;
    ICapacityPool public immutable capacity;
    IDefaultFund public immutable defaultFund;
    IZkDeliveryAdjudicator public immutable adjudicator;
    IFederation public immutable federation;
    address public immutable treasury;

    Params public params;
    uint256 public nextTradeId = 1;

    mapping(address => uint256) public free; // withdrawable balance
    mapping(uint256 => Trade) public trades;
    mapping(uint256 => Claim) public claims;
    mapping(bytes32 => uint64) public filled; // order hash => GPU-hours already matched
    mapping(bytes32 => bool) public cancelled;
    uint256 public totalLocked; // everything held against live trades and bonds

    event Deposited(address indexed who, uint256 amount);
    event Withdrawn(address indexed who, uint256 amount);
    event OrderCancelled(bytes32 indexed orderHash, address indexed maker);
    event TradeOpened(
        uint256 indexed tradeId,
        address indexed buyer,
        address indexed seller,
        uint256 passportId,
        bytes32 sku,
        uint64 gpuHours,
        uint64 priceE6,
        uint64 start,
        uint64 end
    );
    event DeliveryClaimed(
        uint256 indexed tradeId, uint32 uptimeBps, bytes32 telemetryRoot, uint256 featureCommitment, uint64 finalizableAt
    );
    event DeliveryChallenged(uint256 indexed tradeId, address indexed challenger, uint128 bond, uint64 responseDeadline);
    event ChallengeDefeated(uint256 indexed tradeId, address indexed challenger, uint128 bondToSeller);
    event TradeSettled(
        uint256 indexed tradeId,
        uint256 deliveredValue,
        uint256 buyerRefund,
        uint256 buyerFee,
        uint256 sellerFee,
        uint256 slaCredit
    );
    event TradeDefaulted(
        uint256 indexed tradeId,
        uint256 buyerRefund,
        uint256 fromCollateral,
        uint256 fromDefaultFund,
        uint256 challengerReward,
        uint256 slashedToFund
    );
    event ParamsChanged(Params params);

    error BadSides();
    error OrderMismatch();
    error PriceOutsideLimits();
    error OrderExpired();
    error OrderCancelledAlready();
    error Overfill();
    error BadSignature(address maker);
    error NotEligible(address who);
    error PassportConstraint();
    error PassportFeeDue();
    error NotAttestedForWindow();
    error DeliveryInPast();
    error InsufficientFree(address who, uint256 needed, uint256 available);
    error WrongStatus(Status actual);
    error TooEarly();
    error TooLate();
    error NotAuthorized();
    error InvalidUptime();
    error InvalidSeal();
    error InvalidProof();
    error QuorumNotMet();
    error InvalidParams();

    struct Deps {
        IERC20 token;
        IAccessList access;
        IComputePassport passports;
        IProofOfDeliveryOracle oracle;
        ICapacityPool capacity;
        IDefaultFund defaultFund;
        IZkDeliveryAdjudicator adjudicator;
        IFederation federation;
        address treasury;
    }

    constructor(address admin, Deps memory d, Params memory p) EIP712("Petahour DvP Escrow", "1") {
        token = d.token;
        access = d.access;
        passports = d.passports;
        oracle = d.oracle;
        capacity = d.capacity;
        defaultFund = d.defaultFund;
        adjudicator = d.adjudicator;
        federation = d.federation;
        treasury = d.treasury;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PARAM_ROLE, admin);
        _setParams(p);
    }

    // ------------------------------------------------------------------ funds

    function deposit(uint256 amount) external nonReentrant {
        if (!access.isEligible(msg.sender)) revert NotEligible(msg.sender);
        token.safeTransferFrom(msg.sender, address(this), amount);
        free[msg.sender] += amount;
        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant {
        // A frozen wallet keeps its balance on the ledger but cannot move it out.
        if (msg.sender != treasury && !access.isEligible(msg.sender)) revert NotEligible(msg.sender);
        uint256 balance = free[msg.sender];
        if (balance < amount) revert InsufficientFree(msg.sender, amount, balance);
        free[msg.sender] = balance - amount;
        token.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // ------------------------------------------------------------------ orders

    function hashOrder(Order calldata o) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    ORDER_TYPEHASH,
                    o.maker,
                    o.isBuy,
                    o.sku,
                    o.passportId,
                    o.gpuHours,
                    o.limitPriceE6,
                    o.deliveryStart,
                    o.windowHours,
                    o.minSlaBps,
                    o.gridZone,
                    o.expiry,
                    o.salt
                )
            )
        );
    }

    function cancelOrder(Order calldata o) external {
        if (msg.sender != o.maker) revert NotAuthorized();
        bytes32 h = hashOrder(o);
        cancelled[h] = true;
        emit OrderCancelled(h, msg.sender);
    }

    /// @notice Settles one match from the off-chain engine. Everything the engine claims is
    /// re-checked here, so a compromised matcher can at worst fail to match; it cannot trade
    /// outside a client's signed limits.
    function matchOrders(
        Order calldata buy,
        bytes calldata buySig,
        Order calldata sell,
        bytes calldata sellSig,
        uint64 qty,
        uint64 priceE6,
        uint256 listingId
    ) external onlyRole(MATCHER_ROLE) nonReentrant returns (uint256 tradeId) {
        if (!buy.isBuy || sell.isBuy) revert BadSides();
        if (
            buy.sku != sell.sku || buy.deliveryStart != sell.deliveryStart || buy.windowHours != sell.windowHours
                || qty == 0
        ) revert OrderMismatch();
        if (priceE6 > buy.limitPriceE6 || priceE6 < sell.limitPriceE6) revert PriceOutsideLimits();
        if (block.timestamp > buy.expiry || block.timestamp > sell.expiry) revert OrderExpired();
        if (buy.deliveryStart < block.timestamp) revert DeliveryInPast();
        if (!access.isEligible(buy.maker)) revert NotEligible(buy.maker);
        if (!access.isEligible(sell.maker)) revert NotEligible(sell.maker);

        _consumeOrder(buy, buySig, qty);
        _consumeOrder(sell, sellSig, qty);

        uint64 end = sell.deliveryStart + uint64(sell.windowHours) * 1 hours;
        _checkPassport(buy, sell, end);
        capacity.consume(listingId, sell.passportId, qty, sell.deliveryStart, sell.windowHours);

        tradeId = _openTrade(buy.maker, sell.maker, sell, qty, priceE6, end);
    }

    function _consumeOrder(Order calldata o, bytes calldata sig, uint64 qty) private {
        bytes32 h = hashOrder(o);
        if (cancelled[h]) revert OrderCancelledAlready();
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(h, sig);
        if (err != ECDSA.RecoverError.NoError || signer != o.maker) revert BadSignature(o.maker);
        uint64 done = filled[h] + qty;
        if (done > o.gpuHours) revert Overfill();
        filled[h] = done;
    }

    function _checkPassport(Order calldata buy, Order calldata sell, uint64 end) private view {
        IComputePassport.Passport memory p = passports.getPassport(sell.passportId);
        if (
            passports.ownerOf(sell.passportId) != sell.maker || p.sku != sell.sku
                || (buy.passportId != 0 && buy.passportId != sell.passportId) || p.slaBps < buy.minSlaBps
                || (buy.gridZone != bytes32(0) && buy.gridZone != p.gridZone)
        ) revert PassportConstraint();
        if (passports.paidUntil(sell.passportId) < end) revert PassportFeeDue();
        if (!oracle.isAttested(sell.passportId) || oracle.attestedUntil(sell.passportId) < end) {
            revert NotAttestedForWindow();
        }
    }

    function _openTrade(address buyer, address seller, Order calldata sell, uint64 qty, uint64 priceE6, uint64 end)
        private
        returns (uint256 tradeId)
    {
        uint256 notional = uint256(qty) * priceE6;
        uint256 buyerFee = notional * params.buyerFeeBps / BPS;
        uint256 sellerFee = notional * params.sellerFeeBps / BPS;
        uint256 collateral = notional * params.sellerCollateralBps / BPS;

        _lock(buyer, notional + buyerFee);
        _lock(seller, collateral);

        tradeId = nextTradeId++;
        trades[tradeId] = Trade({
            buyer: buyer,
            seller: seller,
            passportId: sell.passportId,
            sku: sell.sku,
            gpuHours: qty,
            priceE6: priceE6,
            start: sell.deliveryStart,
            end: end,
            notional: uint128(notional),
            buyerFee: uint128(buyerFee),
            sellerFee: uint128(sellerFee),
            sellerCollateral: uint128(collateral),
            status: Status.Open
        });
        emit TradeOpened(tradeId, buyer, seller, sell.passportId, sell.sku, qty, priceE6, sell.deliveryStart, end);
    }

    function _lock(address who, uint256 amount) private {
        uint256 balance = free[who];
        if (balance < amount) revert InsufficientFree(who, amount, balance);
        free[who] = balance - amount;
        totalLocked += amount;
    }

    // ---------------------------------------------------------------- delivery

    /// @notice T+0 provisional step. The seller asserts the uptime it delivered, and the
    /// host's sealed key must have signed the telemetry behind that assertion.
    function claimDelivery(
        uint256 tradeId,
        uint32 uptimeBps,
        bytes32 telemetryRoot,
        uint256 featureCommitment,
        bytes calldata teeSig
    ) external nonReentrant {
        Trade storage t = trades[tradeId];
        if (t.status != Status.Open) revert WrongStatus(t.status);
        if (msg.sender != t.seller && !hasRole(RELAY_ROLE, msg.sender)) revert NotAuthorized();
        if (block.timestamp < t.end) revert TooEarly();
        if (block.timestamp > uint256(t.end) + params.claimGrace) revert TooLate();
        if (uptimeBps > BPS) revert InvalidUptime();
        if (oracle.attestedUntil(t.passportId) < t.end) revert NotAttestedForWindow();
        if (!oracle.verifyTelemetrySeal(tradeId, t.passportId, telemetryRoot, featureCommitment, teeSig)) {
            revert InvalidSeal();
        }

        t.status = Status.Claimed;
        Claim storage c = claims[tradeId];
        c.uptimeBps = uptimeBps;
        c.claimedAt = uint64(block.timestamp);
        c.telemetryRoot = telemetryRoot;
        c.featureCommitment = featureCommitment;
        emit DeliveryClaimed(
            tradeId, uptimeBps, telemetryRoot, featureCommitment, uint64(block.timestamp) + params.disputeWindow
        );
    }

    /// @notice T+1 final step. Anyone may call once the window closes unchallenged.
    function finalize(uint256 tradeId) external nonReentrant {
        Trade storage t = trades[tradeId];
        if (t.status != Status.Claimed) revert WrongStatus(t.status);
        if (block.timestamp < uint256(claims[tradeId].claimedAt) + params.disputeWindow) revert TooEarly();
        _settle(tradeId);
    }

    /// @notice The buyer may waive its own dispute window for same-day final settlement.
    function acceptDelivery(uint256 tradeId) external nonReentrant {
        Trade storage t = trades[tradeId];
        if (t.status != Status.Claimed) revert WrongStatus(t.status);
        if (msg.sender != t.buyer) revert NotAuthorized();
        _settle(tradeId);
    }

    /// @notice Nothing was claimed in time, so the delivery is treated as failed.
    function failUndelivered(uint256 tradeId) external nonReentrant {
        Trade storage t = trades[tradeId];
        if (t.status != Status.Open) revert WrongStatus(t.status);
        if (block.timestamp <= uint256(t.end) + params.claimGrace) revert TooEarly();
        _default(tradeId, address(0), 0);
    }

    // ----------------------------------------------------------------- disputes

    /// @notice opML step. Any eligible watcher can post a bond and contest a claim.
    function challenge(uint256 tradeId) external nonReentrant {
        Trade storage t = trades[tradeId];
        if (t.status != Status.Claimed) revert WrongStatus(t.status);
        if (!access.isEligible(msg.sender)) revert NotEligible(msg.sender);
        Claim storage c = claims[tradeId];
        if (block.timestamp >= uint256(c.claimedAt) + params.disputeWindow) revert TooLate();

        uint128 bond = params.challengeBond;
        _lock(msg.sender, bond);
        t.status = Status.Challenged;
        c.challenger = msg.sender;
        c.bond = bond;
        c.responseDeadline = uint64(block.timestamp) + params.responseWindow;
        emit DeliveryChallenged(tradeId, msg.sender, bond, c.responseDeadline);
    }

    /// @notice zkML step. A valid proof shows the approved model, run on the telemetry the
    /// host sealed, passes the SLA at the claimed uptime. The telemetry itself stays private.
    function respondWithProof(uint256 tradeId, uint256[2] calldata a, uint256[2][2] calldata b, uint256[2] calldata c)
        external
        nonReentrant
    {
        Trade storage t = trades[tradeId];
        if (t.status != Status.Challenged) revert WrongStatus(t.status);
        Claim storage cl = claims[tradeId];
        if (block.timestamp > cl.responseDeadline) revert TooLate();
        if (!adjudicator.verifyDelivery(tradeId, cl.featureCommitment, cl.uptimeBps, a, b, c)) revert InvalidProof();

        uint128 bond = cl.bond;
        totalLocked -= bond;
        free[t.seller] += bond;
        emit ChallengeDefeated(tradeId, cl.challenger, bond);
        _settle(tradeId);
    }

    /// @notice The seller stayed silent or could not produce a proof.
    function resolveTimeout(uint256 tradeId) external nonReentrant {
        Trade storage t = trades[tradeId];
        if (t.status != Status.Challenged) revert WrongStatus(t.status);
        Claim storage c = claims[tradeId];
        if (block.timestamp <= c.responseDeadline) revert TooEarly();
        _default(tradeId, c.challenger, c.bond);
    }

    /// @notice PoC-0 fallback for disputes the zk model cannot express, such as multi-rack SLAs.
    function federationResolve(uint256 tradeId, bool sellerAtFault, bytes32 evidenceHash, bytes[] calldata sigs)
        external
        nonReentrant
    {
        Trade storage t = trades[tradeId];
        if (t.status != Status.Challenged) revert WrongStatus(t.status);
        bytes32 digest =
            _hashTypedDataV4(keccak256(abi.encode(RULING_TYPEHASH, tradeId, sellerAtFault, evidenceHash)));
        if (!federation.verifyQuorum(digest, sigs)) revert QuorumNotMet();

        Claim storage c = claims[tradeId];
        if (sellerAtFault) {
            _default(tradeId, c.challenger, c.bond);
        } else {
            uint128 bond = c.bond;
            totalLocked -= bond;
            free[t.seller] += bond;
            emit ChallengeDefeated(tradeId, c.challenger, bond);
            _settle(tradeId);
        }
    }

    // --------------------------------------------------------------- settlement

    function _settle(uint256 tradeId) private {
        Trade storage t = trades[tradeId];
        uint256 uptime = claims[tradeId].uptimeBps;
        uint256 notional = t.notional;
        uint256 collateral = t.sellerCollateral;

        // Honest partial delivery is paid pro rata.
        uint256 paid = notional * uptime / BPS;
        uint256 buyerFeeDue = t.buyerFee * uptime / BPS;
        uint256 sellerFeeDue = t.sellerFee * uptime / BPS;
        uint256 refund = (notional - paid) + (t.buyerFee - buyerFeeDue);

        uint256 credit;
        if (uptime < passports.getPassport(t.passportId).slaBps) {
            credit = (notional - paid) * params.slaCreditBps / BPS;
            if (credit > collateral) credit = collateral;
        }

        t.status = Status.Settled;
        totalLocked -= notional + t.buyerFee + collateral;
        free[t.seller] += paid - sellerFeeDue + collateral - credit;
        free[t.buyer] += refund + credit;
        free[treasury] += buyerFeeDue + sellerFeeDue;
        emit TradeSettled(tradeId, paid, refund + credit, buyerFeeDue, sellerFeeDue, credit);
    }

    /// @dev Waterfall: challenger reward, buyer penalty from collateral, default fund for any
    /// shortfall. Whatever collateral is left is slashed into the mutual pool.
    function _default(uint256 tradeId, address challenger, uint128 bond) private {
        Trade storage t = trades[tradeId];
        uint256 notional = t.notional;
        uint256 collateral = t.sellerCollateral;
        uint256 refund = notional + t.buyerFee;
        uint256 left = collateral;

        uint256 reward;
        if (challenger != address(0)) {
            reward = collateral * params.challengerRewardBps / BPS;
            left -= reward;
        }

        uint256 penalty = notional * params.penaltyBps / BPS;
        uint256 fromCollateral = penalty < left ? penalty : left;
        left -= fromCollateral;

        t.status = Status.Defaulted;
        totalLocked -= notional + t.buyerFee + collateral + bond;

        uint256 fromFund;
        if (penalty > fromCollateral) fromFund = defaultFund.cover(t.seller, penalty - fromCollateral);

        free[t.buyer] += refund + fromCollateral + fromFund;
        if (challenger != address(0)) free[challenger] += uint256(bond) + reward;

        if (left != 0) {
            token.forceApprove(address(defaultFund), left);
            defaultFund.fundMutual(left);
        }
        passports.suspend(t.passportId, keccak256(abi.encode("DELIVERY_FAULT", tradeId)));
        emit TradeDefaulted(tradeId, refund, fromCollateral, fromFund, reward, left);
    }

    // -------------------------------------------------------------------- admin

    function setParams(Params calldata p) external onlyRole(PARAM_ROLE) {
        _setParams(p);
    }

    function _setParams(Params memory p) private {
        if (
            p.disputeWindow == 0 || p.responseWindow == 0 || p.buyerFeeBps > 1_000 || p.sellerFeeBps > 1_000
                || p.sellerCollateralBps > BPS || p.penaltyBps > BPS || p.challengerRewardBps > BPS || p.slaCreditBps > BPS
        ) revert InvalidParams();
        params = p;
        emit ParamsChanged(p);
    }
}
