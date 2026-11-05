// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "../script/libraries/RescueContractsDeployment.sol";

/// Checks script/DeployRakeDepositorsClaim.s.sol on a BSC fork: the claim contract is owned by its
/// deployer, lists the seven underlyings in market order, and snapshots every depositor before
/// any rescue runs.
contract DeployRakeDepositorsClaimTest is Test {
    RakeDepositorsClaim claim;

    function setUp() public {
        uint256 b = vm.envOr("FORK_BLOCK", uint256(0));
        if (b == 0) vm.createSelectFork(vm.envString("BSC_RPC_URL"));
        else vm.createSelectFork(vm.envString("BSC_RPC_URL"), b);
        claim = RescueContractsDeployment.deployClaim();
    }

    function test_deploy_onlyTheTimelockOpensAndTheSevenUnderlyingsAreInMarketOrder() public view {
        assertEq(claim.OPENER(), 0x939bD8d64c0A9583A7Dcea9933f7b21697ab6396, "opener is not the Normal Timelock");
        assertEq(claim.FEE_RECIPIENT(), address(this), "fee recipient");
        assertEq(claim.BENEFICIARY(), address(this), "beneficiary");
        assertEq(claim.openedAt(), 0, "must not be open");
        address[7] memory markets = RakeFrozenPositions.vTokens();
        for (uint256 i; i < RakeFrozenPositions.COUNT; ++i) {
            assertEq(claim.tokens(i), IVTokenClaim(markets[i]).underlying(), "token order");
        }
    }

    function test_deploy_claimContractSnapshotsAll103DepositorsCoveringEveryPoolsShares() public view {
        address[] memory wallets = claim.builtInWallets();
        assertEq(wallets.length, 103, "wallet count");
        for (uint256 i; i < RakeFrozenPositions.COUNT; ++i) {
            address t = claim.tokens(i);
            uint256 recorded;
            for (uint256 j; j < wallets.length; ++j) {
                assertTrue(claim.recorded(wallets[j]), "wallet not recorded");
                recorded += claim.snapshot(wallets[j], t);
            }
            assertLe(claim.totalShares(t) - recorded, 10, "a pool has unrecorded shares");
        }
    }
}
