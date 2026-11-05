// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "./RakeDepositorsClaimHarness.sol";

contract ClaimMockToken {
    uint8 public immutable decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => bool) public blocked; // models a token that refuses some recipients

    constructor(uint8 d) {
        decimals = d;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function block_(address who) external {
        blocked[who] = true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        require(!blocked[to], "blocked");
        require(balanceOf[msg.sender] >= a, "insufficient");
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }
}

contract MockStrat {
    uint256 public sharesTotal;

    function set(uint256 s) external {
        sharesTotal = s;
    }
}

contract MockFarm {
    struct P {
        address want;
        address strat;
    }

    mapping(uint256 => P) public p;
    mapping(uint256 => mapping(address => uint256)) public shares;

    function addPool(uint256 pid, address want, address strat) external {
        p[pid] = P(want, strat);
    }

    function setShares(uint256 pid, address user, uint256 s) external {
        shares[pid][user] = s;
    }

    function poolInfo(uint256 pid) external view returns (address, uint256, uint256, uint256, address) {
        return (p[pid].want, 0, 0, 0, p[pid].strat);
    }

    function userInfo(uint256 pid, address user) external view returns (uint256, uint256) {
        return (shares[pid][user], 0);
    }
}

contract RakeDepositorsClaimTest is Test, IClaimCfg {
    RakeDepositorsClaimHarness c;
    MockFarm farm;
    MockStrat sUsdc;
    MockStrat sBtc;
    ClaimMockToken usdc; // Binance-Peg USDC: 18 decimals on BSC
    ClaimMockToken btc8; // 8-decimal token, to prove decimals don't matter to the split
    ClaimMockToken xvs; // optional extra token, split by each pool's earned-XVS weight
    // the deployer (this test) is the opener (stands in for the Timelock), fee recipient and beneficiary
    address beneficiary = address(this);
    address dev = address(this);
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    // Raw farm shares (18-dec, production scale): alice 3/4, bob 1/4 of USDC; alice all of BTC.
    uint256 constant ALICE_USDC = 144_759e18;
    uint256 constant BOB_USDC = 48_253e18;
    uint256 constant ALICE_BTC = 4.265e18;

    uint256[] pids;
    address[] wallets;
    uint256[] xvsWeights;

    function cfgFarm() external view returns (address) {
        return address(farm);
    }

    function cfgFee() external pure returns (uint256) {
        return 1_000; // 10%
    }

    function cfgPids() external view returns (uint256[] memory) {
        return pids;
    }

    function cfgWallets() external view returns (address[] memory) {
        return wallets;
    }

    function cfgXvs() external view returns (address) {
        return address(xvs);
    }

    function cfgXvsWeights() external view returns (uint256[] memory) {
        return xvsWeights;
    }

    function setUp() public {
        usdc = new ClaimMockToken(18);
        btc8 = new ClaimMockToken(8);
        farm = new MockFarm();
        sUsdc = new MockStrat();
        sBtc = new MockStrat();
        farm.addPool(14, address(usdc), address(sUsdc));
        farm.addPool(10, address(btc8), address(sBtc));
        farm.setShares(14, alice, ALICE_USDC);
        farm.setShares(14, bob, BOB_USDC);
        farm.setShares(10, alice, ALICE_BTC);
        sUsdc.set(ALICE_USDC + BOB_USDC);
        sBtc.set(ALICE_BTC);

        pids = [14, 10];
        xvs = new ClaimMockToken(18);
        xvsWeights = [3, 1]; // the USDC strategy earned 3x the XVS of the BTC one
        c = new RakeDepositorsClaimHarness();
    }

    function _fundAndOpen(uint256 usdcAmt, uint256 btcAmt) internal {
        usdc.mint(address(c), usdcAmt);
        btc8.mint(address(c), btcAmt);
        c.open();
    }

    function test_constructor_readsTokensAndStrategiesFromRakeFarm() public view {
        assertEq(c.tokens(0), address(usdc));
        assertEq(c.tokens(1), address(btc8));
        assertEq(c.pidOf(address(btc8)), 10);
        assertEq(c.sharesOf(alice, address(usdc)), ALICE_USDC);
    }

    function test_claim_paysEachDepositorProRataOfWhatArrived() public {
        _fundAndOpen(200_000e18, 3.9e8);
        assertEq(usdc.balanceOf(dev), 20_000e18);
        assertEq(btc8.balanceOf(dev), 0.39e8);

        vm.prank(alice);
        c.claim();
        vm.prank(bob);
        c.claim();
        // 180,000 after fee, split 3:1 (rounding down at most 1 wei each)
        assertApproxEqAbs(usdc.balanceOf(alice), 135_000e18, 1);
        assertApproxEqAbs(usdc.balanceOf(bob), 45_000e18, 1);
        assertEq(btc8.balanceOf(alice), 3.51e8); // sole BTC holder gets the whole pool
    }

    function test_claim_anyArrivedAmountSplitsInTheSameRatio() public {
        _fundAndOpen(123_456e18, 1);
        vm.prank(bob);
        c.claim();
        assertApproxEqAbs(usdc.balanceOf(bob), (123_456e18 - 12_345.6e18) / 4, 1);
    }

    function test_claimable_previewEqualsWhatClaimPays() public {
        _fundAndOpen(200_000e18, 3.9e8);
        uint256 q = c.claimable(alice, address(usdc));
        vm.prank(alice);
        c.claim();
        assertEq(usdc.balanceOf(alice), q);
        assertEq(c.claimable(alice, address(usdc)), 0);
    }

    function test_claim_onlyDepositorsCanClaimAndOnlyOnce() public {
        _fundAndOpen(200_000e18, 3.9e8);
        vm.prank(alice);
        c.claim();
        vm.prank(alice);
        vm.expectRevert("nothing to claim");
        c.claim();
        assertTrue(c.claimedAll(alice));
        vm.prank(makeAddr("stranger"));
        vm.expectRevert("nothing to claim");
        c.claim();
    }

    /// If farm shares ever grew after open, nobody could be paid past the pool.
    function test_claim_farmSharesGrowingAfterOpenCannotOverpayThePool() public {
        _fundAndOpen(200_000e18, 3.9e8);
        farm.setShares(14, bob, 10 * (ALICE_USDC + BOB_USDC)); // impossible on the real farm
        vm.prank(bob);
        c.claimToken(address(usdc)); // capped to shares == totalShares → at most the whole pool
        assertApproxEqAbs(usdc.balanceOf(bob), 180_000e18, 1);
        vm.prank(alice);
        vm.expectRevert("pool exhausted");
        c.claimToken(address(usdc));
    }

    /// open() has no balance checks, so it cannot revert the VIP over amounts: a pool is
    /// whatever arrived, even zero.
    function test_open_neverFailsOnAmounts() public {
        usdc.mint(address(c), 1e18);
        c.open();
        assertGt(c.openedAt(), 0);
        assertEq(c.pool(address(btc8)), 0);
        assertEq(c.pool(address(usdc)), 1e18 - 1e18 * c.FEE_BPS() / 10_000);
    }

    /// Only the opener (the Timelock) can open: 1 wei of every token does not let anyone start
    /// the window early and fix the pools at dust.
    function test_open_oneWeiCannotOpenEarly() public {
        usdc.mint(address(c), 1);
        btc8.mint(address(c), 1);
        vm.prank(alice);
        vm.expectRevert("not opener");
        c.open();
        assertEq(c.openedAt(), 0);
    }

    function test_claim_oneBlockedTokenDoesNotBlockTheOtherTokens() public {
        _fundAndOpen(200_000e18, 3.9e8);
        btc8.block_(alice);
        vm.prank(alice);
        vm.expectRevert("transfer failed");
        c.claim();
        vm.prank(alice);
        c.claimToken(address(usdc));
        assertApproxEqAbs(usdc.balanceOf(alice), 135_000e18, 1);
        assertFalse(c.claimedAll(alice));
        assertEq(c.claimable(alice, address(btc8)), 3.51e8);
    }

    function test_open_onlyOnce() public {
        _fundAndOpen(200_000e18, 3.9e8);
        vm.expectRevert("already open");
        c.open();
    }

    function test_record_snapshotSurvivesTheFarmBurningShares() public {
        address[] memory ws = new address[](2);
        (ws[0], ws[1]) = (alice, bob);
        c.record(ws);
        farm.setShares(14, alice, 0); // a farm withdrawal after the rescue burns her shares
        _fundAndOpen(200_000e18, 3.9e8);
        vm.prank(alice);
        c.claim();
        assertApproxEqAbs(usdc.balanceOf(alice), 135_000e18, 1); // full claim kept
    }

    function test_record_oncePerWalletAndCannotBeRaised() public {
        address[] memory ws = new address[](1);
        ws[0] = bob;
        c.record(ws);
        farm.setShares(14, bob, 10 * BOB_USDC); // impossible on the real farm
        c.record(ws); // second record is ignored
        assertEq(c.sharesOf(bob, address(usdc)), BOB_USDC);
    }

    function test_constructor_recordsTheBuiltInDepositorWallets() public {
        wallets = [alice];
        RakeDepositorsClaimHarness c2 = new RakeDepositorsClaimHarness();
        assertTrue(c2.recorded(alice));
        assertEq(c2.snapshot(alice, address(usdc)), ALICE_USDC);
        assertEq(c2.snapshot(alice, address(btc8)), ALICE_BTC);
    }

    function test_claim_unrecordedWalletIsPaidOnLiveFarmShares() public {
        _fundAndOpen(200_000e18, 3.9e8);
        vm.prank(bob);
        c.claim();
        assertApproxEqAbs(usdc.balanceOf(bob), 45_000e18, 1);
    }

    function test_sweep_after90DayWindowRemainderGoesToBeneficiary() public {
        _fundAndOpen(200_000e18, 3.9e8);
        vm.prank(alice);
        c.claim();

        vm.warp(block.timestamp + 90 days);
        vm.expectRevert("window open");
        c.sweep(address(usdc));

        vm.warp(block.timestamp + 1);
        vm.prank(bob);
        vm.expectRevert("window closed");
        c.claim();

        uint256 left = usdc.balanceOf(address(c));
        uint256 b0 = usdc.balanceOf(beneficiary); // already holds the fee
        c.sweep(address(usdc));
        assertEq(usdc.balanceOf(beneficiary) - b0, left);
        assertApproxEqAbs(left, 45_000e18, 1);
    }

    /// Nothing can be swept before the window opens, by anyone, however long it waits.
    function test_sweep_nothingBeforeOpen() public {
        usdc.mint(address(c), 50_000e18);
        vm.warp(block.timestamp + 1_000 days);
        vm.expectRevert("not open");
        c.sweep(address(usdc));
        vm.prank(beneficiary);
        vm.expectRevert("not open");
        c.sweep(address(usdc));
    }

    /// XVS: pool weight first (3:1), then shares within the pool.
    /// alice = (3 × 3/4 + 1 × 1) / 4 = 81.25%, bob = (3 × 1/4) / 4 = 18.75%.
    function test_xvs_splitByPoolWeightThenByShares() public {
        xvs.mint(address(c), 1_000e18);
        assertApproxEqAbs(c.claimable(alice, address(xvs)), 731.25e18, 1, "preview");
        _fundAndOpen(200_000e18, 3.9e8);
        assertEq(xvs.balanceOf(dev), 100e18, "fee on XVS");
        assertEq(c.pool(address(xvs)), 900e18);

        vm.prank(alice);
        c.claim();
        assertFalse(c.claimedAll(bob));
        vm.prank(bob);
        c.claim();
        assertApproxEqAbs(xvs.balanceOf(alice), 731.25e18, 1);
        assertApproxEqAbs(xvs.balanceOf(bob), 168.75e18, 1);
        assertTrue(c.claimedAll(alice) && c.claimedAll(bob));
        assertLe(c.paidOut(address(xvs)), c.pool(address(xvs)));
    }

    /// No XVS arriving changes nothing: open works, nobody is owed XVS.
    function test_xvs_noXvsArrivingChangesNothing() public {
        _fundAndOpen(200_000e18, 3.9e8);
        assertEq(c.pool(address(xvs)), 0);
        assertEq(c.claimable(alice, address(xvs)), 0);
        vm.prank(alice);
        c.claim();
        assertTrue(c.claimedAll(alice));
        vm.prank(alice);
        vm.expectRevert("nothing to claim");
        c.claimToken(address(xvs));
    }

    /// XVS stays open: it can arrive after open, in several transfers, and is claimable each time.
    function test_xvs_arrivingAfterOpenIsStillClaimable() public {
        _fundAndOpen(200_000e18, 3.9e8);
        vm.prank(alice);
        c.claim();
        assertTrue(c.claimedAll(alice));

        xvs.mint(address(c), 1_000e18); // first XVS transfer, after open
        assertFalse(c.claimedAll(alice));
        assertApproxEqAbs(c.claimable(alice, address(xvs)), 731.25e18, 1, "preview");
        vm.prank(alice);
        c.claim();
        assertApproxEqAbs(xvs.balanceOf(alice), 731.25e18, 1);
        assertEq(xvs.balanceOf(dev), 100e18, "fee once");

        xvs.mint(address(c), 1_000e18); // second transfer
        vm.prank(alice);
        c.claimToken(address(xvs));
        assertApproxEqAbs(xvs.balanceOf(alice), 1_462.5e18, 2);
        vm.prank(bob);
        c.claim();
        assertApproxEqAbs(xvs.balanceOf(bob), 337.5e18, 2);
        assertEq(xvs.balanceOf(dev), 200e18, "each arrival fee'd once");
        assertLe(c.paidOut(address(xvs)), c.pool(address(xvs)));

        vm.prank(alice);
        vm.expectRevert("nothing to claim");
        c.claimToken(address(xvs));
    }

    /// A VIP that lands long after deploy still opens: nothing was swept in the meantime.
    function test_open_fundsArrivingLongAfterDeployStillOpen() public {
        vm.warp(block.timestamp + 200 days);
        _fundAndOpen(200_000e18, 3.9e8);
        vm.prank(alice);
        c.claim();
        assertGt(usdc.balanceOf(alice), 0);
    }

    /// After the window, claimable() reads 0 for every token, and the XVS view does not revert
    /// once XVS has been swept.
    function test_claimable_readsZeroAfterWindowAndSweep() public {
        xvs.mint(address(c), 1_000e18);
        _fundAndOpen(200_000e18, 3.9e8);
        assertGt(c.claimable(alice, address(usdc)), 0);
        vm.warp(c.deadline() + 1);
        assertEq(c.claimable(alice, address(usdc)), 0);
        assertEq(c.claimable(alice, address(xvs)), 0);
        c.sweep(address(xvs));
        assertEq(c.claimable(alice, address(xvs)), 0);
        assertFalse(c.claimedAll(alice));
    }
}
