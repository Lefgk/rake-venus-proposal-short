// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "./RakeFrozenPositions.sol";
import "../../src/VenusMarketRescuePatch.sol";

/// The proposal's command list, shared by script/VenusRescueProposal.s.sol and test/VenusRescueProposal.t.sol,
/// so the commands the tests execute are byte-for-byte the commands Venus is asked to submit.
library VenusRescueProposalCommands {
    /// One Venus Timelock action: it calls `target` with selector(signature) ++ params.
    struct Command {
        address target;
        string signature;
        bytes params;
    }

    /// Number of XVS-settle commands at the start of the list (step 1 below).
    uint256 internal constant XVS_SETTLE_COMMANDS = 2;

    /// 1. Settle the XVS index of the claim contract and the Venus treasury on the seven
    ///    markets, so the vTokens they receive earn no back-dated XVS. Uses the 2-argument
    ///    claimVenus: the 1-argument one walks every market ever listed and reverts on a delisted one.
    /// 2. For each market: accrue interest, swap in its VenusMarketRescuePatch, call settleAndRescue()
    ///    (retires the strategy's debt from its own collateral, moves the net vTokens 20% to the
    ///    Venus treasury and 80% to the claim contract), then restore the original implementation.
    /// 3. Optional: grant the strategies' earned XVS to the claim contract.
    /// 4. Open the claim window: the claim contract redeems its vTokens, takes the 10% recovery
    ///    cost and starts the 90 days, in the same transaction that delivered the funds.
    function build(address claim, address[7] memory rescuePatches, bool includeXvsGrant)
        internal
        view
        returns (Command[] memory c)
    {
        address comptroller = RakeFrozenPositions.VENUS_COMPTROLLER;
        address[7] memory markets = RakeFrozenPositions.vTokens();
        address[] memory marketList = RakeFrozenPositions.vTokenList();

        c = new Command[](XVS_SETTLE_COMMANDS + 4 * RakeFrozenPositions.COUNT + (includeXvsGrant ? 1 : 0) + 1);
        uint256 n;
        c[n++] = Command(comptroller, "claimVenus(address,address[])", abi.encode(claim, marketList));
        c[n++] = Command(
            comptroller, "claimVenus(address,address[])", abi.encode(RakeFrozenPositions.VENUS_TREASURY, marketList)
        );
        for (uint256 i; i < RakeFrozenPositions.COUNT; ++i) {
            VenusMarketRescuePatch d = VenusMarketRescuePatch(rescuePatches[i]);
            c[n++] = Command(markets[i], "accrueInterest()", "");
            c[n++] = Command(markets[i], "_setImplementation(address,bool,bytes)", abi.encode(address(d), false, ""));
            c[n++] = Command(markets[i], "settleAndRescue()", "");
            c[n++] = Command(
                markets[i], "_setImplementation(address,bool,bytes)", abi.encode(d.ORIGINAL_IMPL(), false, "")
            );
        }
        if (includeXvsGrant) {
            c[n++] = Command(
                comptroller, "_grantXVS(address,uint256)", abi.encode(claim, RakeFrozenPositions.OPTIONAL_XVS_GRANT)
            );
        }
        c[n++] = Command(claim, "open()", "");
    }

    /// The exact bytes the Timelock sends for a command.
    function callData(Command memory c) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes4(keccak256(bytes(c.signature))), c.params);
    }
}
