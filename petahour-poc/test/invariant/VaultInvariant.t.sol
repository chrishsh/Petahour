// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockUSD} from "../../contracts/mocks/MockUSD.sol";
import {IsolatedLendingMarket} from "../../contracts/labs/IsolatedLendingMarket.sol";
import {ComputeCreditVault, FirstLossTranche} from "../../contracts/labs/ComputeCreditVault.sol";
import {LabsTreasury} from "../../contracts/labs/LabsTreasury.sol";
import {IAccessList, IMorphoOracle} from "../../contracts/interfaces/IPetahour.sol";

contract OpenAccess is IAccessList {
    function isEligible(address) external pure returns (bool) {
        return true;
    }
}

contract SettableOracle is IMorphoOracle {
    uint256 public price = 1e36; // one collateral atom buys one loan atom

    function set(uint256 price_) external {
        price = price_;
    }
}

/// @notice Random lenders, first-loss holders, borrowers and crashes, in any order.
contract VaultHandler is Test {
    uint256 private constant OFFSET = 1e6;
    uint256 private constant WAD = 1e18;

    MockUSD public usd;
    MockUSD public collateral;
    SettableOracle public oracle;
    IsolatedLendingMarket public market;
    FirstLossTranche public tranche;
    ComputeCreditVault public vault;
    LabsTreasury public treasury;

    address public curator = makeAddr("curator");
    address public borrower = makeAddr("borrower");
    address public liquidator = makeAddr("liquidator");
    address[2] public seniors = [makeAddr("senior-a"), makeAddr("senior-b")];
    address[2] public juniors = [makeAddr("junior-a"), makeAddr("junior-b")];

    uint256 public seniorPriceDrops; // times a senior price fell while first-loss capital survived
    // Ghost counters: a handler that swallows reverts can pass while doing nothing.
    uint256 public losses;
    uint256 public seniorLosses;
    uint256 public excessPaid;
    uint256 public seniorExits;
    uint256 public firstLossExits;

    constructor() {
        usd = new MockUSD();
        collateral = new MockUSD();
        oracle = new SettableOracle();
        OpenAccess open = new OpenAccess();
        treasury = new LabsTreasury(curator, IERC20(address(usd)), makeAddr("petahour"), 10);
        market = new IsolatedLendingMarket(
            IERC20(address(usd)),
            IERC20(address(collateral)),
            IMorphoOracle(address(oracle)),
            open,
            0.625e18,
            0.12e18,
            1_126_760_563_380_281_690,
            50,
            address(treasury)
        );
        tranche = new FirstLossTranche(curator, IERC20(address(usd)), open);
        vault = new ComputeCreditVault(curator, IERC20(address(usd)), open, market, tranche, 1_000, 800, address(treasury));
        vm.startPrank(curator);
        treasury.bind(market, vault);
        tranche.bind(vault);
        vm.stopPrank();
    }

    /// @dev What one senior share is worth, scaled up, so small moves are visible.
    function seniorPrice() public view returns (uint256) {
        return vault.convertToAssets(1e24);
    }

    modifier watched() {
        uint256 before = seniorPrice();
        uint256 held = vault.totalSupply();
        if (vault.waterfall().excess != 0) excessPaid++;
        _;
        uint256 afterwards = seniorPrice();
        // Measured as what holders who stayed lost, so rounding on dust does not count: 2 atoms of tUSD.
        uint256 stayed = held < vault.totalSupply() ? held : vault.totalSupply();
        if (afterwards < before && vault.firstLossClaim() != 0 && (before - afterwards) * stayed / 1e24 > 2) {
            seniorPriceDrops++;
        }
    }

    function seniorIn(uint256 who, uint256 assets) external watched {
        address a = seniors[who % 2];
        assets = bound(assets, 1e6, 5_000e6);
        usd.mint(a, assets);
        vm.startPrank(a);
        usd.approve(address(vault), assets);
        vault.deposit(assets, a);
        vm.stopPrank();
    }

    function seniorOut(uint256 who, uint256 bps) external watched {
        address a = seniors[who % 2];
        uint256 shares = vault.balanceOf(a) * bound(bps, 1, 10_000) / 10_000;
        if (shares == 0) return;
        vm.prank(a);
        try vault.redeem(shares, a, a) { // may be waiting on liquidity
            seniorExits++;
        } catch {}
    }

    function firstLossIn(uint256 who, uint256 assets) external watched {
        address a = juniors[who % 2];
        assets = bound(assets, 1e6, 1_000e6);
        usd.mint(a, assets);
        vm.startPrank(a);
        usd.approve(address(tranche), assets);
        try tranche.deposit(assets, a) {} catch {} // after many wipe-outs the supply can be full
        vm.stopPrank();
    }

    function clearWorthless() external watched {
        if (vault.firstLossClaim() != 0) return;
        tranche.clearWorthless(_juniors());
    }

    function _juniors() private view returns (address[] memory list) {
        list = new address[](2);
        list[0] = juniors[0];
        list[1] = juniors[1];
    }

    /// @dev Clears a wiped-out tranche and tries new money, in the invariant's throwaway state.
    function restart() external returns (bool) {
        if (vault.firstLossClaim() != 0) return true;
        tranche.clearWorthless(_juniors());
        address a = juniors[0];
        usd.mint(a, 1_000e6);
        vm.startPrank(a);
        usd.approve(address(tranche), 1_000e6);
        tranche.deposit(1_000e6, a);
        vm.stopPrank();
        return tranche.convertToAssets(tranche.balanceOf(a)) + 2 >= 1_000e6;
    }

    function firstLossOut(uint256 who, uint256 bps) external watched {
        address a = juniors[who % 2];
        uint256 shares = tranche.balanceOf(a) * bound(bps, 1, 10_000) / 10_000;
        if (shares == 0) return;
        vm.prank(a);
        try tranche.redeem(shares, a, a) {
            firstLossExits++;
        } catch {}
    }

    function lend(uint256 bps) external watched {
        uint256 idle = usd.balanceOf(address(vault)) * bound(bps, 1, 10_000) / 10_000;
        if (idle == 0) return;
        vm.prank(curator);
        vault.allocate(idle);
    }

    function borrow(uint256 bps) external watched {
        uint256 room = market.totalSupplyAssets() - market.totalBorrowAssets();
        uint256 assets = room * bound(bps, 1, 10_000) / 10_000;
        if (assets == 0) return;
        collateral.mint(borrower, assets * 2);
        vm.startPrank(borrower);
        collateral.approve(address(market), assets * 2);
        market.supplyCollateral(assets * 2);
        try market.borrow(assets) {} catch {}
        vm.stopPrank();
    }

    function repay(uint256 bps) external watched {
        uint256 assets = market.debtOf(borrower) * bound(bps, 1, 10_000) / 10_000;
        if (assets == 0) return;
        usd.mint(borrower, assets);
        vm.startPrank(borrower);
        usd.approve(address(market), assets);
        market.repay(assets);
        vm.stopPrank();
    }

    function pass(uint256 elapsed) external watched {
        skip(bound(elapsed, 1 hours, 120 days));
    }

    function crash(uint256 keepBps) external watched {
        uint256 held = market.collateral(borrower);
        if (held == 0 || market.debtOf(borrower) == 0) return;
        oracle.set(1e36 * bound(keepBps, 500, 9_000) / 10_000);
        if (market.isHealthy(borrower)) {
            oracle.set(1e36);
            return;
        }
        usd.mint(liquidator, 1e15);
        vm.startPrank(liquidator);
        usd.approve(address(market), type(uint256).max);
        market.liquidate(borrower, held);
        vm.stopPrank();
        oracle.set(1e36);
        losses++;
        if (vault.firstLossClaim() == 0) seniorLosses++;
    }

    function settle() external watched {
        vault.settle();
    }

    function collectFees(uint256 bps) external watched {
        uint256 shares = vault.balanceOf(address(treasury)) * bound(bps, 1, 10_000) / 10_000;
        if (shares == 0) return;
        try treasury.collectCuratorFees(shares) {} catch {}
    }

    /// @dev Repays everything and takes everybody out, in the invariant's throwaway state.
    function unwind() external {
        uint256 debt = market.debtOf(borrower);
        if (debt != 0) {
            usd.mint(borrower, debt);
            vm.startPrank(borrower);
            usd.approve(address(market), debt);
            market.repay(debt);
            vm.stopPrank();
        }
        vault.settle();
        for (uint256 i; i < 2; i++) {
            uint256 shares = vault.balanceOf(seniors[i]);
            if (shares != 0) {
                vm.prank(seniors[i]);
                vault.redeem(shares, seniors[i], seniors[i]);
            }
            shares = tranche.balanceOf(juniors[i]);
            if (shares != 0) {
                vm.prank(juniors[i]);
                tranche.redeem(shares, juniors[i], juniors[i]);
            }
        }
        uint256 fees = vault.balanceOf(address(treasury));
        if (fees != 0) treasury.collectCuratorFees(fees);
    }
}

contract VaultInvariantTest is Test {
    VaultHandler handler;
    ComputeCreditVault vault;

    function setUp() public {
        handler = new VaultHandler();
        vault = handler.vault();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = VaultHandler.seniorIn.selector;
        selectors[1] = VaultHandler.seniorOut.selector;
        selectors[2] = VaultHandler.firstLossIn.selector;
        selectors[3] = VaultHandler.firstLossOut.selector;
        selectors[4] = VaultHandler.lend.selector;
        selectors[5] = VaultHandler.borrow.selector;
        selectors[6] = VaultHandler.repay.selector;
        selectors[7] = VaultHandler.pass.selector;
        selectors[8] = VaultHandler.crash.selector;
        selectors[9] = VaultHandler.settle.selector;
        selectors[10] = VaultHandler.collectFees.selector;
        selectors[11] = VaultHandler.clearWorthless.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice Every dollar in the pool belongs to one tranche or the other.
    function invariant_theTranchesAddUpToThePool() public view {
        ComputeCreditVault.Waterfall memory w = vault.waterfall();
        assertEq(w.senior + w.firstLoss, w.pool);
    }

    /// @notice Settling only records what prices already show.
    function invariant_settlingMovesNoOnesMoney() public {
        uint256 senior = vault.totalAssets();
        uint256 firstLoss = vault.firstLossClaim();
        uint256 price = handler.seniorPrice();
        uint256 snapshot = vm.snapshotState();
        vault.settle();
        assertApproxEqAbs(vault.totalAssets(), senior, 3, "senior value");
        assertApproxEqAbs(vault.firstLossClaim(), firstLoss, 3, "first-loss value");
        uint256 moved = handler.seniorPrice() > price ? handler.seniorPrice() - price : price - handler.seniorPrice();
        assertLe(moved * vault.totalSupply() / 1e24, 3, "senior price");
        vm.revertToState(snapshot);
    }

    /// @notice While first-loss capital survives, seniors never see a loss.
    function invariant_seniorsAreProtectedWhileFirstLossLasts() public view {
        assertEq(handler.seniorPriceDrops(), 0);
    }

    /// @notice With first-loss capital in place, seniors earn no more than their yield.
    function invariant_seniorsStopAtTheirHurdle() public view {
        if (vault.firstLossClaim() == 0 || vault.totalSupply() == 0) return;
        uint256 price = handler.seniorPrice(); // same scale as hurdle(): 1e18 at the launch price
        uint256 hurdle = vault.hurdle();
        if (price > hurdle) assertLe((price - hurdle) * vault.totalSupply() / 1e24, 2);
    }

    /// @notice One line per run. scripts/invariant_coverage.py sums them and fails if a path was
    /// never reached, so this suite cannot pass by doing nothing.
    function afterInvariant() public {
        vm.writeLine(
            "reports/vault_runs.csv",
            string.concat(
                vm.toString(handler.losses()), ",",
                vm.toString(handler.seniorLosses()), ",",
                vm.toString(handler.excessPaid()), ",",
                vm.toString(handler.seniorExits()), ",",
                vm.toString(handler.firstLossExits())
            )
        );
    }

    /// @notice However many wipe-outs there have been, the tranche can always take new capital.
    function invariant_aWipedOutTrancheCanAlwaysRestart() public {
        uint256 snapshot = vm.snapshotState();
        assertTrue(handler.restart(), "new money keeps its value");
        vm.revertToState(snapshot);
    }

    /// @notice Without clearing, each wipe-out adds digits to the supply until it overflows.
    function test_repeatedWipeOutsNeverBlockNewCapital() public {
        handler.seniorIn(0, 5_000e6);
        for (uint256 i; i < 15; i++) {
            handler.firstLossIn(0, 1_000e6);
            handler.lend(10_000);
            handler.borrow(10_000);
            handler.crash(500);
            handler.repay(10_000);
            assertEq(vault.firstLossClaim(), 0, "wiped out");
            handler.clearWorthless();
            assertEq(handler.tranche().totalSupply(), 0, "and cleared");
        }
    }

    /// @notice Whatever has happened, repaying the loans lets every holder leave.
    function invariant_everyoneCanGetOut() public {
        uint256 snapshot = vm.snapshotState();
        handler.unwind();
        assertEq(vault.totalSupply(), 0, "all senior shares redeemed");
        assertEq(handler.tranche().totalSupply(), 0, "all first-loss shares redeemed");
        vm.revertToState(snapshot);
    }
}
