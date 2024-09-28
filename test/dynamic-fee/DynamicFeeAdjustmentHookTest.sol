// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./TestDynamicFeeAdjustmentHook.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {Vault} from "pancake-v4-core/src/Vault.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolManager} from "pancake-v4-core/src/pool-cl/CLPoolManager.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {SortTokens} from "pancake-v4-core/test/helpers/SortTokens.sol";
import {Deployers} from "pancake-v4-core/test/pool-cl/helpers/Deployers.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {ICLPositionManager} from "pancake-v4-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";
import {MockCLPositionManager} from "../helpers/MockCLPositionManager.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {MockCLSwapRouter} from "../helpers/MockCLSwapRouter.sol";
import {IV4Router} from "pancake-v4-periphery/src/interfaces/IV4Router.sol";
import {ICLRouterBase} from "pancake-v4-periphery/src/pool-cl/interfaces/ICLRouterBase.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract DynamicFeeAdjustmentHookTest is Test, Deployers, DeployPermit2 {
    using PoolIdLibrary for PoolKey;

    IVault vault;
    ICLPoolManager poolManager;
    MockERC20 token0;
    MockERC20 token1;
    Currency currency0;
    Currency currency1;
    PoolKey poolKey;
    PoolId poolId;
    TestDynamicFeeAdjustmentHook hook;
    MockCLPositionManager positionManager;
    MockCLSwapRouter swapRouter;
    IAllowanceTransfer permit2;

    function setUp() public {
        // Deploy tokens
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);

        // Create currencies
        (currency0, currency1) = SortTokens.sort(token0, token1);

        // Create vault and pool manager
        (vault, poolManager) = createFreshManager();

        // Deploy the hook contract
        IBrevisProof brevisProof = IBrevisProof(address(0)); // Mock address

        hook = new TestDynamicFeeAdjustmentHook(poolManager, brevisProof);

        // Initialize pool key
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000, // initial fee
            hooks: hook,
            poolManager: poolManager,
            parameters: bytes32(0) // default parameters
        });

        poolId = poolKey.toId();

        // Initialize the pool with initial fees
        uint24 initialTradingFee = 500; // 0.05%
        uint24 initialLPFee = 300; // 0.03%
        bytes memory hookData = abi.encode(initialTradingFee, initialLPFee);

        poolManager.initialize(poolKey, 1 << 96, hookData); // sqrtPriceX96 = 1 << 96 represents a price of 1:1

        // Deploy Permit2 and get IAllowanceTransfer instance
        permit2 = IAllowanceTransfer(deployPermit2());

        // Provide initial liquidity using a position manager
        positionManager = new MockCLPositionManager(
            vault,
            poolManager,
            permit2
        );

        // Mint tokens to the test contract
        token0.mint(address(this), 2000 ether);
        token1.mint(address(this), 2000 ether);

        // Approve tokens
        token0.approve(address(positionManager), type(uint256).max);
        token1.approve(address(positionManager), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);

        // Provide liquidity
        positionManager.mint(
            poolKey,
            -887220, // Min tick
            887220, // Max tick
            1000 ether,
            uint128(1000 ether),
            uint128(1000 ether),
            address(this),
            bytes("")
        );

        // Deploy swap router
        swapRouter = new MockCLSwapRouter(vault, poolManager);

        // Approve tokens for swap router
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
    }

    function testDynamicFeeAdjustmentWithSwaps() public {
        // Perform swaps to simulate trading activity

        // Swap token0 for token1
        uint256 amountIn = 100 ether;
        IERC20(address(token0)).approve(address(swapRouter), amountIn);

        IV4Router.CLSwapExactInputSingleParams memory params = ICLRouterBase
            .CLSwapExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: true,
                amountIn: uint128(amountIn),
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0,
                hookData: bytes("")
            });

        swapRouter.exactInputSingle(params, block.timestamp + 1);

        // Advance time to trigger update interval
        vm.warp(block.timestamp + 1 hours + 1);

        // Set vkHash
        bytes32 vkHash = keccak256("test_vk");
        hook.setVkHash(vkHash);

        // Construct circuitOutput
        uint24 newTradingFee = 600; // 0.06%
        uint24 newLPFee = 400; // 0.04%

        bytes memory circuitOutput = abi.encodePacked(
            PoolId.unwrap(poolId),
            bytes3(uint24(newTradingFee)),
            bytes3(uint24(newLPFee))
        );

        // Call handleProofResult via testHandleProofResult
        hook.testHandleProofResult(vkHash, circuitOutput);

        // Verify that fees have been updated
        (
            ,
            ,
            uint24 currentTradingFee,
            uint24 currentLPFee,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,

        ) = hook.getPoolData(poolId);

        assertEq(currentTradingFee, newTradingFee, "Trading fee not updated");
        assertEq(currentLPFee, newLPFee, "LP fee not updated");

        // Verify that cumulativeVolume has been updated
        (uint256 cumulativeVolume, , , , , , , , , , , , ) = hook.getPoolData(
            poolId
        );

        assertGt(cumulativeVolume, 0, "Cumulative volume not updated");
    }

    function testDynamicFeeAdjustmentWithSwapsAndVolatility() public {
        // Perform swaps to simulate trading activity and price changes

        // Swap token0 for token1
        uint256 amountIn = 100 ether;
        IERC20(address(token0)).approve(address(swapRouter), amountIn);

        IV4Router.CLSwapExactInputSingleParams memory params1 = ICLRouterBase
            .CLSwapExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: true,
                amountIn: uint128(amountIn),
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0,
                hookData: bytes("")
            });

        swapRouter.exactInputSingle(params1, block.timestamp + 1);

        // Swap token1 for token0
        uint256 amountIn2 = 50 ether;
        IERC20(address(token1)).approve(address(swapRouter), amountIn2);

        IV4Router.CLSwapExactInputSingleParams memory params2 = ICLRouterBase
            .CLSwapExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: false,
                amountIn: uint128(amountIn2),
                amountOutMinimum: 0,
                sqrtPriceLimitX96: type(uint160).max,
                hookData: bytes("")
            });

        swapRouter.exactInputSingle(params2, block.timestamp + 1);

        // Advance time to trigger update interval
        vm.warp(block.timestamp + 1 hours + 1);

        // Set vkHash
        bytes32 vkHash = keccak256("test_vk");
        hook.setVkHash(vkHash);

        // Construct circuitOutput
        uint24 newTradingFee = 700; // 0.07%
        uint24 newLPFee = 500; // 0.05%

        bytes memory circuitOutput = abi.encodePacked(
            PoolId.unwrap(poolId),
            bytes3(uint24(newTradingFee)),
            bytes3(uint24(newLPFee))
        );

        // Call handleProofResult via testHandleProofResult
        hook.testHandleProofResult(vkHash, circuitOutput);

        // Verify that fees have been updated
        (
            ,
            ,
            uint24 currentTradingFee,
            uint24 currentLPFee,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,

        ) = hook.getPoolData(poolId);

        assertEq(currentTradingFee, newTradingFee, "Trading fee not updated");
        assertEq(currentLPFee, newLPFee, "LP fee not updated");

        // Verify that cumulativeVolume has been updated
        (uint256 cumulativeVolume, , , , , , , , , , , , ) = hook.getPoolData(
            poolId
        );

        assertGt(cumulativeVolume, 0, "Cumulative volume not updated");

        // Verify that volatility has been updated
        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            uint256[30] memory historicalVolatilities,
            ,
            ,
            ,

        ) = hook.getPoolData(poolId);

        // Since we performed swaps that change price, volatility should be > 0
        bool volatilityUpdated = false;
        for (uint256 i = 0; i < historicalVolatilities.length; i++) {
            if (historicalVolatilities[i] > 0) {
                volatilityUpdated = true;
                break;
            }
        }

        assertTrue(volatilityUpdated, "Volatility not updated");
    }

    function testDynamicFeeAdjustmentWithLiquidityAndImpermanentLoss() public {
        // Add more liquidity
        positionManager.mint(
            poolKey,
            -887220,
            887220,
            500 ether,
            uint128(500 ether),
            uint128(500 ether),
            address(this),
            bytes("")
        );

        // Remove some liquidity
        // Assuming the tokenId is 1 (the first minted position)
        positionManager.decreaseLiquidity(
            1, // tokenId
            poolKey,
            200 ether,
            uint128(0),
            uint128(0),
            bytes("")
        );

        // Perform a swap to change price
        uint256 amountIn = 100 ether;
        IERC20(address(token0)).approve(address(swapRouter), amountIn);

        IV4Router.CLSwapExactInputSingleParams memory params = ICLRouterBase
            .CLSwapExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: true,
                amountIn: uint128(amountIn),
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0,
                hookData: bytes("")
            });

        swapRouter.exactInputSingle(params, block.timestamp + 1);

        // Advance time to trigger update interval
        vm.warp(block.timestamp + 1 hours + 1);

        // Set vkHash
        bytes32 vkHash = keccak256("test_vk");
        hook.setVkHash(vkHash);

        // Construct circuitOutput
        uint24 newTradingFee = 800; // 0.08%
        uint24 newLPFee = 600; // 0.06%

        bytes memory circuitOutput = abi.encodePacked(
            PoolId.unwrap(poolId),
            bytes3(uint24(newTradingFee)),
            bytes3(uint24(newLPFee))
        );

        // Call handleProofResult via testHandleProofResult
        hook.testHandleProofResult(vkHash, circuitOutput);

        // Verify that fees have been updated
        (
            ,
            ,
            uint24 currentTradingFee,
            uint24 currentLPFee,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,

        ) = hook.getPoolData(poolId);

        assertEq(currentTradingFee, newTradingFee, "Trading fee not updated");
        assertEq(currentLPFee, newLPFee, "LP fee not updated");

        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            uint256 impermanentLoss,
            uint256[30] memory historicalImpermanentLosses
        ) = hook.getPoolData(poolId);

        // Since we performed swaps and liquidity changes, impermanent loss should be > 0
        assertGt(impermanentLoss, 0, "Impermanent loss not updated");

        bool impermanentLossUpdated = false;
        for (uint256 i = 0; i < historicalImpermanentLosses.length; i++) {
            if (historicalImpermanentLosses[i] > 0) {
                impermanentLossUpdated = true;
                break;
            }
        }

        assertTrue(
            impermanentLossUpdated,
            "Historical impermanent loss not updated"
        );
    }

    function testHistoricalDataUpdate() public {
        // Simulate multiple intervals
        for (uint256 i = 0; i < 35; i++) {
            // Perform a swap each interval
            uint256 amountIn = 10 ether;
            IERC20(address(token0)).approve(address(swapRouter), amountIn);

            IV4Router.CLSwapExactInputSingleParams memory params = ICLRouterBase
                .CLSwapExactInputSingleParams({
                    poolKey: poolKey,
                    zeroForOne: true,
                    amountIn: uint128(amountIn),
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0,
                    hookData: bytes("")
                });

            swapRouter.exactInputSingle(params, block.timestamp + 1);

            // Advance time to trigger update interval
            // vm.warp(block.timestamp + UPDATE_INTERVAL + 1);

            // Call updateHistoricalData via handleProofResult
            bytes32 vkHash = keccak256("test_vk");
            hook.setVkHash(vkHash);

            // Construct circuitOutput
            uint24 newTradingFee = 500 + uint24(i * 10);
            uint24 newLPFee = 300 + uint24(i * 5);

            bytes memory circuitOutput = abi.encodePacked(
                PoolId.unwrap(poolId),
                bytes3(uint24(newTradingFee)),
                bytes3(uint24(newLPFee))
            );

            hook.testHandleProofResult(vkHash, circuitOutput);
        }

        // Verify that historical data arrays have been updated correctly
        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            uint256[30] memory historicalVolumes,
            uint256[30] memory historicalVolatilities,
            ,
            uint256[30] memory historicalLiquidities,
            ,
            uint256[30] memory historicalImpermanentLosses
        ) = hook.getPoolData(poolId);

        // Check that the arrays are filled with data
        for (uint256 i = 0; i < historicalVolumes.length; i++) {
            assertGt(historicalVolumes[i], 0, "Historical volume not updated");
            assertGt(
                historicalVolatilities[i],
                0,
                "Historical volatility not updated"
            );
            assertGt(
                historicalLiquidities[i],
                0,
                "Historical liquidity not updated"
            );
            assertGt(
                historicalImpermanentLosses[i],
                0,
                "Historical impermanent loss not updated"
            );
        }
    }
}
