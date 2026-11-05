// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "./Interfaces.sol";
import "../src/VenusMarketRescuePatch.sol";
import "../src/RakeDepositorsClaim.sol";
import "../script/libraries/RescueContractsDeployment.sol";
import "../script/libraries/VenusRescueProposalCommands.sol";

interface IAccrueS {
    function accrueInterest() external returns (uint256);
}

interface IMarketS {
    function exchangeRateStored() external view returns (uint256);
    function getCash() external view returns (uint256);
    function totalReserves() external view returns (uint256);
    function borrowIndex() external view returns (uint256);
    function totalBorrows() external view returns (uint256);
    function mint(uint256) external returns (uint256);
}

interface IComptrollerS {
    function claimVenus(address holder, address[] calldata vTokens) external;
    function _grantXVS(address recipient, uint256 amount) external;
}

/// Simulates script/VenusRescueProposal.s.sol on a BSC fork: the contracts are deployed exactly as
/// script/DeployRakeDepositorsClaim.s.sol and script/DeployVenusMarketRescuePatches.s.sol deploy them, then every command of the proposal is sent
/// from the Venus Normal Timelock, byte-for-byte as Venus would submit it. Its last command opens
/// the claim contract, which redeems its vTokens, in the same transaction.
contract VenusRescueProposalTest is Test {
    using VenusRescueProposalCommands for VenusRescueProposalCommands.Command;

    address constant TIMELOCK = 0x939bD8d64c0A9583A7Dcea9933f7b21697ab6396;
    address constant TREASURY = 0xF322942f644A996A617BD29c16bd7d231d9F35E9;
    address constant COMPTROLLER = 0xfD36E2c2a6789Db23113685031d7F16329158384;
    address constant XVS = 0xcF6BB5389c92Bdda8a3747Ddb454cB7a64626C63;
    uint256 constant XVS_GRANT = 8_021_990798477276016835;

    address[7] internal st = [
        0xDF3df3EE9Fb6D5c9B4fdcF80A92D25d2285A859C,
        0xB3bCA2C1c2C4DF2C903BE3F341C96732Ac8b3c12,
        0x9E3e8878B53c5762Ec6F461701f02ee6d1D9d19C,
        0x0b09Efc9458c00354414D2A560aA6EDa19490169,
        0xc6f470dA6C284D16647CEE2230522a85b0818f6D,
        0x7485704d8B6cEBd1411F5AAfEB063e6f2816069A,
        0x568254EAAC1476faf9A908e577faa3Ab96029801
    ];

    RakeDepositorsClaim claim;
    address[7] rescuePatches;

    function setUp() public {
        // Pin FORK_BLOCK to reuse foundry's RPC cache across tests and runs.
        uint256 b = vm.envOr("FORK_BLOCK", uint256(0));
        if (b == 0) vm.createSelectFork(vm.envString("BSC_RPC_URL"));
        else vm.createSelectFork(vm.envString("BSC_RPC_URL"), b);
        // This test is the deployer: fee recipient and beneficiary of the claim contract.
        claim = RescueContractsDeployment.deployClaim();
        rescuePatches = RescueContractsDeployment.deployRescuePatches(address(claim));
    }

    /// vBUSD, vBTC, vETH, vLINK, vUSDT, vUSDC, vDOT — RakeFarm pids 9–15.
    function _markets() internal pure returns (address[7] memory) {
        return [
            0x95c78222B3D6e262426483D42CfA53685A67Ab9D,
            0x882C173bC7Ff3b7786CA16dfeD3DFFfb9Ee7847B,
            0xf508fCD89b8bd15579dc79A6827cB4686A3592c8,
            0x650b940a1033B8A1b1873f78730FcFC73ec11f1f,
            0xfD5840Cd36d94D7229439859C0112a4185BC0255,
            0xecA88125a5ADbe82614ffC12D0DB554E2e2867C8,
            0x1610bc33319e9398de5f57B33a5b184c806aD217
        ];
    }

    function _list() internal pure returns (address[] memory list) {
        address[7] memory m = _markets();
        list = new address[](7);
        for (uint256 i; i < 7; ++i) list[i] = m[i];
    }

    function _commands(bool includeXvsGrant) internal view returns (VenusRescueProposalCommands.Command[] memory) {
        return VenusRescueProposalCommands.build(address(claim), rescuePatches, includeXvsGrant);
    }

    /// Sends one proposal command from the Timelock, as Timelock.executeTransaction does.
    function _send(VenusRescueProposalCommands.Command memory c) internal {
        vm.prank(TIMELOCK);
        (bool ok, bytes memory ret) = c.target.call(c.callData());
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    /// Executes the proposal. `skipXvsSettle` drops step 1, only to measure what it prevents;
    /// `andOpen = false` stops before the last command (open()), only to inspect the state between.
    function _executeProposal(bool skipXvsSettle, bool includeXvsGrant, bool andOpen) internal {
        address[7] memory m = _markets();
        for (uint256 i; i < 7; ++i) assertEq(IVToken(m[i]).admin(), TIMELOCK, "vToken admin is not the Normal Timelock");
        VenusRescueProposalCommands.Command[] memory c = _commands(includeXvsGrant);
        uint256 first = skipXvsSettle ? VenusRescueProposalCommands.XVS_SETTLE_COMMANDS : 0;
        uint256 end = andOpen ? c.length : c.length - 1;
        for (uint256 k = first; k < end; ++k) _send(c[k]);
    }

    function _executeProposal(bool skipXvsSettle, bool includeXvsGrant) internal {
        _executeProposal(skipXvsSettle, includeXvsGrant, true);
    }

    /// The proposal's last command: open().
    function _sendOpen() internal {
        VenusRescueProposalCommands.Command[] memory c = _commands(false);
        _send(c[c.length - 1]);
    }

    function _executeProposal() internal {
        _executeProposal(false, false);
    }

    function test_proposal_moves20PercentToVenusTreasuryAnd80PercentToClaimContract() public {
        address[7] memory m = _markets();
        uint256[7] memory t0;
        for (uint256 i; i < 7; ++i) t0[i] = IERC20(m[i]).balanceOf(TREASURY);
        _executeProposal(false, false, false);
        for (uint256 i; i < 7; ++i) {
            uint256 toVenus = IERC20(m[i]).balanceOf(TREASURY) - t0[i];
            uint256 toClaim = IERC20(m[i]).balanceOf(address(claim));
            assertGt(toClaim, 0, "claim got nothing");
            assertApproxEqAbs(toVenus * 4, toClaim, 4, "not 20/80");
            assertEq(IERC20(m[i]).balanceOf(st[i]), 0, "strategy kept vTokens");
            assertEq(IVToken(m[i]).implementation(), RakeFrozenPositions.VBEP20_DELEGATE_IMPLEMENTATION, "not restored");
        }
        assertEq(claim.openedAt(), 0, "not open before the last command");

        _sendOpen();
        assertEq(claim.openedAt(), block.timestamp, "the VIP's last command opens the window");
        for (uint256 i; i < 7; ++i) {
            assertEq(IERC20(m[i]).balanceOf(address(claim)), 0, "vTokens not redeemed");
            address u = IVToken(m[i]).underlying();
            assertEq(claim.tokens(i), u, "token order");
            assertGt(claim.pool(u), 0, "empty pool");
            emit log_named_decimal_uint(string.concat(vm.toString(u), " pool"), claim.pool(u), 18);
        }
    }

    /// Only the Timelock opens, so nobody can open early with 1 wei of each token or hold the
    /// window back; the deployer cannot open it either.
    function test_claimContract_onlyTheTimelockCanOpen() public {
        vm.expectRevert("not opener");
        claim.open();
        vm.prank(makeAddr("anyone"));
        vm.expectRevert("not opener");
        claim.open();
        assertEq(claim.OPENER(), TIMELOCK);
    }

    /// With action 0 the claim contract earns ~no XVS from the move; without it, the over-credit.
    function test_proposal_xvsSettleStepStopsBackdatedXvsRewards() public {
        uint256 snap = vm.snapshotState();
        _executeProposal(true, false, false);
        IComptrollerS(COMPTROLLER).claimVenus(address(claim), _list());
        uint256 withoutSettle = IERC20(XVS).balanceOf(address(claim));
        emit log_named_decimal_uint("XVS to claim WITHOUT settle (over-credit)", withoutSettle, 18);

        vm.revertToState(snap);
        _executeProposal(false, false, false);
        uint256 tr0 = IERC20(XVS).balanceOf(TREASURY);
        IComptrollerS(COMPTROLLER).claimVenus(address(claim), _list());
        IComptrollerS(COMPTROLLER).claimVenus(TREASURY, _list());
        uint256 withSettle = IERC20(XVS).balanceOf(address(claim));
        emit log_named_decimal_uint("XVS to claim WITH settle", withSettle, 18);
        assertGt(withoutSettle, 1_000e18, "expected a windfall without settle");
        assertLt(withSettle, 1e18, "settle should leave ~0 XVS");
        assertLt(IERC20(XVS).balanceOf(TREASURY) - tr0, 1e18, "treasury over-credited");
    }

    /// Optional: Venus grants the strategies' earned XVS straight to the claim contract.
    function test_proposal_optionalXvsGrantReachesTheClaimContract() public {
        _executeProposal(false, true);
        assertEq(claim.pool(XVS), XVS_GRANT - XVS_GRANT * 1_250 / 10_000, "xvs pool");
    }

    /// The patch accepts only the market's live admin (the Normal Timelock today), nobody else.
    function test_rescuePatch_onlyTheMarketAdminCanCallSettleAndRescue() public {
        IVToken v = IVToken(_markets()[1]);
        IAccrueS(address(v)).accrueInterest();
        address original = v.implementation();
        VenusMarketRescuePatch patch = new VenusMarketRescuePatch(st[1], address(claim), original);
        vm.prank(TIMELOCK);
        v._setImplementation(address(patch), false, "");
        vm.prank(makeAddr("notAdmin"));
        vm.expectRevert("only admin");
        VenusMarketRescuePatch(address(v)).settleAndRescue();
        vm.prank(TIMELOCK);
        VenusMarketRescuePatch(address(v)).settleAndRescue();
    }

    function test_rescuePatch_rejectsAnEoaAsTheClaimContract() public {
        address impl = IVToken(_markets()[1]).implementation();
        address eoa = makeAddr("eoa");
        vm.expectRevert("claim not a contract");
        new VenusMarketRescuePatch(st[1], eoa, impl);
    }

    /// Item 8: other suppliers lose nothing. For every market: a separate supplier deposits
    /// first; the rescue (same block) leaves exchange rate, cash, reserves and borrow index
    /// unchanged and the supplier's balance untouched; after the claim contract redeems, the supplier still
    /// redeems at least what they put in.
    function test_proposal_otherVenusSuppliersLoseNothing() public {
        address[7] memory m = _markets();
        address other = makeAddr("otherSupplier");
        uint256[7] memory er0;
        uint256[7] memory bal0;
        uint256[7] memory value0;
        bool[7] memory minted;

        for (uint256 i; i < 7; ++i) {
            IAccrueS(m[i]).accrueInterest();
            address u = IVToken(m[i]).underlying();
            uint256 amt = 1_000 * 10 ** 18 / (i == 1 ? 100_000 : i == 2 ? 3_000 : 1); // ~$1k each
            deal(u, other, amt);
            vm.startPrank(other);
            IERC20(u).approve(m[i], amt);
            // Some deprecated markets have mint paused; those are checked on market state only.
            try IMarketS(m[i]).mint(amt) returns (uint256 err) {
                minted[i] = err == 0 && IVToken(m[i]).balanceOf(other) > 0;
            } catch {}
            vm.stopPrank();
            bal0[i] = IVToken(m[i]).balanceOf(other);
            value0[i] = bal0[i] * IMarketS(m[i]).exchangeRateStored() / 1e18;
        }

        VenusRescueProposalCommands.Command[] memory c = _commands(false);
        uint256 k;
        for (; k < VenusRescueProposalCommands.XVS_SETTLE_COMMANDS; ++k) _send(c[k]);
        for (uint256 i; i < 7; ++i) {
            IMarketS mk = IMarketS(m[i]);
            IVToken v = IVToken(m[i]);
            _send(c[k++]); // accrueInterest()
            er0[i] = mk.exchangeRateStored();
            uint256 cash0 = mk.getCash();
            uint256 res0 = mk.totalReserves();
            uint256 bi0 = mk.borrowIndex();

            _send(c[k++]); // _setImplementation(rescue patch)
            _send(c[k++]); // settleAndRescue()
            _send(c[k++]); // _setImplementation(original)

            assertGe(mk.exchangeRateStored(), er0[i], "exchange rate fell");
            // Only the rounded-UP burn can move it, by one vToken unit: < 1e-12 relative.
            assertLe((mk.exchangeRateStored() - er0[i]) * 1e18 / er0[i], 1e6, "exchange rate moved more than dust");
            assertEq(mk.getCash(), cash0, "cash changed");
            assertEq(mk.totalReserves(), res0, "reserves changed");
            assertEq(mk.borrowIndex(), bi0, "borrow index changed");
            assertEq(v.balanceOf(other), bal0[i], "other supplier balance changed");
            emit log_named_uint(string.concat("market ", vm.toString(i), " other supplier minted (1=yes)"), minted[i] ? 1 : 0);
        }

        _send(c[k++]); // open(): redeems the claim contract's 80% through the ordinary path

        for (uint256 i; i < 7; ++i) {
            assertGe(IMarketS(m[i]).exchangeRateStored(), er0[i], "exchange rate fell after redeem");
            if (!minted[i]) continue;
            address u = IVToken(m[i]).underlying();
            uint256 b = IERC20(u).balanceOf(other);
            vm.prank(other);
            assertEq(IVToken(m[i]).redeem(bal0[i]), 0, "other supplier cannot redeem");
            assertGe(IERC20(u).balanceOf(other) - b + 1, value0[i], "other supplier got back less");
        }
    }

    /// Full chain: VIP (settle XVS, rescue, optional XVS grant, open) → every one of the
    /// 103 wallets claims → each gets exactly pool × shares ÷ total, the fee is 12.5% of what
    /// arrived, pools empty to dust, and after the window the dust sweeps to the beneficiary.
    function test_proposalThenOpen_all103DepositorsClaimTheirExactShare() public {
        _executeProposal(false, true, false);

        uint256 n = claim.tokenCount();
        address[] memory toks = new address[](n + 1);
        uint256[] memory fee0 = new uint256[](n + 1);
        for (uint256 i; i < n; ++i) toks[i] = claim.tokens(i);
        toks[n] = XVS;
        for (uint256 i; i <= n; ++i) fee0[i] = IERC20(toks[i]).balanceOf(address(this));

        // Before open, the site's preview prices the vTokens at the stored exchange rate.
        address[] memory ws = claim.builtInWallets();
        assertEq(ws.length, 103);
        uint256 preview = claim.claimable(ws[0], toks[0]);

        _sendOpen();
        for (uint256 i; i <= n; ++i) {
            uint256 fee = IERC20(toks[i]).balanceOf(address(this)) - fee0[i];
            assertGt(claim.pool(toks[i]), 0, "token not funded");
            assertEq(fee, (claim.pool(toks[i]) + fee) * 1_250 / 10_000, "fee != 12.5%");
        }
        assertApproxEqRel(claim.claimable(ws[0], toks[0]), preview, 1e12, "pre-open preview off");

        for (uint256 k; k < ws.length; ++k) {
            address w = ws[k];
            uint256[] memory want = new uint256[](n + 1);
            uint256[] memory b0 = new uint256[](n + 1);
            bool any;
            for (uint256 i; i <= n; ++i) {
                want[i] = claim.claimable(w, toks[i]);
                b0[i] = IERC20(toks[i]).balanceOf(w);
                if (want[i] > 0) any = true;
            }
            for (uint256 i; i < n; ++i) {
                assertEq(want[i], claim.pool(toks[i]) * claim.sharesOf(w, toks[i]) / claim.totalShares(toks[i]));
            }
            if (!any) {
                // Shares so small every cut rounds to 0 (< 1 wei of each token): nothing to pay.
                emit log_named_address("dust-only wallet", w);
                assertTrue(claim.claimedAll(w), "dust wallet not done");
                continue;
            }
            vm.prank(w);
            claim.claim();
            assertTrue(claim.claimedAll(w), "not fully claimed");
            for (uint256 i; i <= n; ++i) {
                assertEq(IERC20(toks[i]).balanceOf(w) - b0[i], want[i], "paid != claimable");
            }
            vm.prank(w);
            vm.expectRevert("nothing to claim");
            claim.claim();
        }

        // Every share is accounted for: pools empty to rounding dust (< 1 unit per wallet).
        for (uint256 i; i <= n; ++i) {
            uint256 left = IERC20(toks[i]).balanceOf(address(claim));
            assertEq(left, claim.pool(toks[i]) - claim.paidOut(toks[i]), "balance != unpaid");
            assertLe(left, ws.length, "more than dust left");
        }

        vm.warp(claim.deadline() + 1);
        for (uint256 i; i <= n; ++i) {
            uint256 left = IERC20(toks[i]).balanceOf(address(claim));
            if (left == 0) continue;
            uint256 b0 = IERC20(toks[i]).balanceOf(address(this));
            claim.sweep(toks[i]);
            assertEq(IERC20(toks[i]).balanceOf(address(this)) - b0, left, "sweep");
        }
    }

    /// A VIP that lands long after deploy opens the 90 days in its own transaction, and nothing
    /// can be swept until they have run.
    function test_proposal_lateVipOpensTheWindowInItsOwnTransaction() public {
        vm.warp(block.timestamp + 200 days);
        _executeProposal();
        assertEq(claim.openedAt(), block.timestamp);
        assertEq(claim.deadline(), block.timestamp + 90 days);
        address usdc = claim.tokens(5);
        assertGt(claim.pool(usdc), 0);
        vm.prank(makeAddr("anyone"));
        vm.expectRevert("window open");
        claim.sweep(usdc);
    }
}
