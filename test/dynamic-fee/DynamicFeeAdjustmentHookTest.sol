// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/dynamic-fee/DynamicFeeAdjustmentHook.sol";
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
import {MockCLPositionManager} from "../helpers/MockCLPositionManager.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {MockCLSwapRouter} from "../helpers/MockCLSwapRouter.sol";
import {IV4Router} from "pancake-v4-periphery/src/interfaces/IV4Router.sol";
import {ICLRouterBase} from "pancake-v4-periphery/src/pool-cl/interfaces/ICLRouterBase.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {CLPoolParametersHelper} from "pancake-v4-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";

contract DynamicFeeAdjustmentHookTest is Test, Deployers, DeployPermit2 {
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;

    IVault vault;
    ICLPoolManager poolManager;
    MockERC20 token0;
    MockERC20 token1;
    Currency currency0;
    Currency currency1;
    PoolKey poolKey;
    PoolId poolId;
    DynamicFeeAdjustmentHook hook;
    MockCLPositionManager positionManager;
    MockCLSwapRouter swapRouter;
    IAllowanceTransfer permit2;
    address mockBrevisRequest;

    function setUp() public {
        (vault, poolManager) = createFreshManager();

        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        (currency0, currency1) = SortTokens.sort(token0, token1);

        mockBrevisRequest = address(0xbeef);
        hook = new DynamicFeeAdjustmentHook(poolManager, mockBrevisRequest);

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            hooks: hook,
            poolManager: poolManager,
            parameters: bytes32(uint256(hook.getHooksRegistrationBitmap()))
                .setTickSpacing(60)
        });

        poolId = poolKey.toId();

        uint24 initialTradingFee = 500;
        uint24 initialLPFee = 300;
        bytes memory hookData = abi.encode(initialTradingFee, initialLPFee);

        // Use the helper function to initialize the pool
        initializePoolWithHook(poolKey, SQRT_RATIO_1_1, hookData);

        permit2 = IAllowanceTransfer(deployPermit2());

        positionManager = new MockCLPositionManager(
            vault,
            poolManager,
            permit2
        );

        token0.mint(address(this), 2000 ether);
        token1.mint(address(this), 2000 ether);

        token0.approve(address(positionManager), type(uint256).max);
        token1.approve(address(positionManager), type(uint256).max);

        swapRouter = new MockCLSwapRouter(vault, poolManager);

        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);

        // Approve tokens for Permit2
        token0.approve(address(permit2), type(uint256).max);
        token1.approve(address(permit2), type(uint256).max);

        // Set allowance for Permit2
        permit2.approve(
            address(token0),
            address(positionManager),
            type(uint160).max,
            uint48(block.timestamp + 1 days)
        );
        permit2.approve(
            address(token1),
            address(positionManager),
            type(uint160).max,
            uint48(block.timestamp + 1 days)
        );

        positionManager.mint(
            poolKey,
            -887220,
            887220,
            1000 ether,
            uint128(1000 ether),
            uint128(1000 ether),
            address(this),
            bytes("")
        );
    }

    // Helper function to initialize the pool
    function initializePoolWithHook(
        PoolKey memory key,
        uint160 sqrtPriceX96,
        bytes memory hookData
    ) internal {
        vm.startPrank(address(poolManager));
        poolManager.initialize(key, sqrtPriceX96, hookData);
        vm.stopPrank();
    }

    function testDynamicFeeAdjustmentWithSwaps() public {
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

        vm.warp(block.timestamp + 1 hours + 1);

        bytes32 vkHash = keccak256("test_vk");
        hook.setVkHash(vkHash);

        uint24 newTradingFee = 600;
        uint24 newLPFee = 400;

        bytes memory circuitOutput = abi.encodePacked(
            PoolId.unwrap(poolId),
            bytes3(uint24(newTradingFee)),
            bytes3(uint24(newLPFee))
        );

        vm.prank(mockBrevisRequest);
        hook.brevisCallback(vkHash, circuitOutput);

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

        (uint256 cumulativeVolume, , , , , , , , , , , , ) = hook.getPoolData(
            poolId
        );

        assertGt(cumulativeVolume, 0, "Cumulative volume not updated");
    }

    function testInitialFees() public {
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

        assertEq(
            currentTradingFee,
            500,
            "Initial trading fee not set correctly"
        );
        assertEq(currentLPFee, 300, "Initial LP fee not set correctly");
    }

    function testVkHashUpdate() public {
        bytes32 newVkHash = keccak256("new_test_vk");
        hook.setVkHash(newVkHash);
        assertEq(hook.vkHash(), newVkHash, "VK hash not updated correctly");
    }

    function testUnauthorizedProofSubmission() public {
        bytes32 vkHash = keccak256("test_vk");
        hook.setVkHash(vkHash);

        bytes memory circuitOutput = abi.encodePacked(
            PoolId.unwrap(poolId),
            bytes3(uint24(600)),
            bytes3(uint24(400))
        );

        vm.prank(address(0xdead));
        vm.expectRevert("invalid caller");
        hook.brevisCallback(vkHash, circuitOutput);
    }
}
