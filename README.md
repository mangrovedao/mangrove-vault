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
3. Fund mangrove with native tokens with the `fundMangrove` function.
4. Set the initial Kandel position using the `setPosition` function (initial parameters can be set in the factory).
5. Users can mint shares by calling the `mint` function and providing tokens.
6. The vault automatically manages the funds using the Kandel strategy.
7. The vault manager can adjust the position and rebalance tokens as needed.
8. Users can burn their shares to withdraw their proportion of the vault's assets.

## Important Notes

- The contract includes various safety checks and access controls to ensure secure operation.
- The vault's performance is dependent on the effectiveness of the Kandel strategy, market conditions, and the manager's position adjustments.
- Both performance and management fees are implemented and distributed to the designated fee recipient.
- Users should be aware of potential risks associated with automated market-making strategies and the manager's control over the position.
- The contract includes pause functionality, allowing the owner to pause and unpause vault operations.
- The contract uses the dead shares mechanism to prevent the vault from being exploited.

## Understanding the underlying Kandel strategy

The Kandel strategy is a market making strategy that uses a geometric distribution. Kandel is a CLMM (Central Limit Market Maker) strategy.

### Core Kandel

The Core Kandel strategy uses the following parameters, defined in the `Params` struct of `CoreKandel.sol`:

1. `gasprice` (uint32): This parameter sets the gas price to use for offers. It must fit within 26 bits, allowing for a maximum value of 67,108,863 (2^26 - 1). The gas price affects the cost of executing offers on Mangrove.

2. `gasreq` (uint24): This parameter sets the gas requirement for offers. It determines the amount of gas that should be available for executing an offer. This includes any additional gas required by a router if one is used.

3. `stepSize` (uint32): This parameter defines the number of price points to jump when posting a dual offer. It's used in the transport logic to determine where to place new offers after a successful trade.

4. `pricePoints` (uint32): This parameter sets the total number of price points for the Kandel instance. It determines the range of prices at which the strategy will place offers.

These parameters are crucial for the operation of the Kandel strategy:

- The `gasprice` and `gasreq` parameters ensure that offers have sufficient gas to be executed on Mangrove.
- The `stepSize` parameter controls how aggressively the strategy adjusts its offers after trades.
- The `pricePoints` parameter defines the breadth of the market-making strategy.

### Geometric Kandel (inherits from Core Kandel)

The geometric Kandel implementation adds a single parameter which is `baseQuoteTickOffset`. This parameter is defined in the `GeometricKandel.sol` contract:

- `baseQuoteTickOffset` (uint): This parameter sets the tick offset for absolute price used in the geometric progression deployment. It's recommended to be a multiple of the tick spacing for the offer lists to avoid rounding issues.

The `baseQuoteTickOffset` is crucial for determining the price progression of offers in the Kandel strategy:

- It defines the geometric step between price points, allowing for a consistent price ratio between adjacent offers.
- The offset is applied in opposite directions for bids and asks, maintaining symmetry in the offer distribution.
- It can be set using the `setBaseQuoteTickOffset` function, which is restricted to the admin.

By adjusting the `baseQuoteTickOffset`, the vault owner can fine-tune the price range and density of the offers, adapting the strategy to different market conditions and volatility levels.

### Kandel (inherits from Geometric Kandel)

When creating the position, we add 2 other parameters which are crucial for defining the Kandel distribution:

1. `tickIndex0` (Tick): This parameter sets the tick for the price point at index 0, given as a tick on the `base, quote` offer list. It corresponds to an ask with a quote/base ratio. As recommended in `KandelLib.sol`, this should ideally be a multiple of the tick spacing for the offer lists to avoid rounding issues.

2. `firstAskIndex` (uint): This parameter defines the (inclusive) index after which offers should be asks. It must be at most the total number of price points. As seen in `KandelLib.sol`, this parameter is used to determine the boundary between bids and asks in the distribution.

These parameters, along with others from the Kandel strategy, allow for precise control over the price distribution and offer placement:

- `tickIndex0` establishes the starting point of the price curve, affecting the absolute prices of all offers.
- `firstAskIndex` determines where in the distribution the transition from bids to asks occurs, influencing the balance between buy and sell orders.

The `createGeometricDistribution` function in `KandelLib.sol` uses these parameters to generate a distribution of bids and asks, creating a geometric progression of prices across the offer range.

## How does the vaults interact with Kandel

The MangroveVault interacts with Kandel through several key mechanisms:

1. Bounty Management:
   All bounties should be deposited to Mangrove; otherwise, the funds will not be actively listed on Mangrove. This ensures that the strategy has sufficient resources to cover potential transaction costs and incentivize proper execution of trades.

2. Position Setting:
   The vault uses the `setPosition` function to configure the Kandel strategy. This function takes a `KandelPosition` struct as input, which includes:
   - `tickIndex0`: The starting tick for the price distribution.
   - `tickOffset`: The tick spacing between price points.
   - `params`: A `Params` struct containing Kandel strategy parameters (gasprice, gasreq, stepSize, pricePoints).
   - `fundsState`: An enum (`FundsState`) indicating whether funds are in the Vault, Passive, or Active state.

   This function allows the vault to dynamically adjust the Kandel strategy based on market conditions and desired trading behavior.

3. Distribution Creation:
   The first ask index, which determines the transition point from bids to asks in the offer distribution, is calculated using the oracle's mid-price. This mid-price can be sourced from various oracles, such as Mangrove's own mid-price, Chainlink, or other reliable price feeds. By using an external price reference, the strategy can align its offer distribution with current market conditions, ensuring a balanced and responsive market-making approach.

These interactions allow the MangroveVault to effectively manage and optimize the Kandel strategy, adapting to market dynamics while maintaining control over fund allocation and trading parameters.

## Underlying passive strategies

Kandel can source funds from its balance directly, but other implementations of Kandel can source funds from other strategies. For example, the AaveKandel contract, which inherits from GeometricKandel, uses the AavePooledRouter to source funds from Aave.

The AaveKandel contract interacts with the AavePooledRouter in the following ways:

1. Depositing funds: When `depositFunds` is called on AaveKandel, it first transfers the funds to itself and then calls `pushAndSupply` on the AavePooledRouter. This deposits the funds into Aave, allowing them to earn yield while not being used for trading.

2. Withdrawing funds: The `withdrawFundsForToken` function in AaveKandel first checks its local balance and then, if necessary, calls `withdraw` on the AavePooledRouter to retrieve funds from Aave.

3. Checking balance: The `reserveBalance` function in AaveKandel calls `tokenBalanceOf` on the AavePooledRouter to get the balance of funds available in Aave, in addition to checking its local balance.

4. Handling trades: In the `__posthookSuccess__` function, AaveKandel checks if it's the first puller of funds from Aave for a trade. If so, it calls `pushAndSupply` on the AavePooledRouter to deposit any unused funds back into Aave after the trade is completed.

This implementation allows the Kandel strategy to benefit from yield generation on Aave while still maintaining the ability to quickly access funds for trading on Mangrove. The AavePooledRouter acts as an intermediary, managing the deposits and withdrawals from Aave on behalf of the AaveKandel contract.

That's why there is a passive funds state where funds are on the Kandel but no offers are listed on Mangrove. In this state, the funds are deposited into Aave through the AavePooledRouter, earning yield while not actively participating in trading. This allows for a flexible strategy where funds can generate returns even when market conditions are not favorable for active trading. When market conditions improve or the strategy dictates, these funds can be quickly moved from the passive state to an active state, where they are used to create offers on Mangrove.


## Auditing Status

This repository will be audited in its entirety, with the exception of external dependencies. The planned audit will cover all contracts and functions within this repository, aiming to ensure a high level of security and reliability.

It's important to note that two specific functions in the `DistributionLib.sol` file will not be included in this upcoming audit:

1. `transportDestination`
2. `createGeometricDistribution`

These functions have been directly copied from the `mangrove-strats` repository and have already undergone a separate audit. Their inclusion in this project does not compromise the overall security of the system, as they have been previously verified and tested.

The comprehensive audit of this repository, combined with the pre-audited functions from `mangrove-strats`, will provide users with a robust and secure foundation for interacting with the MangroveVault system once the audit is completed.

## Mint Helper

The `MintHelperV1` contract is a utility contract designed to simplify the process of minting MangroveVault shares. It addresses a key challenge in the minting process: the need to specify both the mint amount and maximum token amounts when minting shares directly through the vault.

Key features of the MintHelperV1:

1. Simplified Minting:
   - Takes desired base and quote token amounts to deposit
   - Automatically calculates the optimal mint amount based on current vault state
   - Handles token approvals and minting in a single transaction
   - Returns any unused tokens to the sender

2. Slippage Protection:
   - Includes a minimum shares parameter to protect against receiving fewer shares than expected
   - Reverts the transaction if the calculated mint amount is below the minimum threshold
   - This protection is crucial since the optimal mint amount can change between blocks due to price/balance changes

3. Security Features:
   - Implements reentrancy protection via OpenZeppelin's ReentrancyGuard
   - Uses SafeERC20 for secure token transfers
   - Resets token allowances after minting
   - Includes owner-only function to recover any stuck tokens

The helper significantly reduces the complexity of minting vault shares by handling all the necessary calculations and token movements in a single, atomic transaction. This makes it easier and safer for users to participate in the vault while maintaining protection against adverse price movements.
