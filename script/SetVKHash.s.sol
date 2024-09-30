// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/dynamic-fee/DynamicFeeAdjustmentHook.sol";

contract SetVKHash is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address hookAddress = vm.envAddress("HOOK_ADDRESS");
        bytes32 vkHash = vm.envBytes32("VK_HASH");

        vm.startBroadcast(deployerPrivateKey);

        DynamicFeeAdjustmentHook hook = DynamicFeeAdjustmentHook(hookAddress);
        hook.setVkHash(vkHash);

        vm.stopBroadcast();

        console.log("VK hash set for hook at:", hookAddress);
    }
}
