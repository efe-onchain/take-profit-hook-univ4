// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
contract TakeProfitsHook is BaseHook, ERC1155 {
    using PoolIdLibrary for PoolKey;

    /**
     * @dev Mapping to store the last known tickLower value for a pool.
     */
    mapping(PoolId poolId => int24 tickLower) public tickLowerLasts;

    /**
     * @dev Nested mapping to store the take-profit orders placed by users.
     * The mapping structure is as follows:
     * - poolId => tickLower => zeroForOne => amount
     *
     * @notice
     * - poolId: Specifies the ID of the pool the order is for.
     * - tickLower: Specifies the tickLower value of the order, i.e., sell when the price is greater than or equal to this tick.
     * - zeroForOne: Specifies whether the order is swapping Token 0 for Token 1 (true), or vice versa (false).
     * - amount: Specifies the amount of the token being sold.
     */
    mapping(PoolId poolId => mapping(int24 tick => mapping(bool zeroForOne => int256 amount)))
        public takeProfitPositions;

    /**
     * @dev Modifier to ensure the function can only be called by the poolManager.
     */
    modifier poolManagerOnly() {
        require(
            msg.sender == address(poolManager),
            "Caller is not the pool manager"
        );
        _;
    }

    /**
     * @dev Initializes the BaseHook and ERC1155 parent contracts in the constructor.
     *
     * This constructor sets up the necessary state and configurations for the
     * TakeProfitsHook contract by calling the constructors of the BaseHook and
     * ERC1155 parent contracts.
     */
    constructor(
        IPoolManager _poolManager,
        string memory _uri
    ) BaseHook(_poolManager) ERC1155(_uri) {}

    /**
     * @notice Required override function for BaseHook to let the PoolManager know which hooks are implemented.
     */
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // Hooks
    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24 tick,
        // Add bytes calldata after tick
        bytes calldata
    ) external override poolManagerOnly returns (bytes4) {
        _setTickLowerLast(key.toId(), _getTickLower(tick, key.tickSpacing));
        return TakeProfitsHook.afterInitialize.selector;
    }

    function _setTickLowerLast(PoolId poolId, int24 tickLower) private {
        tickLowerLasts[poolId] = tickLower;
    }

    function _getTickLower(
        int24 actualTick,
        int24 tickSpacing
    ) private pure returns (int24) {
        int24 intervals = actualTick / tickSpacing;
        if (actualTick < 0 && actualTick % tickSpacing != 0) intervals--; // round towards negative infinity
        return intervals * tickSpacing;
    }
}
