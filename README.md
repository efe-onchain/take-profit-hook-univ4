# TakeProfitsHook Smart Contract - README

## Overview

The `TakeProfitsHook` contract is a specialized DeFi contract built on Uniswap v4's architecture, integrating the ERC1155 token standard. This contract allows users to automate and manage take-profit orders in a Uniswap pool by defining positions based on predefined tick ranges. When certain price conditions are met (i.e., when the tick crosses specified thresholds), the contract will automatically execute the trades, allowing users to secure profits.

### Features
- **Take-Profit Orders**: Users can place take-profit orders that trigger swaps between two tokens when the price reaches a specified tick threshold.
- **Automated Order Fulfillment**: Orders are automatically fulfilled as the pool's tick price reaches the user's set take-profit thresholds.
- **Tokenized Positions**: User orders are tokenized via ERC1155, enabling easy tracking, transfer, and management of orders.
- **Order Cancellation**: Users can cancel their orders if desired, receiving their tokens back before the take-profit is triggered.
- **Claimable Profit**: After the take-profit condition is met, users can redeem the claimable amount of tokens based on the fulfilled orders.

## Contract Details

### Key Components

1. **Mappings**:
   - `tickLowerLasts`: Tracks the last `tickLower` value for each pool, ensuring the contract knows the last execution point for each order.
   - `takeProfitPositions`: Nested mapping that stores the take-profit orders. It's structured as:
     - `poolId` => `tickLower` => `zeroForOne` => `amount`.
   - `tokenIdExists`: Tracks the existence of token IDs.
   - `tokenIdClaimable`: Tracks the claimable amount for each token ID.
   - `tokenIdSupply`: Tracks the total supply of tokens for each token ID.
   - `tokenIdData`: Holds additional metadata for each token ID.

2. **Structures**:
   - `TokenData`: Stores the metadata for each token position, including `poolId`, `tickLower`, and `zeroForOne` (direction of trade).

### ERC1155 Token Integration
Each take-profit position is tokenized as an ERC1155 token. This allows users to trade or manage their positions via tokens. When a take-profit order is fulfilled, the corresponding token can be redeemed for the claimable amount of the token received from the swap.

### Core Functions

- **`placeOrder`**: Allows users to place a take-profit order in a Uniswap pool. The order specifies the tick (price threshold), amount to trade, and the direction of the trade (Token 0 to Token 1, or vice versa). It mints an ERC1155 token representing the position.
  
- **`cancelOrder`**: Allows users to cancel a placed order before it is fulfilled. The user receives their tokens back, and the ERC1155 token representing the order is burned.
  
- **`redeem`**: Users can redeem tokens after an order has been fulfilled. The function burns the ERC1155 token and transfers the claimable amount to the user's specified destination.
  
- **`afterSwap`**: A hook that triggers after every Uniswap pool swap. It checks if the price (tick) has crossed any user's take-profit threshold and automatically fulfills the order if conditions are met.
  
- **`afterInitialize`**: A hook that is executed after a pool is initialized, setting up the contract’s tracking of the initial pool state.

### Hooks Integration

The contract overrides Uniswap’s hook functions to automatically manage orders after each swap or when the pool is initialized. The specific hooks implemented are:
- **`afterInitialize`**: Tracks the initial tick of a newly initialized pool.
- **`afterSwap`**: Checks if a take-profit threshold has been met after a swap and attempts to fulfill any pending orders.

### Token ID Calculation
A unique token ID is generated for each order using the `getTokenId` function, which hashes together the pool key, tickLower, and the direction (`zeroForOne`) of the trade.

### Internal Functions

- **`_fillOrder`**: Fulfills a take-profit order by executing the swap on Uniswap, updating the positions and claimable amounts.
  
- **`_tryFulfillingOrders`**: Checks if the current tick has crossed any user's take-profit threshold and attempts to fulfill the order if possible.

## Usage Instructions

### 1. Placing a Take-Profit Order
To place a take-profit order, call the `placeOrder` function with the desired Uniswap pool, tick (price threshold), amount of tokens, and the direction of the trade (`zeroForOne`).

```solidity
placeOrder(PoolKey calldata key, int24 tick, uint256 amountIn, bool zeroForOne)
```

- `key`: The unique identifier for the pool.
- `tick`: The price threshold at which the trade will trigger.
- `amountIn`: The amount of tokens you want to sell.
- `zeroForOne`: `true` for selling Token 0 for Token 1, `false` for selling Token 1 for Token 0.

### 2. Canceling an Order
Users can cancel their order before it’s fulfilled by calling `cancelOrder`.

```solidity
cancelOrder(PoolKey calldata key, int24 tick, bool zeroForOne)
```

### 3. Redeeming a Fulfilled Order
After a take-profit order has been fulfilled, users can redeem their tokens by calling `redeem`.

```solidity
redeem(uint256 tokenId, uint256 amountIn, address destination)
```

- `tokenId`: The ID of the ERC1155 token representing the fulfilled order.
- `amountIn`: The amount of tokens to redeem.
- `destination`: The address where the redeemed tokens will be sent.

## Security Considerations

- **Slippage**: The swap uses infinite slippage in the `_fillOrder` function. This implementation is not ready for production and should be adjusted for real-world deployment.
- **Token Transfers**: Ensure that sufficient approvals are granted for token transfers to the contract when placing or redeeming orders.
  
## License

This contract is licensed under the MIT License.

## Conclusion

`TakeProfitsHook` offers a streamlined way for users to place automated take-profit orders on Uniswap pools, leveraging the ERC1155 standard for easy tracking and management of positions. This tool is ideal for DeFi traders who want to automate their profit-taking strategies based on market conditions without manual intervention.