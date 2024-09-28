// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../src/dynamic-fee/DynamicFeeAdjustmentHook.sol";

contract TestDynamicFeeAdjustmentHook is DynamicFeeAdjustmentHook {
    constructor(
        ICLPoolManager _poolManager,
        IBrevisProof _brevisProof
    ) DynamicFeeAdjustmentHook(_poolManager, _brevisProof) {}

    function testHandleProofResult(
        bytes32 _vkHash,
        bytes calldata _circuitOutput
    ) external {
        handleProofResult(_vkHash, _circuitOutput);
    }
}
