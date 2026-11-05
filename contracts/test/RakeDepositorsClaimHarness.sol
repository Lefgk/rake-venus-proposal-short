// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "../src/RakeDepositorsClaim.sol";

/// Implemented by the test that deploys a RakeDepositorsClaimHarness.
interface IClaimCfg {
    function cfgFarm() external view returns (address);
    function cfgFee() external view returns (uint256);
    function cfgPids() external view returns (uint256[] memory);
    function cfgWallets() external view returns (address[] memory);
    function cfgXvs() external view returns (address);
    function cfgXvsWeights() external view returns (uint256[] memory);
}

/// Test-only: RakeDepositorsClaim with farm, pools, fee and wallets read from the deployer,
/// so the claim logic can run against a mock farm or another pool.
contract RakeDepositorsClaimHarness is RakeDepositorsClaim {
    /// The deploying test stands in for the Venus Timelock.
    function _opener() internal view override returns (address) {
        return msg.sender;
    }

    function _farm() internal view override returns (address) {
        return IClaimCfg(msg.sender).cfgFarm();
    }

    function _feeBps() internal view override returns (uint256) {
        return IClaimCfg(msg.sender).cfgFee();
    }

    function _pids() internal view override returns (uint256[] memory) {
        return IClaimCfg(msg.sender).cfgPids();
    }

    function _wallets() internal view override returns (address[] memory) {
        return IClaimCfg(msg.sender).cfgWallets();
    }

    function _xvs() internal view override returns (address) {
        return IClaimCfg(msg.sender).cfgXvs();
    }

    function _xvsWeights() internal view override returns (uint256[] memory) {
        return IClaimCfg(msg.sender).cfgXvsWeights();
    }

    /// Mock pools are funded with the underlying directly: no vTokens to redeem.
    function _vTokens() internal pure override returns (address[] memory v) {}
}
