// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

interface ITakeProfitsHook {
    function placeOrder(
        PoolKey calldata key,
        int24 tick,
        uint256 amountIn,
        bool zeroForOne
    ) external returns (int24);

    function cancelOrder(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne
    ) external;

    function redeem(
        uint256 tokenId,
        uint256 amountIn,
        address destination
    ) external;

    function getTokenId(
        PoolKey calldata key,
        int24 tickLower,
        bool zeroForOne
    ) external pure returns (uint256);

    function afterInitialize(
        address addr,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick
    ) external returns (bytes4);
}
