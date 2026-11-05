// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "./Interfaces.sol";
import "../src/VenusMarketRescuePatch.sol";
import "../src/RakeDepositorsClaim.sol";

interface IAccrue {
    function accrueInterest() external returns (uint256);
}

interface IRakeFarmFull {
    function deposit(uint256 pid, uint256 amt) external;
    function withdraw(uint256 pid, uint256 amt) external;
    function emergencyWithdraw(uint256 pid) external;
}

interface IStratGov {
    function unpause() external;
    function setEntranceFeeFactor(uint256) external;
}

/// Whole flow on live BSC state: Venus self-funded rescue of the 7 pools → underlying into
/// RakeDepositorsClaim (reads shares from RakeFarm, 10% fee) → open → real depositors claim.
/// Also proves the gov cannot inflate its farm shares after the rescue.
contract PostRescueRakeFarmSafetyTest is Test {
    address constant TIMELOCK = 0x939bD8d64c0A9583A7Dcea9933f7b21697ab6396;
    address constant FARM = 0x7f7Bf15B9c68D23339C31652C8e860492991760d;
    address constant GOV = 0x16c7C45725A977ae6530e8dEE73F6da9aE2e7E07;
    address constant TOP = 0x3F6BaBbF1a9DFB3039Dc932986D4A9658234fe21; // vBTC + vETH depositor
    address constant SECOND = 0xFFFFF6E70842330948Ca47254F2bE673B1cb0dB7; // vUSDC depositor

    address[7] internal vt = [
        0x95c78222B3D6e262426483D42CfA53685A67Ab9D, // 9  vBUSD
        0x882C173bC7Ff3b7786CA16dfeD3DFFfb9Ee7847B, // 10 vBTC
        0xf508fCD89b8bd15579dc79A6827cB4686A3592c8, // 11 vETH
        0x650b940a1033B8A1b1873f78730FcFC73ec11f1f, // 12 vLINK
        0xfD5840Cd36d94D7229439859C0112a4185BC0255, // 13 vUSDT
        0xecA88125a5ADbe82614ffC12D0DB554E2e2867C8, // 14 vUSDC
        0x1610bc33319e9398de5f57B33a5b184c806aD217 //  15 vDOT
    ];
    address[7] internal st = [
        0xDF3df3EE9Fb6D5c9B4fdcF80A92D25d2285A859C,
        0xB3bCA2C1c2C4DF2C903BE3F341C96732Ac8b3c12,
        0x9E3e8878B53c5762Ec6F461701f02ee6d1D9d19C,
        0x0b09Efc9458c00354414D2A560aA6EDa19490169,
        0xc6f470dA6C284D16647CEE2230522a85b0818f6D,
        0x7485704d8B6cEBd1411F5AAfEB063e6f2816069A,
        0x568254EAAC1476faf9A908e577faa3Ab96029801
    ];

    function _assertListComplete(RakeDepositorsClaim claim) internal {
        address[] memory ws = claim.builtInWallets();
        emit log_named_uint("built-in wallets", ws.length);
        for (uint256 i; i < 7; ++i) {
            address t = claim.tokens(i);
            uint256 sum;
            for (uint256 j; j < ws.length; ++j) sum += claim.snapshot(ws[j], t);
            emit log_named_uint(string.concat("pid ", vm.toString(9 + i), " unrecorded shares (wei)"), claim.totalShares(t) - sum);
            assertLe(claim.totalShares(t) - sum, 10, "wallet list misses a holder");
        }
    }

    function setUp() public {
        uint256 b = vm.envOr("FORK_BLOCK", uint256(0));
        if (b == 0) vm.createSelectFork(vm.envString("BSC_RPC_URL"));
        else vm.createSelectFork(vm.envString("BSC_RPC_URL"), b);
    }

    function test_afterRescue_noOneCanDepositInflateSharesOrDoubleWithdraw_thenDepositorsClaim() public {
        address dev = makeAddr("deployer");
        uint256 g0 = gasleft();
        vm.prank(dev); // the deployer is fee recipient and beneficiary
        RakeDepositorsClaim claim = new RakeDepositorsClaim();
        assertEq(claim.OPENER(), TIMELOCK);
        assertEq(claim.FEE_RECIPIENT(), dev);
        assertEq(claim.BENEFICIARY(), dev);
        emit log_named_uint("deploy gas", g0 - gasleft());

        // ---- the built-in wallet list is complete: recorded shares sum to each pool's total ----
        assertTrue(claim.recorded(TOP) && claim.recorded(SECOND));
        _assertListComplete(claim);

        // ---- Venus vote: self-funded rescue; 20% of the vTokens to Venus, 80% to the claim contract ----
        for (uint256 i; i < 7; ++i) {
            IVToken v = IVToken(vt[i]);
            assertEq(claim.tokens(i), v.underlying(), "token order");
            IAccrue(vt[i]).accrueInterest();
            address original = v.implementation();
            VenusMarketRescuePatch patch = new VenusMarketRescuePatch(st[i], address(claim), original);
            vm.startPrank(TIMELOCK);
            v._setImplementation(address(patch), false, "");
            (,, uint256 moved) = VenusMarketRescuePatch(vt[i]).settleAndRescue();
            v._setImplementation(original, false, "");
            vm.stopPrank();
            assertEq(IERC20(vt[i]).balanceOf(address(claim)), moved - moved * 2_000 / 10_000, "claim 80%");
        }

        // ---- after the rescue, gov tries to inflate its shares in an ERC-20 pool: must fail ----
        {
            address want = claim.tokens(1); // BTCB, pid 10
            deal(want, GOV, 1e18);
            vm.startPrank(GOV);
            try IStratGov(st[1]).unpause() {} catch {}
            IStratGov(st[1]).setEntranceFeeFactor(1e30);
            IERC20(want).approve(FARM, type(uint256).max);
            vm.expectRevert();
            IRakeFarmFull(FARM).deposit(10, 1e6);
            vm.stopPrank();
        }

        // ---- after the rescue nobody can deposit into any of the 7 pools (shares cannot grow) ----
        address attacker = makeAddr("attacker");
        for (uint256 i; i < 7; ++i) {
            address want = claim.tokens(i);
            deal(want, attacker, 1_000e18);
            uint256 sBefore = IERC20(want).balanceOf(st[i]);
            vm.startPrank(attacker);
            IERC20(want).approve(FARM, type(uint256).max);
            bool ok;
            try IRakeFarmFull(FARM).deposit(9 + i, 1e18) { ok = true; } catch {}
            vm.stopPrank();
            emit log_named_uint(string.concat("pid ", vm.toString(9 + i), " deposit succeeded (1=yes)"), ok ? 1 : 0);
            emit log_named_uint("   strategy want before", sBefore);
            emit log_named_uint("   strategy want after ", IERC20(want).balanceOf(st[i]));
            (uint256 sh,) = IRakeFarm(FARM).userInfo(9 + i, attacker);
            emit log_named_uint("   attacker shares     ", sh);
        }

        // ---- a depositor cannot also exit through the farm (no double dip) ----
        {
            address btcb = claim.tokens(1);
            uint256 b0 = IERC20(btcb).balanceOf(TOP);
            vm.startPrank(TOP);
            try IRakeFarmFull(FARM).withdraw(10, 1e18) { emit log_string("farm.withdraw after rescue: did NOT revert"); }
            catch { emit log_string("farm.withdraw after rescue: reverts"); }
            try IRakeFarmFull(FARM).emergencyWithdraw(10) { emit log_string("farm.emergencyWithdraw after rescue: did NOT revert"); }
            catch { emit log_string("farm.emergencyWithdraw after rescue: reverts"); }
            vm.stopPrank();
            assertEq(IERC20(btcb).balanceOf(TOP), b0, "farm paid TOP something after rescue");
        }

        // ---- open (the VIP's last command) and claim ----
        vm.prank(TIMELOCK);
        claim.open();
        uint256 qBtc = claim.claimable(TOP, claim.tokens(1));
        uint256 qEth = claim.claimable(TOP, claim.tokens(2));
        uint256 qUsdc = claim.claimable(SECOND, claim.tokens(5));
        emit log_named_decimal_uint("TOP wallet BTCB", qBtc, 18);
        emit log_named_decimal_uint("TOP wallet ETH ", qEth, 18);
        emit log_named_decimal_uint("2nd wallet USDC", qUsdc, 18);

        vm.prank(TOP);
        claim.claim();
        vm.prank(SECOND);
        claim.claim();
        assertEq(IERC20(claim.tokens(1)).balanceOf(TOP) >= qBtc, true);
        assertGt(qBtc, 1.6e18, "top wallet BTCB too small"); // its share of the 80%, after the 10% fee
        assertGt(qUsdc, 56_000e18, "second wallet USDC too small");
        assertTrue(claim.claimedAll(TOP));

        // fee went out once, at open
        for (uint256 i; i < 7; ++i) {
            address t = claim.tokens(i);
            uint256 fee = IERC20(t).balanceOf(dev);
            assertEq(fee, (claim.pool(t) + fee) * 1_250 / 10_000, "fee");
            assertEq(IERC20(vt[i]).balanceOf(address(claim)), 0, "vTokens not redeemed");
        }
    }
}
