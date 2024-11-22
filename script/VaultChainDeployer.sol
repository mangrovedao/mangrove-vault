// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MangroveVaultFactory, MangroveVault} from "../src/MangroveVaultFactory.sol";
import {
  MangroveChainlinkOracleFactory,
  ChainlinkFeed,
  MangroveChainlinkOracle
} from "../src/oracles/chainlink/MangroveChainlinkOracleFactory.sol";
import {GeometricKandelExtra} from "../src/lib/GeometricKandelExtra.sol";

import {MgvReader, Market, MarketConfig} from "@mgv/src/periphery/MgvReader.sol";
import {AbstractKandelSeeder} from
  "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/AbstractKandelSeeder.sol";

contract VaultChainDeployer is Script {
  MangroveVaultFactory public vaultFactory;
  MangroveVault public vault;
  MangroveChainlinkOracleFactory public oracleFactory;
  MangroveChainlinkOracle public oracle;

  AbstractKandelSeeder public seeder;
  MgvReader public mgvReader;

  function getFirstMarket() public view returns (Market memory) {
    (Market[] memory markets, MarketConfig[] memory configs) = mgvReader.openMarkets(0, 1);
    if (!configs[0].config01.active || !configs[0].config10.active) {
      revert("One market is not active on mangrove reader");
    }
    return markets[0];
  }

  function run() public {
    mgvReader = MgvReader(vm.envAddress("MANGROVE_READER"));
    seeder = AbstractKandelSeeder(vm.envAddress("KANDEL_SEEDER"));

    Market memory market = getFirstMarket();

    console.log("Market: %s/%s", market.tkn0, market.tkn1);

    vm.broadcast();
    oracleFactory = new MangroveChainlinkOracleFactory();

    console.log("Oracle factory: %s", address(oracleFactory));

    ChainlinkFeed memory emptyFeed;

    vm.broadcast();
    oracle = oracleFactory.create(emptyFeed, emptyFeed, emptyFeed, emptyFeed, bytes32(0));

    console.log("Oracle: %s", address(oracle));
    bytes memory contructorArgs = abi.encode(address(0), address(0), address(0), address(0), 0, 0, 0, 0, 0, 0, 0, 0);
    console.logBytes(contructorArgs);

    vm.broadcast();
    vaultFactory = new MangroveVaultFactory();

    console.log("Vault factory: %s", address(vaultFactory));

    vm.broadcast();
    vault = vaultFactory.createVault(
      seeder,
      market.tkn0,
      market.tkn1,
      market.tickSpacing,
      18,
      "Mangrove Vault Initializer",
      "MGV INIT",
      address(oracle),
      msg.sender
    );
  
    console.log("Vault: %s", address(vault));
    contructorArgs = abi.encode(
      seeder,
      market.tkn0,
      market.tkn1,
      market.tickSpacing,
      18,
      "Mangrove Vault Initializer",
      "MGV INIT",
      address(oracle),
      vault.owner()
    );
    console.logBytes(contructorArgs);
    
    vm.broadcast();
    vault.setMaxTotalInQuote(0);
  }
}
