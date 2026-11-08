// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockUSD} from "../contracts/mocks/MockUSD.sol";
import {MockVerifier} from "../contracts/mocks/MockVerifier.sol";
import {Federation} from "../contracts/core/Federation.sol";
import {MemberRegistry} from "../contracts/core/MemberRegistry.sol";
import {ComputePassport} from "../contracts/core/ComputePassport.sol";
import {ProofOfDeliveryOracle} from "../contracts/core/ProofOfDeliveryOracle.sol";
import {CapacityPool} from "../contracts/core/CapacityPool.sol";
import {DefaultFund} from "../contracts/core/DefaultFund.sol";
import {DvPEscrow} from "../contracts/core/DvPEscrow.sol";
import {ZkDeliveryAdjudicator} from "../contracts/zk/ZkDeliveryAdjudicator.sol";
import {
    IAccessList,
    ICapacityPool,
    IComputePassport,
    IDefaultFund,
    IFederation,
    IGroth16Verifier,
    IProofOfDeliveryOracle,
    IZkDeliveryAdjudicator
} from "../contracts/interfaces/IPetahour.sol";

/// @notice Shared deployment and signing helpers for the core protocol.
abstract contract Base is Test {
    bytes32 internal constant SKU = keccak256("B200-180GB-SXM");
    bytes32 internal constant ZONE = keccak256("TPC-NORTH");
    uint64 internal constant ONE_DAY = 1 days;
    uint256 internal constant START_TIME = 1_800_000_000;

    address internal admin = makeAddr("admin");
    address internal matcher = makeAddr("matcher");
    address internal treasury = makeAddr("treasury");
    address internal buyer;
    address internal seller;
    address internal watcher;
    address internal stranger = makeAddr("stranger");
    uint256 internal buyerKey;
    uint256 internal sellerKey;
    uint256 internal teeKey;
    address internal teeAddr;

    uint256[] internal fedKeys; // sorted by signer address
    address[] internal fedAddrs;

    MockUSD internal usd;
    MockVerifier internal verifier;
    Federation internal federation;
    MemberRegistry internal registry;
    ComputePassport internal passports;
    ProofOfDeliveryOracle internal oracle;
    CapacityPool internal pool;
    DefaultFund internal fund;
    ZkDeliveryAdjudicator internal adjudicator;
    DvPEscrow internal escrow;

    uint256 internal passportId;
    uint256 internal listingId;
    uint256 internal salt;

    function _params() internal pure virtual returns (DvPEscrow.Params memory) {
        return DvPEscrow.Params({
            disputeWindow: 1 days,
            responseWindow: 6 hours,
            claimGrace: 6 hours,
            buyerFeeBps: 125,
            sellerFeeBps: 125,
            sellerCollateralBps: 2_000,
            penaltyBps: 2_500,
            challengerRewardBps: 1_000,
            slaCreditBps: 5_000,
            challengeBond: 100e6
        });
    }

    function _verifierForEscrow() internal virtual returns (IGroth16Verifier) {
        verifier = new MockVerifier();
        return IGroth16Verifier(address(verifier));
    }

    function setUp() public virtual {
        vm.warp(START_TIME);
        (buyer, buyerKey) = makeAddrAndKey("buyer");
        (seller, sellerKey) = makeAddrAndKey("seller");
        (teeAddr, teeKey) = makeAddrAndKey("tee");
        watcher = makeAddr("watcher");
        _setupFederationKeys();

        usd = new MockUSD();
        federation = new Federation(admin, fedAddrs, 2);
        registry = new MemberRegistry(admin);
        passports = new ComputePassport(
            admin, IFederation(address(federation)), IAccessList(address(registry)), IERC20(address(usd)), treasury, 60e6, 5_000
        );
        oracle = new ProofOfDeliveryOracle(IFederation(address(federation)), IComputePassport(address(passports)));
        pool = new CapacityPool(admin, IComputePassport(address(passports)), IProofOfDeliveryOracle(address(oracle)));
        fund = new DefaultFund(admin, IERC20(address(usd)));
        adjudicator = new ZkDeliveryAdjudicator(admin, _verifierForEscrow(), 111, 222);

        escrow = new DvPEscrow(
            admin,
            DvPEscrow.Deps({
                token: IERC20(address(usd)),
                access: IAccessList(address(registry)),
                passports: IComputePassport(address(passports)),
                oracle: IProofOfDeliveryOracle(address(oracle)),
                capacity: ICapacityPool(address(pool)),
                defaultFund: IDefaultFund(address(fund)),
                adjudicator: IZkDeliveryAdjudicator(address(adjudicator)),
                federation: IFederation(address(federation)),
                treasury: treasury
            }),
            _params()
        );

        vm.startPrank(admin);
        escrow.grantRole(escrow.MATCHER_ROLE(), matcher);
        pool.grantRole(pool.ESCROW_ROLE(), address(escrow));
        fund.grantRole(fund.ESCROW_ROLE(), address(escrow));
        passports.grantRole(passports.SUSPENDER_ROLE(), address(escrow));
        uint64 expiry = uint64(START_TIME + 365 days);
        registry.enroll(buyer, MemberRegistry.Tier.Participant, expiry, "buyer-case");
        registry.enroll(seller, MemberRegistry.Tier.Participant, expiry, "seller-case");
        registry.enroll(watcher, MemberRegistry.Tier.Participant, expiry, "watcher-case");
        vm.stopPrank();

        _fund(buyer, 1_000_000e6);
        _fund(seller, 1_000_000e6);
        _fund(watcher, 10_000e6);

        passportId = _mintPassport(seller, teeAddr, 8, "host-1");
        _attest(passportId, uint64(START_TIME + 30 days));
        vm.prank(seller);
        listingId = pool.listCapacity(passportId, uint64(START_TIME), uint64(START_TIME + 30 days));
    }

    function _setupFederationKeys() internal {
        uint256[3] memory keys = [uint256(0xA11CE), uint256(0xB0B), uint256(0xCA401)];
        // Insertion sort by address, because verifyQuorum requires ascending signers.
        for (uint256 i = 0; i < 3; ++i) {
            address a = vm.addr(keys[i]);
            uint256 j = fedAddrs.length;
            fedAddrs.push(a);
            fedKeys.push(keys[i]);
            while (j > 0 && fedAddrs[j - 1] > a) {
                fedAddrs[j] = fedAddrs[j - 1];
                fedKeys[j] = fedKeys[j - 1];
                j--;
            }
            fedAddrs[j] = a;
            fedKeys[j] = keys[i];
        }
    }

    function _fund(address who, uint256 amount) internal {
        usd.mint(who, amount);
        vm.startPrank(who);
        usd.approve(address(escrow), type(uint256).max);
        escrow.deposit(amount);
        vm.stopPrank();
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _quorum(bytes32 digest) internal view returns (bytes[] memory sigs) {
        sigs = new bytes[](2);
        sigs[0] = _sign(fedKeys[0], digest);
        sigs[1] = _sign(fedKeys[1], digest);
    }

    function _digest(string memory name, address verifyingContract, bytes32 structHash)
        internal
        view
        returns (bytes32)
    {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes("1")),
                block.chainid,
                verifyingContract
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _passport(address tee, uint32 gpus, string memory host)
        internal
        pure
        returns (IComputePassport.Passport memory)
    {
        return IComputePassport.Passport({
            hostIdHash: keccak256(bytes(host)),
            teeKey: tee,
            sku: SKU,
            gpuCount: gpus,
            pueMilli: 1400,
            slaBps: 9990,
            gridZone: ZONE,
            topology: keccak256("NVLINK5"),
            metadataHash: keccak256("passport-json"),
            suspended: false
        });
    }

    function _mintDigest(address to, IComputePassport.Passport memory p) internal view returns (bytes32) {
        return _digest(
            "Petahour Compute Passport",
            address(passports),
            keccak256(
                abi.encode(
                    passports.MINT_TYPEHASH(),
                    to,
                    p.hostIdHash,
                    p.teeKey,
                    p.sku,
                    p.gpuCount,
                    p.pueMilli,
                    p.slaBps,
                    p.gridZone,
                    p.topology,
                    p.metadataHash
                )
            )
        );
    }

    function _mintPassport(address to, address tee, uint32 gpus, string memory host) internal returns (uint256) {
        IComputePassport.Passport memory p = _passport(tee, gpus, host);
        usd.mint(to, passports.annualFee(gpus));
        vm.prank(to);
        usd.approve(address(passports), type(uint256).max);
        return passports.mintPassport(to, p, _quorum(_mintDigest(to, p)));
    }

    function _attestDigest(uint256 id, bytes32 nonce, uint64 validUntil) internal view returns (bytes32) {
        return _digest(
            "Petahour Proof of Delivery",
            address(oracle),
            keccak256(abi.encode(oracle.ATTESTATION_TYPEHASH(), id, bytes32("rim"), bytes32("eat"), nonce, validUntil))
        );
    }

    function _attest(uint256 id, uint64 validUntil) internal {
        bytes32 nonce = keccak256(abi.encode(id, validUntil, block.timestamp));
        oracle.submitAttestation(id, "rim", "eat", nonce, validUntil, _quorum(_attestDigest(id, nonce, validUntil)));
    }

    function _order(address maker, bool isBuy, uint64 qty, uint64 limit, uint64 start)
        internal
        returns (DvPEscrow.Order memory)
    {
        return DvPEscrow.Order({
            maker: maker,
            isBuy: isBuy,
            sku: SKU,
            passportId: isBuy ? 0 : passportId,
            gpuHours: qty,
            limitPriceE6: limit,
            deliveryStart: start,
            windowHours: 24,
            minSlaBps: 0,
            gridZone: bytes32(0),
            expiry: start,
            salt: ++salt
        });
    }

    /// @dev 8 GPUs for 24 hours = 192 GPU-hours, the full host for one delivery day.
    function _open(uint64 qty, uint64 priceE6) internal returns (uint256 tradeId) {
        uint64 start = uint64(block.timestamp + 1 hours);
        DvPEscrow.Order memory b = _order(buyer, true, qty, priceE6, start);
        DvPEscrow.Order memory s = _order(seller, false, qty, priceE6, start);
        // Signatures first: vm.prank applies to the next external call, and hashOrder is one.
        bytes memory bs = _sign(buyerKey, escrow.hashOrder(b));
        bytes memory ss = _sign(sellerKey, escrow.hashOrder(s));
        vm.prank(matcher);
        tradeId = escrow.matchOrders(b, bs, s, ss, qty, priceE6, listingId);
    }

    function _sealDigest(uint256 tradeId, uint256 pid, bytes32 root, uint256 commitment)
        internal
        view
        returns (bytes32)
    {
        return _digest(
            "Petahour Proof of Delivery",
            address(oracle),
            keccak256(abi.encode(oracle.SEAL_TYPEHASH(), tradeId, pid, root, commitment))
        );
    }

    function _claim(uint256 tradeId, uint32 uptimeBps) internal {
        _claimWith(tradeId, uptimeBps, 999);
    }

    function _claimWith(uint256 tradeId, uint32 uptimeBps, uint256 commitment) internal {
        (,, uint256 pid,,,,, uint64 end,,,,,) = escrow.trades(tradeId);
        if (block.timestamp < end) vm.warp(end);
        bytes memory sig = _sign(teeKey, _sealDigest(tradeId, pid, "root", commitment));
        vm.prank(seller);
        escrow.claimDelivery(tradeId, uptimeBps, "root", commitment, sig);
    }

    function _status(uint256 tradeId) internal view returns (DvPEscrow.Status s) {
        (,,,,,,,,,,,, s) = escrow.trades(tradeId);
    }

    function _proof() internal pure returns (uint256[2] memory a, uint256[2][2] memory b, uint256[2] memory c) {
        a = [uint256(1), 2];
        b = [[uint256(3), 4], [uint256(5), 6]];
        c = [uint256(7), 8];
    }
}
