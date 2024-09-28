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
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BrevisApp} from "../lib/BrevisApp.sol";
import {IBrevisProof} from "../interface/IBrevisProof.sol";

contract DynamicFeeAdjustmentHook is CLBaseHook, BrevisApp, Ownable {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

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

    constructor(
        ICLPoolManager _poolManager,
        IBrevisProof _brevisProof
    )
        CLBaseHook(_poolManager)
        BrevisApp(address(_brevisProof))
        Ownable(msg.sender)
    {}

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
                    beforeAddLiquidity: true,
                    afterAddLiquidity: true,
                    beforeRemoveLiquidity: true,
                    afterRemoveLiquidity: true,
                    beforeSwap: true,
                    afterSwap: true,
                    beforeDonate: false,
                    afterDonate: false,
                    beforeSwapReturnsDelta: false,
                    afterSwapReturnsDelta: false,
                    afterAddLiquidityReturnsDelta: true,
                    afterRemoveLiquidityReturnsDelta: true
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
        ICLPoolManager.SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4, int128) {
        PoolId poolId = key.toId();
        PoolData storage poolData = poolDataMap[poolId];

        poolData.cumulativeVolume += uint256(uint128(-delta.amount0()));
        poolData.token0Balance += uint256(uint128(-delta.amount0()));
        poolData.token1Balance += uint256(uint128(-delta.amount1()));

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

        updateImpermanentLoss(poolId);

        if (block.timestamp >= poolData.lastUpdateTimestamp + UPDATE_INTERVAL) {
            updateHistoricalData(poolId);
        }

        uint256 volatility = calculateVolatility(poolData);
        emit PoolDataUpdated(
            poolId,
            poolData.cumulativeVolume,
            poolData.token0Balance,
            poolData.token1Balance,
            volatility,
            poolData.totalLiquidity,
            poolData.impermanentLoss
        );

        return (ICLHooks.afterSwap.selector, 0);
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4) {
        PoolId poolId = key.toId();
        PoolData storage poolData = poolDataMap[poolId];
        if (params.liquidityDelta > 0) {
            poolData.totalLiquidity += uint256(
                uint128(uint256(params.liquidityDelta))
            );
        }
        return ICLHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4, BalanceDelta) {
        updateImpermanentLoss(key.toId());
        return (ICLHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4) {
        PoolId poolId = key.toId();
        PoolData storage poolData = poolDataMap[poolId];

        if (params.liquidityDelta < 0) {
            uint256 liquidityToRemove = uint256(-params.liquidityDelta);
            if (liquidityToRemove <= poolData.totalLiquidity) {
                poolData.totalLiquidity -= liquidityToRemove;
            } else {
                poolData.totalLiquidity = 0;
            }
        }

        return ICLHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4, BalanceDelta) {
        updateImpermanentLoss(key.toId());
        return (ICLHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
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
        uint256 currentPrice = (poolData.token1Balance * 1e18) /
            poolData.token0Balance;
        uint256 initialPrice = poolData.historicalVolumes[
            HISTORICAL_DATA_POINTS - 1
        ] > 0
            ? (poolData.historicalLiquidities[HISTORICAL_DATA_POINTS - 1] *
                1e18) / poolData.historicalVolumes[HISTORICAL_DATA_POINTS - 1]
            : currentPrice;

        uint256 priceRatio = (currentPrice * 1e18) / initialPrice;
        uint256 sqrtPriceRatio = FixedPointMathLib.sqrt(priceRatio);

        // IL = 2 * sqrt(P_ratio) / (1 + P_ratio) - 1
        poolData.impermanentLoss =
            (2 * sqrtPriceRatio * 1e18) /
            (1e18 + priceRatio) -
            1e18;
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
}
