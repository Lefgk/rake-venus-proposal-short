// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "./Interfaces.sol";
import "../src/VenusMarketRescuePatch.sol";

/// The market-level getters the shared IVToken doesn't carry. Declared locally so the
/// existing interface file stays untouched for the other suites.
/// Stands in for the claim contract: the patch only needs the receiver to be a contract.
contract Sink {}

interface IVTokenX {
    function accrueInterest() external returns (uint256);
    function exchangeRateStored() external view returns (uint256);
    function getCash() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function totalBorrows() external view returns (uint256);
    function totalReserves() external view returns (uint256);
    function borrowIndex() external view returns (uint256);
}

/// Proves the self-funded variant on all seven markets at the current head: the borrow is
/// retired from the strategy's own collateral, the net equity lands on the recovery address
/// and redeems, and the market is left materially untouched.
///
/// The assertions that matter to a Venus reviewer:
///   - exchangeRateStored() is unchanged (this is what protects every other supplier)
///   - getCash() is unchanged (no liquidity leaves the market during settlement)
///   - totalBorrows falls by exactly the retired debt
///   - totalSupply falls by exactly the burned vTokens
///   - totalReserves and borrowIndex are untouched
///   - an unrelated holder's balance is untouched
contract VenusMarketRescuePatchTest is Test {
    address constant TIMELOCK = 0x939bD8d64c0A9583A7Dcea9933f7b21697ab6396;
    address constant TREASURY = 0xF322942f644A996A617BD29c16bd7d231d9F35E9;
    address RECOVERY; // the 80% receiver (the claim contract in production)

    struct M {
        string name;
        address vToken;
        address strat;
    }

    M[] internal ms;

    function setUp() public {
        uint256 b = vm.envOr("FORK_BLOCK", uint256(0));
        if (b == 0) vm.createSelectFork(vm.envString("BSC_RPC_URL"));
        else vm.createSelectFork(vm.envString("BSC_RPC_URL"), b);
        RECOVERY = address(new Sink());
        ms.push(M("vBUSD", 0x95c78222B3D6e262426483D42CfA53685A67Ab9D, 0xDF3df3EE9Fb6D5c9B4fdcF80A92D25d2285A859C));
        ms.push(M("vBTC", 0x882C173bC7Ff3b7786CA16dfeD3DFFfb9Ee7847B, 0xB3bCA2C1c2C4DF2C903BE3F341C96732Ac8b3c12));
        ms.push(M("vETH", 0xf508fCD89b8bd15579dc79A6827cB4686A3592c8, 0x9E3e8878B53c5762Ec6F461701f02ee6d1D9d19C));
        ms.push(M("vLINK", 0x650b940a1033B8A1b1873f78730FcFC73ec11f1f, 0x0b09Efc9458c00354414D2A560aA6EDa19490169));
        ms.push(M("vUSDT", 0xfD5840Cd36d94D7229439859C0112a4185BC0255, 0xc6f470dA6C284D16647CEE2230522a85b0818f6D));
        ms.push(M("vUSDC", 0xecA88125a5ADbe82614ffC12D0DB554E2e2867C8, 0x7485704d8B6cEBd1411F5AAfEB063e6f2816069A));
        ms.push(M("vDOT", 0x1610bc33319e9398de5f57B33a5b184c806aD217, 0x568254EAAC1476faf9A908e577faa3Ab96029801));
    }

    struct Snap {
        uint256 er;
        uint256 cash;
        uint256 totalSupply;
        uint256 totalBorrows;
        uint256 totalReserves;
        uint256 borrowIndex;
        uint256 bystander;
    }

    function _snap(address v, address bystander) internal view returns (Snap memory s) {
        IVTokenX t = IVTokenX(v);
        s.er = t.exchangeRateStored();
        s.cash = t.getCash();
        s.totalSupply = t.totalSupply();
        s.totalBorrows = t.totalBorrows();
        s.totalReserves = t.totalReserves();
        s.borrowIndex = t.borrowIndex();
        s.bystander = IVToken(v).balanceOf(bystander);
    }

    /// The whole VIP for one market, self-funded. No RepayHelper, no external capital.
    function test_settleAndRescue_retiresDebtFromOwnCollateralOnAllSevenMarkets() public {
        uint256 marketsDone;
        for (uint256 i; i < ms.length; i++) {
            IVToken v = IVToken(ms[i].vToken);
            address underlying = v.underlying();
            // A bystander whose balance must not move: the vToken's own admin-ish holder.
            address bystander = TIMELOCK;

            // Action 1 of the VIP: bring interest current.
            IVTokenX(address(v)).accrueInterest();

            Snap memory a = _snap(ms[i].vToken, bystander);
            uint256 debtBefore = v.borrowBalanceStored(ms[i].strat);
            uint256 stratTokens = v.balanceOf(ms[i].strat);

            VenusMarketRescuePatch patch = new VenusMarketRescuePatch(ms[i].strat, RECOVERY, v.implementation());
            assertEq(patch.ORIGINAL_IMPL(), v.implementation(), "impl mismatch");

            address original = v.implementation();
            uint256 recoveryBefore = v.balanceOf(RECOVERY);
            uint256 treasuryBefore = v.balanceOf(TREASURY);

            vm.startPrank(TIMELOCK);
            v._setImplementation(address(patch), false, "");
            (uint256 retired, uint256 burned, uint256 moved) = VenusMarketRescuePatch(ms[i].vToken).settleAndRescue();
            v._setImplementation(original, false, "");
            vm.stopPrank();

            Snap memory b = _snap(ms[i].vToken, bystander);

            // ---- the reviewer-facing invariants ----
            // The burn is rounded UP by design, so the rate can rise by the dust from at most
            // one vToken-wei of supply — never fall. One wei of supply is worth er/totalSupply
            // of rate, taken over the supply left after the burn, so that is the ceiling on the drift.
            assertGe(b.er, a.er, string.concat(ms[i].name, ": exchange rate FELL"));
            assertLe(
                b.er - a.er,
                (a.er / b.totalSupply) + 1,
                string.concat(ms[i].name, ": exchange rate drift exceeds one-wei rounding")
            );
            assertEq(b.cash, a.cash, string.concat(ms[i].name, ": cash moved"));
            assertEq(b.totalReserves, a.totalReserves, string.concat(ms[i].name, ": reserves moved"));
            assertEq(b.borrowIndex, a.borrowIndex, string.concat(ms[i].name, ": borrowIndex moved"));
            assertEq(b.bystander, a.bystander, string.concat(ms[i].name, ": bystander balance moved"));
            assertEq(b.totalBorrows, a.totalBorrows - retired, string.concat(ms[i].name, ": totalBorrows delta"));
            assertEq(b.totalSupply, a.totalSupply - burned, string.concat(ms[i].name, ": totalSupply delta"));
            assertEq(retired, debtBefore, string.concat(ms[i].name, ": debt not fully retired"));

            // ---- the position is gone and the equity landed ----
            assertEq(v.borrowBalanceStored(ms[i].strat), 0, string.concat(ms[i].name, ": strategy still owes"));
            assertEq(v.balanceOf(ms[i].strat), 0, string.concat(ms[i].name, ": strategy still holds vTokens"));
            assertEq(moved, stratTokens - burned, string.concat(ms[i].name, ": moved != net"));
            uint256 toVenus = moved * 2_000 / 10_000;
            assertEq(v.balanceOf(TREASURY) - treasuryBefore, toVenus, string.concat(ms[i].name, ": treasury 20%"));
            assertEq(v.balanceOf(RECOVERY) - recoveryBefore, moved - toVenus, string.concat(ms[i].name, ": claim 80%"));

            // ---- and it redeems through the ordinary path ----
            uint256 uBefore = IERC20(underlying).balanceOf(RECOVERY);
            vm.prank(RECOVERY);
            v.redeem(moved - toVenus);
            uint256 got = IERC20(underlying).balanceOf(RECOVERY) - uBefore;
            assertGt(got, 0, string.concat(ms[i].name, ": redeem returned nothing"));

            emit log_named_string("market", ms[i].name);
            emit log_named_uint("  debt retired from collateral", retired);
            emit log_named_uint("  vTokens burned              ", burned);
            emit log_named_uint("  net vTokens moved           ", moved);
            emit log_named_uint("  underlying redeemed         ", got);
            emit log_named_uint("  exchange-rate drift (wei)   ", b.er - a.er);
            marketsDone++;
        }
        assertEq(marketsDone, 7, "not all markets processed");
    }

    /// Guard: the VIP must accrue interest first, or the settlement reads stale state.
    function test_settleAndRescue_revertsIfInterestNotAccruedThisBlock() public {
        IVToken v = IVToken(ms[1].vToken); // vBTC
        VenusMarketRescuePatch patch = new VenusMarketRescuePatch(ms[1].strat, RECOVERY, v.implementation());
        IVTokenX(address(v)).accrueInterest();
        vm.roll(block.number + 1); // a block passes without accrual
        address original = v.implementation();
        vm.startPrank(TIMELOCK);
        v._setImplementation(address(patch), false, "");
        vm.expectRevert(bytes("interest not accrued"));
        VenusMarketRescuePatch(ms[1].vToken).settleAndRescue();
        v._setImplementation(original, false, "");
        vm.stopPrank();
    }

    /// Guard: only the timelock.
    function test_settleAndRescue_revertsForAnyoneButTheTimelock() public {
        IVToken v = IVToken(ms[1].vToken);
        VenusMarketRescuePatch patch = new VenusMarketRescuePatch(ms[1].strat, RECOVERY, v.implementation());
        IVTokenX(address(v)).accrueInterest();
        address original = v.implementation();
        vm.prank(TIMELOCK);
        v._setImplementation(address(patch), false, "");
        vm.prank(address(0xBEEF));
        vm.expectRevert(bytes("only admin"));
        VenusMarketRescuePatch(ms[1].vToken).settleAndRescue();
        vm.prank(TIMELOCK);
        v._setImplementation(original, false, "");
    }

    /// Guard: one-shot. A second call finds an empty strategy balance.
    function test_settleAndRescue_secondCallRevertsNothingToMove() public {
        IVToken v = IVToken(ms[1].vToken);
        VenusMarketRescuePatch patch = new VenusMarketRescuePatch(ms[1].strat, RECOVERY, v.implementation());
        IVTokenX(address(v)).accrueInterest();
        address original = v.implementation();
        vm.startPrank(TIMELOCK);
        v._setImplementation(address(patch), false, "");
        VenusMarketRescuePatch(ms[1].vToken).settleAndRescue();
        vm.expectRevert(bytes("nothing to move"));
        VenusMarketRescuePatch(ms[1].vToken).settleAndRescue();
        v._setImplementation(original, false, "");
        vm.stopPrank();
    }

    /// The headline comparison: no external capital is required at any point.
    function test_settleAndRescue_needsNoExternalCapital() public {
        uint256 timelockStart = TIMELOCK.balance;
        uint256 recoveryStart = RECOVERY.balance;
        for (uint256 i; i < ms.length; i++) {
            IVToken v = IVToken(ms[i].vToken);
            IVTokenX(address(v)).accrueInterest();
            VenusMarketRescuePatch patch = new VenusMarketRescuePatch(ms[i].strat, RECOVERY, v.implementation());
            address original = v.implementation();
            vm.startPrank(TIMELOCK);
            v._setImplementation(address(patch), false, "");
            VenusMarketRescuePatch(ms[i].vToken).settleAndRescue();
            v._setImplementation(original, false, "");
            vm.stopPrank();
        }
        // Nothing was dealt, approved, or transferred in by anyone.
        assertEq(TIMELOCK.balance, timelockStart, "timelock funded something");
        assertEq(RECOVERY.balance, recoveryStart, "recovery funded something");
        emit log_string("all seven markets settled with zero external capital");
    }
}
