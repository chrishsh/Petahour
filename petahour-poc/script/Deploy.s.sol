// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockUSD} from "../contracts/mocks/MockUSD.sol";
import {Federation} from "../contracts/core/Federation.sol";
import {MemberRegistry} from "../contracts/core/MemberRegistry.sol";
import {ComputePassport} from "../contracts/core/ComputePassport.sol";
import {ProofOfDeliveryOracle} from "../contracts/core/ProofOfDeliveryOracle.sol";
import {CapacityPool} from "../contracts/core/CapacityPool.sol";
import {DefaultFund} from "../contracts/core/DefaultFund.sol";
import {DvPEscrow} from "../contracts/core/DvPEscrow.sol";
import {TCPIOracle, TCPIFeed} from "../contracts/core/TCPIOracle.sol";
import {Groth16Verifier} from "../contracts/zk/Groth16Verifier.sol";
import {ZkDeliveryAdjudicator} from "../contracts/zk/ZkDeliveryAdjudicator.sol";
import {GPUWarehouseReceipt} from "../contracts/labs/GPUWarehouseReceipt.sol";
import {GPUReceiptWrapper} from "../contracts/labs/GPUReceiptWrapper.sol";
import {TCPIPriceAdapter} from "../contracts/labs/TCPIPriceAdapter.sol";
import {IsolatedLendingMarket} from "../contracts/labs/IsolatedLendingMarket.sol";
import {ComputeCreditVault, FirstLossTranche} from "../contracts/labs/ComputeCreditVault.sol";
import {LabsTreasury} from "../contracts/labs/LabsTreasury.sol";
import {
    AggregatorV3Interface,
    IAccessList,
    ICapacityPool,
    IComputePassport,
    IDefaultFund,
    IFederation,
    IGroth16Verifier,
    IMorphoOracle,
    IProofOfDeliveryOracle,
    IZkDeliveryAdjudicator
} from "../contracts/interfaces/IPetahour.sol";

/// @notice Deploys both legal entities from two separate keys.
/// PETAHOUR_ADMIN_KEY owns the onshore Taiwan venue; LABS_ADMIN_KEY owns the offshore Petahour Labs layer.
/// The Labs contracts read core data but hold no role on any core contract.
contract Deploy is Script {
    bytes32 constant SKU_B200 = keccak256("B200-180GB-SXM");
    bytes32 constant INDEX_B200 = keccak256("TCPI-B200");

    struct Core {
        MockUSD usd;
        Federation federation;
        MemberRegistry registry;
        ComputePassport passports;
        ProofOfDeliveryOracle oracle;
        CapacityPool pool;
        DefaultFund fund;
        Groth16Verifier verifier;
        ZkDeliveryAdjudicator adjudicator;
        DvPEscrow escrow;
        TCPIOracle tcpi;
        TCPIFeed feed;
    }

    struct Labs {
        MemberRegistry registry;
        GPUWarehouseReceipt receipts;
        GPUReceiptWrapper wrapper;
        TCPIPriceAdapter adapter;
        IsolatedLendingMarket market;
        FirstLossTranche tranche;
        ComputeCreditVault vault;
        LabsTreasury treasury;
    }

    function run() external {
        uint256 petahourKey = vm.envUint("PETAHOUR_ADMIN_KEY");
        uint256 labsKey = vm.envUint("LABS_ADMIN_KEY");
        Core memory c = _deployCore(petahourKey);
        Labs memory l = _deployLabs(labsKey, c);
        _write(c, l, vm.addr(petahourKey), vm.addr(labsKey));
    }

    function _params() internal view returns (DvPEscrow.Params memory) {
        return DvPEscrow.Params({
            disputeWindow: uint32(vm.envOr("DISPUTE_WINDOW", uint256(1 days))),
            responseWindow: uint32(vm.envOr("RESPONSE_WINDOW", uint256(6 hours))),
            claimGrace: uint32(vm.envOr("CLAIM_GRACE", uint256(6 hours))),
            buyerFeeBps: uint16(vm.envOr("BUYER_FEE_BPS", uint256(125))),
            sellerFeeBps: uint16(vm.envOr("SELLER_FEE_BPS", uint256(125))),
            sellerCollateralBps: 2_000,
            penaltyBps: 2_500,
            challengerRewardBps: 1_000,
            slaCreditBps: 5_000,
            challengeBond: 100e6
        });
    }

    function _deployCore(uint256 key) internal returns (Core memory c) {
        address admin = vm.addr(key);
        address[] memory signers = new address[](3);
        signers[0] = vm.envAddress("FED_SIGNER_1");
        signers[1] = vm.envAddress("FED_SIGNER_2");
        signers[2] = vm.envAddress("FED_SIGNER_3");

        vm.startBroadcast(key);
        c.usd = new MockUSD();
        c.federation = new Federation(admin, signers, 2);
        c.registry = new MemberRegistry(admin);
        c.passports = new ComputePassport(
            admin,
            IFederation(address(c.federation)),
            IAccessList(address(c.registry)),
            IERC20(address(c.usd)),
            vm.envAddress("TREASURY"),
            uint64(vm.envOr("PASSPORT_FEE_PER_GPU_YEAR", uint256(60e6))),
            uint16(vm.envOr("PASSPORT_DISCOUNT_BPS", uint256(5_000)))
        );
        c.oracle = new ProofOfDeliveryOracle(IFederation(address(c.federation)), IComputePassport(address(c.passports)));
        c.pool = new CapacityPool(admin, IComputePassport(address(c.passports)), IProofOfDeliveryOracle(address(c.oracle)));
        c.fund = new DefaultFund(admin, IERC20(address(c.usd)));
        c.verifier = new Groth16Verifier();
        c.adjudicator = new ZkDeliveryAdjudicator(
            admin,
            IGroth16Verifier(address(c.verifier)),
            vm.envUint("ZK_MODEL_HASH"),
            vm.envUint("ZK_THRESHOLD")
        );
        c.escrow = new DvPEscrow(
            admin,
            DvPEscrow.Deps({
                token: IERC20(address(c.usd)),
                access: IAccessList(address(c.registry)),
                passports: IComputePassport(address(c.passports)),
                oracle: IProofOfDeliveryOracle(address(c.oracle)),
                capacity: ICapacityPool(address(c.pool)),
                defaultFund: IDefaultFund(address(c.fund)),
                adjudicator: IZkDeliveryAdjudicator(address(c.adjudicator)),
                federation: IFederation(address(c.federation)),
                treasury: vm.envAddress("TREASURY")
            }),
            _params()
        );
        c.tcpi = new TCPIOracle(admin, IFederation(address(c.federation)), 2_500);
        c.feed = new TCPIFeed(c.tcpi, INDEX_B200, "TCPI-B200 / USD per GPU-hour");

        c.escrow.grantRole(c.escrow.MATCHER_ROLE(), vm.envAddress("MATCHER"));
        c.escrow.grantRole(c.escrow.RELAY_ROLE(), vm.envAddress("RELAY"));
        c.pool.grantRole(c.pool.ESCROW_ROLE(), address(c.escrow));
        c.fund.grantRole(c.fund.ESCROW_ROLE(), address(c.escrow));
        c.passports.grantRole(c.passports.SUSPENDER_ROLE(), address(c.escrow));
        vm.stopBroadcast();
    }

    function _deployLabs(uint256 key, Core memory c) internal returns (Labs memory l) {
        address admin = vm.addr(key);
        vm.startBroadcast(key);
        l.registry = new MemberRegistry(admin);
        l.receipts = new GPUWarehouseReceipt(
            admin,
            IAccessList(address(l.registry)),
            IComputePassport(address(c.passports)),
            IProofOfDeliveryOracle(address(c.oracle))
        );
        l.wrapper = new GPUReceiptWrapper(
            l.receipts, IAccessList(address(l.registry)), SKU_B200, "Wrapped GPU Receipt B200", "wGWR-B200"
        );
        l.adapter = new TCPIPriceAdapter(AggregatorV3Interface(address(c.feed)), 2 days, 8_400, 18, 6);
        l.treasury = new LabsTreasury(
            admin, IERC20(address(c.usd)), vm.envAddress("TREASURY"), vm.envOr("LABS_LICENCE_BPS", uint256(10))
        );
        l.market = new IsolatedLendingMarket(
            IERC20(address(c.usd)),
            IERC20(address(l.wrapper)),
            IMorphoOracle(address(l.adapter)),
            IAccessList(address(l.registry)),
            0.625e18, // an LLTV Morpho allows. With the oracle at 84% of TCPI, a 52.5% advance
            0.12e18,
            1_126_760_563_380_281_690, // Morpho's incentive at this LLTV: 1 / (0.3 x LLTV + 0.7), capped at 1.15
            vm.envOr("LABS_ORIGINATION_FEE_BPS", uint256(50)),
            address(l.treasury)
        );
        l.tranche = new FirstLossTranche(admin, IERC20(address(c.usd)), IAccessList(address(l.registry)));
        l.vault = new ComputeCreditVault(
            admin,
            IERC20(address(c.usd)),
            IAccessList(address(l.registry)),
            l.market,
            l.tranche,
            vm.envOr("LABS_CURATOR_FEE_BPS", uint256(1_000)),
            vm.envOr("LABS_SENIOR_YIELD_BPS", uint256(800)),
            address(l.treasury)
        );
        l.treasury.bind(l.market, l.vault);
        l.tranche.bind(l.vault);

        uint64 far = uint64(block.timestamp + 3650 days);
        l.registry.enroll(address(l.wrapper), MemberRegistry.Tier.Participant, far, "protocol");
        l.registry.enroll(address(l.market), MemberRegistry.Tier.Participant, far, "protocol");
        l.registry.enroll(address(l.vault), MemberRegistry.Tier.Participant, far, "protocol");
        l.registry.enroll(address(l.treasury), MemberRegistry.Tier.Participant, far, "protocol");
        vm.stopBroadcast();
    }

    function _write(Core memory c, Labs memory l, address petahourAdmin, address labsAdmin) internal {
        string memory k = "deployment";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "petahourAdmin", petahourAdmin);
        vm.serializeAddress(k, "labsAdmin", labsAdmin);
        vm.serializeAddress(k, "MockUSD", address(c.usd));
        vm.serializeAddress(k, "Federation", address(c.federation));
        vm.serializeAddress(k, "MemberRegistry", address(c.registry));
        vm.serializeAddress(k, "ComputePassport", address(c.passports));
        vm.serializeAddress(k, "ProofOfDeliveryOracle", address(c.oracle));
        vm.serializeAddress(k, "CapacityPool", address(c.pool));
        vm.serializeAddress(k, "DefaultFund", address(c.fund));
        vm.serializeAddress(k, "Groth16Verifier", address(c.verifier));
        vm.serializeAddress(k, "ZkDeliveryAdjudicator", address(c.adjudicator));
        vm.serializeAddress(k, "DvPEscrow", address(c.escrow));
        vm.serializeAddress(k, "TCPIOracle", address(c.tcpi));
        vm.serializeAddress(k, "TCPIFeed", address(c.feed));
        vm.serializeAddress(k, "LabsRegistry", address(l.registry));
        vm.serializeAddress(k, "GPUWarehouseReceipt", address(l.receipts));
        vm.serializeAddress(k, "GPUReceiptWrapper", address(l.wrapper));
        vm.serializeAddress(k, "TCPIPriceAdapter", address(l.adapter));
        vm.serializeAddress(k, "IsolatedLendingMarket", address(l.market));
        vm.serializeAddress(k, "FirstLossTranche", address(l.tranche));
        vm.serializeAddress(k, "ComputeCreditVault", address(l.vault));
        string memory json = vm.serializeAddress(k, "LabsTreasury", address(l.treasury));
        vm.writeJson(json, string.concat("deployments/", vm.toString(block.chainid), ".json"));
    }
}
