// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/dynamic-fee/DynamicFeeAdjustmentHook.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolManager} from "pancake-v4-core/src/pool-cl/CLPoolManager.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {CLPoolParametersHelper} from "pancake-v4-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeployDynamicFeeAdjustmentHook is Script {
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Use CLPoolManager on BSC testnet
        address poolManagerAddress = 0x969D90aC74A1a5228b66440f8C8326a8dA47A5F9;
        ICLPoolManager poolManager = ICLPoolManager(poolManagerAddress);

        // Use existing tokens on BSC testnet
        address token0Address = 0x1111111111111111111111111111111111111111;
        address token1Address = 0x2222222222222222222222222222222222222222;

        // Sort tokens
        (Currency currency0, Currency currency1) = address(token0Address) <
            address(token1Address)
            ? (Currency.wrap(token0Address), Currency.wrap(token1Address))
            : (Currency.wrap(token1Address), Currency.wrap(token0Address));

        address brevisRequest = 0xF7E9CB6b7A157c14BCB6E6bcf63c1C7c92E952f5;

        // Deploy DynamicFeeAdjustmentHook
        DynamicFeeAdjustmentHook hook = new DynamicFeeAdjustmentHook(
            poolManager,
            brevisRequest
        );

        // Create a PoolKey
        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000, // 0.3% fee
            hooks: hook,
            poolManager: poolManager,
            parameters: bytes32(uint256(hook.getHooksRegistrationBitmap()))
                .setTickSpacing(60)
        });

        // Initialize the pool
        uint160 sqrtPriceX96 = 79228162514264337593543950336; // 1:1 price
        uint24 initialTradingFee = 500; // 0.05%
        uint24 initialLPFee = 2500; // 0.25%
        bytes memory hookData = abi.encode(initialTradingFee, initialLPFee);

        poolManager.initialize(poolKey, sqrtPriceX96, hookData);

        // Get the PoolId
        PoolId poolId = poolKey.toId();

        vm.stopBroadcast();

        console.log("DynamicFeeAdjustmentHook deployed at:", address(hook));
        console.log("Pool ID:", vm.toString(PoolId.unwrap(poolId)));
    }
}
