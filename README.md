# SuperFluidSwapper Contracts

Smart contracts for the SuperFluidSwapper project, integrating PancakeSwap v4 hooks with Brevis Network's ZK coprocessor.

## Key Components

- `DynamicFeeAdjustmentHook.sol`: Core contract implementing dynamic fee adjustment logic
- `DynamicFeeAdjustmentHookTest.sol`: Comprehensive test suite for the hook
- Historical data tracking for volumes, volatilities, and impermanent losses
- Integration with Brevis for ZK proof verification

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)

## Quick Start

1. Clone the repository:

   ```
   git clone https://github.com/aryan877/hookathon-contracts.git
   cd hookathon-contracts
   ```

2. Install dependencies:

   ```
   forge install
   ```

3. Set up `.env` file (see `.env.example`)

4. Run tests:
   ```
   forge test
   ```

## Scripts

- `DeployDynamicFeeAdjustmentHook.s.sol`: Deploys the DynamicFeeAdjustmentHook and initializes a pool

  ```
  forge script script/DeployDynamicFeeAdjustmentHook.s.sol:DeployDynamicFeeAdjustmentHook --rpc-url $BSC_TESTNET_RPC_URL --broadcast --verify -vvvv
  ```

- `SetVKHash.s.sol`: Sets the VK hash for the deployed hook
  ```
  forge script script/SetVKHash.s.sol:SetVKHash --rpc-url $BSC_TESTNET_RPC_URL --broadcast -vvvv
  ```

## Environment Variables

Create a `.env` file with the following variables:

- `PRIVATE_KEY`: Your deployment wallet's private key
- `BSC_TESTNET_RPC_URL`: BSC testnet RPC URL
- `ETHERSCAN_API_KEY`: API key for contract verification
- `VK_HASH`: Verification key hash for the ZK proof system
- `HOOK_ADDRESS`: Address of the deployed DynamicFeeAdjustmentHook (after deployment)

## Foundry Commands

- `forge build`: Compile contracts
- `forge test`: Run all tests
- `forge coverage`: Generate test coverage report
- `forge fmt`: Format Solidity code
- `forge script`: Run deployment scripts

## Configuration

See `foundry.toml` for Foundry configuration settings, including:

- Solidity version (0.8.26)
- EVM version (Cancun)
- Optimization settings

## Key Contracts

- `DynamicFeeAdjustmentHook.sol`: Implements the dynamic fee adjustment logic
- `DynamicFeeAdjustmentHookTest.sol`: Contains unit and integration tests
- `DeployDynamicFeeAdjustmentHook.s.sol`: Deployment script
- `SetVKHash.s.sol`: Script to set the verification key hash

## Testing

Run the test suite with:

```
forge test
```

For verbose output:

```
forge test -vvv
```

## Deployment

1. Set up your `.env` file
2. Run the deployment script:
   ```
   forge script script/DeployDynamicFeeAdjustmentHook.s.sol:DeployDynamicFeeAdjustmentHook --rpc-url $BSC_TESTNET_RPC_URL --broadcast --verify -vvvv
   ```
3. Set the VK hash:
   ```
   forge script script/SetVKHash.s.sol:SetVKHash --rpc-url $BSC_TESTNET_RPC_URL --broadcast -vvvv
   ```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for details on our code of conduct and the process for submitting pull requests.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file
