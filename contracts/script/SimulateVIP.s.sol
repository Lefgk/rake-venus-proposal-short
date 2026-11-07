// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Script.sol";
import "./libraries/RescueContractsDeployment.sol";
import "./libraries/VenusRescueProposalCommands.sol";

interface IVTokenSim {
    function balanceOf(address) external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
    function underlying() external view returns (address);
}

interface IERC20Sim {
    function balanceOf(address) external view returns (uint256);
}

/// The whole rescue on a BSC fork, for anyone (Venus included) to run. Sends nothing, needs no key
/// and no addresses.json: it deploys the claim contract and the seven rescue patches on the fork,
/// sends every proposal command from the Venus Normal Timelock exactly as Timelock.executeTransaction
/// would, then prints what moved and saves the propose() arrays to out/vip-proposal.json.
///
///   forge script script/SimulateVIP.s.sol --fork-url $BSC_RPC_URL
///   INCLUDE_XVS_GRANT=true forge script script/SimulateVIP.s.sol --fork-url $BSC_RPC_URL
contract SimulateVIP is Script {
    using VenusRescueProposalCommands for VenusRescueProposalCommands.Command;

    function run() external {
        address[7] memory markets = RakeFrozenPositions.vTokens();
        string[7] memory symbols = RakeFrozenPositions.symbols();
        address treasury = RakeFrozenPositions.VENUS_TREASURY;
        console.log(string.concat("BSC block ", vm.toString(block.number), " (fork, nothing is sent)"));

        RakeDepositorsClaim claim = RescueContractsDeployment.deployClaim();
        address[7] memory patches = RescueContractsDeployment.deployRescuePatches(address(claim));

        uint256[7] memory t0;
        for (uint256 i; i < 7; ++i) t0[i] = IVTokenSim(markets[i]).balanceOf(treasury);

        VenusRescueProposalCommands.Command[] memory c =
            VenusRescueProposalCommands.build(address(claim), patches, vm.envOr("INCLUDE_XVS_GRANT", false));
        console.log(string.concat("Running the VIP: ", vm.toString(c.length), " commands, sent by the Venus Timelock"));
        console.log("");
        uint256 gasTotal = _send(c, 0, VenusRescueProposalCommands.XVS_SETTLE_COMMANDS, "XVS settle");
        uint256 k = VenusRescueProposalCommands.XVS_SETTLE_COMMANDS;
        for (uint256 i; i < 7; ++i) {
            gasTotal += _send(c, k, 4, string.concat("v", symbols[i], " rescue"));
            k += 4;
        }
        gasTotal += _send(c, k, c.length - k, "open claim");
        console.log(string.concat("  total gas  ", _thousands(gasTotal), "  (block limit 70,000,000)"));

        console.log("");
        console.log("Where the funds go (tokens):");
        console.log("            Venus 20%      cost 10%       depositors 70%");
        for (uint256 i; i < 7; ++i) {
            IVTokenSim v = IVTokenSim(markets[i]);
            address u = v.underlying();
            uint256 toVenus = (v.balanceOf(treasury) - t0[i]) * v.exchangeRateStored() / 1e18;
            console.log(string.concat(
                "  ", _pad(symbols[i], 8),
                _pad(_dec(toVenus), 15),
                _pad(_dec(IERC20Sim(u).balanceOf(claim.FEE_RECIPIENT())), 15),
                _dec(claim.pool(u))
            ));
        }
        console.log("");
        console.log(string.concat("Claim window: open, 90 days, closes at unix ", vm.toString(claim.deadline())));

        address[] memory targets = new address[](c.length);
        uint256[] memory values = new uint256[](c.length);
        string[] memory signatures = new string[](c.length);
        bytes[] memory calldatas = new bytes[](c.length);
        for (uint256 i; i < c.length; ++i) {
            (targets[i], signatures[i], calldatas[i]) = (c[i].target, c[i].signature, c[i].params);
        }
        vm.serializeAddress("proposal", "targets", targets);
        vm.serializeUint("proposal", "values", values);
        vm.serializeString("proposal", "signatures", signatures);
        vm.writeJson(vm.serializeBytes("proposal", "calldatas", calldatas), "out/vip-proposal.json");
        console.log("propose() arrays saved to contracts/out/vip-proposal.json");
    }

    /// Sends `n` commands from `from` as the Timelock; prints one line for the group.
    function _send(VenusRescueProposalCommands.Command[] memory c, uint256 from, uint256 n, string memory label)
        internal
        returns (uint256 gasUsed)
    {
        for (uint256 i = from; i < from + n; ++i) {
            uint256 g = gasleft();
            vm.prank(RakeFrozenPositions.VENUS_NORMAL_TIMELOCK);
            (bool ok, bytes memory ret) = c[i].target.call(c[i].callData());
            gasUsed += g - gasleft();
            if (!ok) {
                console.log(string.concat("  FAIL  ", label, "  at command ", vm.toString(i), " ", c[i].signature));
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
        console.log(string.concat("  OK  ", _pad(label, 16), _pad(string.concat(vm.toString(n), " cmds"), 9), "gas ", _thousands(gasUsed)));
    }

    function _pad(string memory s, uint256 w) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        if (b.length >= w) return string.concat(s, " ");
        bytes memory sp = new bytes(w - b.length);
        for (uint256 i; i < sp.length; ++i) sp[i] = " ";
        return string.concat(s, string(sp));
    }

    function _thousands(uint256 x) internal pure returns (string memory s) {
        if (x < 1000) return vm.toString(x);
        uint256 r = x % 1000;
        return string.concat(_thousands(x / 1000), ",", r < 10 ? "00" : r < 100 ? "0" : "", vm.toString(r));
    }

    /// 18-decimal fixed point to "1234.5678".
    function _dec(uint256 x) internal pure returns (string memory) {
        uint256 frac = x / 1e14 % 1e4;
        string memory pad = frac < 10 ? "000" : frac < 100 ? "00" : frac < 1000 ? "0" : "";
        return string.concat(vm.toString(x / 1e18), ".", pad, vm.toString(frac));
    }
}
