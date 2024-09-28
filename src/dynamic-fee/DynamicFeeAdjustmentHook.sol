// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {CLBaseHook} from "../CLBaseHook.sol";
import {ICLHooks} from "pancake-v4-core/src/pool-cl/interfaces/ICLHooks.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {LPFeeLibrary} from "pancake-v4-core/src/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "pancake-v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BrevisApp} from "../lib/BrevisApp.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract DynamicFeeAdjustmentHook is CLBaseHook, BrevisApp, Ownable {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    struct PoolData {
        uint256 cumulativeVolume;
        uint256 lastUpdateTimestamp;
        uint24 currentTradingFee;
        uint24 currentLPFee;
        uint256 token0Balance;
        uint256 token1Balance;
        uint256 lastPrice;
        uint256 volatilityAccumulator;
        uint256 updateCount;
        uint256[30] historicalVolumes;
        uint256[30] historicalVolatilities;
        uint256 totalLiquidity;
        uint256[30] historicalLiquidities;
        uint256 impermanentLoss;
        uint256[30] historicalImpermanentLosses;
    }

    mapping(PoolId => PoolData) public poolDataMap;
    bytes32 public vkHash;

    uint256 public constant HISTORICAL_DATA_POINTS = 30;
    uint256 public constant UPDATE_INTERVAL = 1 hours;

    event FeesUpdated(
        PoolId indexed poolId,
        uint24 newTradingFee,
        uint24 newLPFee
    );
    event PoolDataUpdated(
        PoolId indexed poolId,
        uint256 cumulativeVolume,
        uint256 token0Balance,
        uint256 token1Balance,
        uint256 volatility,
        uint256 totalLiquidity,
        uint256 impermanentLoss
    );

    struct CallbackData {
        address sender;
        PoolKey key;
        ICLPoolManager.SwapParams swapParams;
        ICLPoolManager.ModifyLiquidityParams modifyLiquidityParams;
        BalanceDelta delta;
    }

    constructor(
        ICLPoolManager _poolManager,
        address _brevisRequest
    ) CLBaseHook(_poolManager) BrevisApp(_brevisRequest) Ownable(msg.sender) {}

    function getHooksRegistrationBitmap()
        external
        pure
        override
        returns (uint16)
    {
        return
            _hooksRegistrationBitmapFrom(
                Permissions({
                    beforeInitialize: false,
                    afterInitialize: true,
                    beforeAddLiquidity: false,
                    afterAddLiquidity: true,
                    beforeRemoveLiquidity: false,
                    afterRemoveLiquidity: true,
                    beforeSwap: true,
                    afterSwap: true,
                    beforeDonate: false,
                    afterDonate: false,
                    beforeSwapReturnsDelta: false,
                    afterSwapReturnsDelta: false,
                    afterAddLiquidityReturnsDelta: false,
                    afterRemoveLiquidityReturnsDelta: false
                })
            );
    }

    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24,
        bytes calldata hookData
    ) external override poolManagerOnly returns (bytes4) {
        PoolId poolId = key.toId();
        (uint24 initialTradingFee, uint24 initialLPFee) = abi.decode(
            hookData,
            (uint24, uint24)
        );

        PoolData storage newPoolData = poolDataMap[poolId];
        newPoolData.cumulativeVolume = 0;
        newPoolData.lastUpdateTimestamp = block.timestamp;
        newPoolData.currentTradingFee = initialTradingFee;
        newPoolData.currentLPFee = initialLPFee;
        newPoolData.token0Balance = 0;
        newPoolData.token1Balance = 0;
        newPoolData.lastPrice = 0;
        newPoolData.volatilityAccumulator = 0;
        newPoolData.updateCount = 0;
        newPoolData.totalLiquidity = 0;
        newPoolData.impermanentLoss = 0;

        for (uint256 i = 0; i < HISTORICAL_DATA_POINTS; i++) {
            newPoolData.historicalVolumes[i] = 0;
            newPoolData.historicalVolatilities[i] = 0;
            newPoolData.historicalLiquidities[i] = 0;
            newPoolData.historicalImpermanentLosses[i] = 0;
        }

        return ICLHooks.afterInitialize.selector;
    }

    function beforeSwap(
        address,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata,
        bytes calldata
    )
        external
        view
        override
        poolManagerOnly
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        PoolData storage poolData = poolDataMap[poolId];
        uint24 totalFee = poolData.currentTradingFee + poolData.currentLPFee;
        return (
            ICLHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            totalFee | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4, int128) {
        PoolId poolId = key.toId();
        PoolData storage poolData = poolDataMap[poolId];

        updatePoolData(poolData, delta);

        // Calculate fee
        uint256 totalFee = poolData.currentTradingFee + poolData.currentLPFee;
        int128 feeAmount;
        if (params.zeroForOne) {
            // Token0 is being swapped for Token1
            feeAmount = int128(
                int256((uint256(uint128(-delta.amount0())) * totalFee) / 1e6)
            );
        } else {
            // Token1 is being swapped for Token0
            feeAmount = int128(
                int256((uint256(uint128(-delta.amount1())) * totalFee) / 1e6)
            );
        }

        // Update historical data
        if (block.timestamp >= poolData.lastUpdateTimestamp + UPDATE_INTERVAL) {
            updateHistoricalData(poolId);
        }

        emit PoolDataUpdated(
            poolId,
            poolData.cumulativeVolume,
            poolData.token0Balance,
            poolData.token1Balance,
            calculateVolatility(poolData),
            poolData.totalLiquidity,
            poolData.impermanentLoss
        );

        return (ICLHooks.afterSwap.selector, feeAmount);
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        PoolData storage poolData = poolDataMap[poolId];

        updatePoolData(poolData, delta);

        if (params.liquidityDelta > 0) {
            poolData.totalLiquidity += uint256(
                uint128(uint256(params.liquidityDelta))
            );
        } else {
            uint256 liquidityToRemove;
            if (params.liquidityDelta < 0) {
                liquidityToRemove = uint256(-params.liquidityDelta);
            } else {
                liquidityToRemove = 0;
            }
            if (liquidityToRemove > poolData.totalLiquidity) {
                poolData.totalLiquidity = 0;
            } else {
                poolData.totalLiquidity -= liquidityToRemove;
            }
        }
        updateImpermanentLoss(poolId);

        // Update historical data if necessary
        if (block.timestamp >= poolData.lastUpdateTimestamp + UPDATE_INTERVAL) {
            updateHistoricalData(poolId);
        }

        emit PoolDataUpdated(
            poolId,
            poolData.cumulativeVolume,
            poolData.token0Balance,
            poolData.token1Balance,
            calculateVolatility(poolData),
            poolData.totalLiquidity,
            poolData.impermanentLoss
        );

        return (ICLHooks.afterAddLiquidity.selector, delta);
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        PoolData storage poolData = poolDataMap[poolId];

        updatePoolData(poolData, delta);

        uint256 liquidityToRemove = uint256(-params.liquidityDelta);
        if (liquidityToRemove <= poolData.totalLiquidity) {
            poolData.totalLiquidity -= liquidityToRemove;
        } else {
            poolData.totalLiquidity = 0;
        }
        updateImpermanentLoss(poolId);

        // Update historical data
        if (block.timestamp >= poolData.lastUpdateTimestamp + UPDATE_INTERVAL) {
            updateHistoricalData(poolId);
        }

        emit PoolDataUpdated(
            poolId,
            poolData.cumulativeVolume,
            poolData.token0Balance,
            poolData.token1Balance,
            calculateVolatility(poolData),
            poolData.totalLiquidity,
            poolData.impermanentLoss
        );

        return (ICLHooks.afterRemoveLiquidity.selector, delta);
    }

    function lockAcquired(
        bytes calldata rawData
    ) external override vaultOnly returns (bytes memory) {
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        PoolId poolId = data.key.toId();
        PoolData storage poolData = poolDataMap[poolId];

        // Update pool data
        updatePoolData(poolData, data.delta);

        int128 feeAmount = 0;

        if (data.swapParams.amountSpecified != 0) {
            // This is a swap operation
            uint256 totalFee = poolData.currentTradingFee +
                poolData.currentLPFee;
            if (data.swapParams.zeroForOne) {
                // Token0 is being swapped for Token1
                feeAmount = int128(
                    int256(
                        (uint256(uint128(-data.delta.amount0())) * totalFee) /
                            1e6
                    )
                );
            } else {
                // Token1 is being swapped for Token0
                feeAmount = int128(
                    int256(
                        (uint256(uint128(-data.delta.amount1())) * totalFee) /
                            1e6
                    )
                );
            }
        } else {
            // This is a liquidity change operation
            if (data.modifyLiquidityParams.liquidityDelta > 0) {
                poolData.totalLiquidity += uint256(
                    uint128(uint256(data.modifyLiquidityParams.liquidityDelta))
                );
            } else {
                uint256 liquidityToRemove = uint256(
                    -data.modifyLiquidityParams.liquidityDelta
                );
                if (liquidityToRemove <= poolData.totalLiquidity) {
                    poolData.totalLiquidity -= liquidityToRemove;
                } else {
                    poolData.totalLiquidity = 0;
                }
            }
            updateImpermanentLoss(poolId);
        }

        // Update historical data if necessary
        if (block.timestamp >= poolData.lastUpdateTimestamp + UPDATE_INTERVAL) {
            updateHistoricalData(poolId);
        }

        emit PoolDataUpdated(
            poolId,
            poolData.cumulativeVolume,
            poolData.token0Balance,
            poolData.token1Balance,
            calculateVolatility(poolData),
            poolData.totalLiquidity,
            poolData.impermanentLoss
        );

        return abi.encode(feeAmount);
    }

    function updatePoolData(
        PoolData storage poolData,
        BalanceDelta delta
    ) internal {
        // Update token balances safely
        if (delta.amount0() >= 0) {
            poolData.token0Balance += uint256(uint128(delta.amount0()));
        } else {
            uint256 amount0ToSubtract = uint256(uint128(-delta.amount0()));
            if (amount0ToSubtract > poolData.token0Balance) {
                poolData.token0Balance = 0;
            } else {
                poolData.token0Balance -= amount0ToSubtract;
            }
        }

        if (delta.amount1() >= 0) {
            poolData.token1Balance += uint256(uint128(delta.amount1()));
        } else {
            uint256 amount1ToSubtract = uint256(uint128(-delta.amount1()));
            if (amount1ToSubtract > poolData.token1Balance) {
                poolData.token1Balance = 0;
            } else {
                poolData.token1Balance -= amount1ToSubtract;
            }
        }

        // Calculate absolute values for volume
        uint256 amount0Abs = delta.amount0() >= 0
            ? uint256(uint128(delta.amount0()))
            : uint256(uint128(-delta.amount0()));
        uint256 amount1Abs = delta.amount1() >= 0
            ? uint256(uint128(delta.amount1()))
            : uint256(uint128(-delta.amount1()));

        // Update cumulative volume (use the larger of the two amounts)
        poolData.cumulativeVolume += amount0Abs > amount1Abs
            ? amount0Abs
            : amount1Abs;

        // Update price and volatility
        updatePriceAndVolatility(poolData);
    }

    function updatePriceAndVolatility(PoolData storage poolData) internal {
        if (poolData.token0Balance == 0) return; // Avoid division by zero

        uint256 newPrice = (poolData.token1Balance * 1e18) /
            poolData.token0Balance;
        if (poolData.lastPrice > 0) {
            uint256 priceDiff = newPrice > poolData.lastPrice
                ? newPrice - poolData.lastPrice
                : poolData.lastPrice - newPrice;
            uint256 priceChange = (priceDiff * 1e18) / poolData.lastPrice;
            poolData.volatilityAccumulator += priceChange * priceChange;
            poolData.updateCount++;
        }
        poolData.lastPrice = newPrice;
    }

    function updateHistoricalData(PoolId poolId) internal {
        PoolData storage poolData = poolDataMap[poolId];

        for (uint256 i = HISTORICAL_DATA_POINTS - 1; i > 0; i--) {
            poolData.historicalVolumes[i] = poolData.historicalVolumes[i - 1];
            poolData.historicalVolatilities[i] = poolData
                .historicalVolatilities[i - 1];
            poolData.historicalLiquidities[i] = poolData.historicalLiquidities[
                i - 1
            ];
            poolData.historicalImpermanentLosses[i] = poolData
                .historicalImpermanentLosses[i - 1];
        }
        poolData.historicalVolumes[0] = poolData.cumulativeVolume;
        poolData.historicalVolatilities[0] = calculateVolatility(poolData);
        poolData.historicalLiquidities[0] = poolData.totalLiquidity;
        poolData.historicalImpermanentLosses[0] = poolData.impermanentLoss;

        poolData.cumulativeVolume = 0;
        poolData.volatilityAccumulator = 0;
        poolData.updateCount = 0;
        poolData.lastUpdateTimestamp = block.timestamp;
    }

    function calculateVolatility(
        PoolData storage poolData
    ) internal view returns (uint256) {
        if (poolData.updateCount == 0) return 0;
        return
            FixedPointMathLib.sqrt(
                poolData.volatilityAccumulator / poolData.updateCount
            );
    }

    function updateImpermanentLoss(PoolId poolId) internal {
        PoolData storage poolData = poolDataMap[poolId];

        if (poolData.token0Balance == 0) {
            poolData.impermanentLoss = 0;
            return;
        }

        uint256 currentPrice = (poolData.token1Balance * 1e18) /
            poolData.token0Balance;

        uint256 initialPrice;
        if (poolData.historicalVolumes[HISTORICAL_DATA_POINTS - 1] > 0) {
            initialPrice =
                (poolData.historicalLiquidities[HISTORICAL_DATA_POINTS - 1] *
                    1e18) /
                poolData.historicalVolumes[HISTORICAL_DATA_POINTS - 1];
        } else {
            initialPrice = currentPrice;
        }

        // Check if initialPrice is zero to avoid division by zero
        if (initialPrice == 0) {
            poolData.impermanentLoss = 0;
            return;
        }

        uint256 priceRatio = (currentPrice * 1e18) / initialPrice;
        uint256 sqrtPriceRatio = FixedPointMathLib.sqrt(priceRatio);

        // IL = 2 * sqrt(P_ratio) / (1 + P_ratio) - 1
        // Check if (1e18 + priceRatio) is zero to avoid division by zero
        if (1e18 + priceRatio == 0) {
            poolData.impermanentLoss = 0;
        } else {
            poolData.impermanentLoss =
                (2 * sqrtPriceRatio * 1e18) /
                (1e18 + priceRatio) -
                1e18;
        }
    }

    function handleProofResult(
        bytes32 _vkHash,
        bytes calldata _circuitOutput
    ) internal override {
        require(vkHash == _vkHash, "invalid vk");
        (PoolId poolId, uint24 newTradingFee, uint24 newLPFee) = decodeOutput(
            _circuitOutput
        );

        PoolData storage poolData = poolDataMap[poolId];
        poolData.currentTradingFee = newTradingFee;
        poolData.currentLPFee = newLPFee;

        emit FeesUpdated(poolId, newTradingFee, newLPFee);
    }

    function handleOpProofResult(
        bytes32 _vkHash,
        bytes calldata _circuitOutput
    ) internal override {
        handleProofResult(_vkHash, _circuitOutput);
    }

    function decodeOutput(
        bytes calldata o
    ) internal pure returns (PoolId, uint24, uint24) {
        PoolId poolId = PoolId.wrap(bytes32(o[0:32]));
        uint24 newTradingFee = uint24(bytes3(o[32:35]));
        uint24 newLPFee = uint24(bytes3(o[35:38]));
        return (poolId, newTradingFee, newLPFee);
    }

    function getPoolData(
        PoolId poolId
    )
        external
        view
        returns (
            uint256 cumulativeVolume,
            uint256 lastUpdateTimestamp,
            uint24 currentTradingFee,
            uint24 currentLPFee,
            uint256 token0Balance,
            uint256 token1Balance,
            uint256 lastPrice,
            uint256[30] memory historicalVolumes,
            uint256[30] memory historicalVolatilities,
            uint256 totalLiquidity,
            uint256[30] memory historicalLiquidities,
            uint256 impermanentLoss,
            uint256[30] memory historicalImpermanentLosses
        )
    {
        PoolData storage poolData = poolDataMap[poolId];
        return (
            poolData.cumulativeVolume,
            poolData.lastUpdateTimestamp,
            poolData.currentTradingFee,
            poolData.currentLPFee,
            poolData.token0Balance,
            poolData.token1Balance,
            poolData.lastPrice,
            poolData.historicalVolumes,
            poolData.historicalVolatilities,
            poolData.totalLiquidity,
            poolData.historicalLiquidities,
            poolData.impermanentLoss,
            poolData.historicalImpermanentLosses
        );
    }

    function setVkHash(bytes32 _vkHash) external onlyOwner {
        vkHash = _vkHash;
    }

    function setBrevisOpConfig(
        uint64 _challengeWindow,
        uint8 _sigOption
    ) external onlyOwner {
        brevisOpConfig = BrevisOpConfig(_challengeWindow, _sigOption);
    }
}
