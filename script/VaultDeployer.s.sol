// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

// Base imports
import {IMangrove} from "@mgv/src/IMangrove.sol";
import {MangroveVaultFactory, MangroveVault} from "src/MangroveVaultFactory.sol";

// ERC4626 imports
import {MangroveERC4626KandelVaultFactory, MangroveERC4626KandelVault} from "src/integrations/MangroveERC4626KandelVaultFactory.sol";

// Morpho imports
import {MangroveMorphoKandelVaultFactory, MangroveMorphoKandelVault} from "src/integrations/MangroveMorphoKandelVaultFactory.sol";

// Seeder imports
import {AbstractKandelSeeder} from "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/AbstractKandelSeeder.sol";
import {KandelSeeder} from "@mgv-strats/src/strategies/offer_maker/market_making/kandel/KandelSeeder.sol";
import {AaveKandelSeeder} from "@mgv-strats/src/strategies/offer_maker/market_making/kandel/AaveKandelSeeder.sol";
import {ERC4626KandelSeeder} from "@mgv-strats/src/strategies/offer_maker/market_making/kandel/ERC4626KandelSeeder.sol";
import {MorphoKandelSeeder, IMorphoFactory, IMorphoRewardDistributor} from "@mgv-strats/src/strategies/offer_maker/market_making/kandel/MorphoKandelSeeder.sol";
import {
  AavePooledRouter,
  IPoolAddressesProvider
} from "@mgv-strats/src/strategies/routers/integrations/AavePooledRouter.sol";

// Oracle imports
import {IOracle} from "src/oracles/IOracle.sol";

/**
 * @title VaultDeployerScript
 * @notice Forge script for deploying different types of MangroveVault contracts on any chain
 * @dev Uses a mix of .env variables and command-line arguments for a better UX
 */
contract VaultDeployerScript is Script {
    enum VaultType {
        Standard,
        ERC4626,
        Morpho
    }

    enum SeederType {
        Standard,
        Aave,
        ERC4626,
        Morpho
    }

    struct DeploymentParams {
        // Basic vault parameters
        VaultType vaultType;
        SeederType seederType;
        address baseToken;
        address quoteToken;
        uint256 tickSpacing;
        uint8 decimals;
        string name;
        string symbol;
        address oracle;
        address owner;
        
        // Existing contract addresses (optional)
        address existingSeeder;
        address existingFactory;
        
        // Seeder parameters (required if creating new seeder)
        address mangrove;
        address poolAddressProvider; // For Aave
        address morphoFactory; // For Morpho
        address morphoRewardDistributor; // For Morpho
        uint256 gasreq;
        
        // Output
        address deployedSeeder;
        address deployedFactory;
        address deployedVault;
        address deployedKandel;
    }

    /**
     * @notice Main run function that accepts minimal command-line arguments
     * @param vaultType Type of vault to deploy (Standard, ERC4626, Morpho)
     * @param seederType Type of seeder to use (Standard, Aave, ERC4626, Morpho)
     * @param baseToken Address of the base token
     * @param quoteToken Address of the quote token
     * @param name Name of the vault token
     * @param symbol Symbol of the vault token
     * @param existingSeeder Optional address of an existing seeder to use (use 0x0 for new)
     * @param existingFactory Optional address of an existing factory to use (use 0x0 for new)
     */
    function run(
        string calldata vaultType,
        string calldata seederType,
        address baseToken,
        address quoteToken,
        string calldata name,
        string calldata symbol,
        address existingSeeder,
        address existingFactory
    ) public returns (DeploymentParams memory params) {
        // Load core parameters from .env
        params.mangrove = vm.envAddress("MANGROVE_ADDRESS");
        params.poolAddressProvider = vm.envOr("POOL_ADDRESS_PROVIDER", address(0));
        params.morphoFactory = vm.envOr("MORPHO_FACTORY", address(0));
        params.morphoRewardDistributor = vm.envOr("MORPHO_REWARD_DISTRIBUTOR", address(0));
        params.gasreq = vm.envUint("GAS_REQ");
        params.tickSpacing = vm.envUint("TICK_SPACING");
        params.decimals = uint8(vm.envUint("DECIMALS"));
        params.oracle = vm.envAddress("ORACLE_ADDRESS");
        params.owner = vm.envAddress("OWNER_ADDRESS");
        
        // Set up deployment parameters
        params.baseToken = baseToken;
        params.quoteToken = quoteToken;
        params.name = name;
        params.symbol = symbol;
        params.existingSeeder = existingSeeder;
        params.existingFactory = existingFactory;
        
        // Parse vault type
        if (keccak256(bytes(vaultType)) == keccak256(bytes("Standard"))) {
            params.vaultType = VaultType.Standard;
        } else if (keccak256(bytes(vaultType)) == keccak256(bytes("ERC4626"))) {
            params.vaultType = VaultType.ERC4626;
        } else if (keccak256(bytes(vaultType)) == keccak256(bytes("Morpho"))) {
            params.vaultType = VaultType.Morpho;
        } else {
            revert("Invalid vault type. Use Standard, ERC4626, or Morpho");
        }
        
        // Parse seeder type
        if (keccak256(bytes(seederType)) == keccak256(bytes("Standard"))) {
            params.seederType = SeederType.Standard;
        } else if (keccak256(bytes(seederType)) == keccak256(bytes("Aave"))) {
            params.seederType = SeederType.Aave;
        } else if (keccak256(bytes(seederType)) == keccak256(bytes("ERC4626"))) {
            params.seederType = SeederType.ERC4626;
        } else if (keccak256(bytes(seederType)) == keccak256(bytes("Morpho"))) {
            params.seederType = SeederType.Morpho;
        } else {
            revert("Invalid seeder type. Use Standard, Aave, ERC4626, or Morpho");
        }
        
        // Validate parameters
        validateParams(params);
        
        // Start broadcast
        vm.startBroadcast();
        
        // Get or deploy the seeder
        AbstractKandelSeeder seeder;
        if (params.existingSeeder != address(0)) {
            // Use existing seeder
            seeder = AbstractKandelSeeder(params.existingSeeder);
            params.deployedSeeder = params.existingSeeder;
            console.log("Using existing seeder at:", params.existingSeeder);
        } else {
            // Deploy new seeder
            seeder = deploySeeder(params);
            params.deployedSeeder = address(seeder);
            console.log("Deployed new seeder at:", address(seeder));
        }
        
        // Deploy the vault using the appropriate factory
        if (params.vaultType == VaultType.Standard) {
            // Handle standard vault deployment
            address factory;
            if (params.existingFactory != address(0)) {
                factory = params.existingFactory;
            } else {
                MangroveVaultFactory newFactory = new MangroveVaultFactory();
                factory = address(newFactory);
                params.deployedFactory = factory;
            }
            
            MangroveVaultFactory factoryInstance = MangroveVaultFactory(factory);
            MangroveVault vault = factoryInstance.createVault(
                seeder,
                params.baseToken,
                params.quoteToken,
                params.tickSpacing,
                params.decimals,
                params.name,
                params.symbol,
                params.oracle,
                params.owner
            );
            
            params.deployedVault = address(vault);
            params.deployedKandel = address(vault.kandel());
        } 
        else if (params.vaultType == VaultType.ERC4626) {
            // Handle ERC4626 vault deployment
            address factory;
            if (params.existingFactory != address(0)) {
                factory = params.existingFactory;
            } else {
                MangroveERC4626KandelVaultFactory newFactory = new MangroveERC4626KandelVaultFactory();
                factory = address(newFactory);
                params.deployedFactory = factory;
            }
            
            MangroveERC4626KandelVaultFactory factoryInstance = MangroveERC4626KandelVaultFactory(factory);
            MangroveERC4626KandelVault vault = factoryInstance.createVault(
                seeder,
                params.baseToken,
                params.quoteToken,
                params.tickSpacing,
                params.decimals,
                params.name,
                params.symbol,
                params.oracle,
                params.owner
            );
            
            params.deployedVault = address(vault);
            params.deployedKandel = address(vault.kandel());
        }
        else if (params.vaultType == VaultType.Morpho) {
            // Handle Morpho vault deployment
            address factory;
            if (params.existingFactory != address(0)) {
                factory = params.existingFactory;
            } else {
                MangroveMorphoKandelVaultFactory newFactory = new MangroveMorphoKandelVaultFactory();
                factory = address(newFactory);
                params.deployedFactory = factory;
            }
            
            MangroveMorphoKandelVaultFactory factoryInstance = MangroveMorphoKandelVaultFactory(factory);
            MangroveMorphoKandelVault vault = factoryInstance.createVault(
                seeder,
                params.baseToken,
                params.quoteToken,
                params.tickSpacing,
                params.decimals,
                params.name,
                params.symbol,
                params.oracle,
                params.owner
            );
            
            params.deployedVault = address(vault);
            params.deployedKandel = address(vault.kandel());
        }
        
        // Stop broadcast
        vm.stopBroadcast();
        
        // Log deployment information
        logDeployment(params);
        
        return params;
    }
    
    /**
     * @notice Validate the provided parameters
     */
    function validateParams(DeploymentParams memory params) internal view {
        // Basic parameter validation
        require(params.baseToken != address(0), "Base token address cannot be zero");
        require(params.quoteToken != address(0), "Quote token address cannot be zero");
        require(params.oracle != address(0), "Oracle address cannot be zero");
        require(params.owner != address(0), "Owner address cannot be zero");
        require(bytes(params.name).length > 0, "Name cannot be empty");
        require(bytes(params.symbol).length > 0, "Symbol cannot be empty");
        
        // If no existing seeder is provided, validate seeder parameters
        if (params.existingSeeder == address(0)) {
            require(params.mangrove != address(0), "Mangrove address cannot be zero when creating a new seeder");
            require(params.gasreq > 0, "Gas requirement must be greater than zero when creating a new seeder");
            
            // Specific validation for seeder types
            if (params.seederType == SeederType.Aave) {
                require(params.poolAddressProvider != address(0), 
                    "Pool address provider must be set in .env for Aave seeder");
            }
            
            if (params.seederType == SeederType.Morpho) {
                require(params.morphoFactory != address(0), 
                    "Morpho factory must be set in .env for Morpho seeder");
                require(params.morphoRewardDistributor != address(0), 
                    "Morpho reward distributor must be set in .env for Morpho seeder");
            }
        }
    }
    
    /**
     * @notice Deploy the appropriate seeder based on the seeder type
     */
    function deploySeeder(DeploymentParams memory params) internal returns (AbstractKandelSeeder) {
        if (params.seederType == SeederType.Standard) {
            return new KandelSeeder(
                IMangrove(payable(params.mangrove)),
                params.gasreq
            );
        } 
        else if (params.seederType == SeederType.Aave) {
            return new AaveKandelSeeder(
                IMangrove(payable(params.mangrove)),
                IPoolAddressesProvider(params.poolAddressProvider),
                params.gasreq
            );
        }
        else if (params.seederType == SeederType.ERC4626) {
            return new ERC4626KandelSeeder(
                IMangrove(payable(params.mangrove)),
                params.gasreq
            );
        }
        else if (params.seederType == SeederType.Morpho) {
            return new MorphoKandelSeeder(
                IMangrove(payable(params.mangrove)),
                params.gasreq,
                IMorphoFactory(params.morphoFactory),
                IMorphoRewardDistributor(params.morphoRewardDistributor)
            );
        }
        
        revert("Invalid seeder type");
    }
    
    /**
     * @notice Log deployment information
     */
    function logDeployment(DeploymentParams memory params) internal view {
        console.log("\n==== Vault Deployment Summary ====");
        console.log("Chain ID:", block.chainid);
        console.log("Vault Type:", uint(params.vaultType));
        console.log("Seeder Type:", uint(params.seederType));
        console.log("Base Token:", params.baseToken);
        console.log("Quote Token:", params.quoteToken);
        console.log("Tick Spacing:", params.tickSpacing);
        console.log("Decimals:", params.decimals);
        console.log("Name:", params.name);
        console.log("Symbol:", params.symbol);
        console.log("Oracle:", params.oracle);
        console.log("Owner:", params.owner);
        
        console.log("\nDeployed Contracts:");
        if (params.existingSeeder == address(0)) {
            console.log("Seeder (new):", params.deployedSeeder);
        } else {
            console.log("Seeder (existing):", params.existingSeeder);
        }
        
        if (params.existingFactory == address(0)) {
            console.log("Factory (new):", params.deployedFactory);
        } else {
            console.log("Factory (existing):", params.existingFactory);
        }
        
        console.log("Vault:", params.deployedVault);
        console.log("Kandel:", params.deployedKandel);
        console.log("==============================\n");
    }
}