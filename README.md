# MangroveVault

MangroveVault is a smart contract implementation of a vault built on top of the Mangrove Kandel strategy. This vault allows users to deposit tokens and participate in automated market-making activities on the Mangrove decentralized exchange, with additional features for position management and fee accrual.

## Overview

The MangroveVault contract provides a way for users to pool their assets and benefit from the Kandel strategy, which is an automated market-making algorithm designed for Mangrove. The vault manager can set and adjust the Kandel position, which represents a range in price for market-making activities. 

Key features include:

1. **Token Deposits and Withdrawals**: Users can deposit and withdraw tokens to/from the vault.
2. **Automated Market Making**: The vault interacts with a Kandel contract to perform market-making activities on Mangrove.
3. **Position Management**: The vault manager can set and adjust the Kandel position, including rebalancing tokens.
4. **Fee Structure**: The vault implements both performance and management fees, which are distributed to a fee recipient chosen by the vault manager.
5. **Oracle Integration**: The vault uses an oracle for fee accrual and initial minting, which can compose different Chainlink price sources.

For more information about the Kandel strategy, please refer to the [Mangrove Kandel documentation](https://docs.mangrove.exchange/general/kandel/).

## Main Components

The main contract in this repository is `MangroveVault.sol`. Here are some of its key functions:

The main entrypoints of the MangroveVault contract are:

1. `getMintAmounts(uint256 baseAmountMax, uint256 quoteAmountMax) external view returns (uint256 baseAmountOut, uint256 quoteAmountOut, uint256 shares)`
   Calculates the amount of shares to be minted and the actual amounts of base and quote tokens to be deposited based on the maximum amounts provided.

2. `mint(uint256 mintAmount, uint256 baseAmountMax, uint256 quoteAmountMax) external returns (uint256 shares, uint256 baseAmount, uint256 quoteAmount)`
   Allows users to deposit base and quote tokens into the vault and receive shares in return.

3. `burn(uint256 shares, uint256 minAmountBaseOut, uint256 minAmountQuoteOut) external returns (uint256 amountBaseOut, uint256 amountQuoteOut)`
   Enables users to burn their shares and withdraw the corresponding amounts of base and quote tokens from the vault.

4. `swap(address target, bytes calldata data, uint256 amountOut, uint256 amountInMin, bool sell) external`
   Allows the vault owner to perform token swaps, potentially using external DEXs or AMMs.

5. `setPosition(KandelPosition memory position) external`
   Permits the vault owner to set or update the Kandel position, which defines the market-making strategy parameters.

6. `updatePosition() external`
   Allows anyone to update the vault's position in the Kandel strategy.

7. `setPerformanceFee(uint256 _fee) external`
   Allows the owner to set the performance fee for the vault.

8. `setManagementFee(uint256 _fee) external`
   Allows the owner to set the management fee for the vault.

## Oracle Integration

The repository includes a contract to convert Chainlink oracles into a format compatible with Mangrove. This oracle can compose different Chainlink price sources to provide accurate price information for the vault's operations.

## Usage

To use the MangroveVault:

1. Deploy or find an existing MangroveChainlinkOracle using the MangroveChainlinkOracleFactory contract.
2. Deploy the MangroveVault contract using the MangroveVaultFactory contract, providing appropriate parameters (seeder, token addresses, tick spacing, oracle address, etc.) to the `createVault` function.
3. Set the initial Kandel position using the `setPosition` function (initial parameters can be set in the factory).
4. Users can mint shares by calling the `mint` function and providing tokens.
5. The vault automatically manages the funds using the Kandel strategy.
6. The vault manager can adjust the position and rebalance tokens as needed.
7. Users can burn their shares to withdraw their proportion of the vault's assets.

## Important Notes

- The contract includes various safety checks and access controls to ensure secure operation.
- The vault's performance is dependent on the effectiveness of the Kandel strategy, market conditions, and the manager's position adjustments.
- Both performance and management fees are implemented and distributed to the designated fee recipient.
- Users should be aware of potential risks associated with automated market-making strategies and the manager's control over the position.
- The contract includes pause functionality, allowing the owner to pause and unpause vault operations.
- The contract uses the dead shares mechanism to prevent the vault from being exploited.