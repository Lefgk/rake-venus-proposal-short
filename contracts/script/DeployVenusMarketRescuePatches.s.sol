// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Script.sol";
import "./libraries/RescueContractsDeployment.sol";
import "./libraries/AddressesJson.sol";

/// Step 3 (APPENDIX A2), run by Venus: deploys the seven VenusMarketRescuePatches, each bound to the claim contract
/// read from addresses.json, and records them there (.deployed.rescuePatches.<TOKEN>).
/// The key is read from $PRIVATE_KEY; the deployer gets no power over the patches.
///
///   forge script script/DeployVenusMarketRescuePatches.s.sol --fork-url $BSC_RPC_URL              # dry run
///   forge script script/DeployVenusMarketRescuePatches.s.sol --rpc-url $BSC_MEV_RPC_URL --broadcast   # deploy, MEV-protected RPC
contract DeployVenusMarketRescuePatches is Script {
    function run() external {
        address claim = AddressesJson.deployed(".deployed.claimContract", "DeployRakeDepositorsClaim");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);
        address[7] memory rescuePatches = RescueContractsDeployment.deployRescuePatches(claim);
        vm.stopBroadcast();

        string[7] memory symbols = RakeFrozenPositions.symbols();
        for (uint256 i; i < RakeFrozenPositions.COUNT; ++i) {
            console.log(string.concat("rescue patch ", symbols[i]), rescuePatches[i]);
            AddressesJson.record(string.concat(".deployed.rescuePatches.", symbols[i]), rescuePatches[i]);
        }
    }
}
