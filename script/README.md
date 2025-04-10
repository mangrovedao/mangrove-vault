# MangroveVault Deployment Script

This script provides a user-friendly way to deploy different types of MangroveVault contracts on any EVM-compatible blockchain. It uses a combination of environment variables (for common configuration) and command-line arguments (for deployment-specific parameters).

## Setup

1. Copy the `.env.example` file to `.env`:
   ```bash
   cp .env.example .env
   ```

2. Edit the `.env` file to set your network-specific configurations:
   ```
   # Network-specific configurations
   MANGROVE_ADDRESS=0x109d9CDFA4aC534354873EF634EF63C235F93f61
   GAS_REQ=128000
   TICK_SPACING=1
   DECIMALS=18
   ORACLE_ADDRESS=0x...
   OWNER_ADDRESS=0x...
   POOL_ADDRESS_PROVIDER=0x0  # Required for Aave or Morpho seeders
   ```

## Usage

The script minimizes command-line parameters, requiring only the most important deployment-specific values:

```bash
forge script script/BetterVaultDeployer.sol:BetterVaultDeployer \
  --sig "run(string,string,address,address,string,string,address,address)" \
  "Standard" \                           # vaultType
  "Standard" \                           # seederType
  "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1" \ # baseToken
  "0xaf88d065e77c8cC2239327C5EDb3A432268e5831" \ # quoteToken
  "Mangrove WETH-USDC Vault" \           # name
  "MGV-WETH-USDC" \                      # symbol
  "0x0" \                                # existingSeeder (0x0 to deploy new)
  "0x0" \                                # existingFactory (0x0 to deploy new)
  --rpc-url <YOUR_RPC_URL> \
  --private-key <YOUR_PRIVATE_KEY> \
  --broadcast
```

### Command Line Parameters

1. **vaultType**: Type of vault to deploy
   - Options: "Standard", "ERC4626", "Morpho"

2. **seederType**: Type of seeder to use
   - Options: "Standard", "Aave", "ERC4626", "Morpho"

3. **baseToken**: Address of the base token

4. **quoteToken**: Address of the quote token

5. **name**: Name of the vault token

6. **symbol**: Symbol of the vault token

7. **existingSeeder**: (Optional) Address of an existing seeder to use
   - Use "0x0" to deploy a new seeder

8. **existingFactory**: (Optional) Address of an existing factory to use
   - Use "0x0" to deploy a new factory

### Configuration in .env

Network and platform-specific configurations that don't change often between deployments:

- **MANGROVE_ADDRESS**: Address of the Mangrove deployment
- **GAS_REQ**: Gas required for offer execution
- **TICK_SPACING**: Tick spacing for the Mangrove market
- **DECIMALS**: Number of decimals for the vault token
- **ORACLE_ADDRESS**: Address of the oracle to use
- **OWNER_ADDRESS**: Address of the vault owner
- **POOL_ADDRESS_PROVIDER**: Address of the pool addresses provider (for Aave/Morpho)

## Examples

### Deploying a Standard Vault on Arbitrum

```bash
# Setup .env for Arbitrum
MANGROVE_ADDRESS=0x109d9CDFA4aC534354873EF634EF63C235F93f61
GAS_REQ=128000
TICK_SPACING=1
DECIMALS=18
ORACLE_ADDRESS=0xYourOracleAddress
OWNER_ADDRESS=0xYourWalletAddress
POOL_ADDRESS_PROVIDER=0x0

# Deploy the vault
forge script script/BetterVaultDeployer.sol:BetterVaultDeployer \
  --sig "run(string,string,address,address,string,string,address,address)" \
  "Standard" \
  "Standard" \
  "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1" \
  "0xaf88d065e77c8cC2239327C5EDb3A432268e5831" \
  "Mangrove WETH-USDC Vault" \
  "MGV-WETH-USDC" \
  "0x0" \
  "0x0" \
  --rpc-url https://arb1.arbitrum.io/rpc \
  --private-key $PRIVATE_KEY \
  --broadcast
```

### Deploying a Morpho Vault on Ethereum Mainnet

```bash
# Setup .env for Ethereum with Morpho
MANGROVE_ADDRESS=0xYourMangroveAddress
GAS_REQ=628000
TICK_SPACING=1
DECIMALS=18
ORACLE_ADDRESS=0xYourOracleAddress
OWNER_ADDRESS=0xYourWalletAddress
POOL_ADDRESS_PROVIDER=0xMorphoPoolAddressProvider

# Deploy the vault
forge script script/BetterVaultDeployer.sol:BetterVaultDeployer \
  --sig "run(string,string,address,address,string,string,address,address)" \
  "Morpho" \
  "Morpho" \
  "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2" \
  "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48" \
  "Morpho WETH-USDC Vault" \
  "MORPHO-WETH-USDC" \
  "0x0" \
  "0x0" \
  --rpc-url https://eth.llamarpc.com \
  --private-key $PRIVATE_KEY \
  --broadcast
```

### Reusing an Existing Seeder and Factory

```bash
# After a deployment, you can reuse components for new token pairs
forge script script/BetterVaultDeployer.sol:BetterVaultDeployer \
  --sig "run(string,string,address,address,string,string,address,address)" \
  "Standard" \
  "Standard" \
  "0xOtherBaseToken" \
  "0xOtherQuoteToken" \
  "Mangrove Other Vault" \
  "MGV-OTHER" \
  "0xPreviouslyDeployedSeeder" \
  "0xPreviouslyDeployedFactory" \
  --rpc-url https://arb1.arbitrum.io/rpc \
  --private-key $PRIVATE_KEY \
  --broadcast
```

## Post-Deployment Steps

After deploying the vault:

1. Fund Mangrove with native tokens:
   ```solidity
   vault.fundMangrove{value: 1 ether}();
   ```

2. Set the initial Kandel position:
   ```solidity
   KandelPosition memory position;
   position.tickIndex0 = Tick.wrap(Tick.unwrap(vault.currentTick()) - 10);
   position.tickOffset = 3;
   position.fundsState = FundsState.Active;
   position.params = Params({gasprice: 0, gasreq: 0, stepSize: 1, pricePoints: 10});
   vault.setPosition(position);
   ```

3. For specialized vaults, perform additional setup:
   - For ERC4626 vaults, set the appropriate vaults
   - For Morpho vaults, claim rewards when needed

4. Set the fee data:
   ```solidity
   vault.setFeeData(performanceFee, managementFee, feeRecipient);
   ```

## Troubleshooting

If you encounter issues:

1. **Environment Variables**: Ensure all required variables are set in the `.env` file. Use `source .env` to load them.

2. **Missing Parameters**: Ensure all required command-line parameters are provided.

3. **Aave/Morpho Seeder**: If using Aave or Morpho seeder, make sure `POOL_ADDRESS_PROVIDER` is set in the `.env` file.

4. **Gas Issues**: For complex deployments on mainnet, you may need to increase the gas limit.

5. **Existing Contract Validation**: If reusing seeders or factories, verify they exist and are of the correct type.