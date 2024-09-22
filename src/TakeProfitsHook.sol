// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/console.sol";

import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BaseHook} from "v4-periphery/BaseHook.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {ERC1155} from "openzeppelin-contracts/contracts/token/ERC1155/ERC1155.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

contract TakeProfitsHook is ITakeProfitsHook, BaseHook, ERC1155 {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using FixedPointMathLib for uint256;

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
     * @dev Mapping to check the existence of a token ID.
     * The key is the token ID (uint256) and the value is a boolean indicating whether the token ID exists.
     */
    mapping(uint256 tokenId => bool exists) public tokenIdExists;

    /**
     * @dev Mapping to store the claimable amount for each token ID.
     * @param tokenId The unique identifier for a token.
     * @param claimable The amount that can be claimed for the given token ID.
     */
    mapping(uint256 tokenId => uint256 claimable) public tokenIdClaimable;

    /**
     * @dev Mapping to store the supply of each token identified by its tokenId.
     * The key is the tokenId and the value is the supply of that token.
     */
    mapping(uint256 tokenId => uint256 supply) public tokenIdSupply;

    /**
     * @dev Mapping to store TokenData associated with each tokenId.
     * The key is the tokenId (uint256) and the value is the TokenData structure.
     * This mapping is publicly accessible.
     */
    mapping(uint256 tokenId => TokenData) public tokenIdData;

    /**
     * @dev Structure to hold data related to a specific token.
     * @param poolId The identifier for the pool associated with the token.
     * @param tickLower The lower tick boundary for the token.
     * @param zeroForOne A boolean indicating the direction of the swap (true if zero for one, false otherwise).
     */
    struct TokenData {
        PoolKey poolId;
        int24 tickLower;
        bool zeroForOne;
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

    /*░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
    ░░░░                             Hooks                               ░░░░
    ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░*/

    /**
     * @notice Executes actions after the pool has been initialized.
     * @param address Unused parameter.
     * @param key The PoolKey struct containing the pool's parameters.
     * @param uint160 Unused parameter.
     * @param tick The initial tick value of the pool.
     * @return bytes4 The selector for the afterInitialize function.
     */
    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24 tick
    ) external override poolManagerOnly returns (bytes4) {
        _setTickLowerLast(key.toId(), _getTickLower(tick, key.tickSpacing));
        return TakeProfitsHook.afterInitialize.selector;
    }

    /**
     * @notice Executes actions after a swap has occurred in the pool.
     * @param addr The address initiating the swap.
     * @param key The PoolKey struct containing the pool's parameters.
     * @param params The SwapParams struct containing the swap parameters.
     * @param BalanceDelta The balance delta resulting from the swap.
     * @return bytes4 The selector for the afterSwap function.
     */
    function afterSwap(
        address addr,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta
    ) external override poolManagerOnly returns (bytes4) {
        if (addr == address(this)) {
            return TakeProfitsHook.afterSwap.selector;
        }

        bool attemptFulfillment = true;
        int24 currentTickLower;

        while (attemptFulfillment) {
            (attemptFulfillment, currentTickLower) = _tryFulfillingOrders(
                key,
                params
            );
            _setTickLowerLast(key.toId(), currentTickLower);
        }

        return TakeProfitsHook.afterSwap.selector;
    }

    /*░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
    ░░░░                         Public Functions                          ░░░░
    ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░*/

    /**
     * @notice Cancels an existing order in the specified pool.
     * @param key The PoolKey struct containing the pool's parameters.
     * @param tick The tick at which the order was placed.
     * @param zeroForOne A boolean indicating the direction of the trade.
     *                    - true: selling token0 for token1
     *                    - false: selling token1 for token0
     */
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

    /**
     * @notice Required override function for BaseHook to let the PoolManager know which hooks are implemented.
     */
    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return
            Hooks.Calls({
                beforeInitialize: false,
                afterInitialize: true,
                beforeModifyPosition: false,
                afterModifyPosition: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false
            });
    }

    /**
     * @notice Places an order in the Uniswap pool.
     * @param key The pool key containing the pool's parameters.
     * @param tick The tick at which the order is placed.
     * @param amountIn The amount of tokens to be placed in the order.
     * @param zeroForOne A boolean indicating the direction of the trade.
     *                   If true, the trade is from token0 to token1; otherwise, it's from token1 to token0.
     * @return The lower tick boundary of the order.
     *
     * @dev This function calculates the lower tick boundary for the given tick and pool key's tick spacing.
     *      It updates the take profit positions and mints a new token if the token ID does not exist.
     *      The function also transfers the specified amount of tokens from the sender to the contract.
     */
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
                poolId: key,
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

    /**
     * @notice Redeems a specified amount of tokens for a given tokenId and transfers the equivalent amount to the destination address.
     * @dev This function checks if the tokenId has claimable tokens and if the caller has sufficient balance to redeem the specified amount.
     *      It calculates the amount to send based on the claimable tokens and total supply, then burns the redeemed tokens and transfers the equivalent amount.
     * @param tokenId The ID of the token to redeem.
     * @param amountIn The amount of tokens to redeem.
     * @param destination The address to which the redeemed tokens will be transferred.
     * @require The tokenId must have claimable tokens.
     * @require The caller must have a sufficient balance of the specified tokenId to redeem the specified amount.
     * @require The transfer of tokens to the destination address must succeed.
     */
    function redeem(
        uint256 tokenId,
        uint256 amountIn,
        address destination
    ) external {
        require(tokenIdClaimable[tokenId] > 0, "TPH:No tokens to redeem");

        uint256 balace = balanceOf(msg.sender, tokenId);
        require(
            balace >= amountIn,
            "TPH:Insufficient balance to redeem specified amount"
        );

        TokenData memory tokenData = tokenIdData[tokenId];
        Currency tokensToSend = tokenData.zeroForOne
            ? tokenData.poolId.currency1
            : tokenData.poolId.currency0;

        uint256 amountToSend = amountIn.mulDivDown(
            tokenIdClaimable[tokenId],
            tokenIdSupply[tokenId]
        );

        tokenIdClaimable[tokenId] -= amountToSend;
        tokenIdSupply[tokenId] -= amountIn;
        _burn(msg.sender, tokenId, amountIn);

        IERC20(Currency.unwrap(tokensToSend)).transfer(
            destination,
            amountToSend
        );
    }

    /*░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
    ░░░░                          ERC1155 Helpers                          ░░░░
    ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░*/

    /**
     * @notice Computes a unique token ID based on the provided pool key, tick lower bound, and direction.
     * @param key The pool key containing the necessary parameters to identify the pool.
     * @param tickLower The lower bound of the tick range.
     * @param zeroForOne A boolean indicating the direction of the trade.
     * @return A unique uint256 token ID generated using the keccak256 hash of the encoded parameters.
     */
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

    /*░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
    ░░░░                        Internal Functions                         ░░░░
    ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░*/

    /**
     * @dev Executes a swap order on the pool and updates the profit positions.
     *
     * @param key The pool key containing the pool's identifiers.
     * @param tick The tick at which the order is being filled.
     * @param zeroForOne A boolean indicating the direction of the swap.
     * @param amountIn The amount of input tokens for the swap.
     *
     * @notice This function performs a swap with infinite slippage, which is not suitable for production use.
     *
     * @dev The function calculates the swap parameters, executes the swap, and updates the profit positions and claimable tokens.
     */
    function _fillOrder(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne,
        int256 amountIn
    ) internal {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -amountIn,
            //infinite slippage (not ready for production)
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_RATIO + 1
                : TickMath.MAX_SQRT_RATIO - 1
        });

        BalanceDelta delta = _handleSwap(key, params);

        takeProfitPositions[key.toId()][tick][zeroForOne] -= amountIn;
        uint256 tokenId = getTokenId(key, tick, zeroForOne);
        uint256 tokensReceived = zeroForOne
            ? uint256(int256(delta.amount1()))
            : uint256(int256(delta.amount0()));
        tokenIdClaimable[tokenId] += tokensReceived;
    }

    /**
     * @dev Handles the swap operation by interacting with the pool manager.
     *
     * @param key The pool key containing the currencies involved in the swap.
     * @param params The parameters for the swap, including the direction of the swap.
     * @return delta The balance delta resulting from the swap.
     *
     * This function performs the following steps:
     * 1. Calls the pool manager to execute the swap and get the balance delta.
     * 2. Depending on the swap direction (zeroForOne):
     *    - If swapping token0 for token1:
     *      - If the contract owes token0 to Uniswap, it transfers the owed amount to the pool manager.
     *      - If the contract is owed token1, it takes the owed amount from the pool manager.
     *    - If swapping token1 for token0:
     *      - If the contract owes token1 to Uniswap, it transfers the owed amount to the pool manager.
     *      - If the contract is owed token0, it takes the owed amount from the pool manager.
     */
    function _handleSwap(
        PoolKey calldata key,
        IPoolManager.SwapParams memory params
    ) internal returns (BalanceDelta) {
        //get quote of what we owe and are owed
        BalanceDelta delta = poolManager.swap(key, params);

        // we swap token0 for token1
        if (params.zeroForOne) {
            //we owe uniswap token0
            if (delta.amount0() < 0) {
                IERC20(Currency.unwrap(key.currency0)).transfer(
                    address(poolManager),
                    //delta is negative so we need to make it positive
                    uint128(-delta.amount0())
                );
                poolManager.settle(key.currency1);
            }

            //we are owed token1
            if (delta.amount1() > 0) {
                poolManager.take(
                    key.currency1,
                    address(this),
                    uint128(delta.amount1())
                );
            }
        } else {
            //we owe uniswap token1
            if (delta.amount1() < 0) {
                IERC20(Currency.unwrap(key.currency1)).transfer(
                    address(poolManager),
                    //delta is negative so we need to make it positive
                    uint128(-delta.amount1())
                );
                poolManager.settle(key.currency1);
            }

            //we are owed token0
            if (delta.amount0() > 0) {
                poolManager.take(
                    key.currency0,
                    address(this),
                    uint128(delta.amount0())
                );
            }
        }

        return delta;
    }

    /**
     * @dev Attempts to fulfill orders based on the current and last tick positions.
     *
     * @param key The PoolKey containing the pool's unique identifiers.
     * @param params The SwapParams containing the swap parameters.
     * @return A tuple where the first value is a boolean indicating if an order was fulfilled,
     *         and the second value is the current tick lower value.
     *
     * This function checks the current tick position and compares it with the last tick position.
     * If the last tick position is lower than the current tick position, it iterates through the ticks
     * from the last tick position to the current tick position, attempting to fulfill orders.
     * If the last tick position is higher than the current tick position, it iterates through the ticks
     * from the last tick position to the current tick position in reverse, attempting to fulfill orders.
     *
     * The function returns true and the current tick lower value if an order is fulfilled, otherwise it returns false
     * and the current tick lower value.
     */

    function _tryFulfillingOrders(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params
    ) internal returns (bool, int24) {
        (, int24 currentTick, , , , ) = poolManager.getSlot0(key.toId());
        int24 currentTickLower = _getTickLower(currentTick, key.tickSpacing);
        int24 lastTickLower = tickLowerLasts[key.toId()];

        bool swapZeroForOne = !params.zeroForOne;
        int256 swapAmountIn;

        if (lastTickLower < currentTickLower) {
            for (int24 tick = lastTickLower; tick < currentTickLower; ) {
                swapAmountIn = takeProfitPositions[key.toId()][tick][
                    swapZeroForOne
                ];
                if (swapAmountIn > 0) {
                    fillOrder(key, tick, swapZeroForOne, swapAmountIn);
                    (, currentTick, , , , ) = poolManager.getSlot0(key.toId());
                    currentTickLower = _getTickLower(
                        currentTick,
                        key.tickSpacing
                    );
                    return (true, currentTickLower);
                }
                tick += key.tickSpacing;
            }
        } else {
            for (int24 tick = lastTickLower; tick > currentTickLower; ) {
                swapAmountIn = takeProfitPositions[key.toId()][tick][
                    swapZeroForOne
                ];
                if (swapAmountIn > 0) {
                    fillOrder(key, tick, swapZeroForOne, swapAmountIn);
                    (, currentTick, , , , ) = poolManager.getSlot0(key.toId());
                    currentTickLower = _getTickLower(
                        currentTick,
                        key.tickSpacing
                    );
                }
                tick -= key.tickSpacing;
            }
        }

        return (false, currentTickLower);
    }

    /*░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
    ░░░░                        Private Functions                          ░░░░
    ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░*/

    /**
     * @dev Calculates the lower tick boundary for a given tick and tick spacing.
     *      This function rounds towards negative infinity if the actual tick is negative
     *      and not a multiple of the tick spacing.
     * @param actualTick The current tick value.
     * @param tickSpacing The spacing between ticks.
     * @return The lower tick boundary.
     */
    function _getTickLower(
        int24 actualTick,
        int24 tickSpacing
    ) private pure returns (int24) {
        int24 intervals = actualTick / tickSpacing;
        if (actualTick < 0 && actualTick % tickSpacing != 0) intervals--; // round towards negative infinity
        return intervals * tickSpacing;
    }

    /**
     * @dev Sets the last recorded lower tick for a given pool.
     * @param poolId The identifier of the pool.
     * @param tickLower The lower tick value to be recorded.
     */
    function _setTickLowerLast(PoolId poolId, int24 tickLower) private {
        tickLowerLasts[poolId] = tickLower;
    }
}
