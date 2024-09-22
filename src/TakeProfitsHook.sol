// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
contract TakeProfitsHook is BaseHook, ERC1155 {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
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

    mapping(uint256 tokenId => bool exists) public tokenIdExists;
    mapping(uint256 tokenId => uint256 claimable) public tokenIdClaimable;
    mapping(uint256 tokenId => uint256 supply) public tokenIdSupply;
    mapping(uint256 tokenId => TokenData) public tokenIdData;

    struct TokenData {
        PoolId poolId;
        int24 tickLower;
        bool zeroForOne;
    }

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

    function placeOrder(
        PoolKey calldata key,
        int24 tick,
        uint256 amountIn,
        bool zeroForOne
    ) external returns (int24) {
        int24 tickLower = _getTickLower(tick, key.tickSpacing);
        takeProfitPositions[key.toId()][tickLower][zeroForOne] += int256(
            amountIn
        );

        uint256 tokenId = getTokenId(key, tickLower, zeroForOne);

        if (!tokenIdExists[tokenId]) {
            tokenIdExists[tokenId] = true;
            tokenIdData[tokenId] = TokenData({
                poolId: key.toId(),
                tickLower: tickLower,
                zeroForOne: zeroForOne
            });
        }

        _mint(msg.sender, tokenId, amountIn, "");
        tokenIdSupply[tokenId] += amountIn;

        address tokenToBeSoldContract = zeroForOne
            ? Currency.unwrap(key.currency0)
            : Currency.unwrap(key.currency1);

        IERC20(tokenToBeSoldContract).transferFrom(
            msg.sender,
            address(this),
            amountIn
        );

        return tickLower;
    }

    function cancelOrder(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne
    ) external {
        int24 tickLower = _getTickLower(tick, key.tickSpacing);
        uint256 tokenId = getTokenId(key, tickLower, zeroForOne);

        //cancel entire order
        uint256 amountIn = balanceOf(msg.sender, tokenId);
        require(amountIn > 0, "TPH:No order to cancel");

        takeProfitPositions[key.toId()][tickLower][zeroForOne] -= int256(
            amountIn
        );
        tokenIdSupply[tokenId] -= amountIn;
        _burn(msg.sender, tokenId, amountIn);

        Currency tokenToBeSold = zeroForOne ? key.currency0 : key.currency1;
        IERC20(Currency.unwrap(tokenToBeSold)).transfer(msg.sender, amountIn);
    }

    function fillOrder(
        PoolKey calldata key, 
        int24 tick, 
        bool zeroForOne,
        int256 amountIn
    ) internal {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -amountIn,
            //infinite slippage (not ready for production)
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
        })
    }

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

    // ERC-1155 Helpers
    function getTokenId(
        PoolKey calldata key,
        int24 tickLower,
        bool zeroForOne
    ) public pure returns (uint256) {
        return
            uint256(
                keccak256(abi.encodePacked(key.toId(), tickLower, zeroForOne))
            );
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

    function _handleSwap(
        PoolKey calldata key,
        IPoolManager.SwapParams memory params
    ) internal returns (BalanceDelta) {
        //get quote of what we owe and are owed
        BalanceDelta delta = poolManager.swap(key, params, "");

        // we swap token0 for token1
        if (params.zeroForOne) {
            //we owe uniswap token0
            if (delta.amount0() < 0) {
                IERC20(Currency.unwrap(key.currency0)).transfer(
                    address(poolManager),
                    //delta is negative so we need to make it positive
                    uint128(-delta.amount0())
                );
                poolManager.settle();
            }

            //we are owed token1
            if (delta.amount1() > 0) {
                poolManager.take(key.currency1, address(this), delta.amount1());
            }
        } else {
            //we owe uniswap token1
            if (delta.amount1() < 0) {
                IERC20(Currency.unwrap(key.currency1)).transfer(
                    address(poolManager),
                    //delta is negative so we need to make it positive
                    uint128(-delta.amount1())
                );
                poolManager.settle();
            }

            //we are owed token0
            if (delta.amount0() > 0) {
                poolManager.take(key.currency0, address(this), delta.amount0());
            }
        }

        return delta;
    }
}
