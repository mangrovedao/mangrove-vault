# MangroveERC4626KandelVault

MangroveERC4626KandelVault is an extension of the MangroveVault contract that implements the ERC4626 standard for tokenized vaults. This vault builds on the Mangrove Kandel strategy for automated market-making, while additionally supporting integration with external yield-generating vaults through the ERC4626 interface.

## Overview

The MangroveERC4626KandelVault contract extends the functionality of MangroveVault by enabling integration with external ERC4626-compliant vaults. This allows the idle assets in the Kandel strategy to be deposited into yield-generating protocols, enhancing the overall returns for vault participants.

Key features include:

1. **All MangroveVault Features**: Inherits all functionality from the base MangroveVault, including token deposits/withdrawals, automated market-making, position management, and fee structures.
2. **ERC4626 Integration**: Allows the vault to deposit idle tokens into external ERC4626-compliant vaults for additional yield generation.
3. **Configurable Vault Strategy**: The owner can set different ERC4626 vaults for base and quote tokens, allowing for flexible yield strategies.
4. **Admin Controls**: Includes additional administrative functions for managing the external vault integrations and withdrawing tokens when necessary.

## Main Components

The MangroveERC4626KandelVault contract extends `MangroveVault.sol` and adds the following key functions:

1. `setVaultForToken(IERC20 token, IERC4626 vault) external virtual onlyOwner`
   Allows the owner to specify which ERC4626-compliant vault should be used for a particular token (either base or quote).

2. `adminWithdrawTokens(IERC20 token, uint256 amount, address recipient) public onlyOwner`
   Enables the owner to withdraw specific ERC20 tokens from the Kandel strategy to a designated recipient.

3. `adminWithdrawNative(uint256 amount, address recipient) public onlyOwner`
   Allows the owner to withdraw native tokens (e.g., ETH) from the Kandel strategy to a designated recipient.

4. `currentVaults() public view returns (address baseVault, address quoteVault)`
   Returns the addresses of the currently configured ERC4626 vaults for both base and quote tokens.

## Enhanced Yield Generation

The key innovation of MangroveERC4626KandelVault compared to the standard MangroveVault is its ability to generate additional yield through ERC4626 vault integrations:

1. **Layered Yield Strategy**: The vault generates returns from both Mangrove market-making activities and from the yield earned in external protocols via ERC4626 vaults.
   
2. **Optimized Capital Efficiency**: By depositing idle funds (funds not actively being used for market-making) into external yield-generating protocols, the vault maximizes the capital efficiency of all assets.

3. **Flexible Vault Selection**: The owner can select different ERC4626-compliant vaults for base and quote tokens, optimizing for the best available yield opportunities in the market.

## Usage

To use the MangroveERC4626KandelVault:

1. Deploy the contract using appropriate parameters (seeder, token addresses, tick spacing, oracle address, etc.).
2. Set the appropriate ERC4626 vaults for both base and quote tokens using the `setVaultForToken` function.
3. Fund Mangrove with native tokens using the `fundMangrove` function.
4. Set the initial Kandel position using the `setPosition` function.
5. Users can mint shares by calling the `mint` function and providing tokens.
6. The vault automatically manages the funds using the Kandel strategy, with idle funds being deposited into the configured ERC4626 vaults.
7. The vault manager can adjust the position and rebalance tokens as needed.
8. Users can burn their shares to withdraw their proportion of the vault's assets.

## Understanding the Dual Yield Mechanism

The MangroveERC4626KandelVault benefits from two sources of yield:

1. **Market-Making Yield**: As with the standard MangroveVault, the contract earns rewards from the spread between bid and ask prices when providing liquidity on Mangrove.

2. **Passive Yield**: When funds are in the "Passive" state or not actively being used for offers, they can be deposited into ERC4626-compliant vaults to earn additional yield from external protocols like Aave, Compound, or other yield-generating platforms.

This dual yield approach maximizes returns for vault participants while still maintaining the core market-making functionality of the Kandel strategy.

## Admin Functions

The contract includes several admin-only functions to manage the external vault integrations:

1. **Setting Vaults**: The owner can set which ERC4626-compliant vault should be used for each token.

2. **Emergency Withdrawals**: In case of emergencies or necessary protocol adjustments, the owner can withdraw tokens or native currency from the Kandel contract.

3. **Inherited Controls**: All admin controls from the base MangroveVault contract are also available, including fee setting, position management, and pause functionality.

## Important Notes

- The contract includes all the safety features of the base MangroveVault, including pause functionality and various access controls.
- The vault's performance depends on both the effectiveness of the Kandel strategy and the yield earned from the external ERC4626 vaults.
- Users should be aware of potential risks associated with both automated market-making strategies and the external protocols used for yield generation.
- The contract maintains the fee structure from MangroveVault, with both performance and management fees being implemented.
- As with the base contract, the dead shares mechanism is used to prevent the vault from being exploited.

## ERC4626 Integration Details

The MangroveERC4626KandelVault integrates with external ERC4626-compliant vaults through the Kandel strategy:

1. **Vault Selection**: The owner selects appropriate ERC4626 vaults for base and quote tokens based on security, yield, and other factors.

2. **Deposit Process**: When funds are in the "Passive" state, the Kandel strategy can deposit them into the configured ERC4626 vaults.

3. **Yield Accrual**: While deposited in external vaults, the tokens earn yield according to the specific vault's mechanics.

4. **Withdrawal Process**: When funds are needed for market-making or user redemptions, they are withdrawn from the external vaults back to the Kandel strategy.

5. **Yield Distribution**: The additional yield earned from external vaults benefits all vault participants proportionally to their share ownership.

By leveraging the ERC4626 standard, the vault can easily integrate with a wide range of yield-generating protocols without requiring custom integration code for each one.