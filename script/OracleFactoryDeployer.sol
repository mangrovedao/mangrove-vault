// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MangroveChainlinkOracleFactoryV2} from "../src/oracles/chainlink/v2/MangroveChainlinkOracleFactoryV2.sol";
import {MangroveDiaOracleFactory} from "../src/oracles/dia/MangroveDiaOracleFactory.sol";
import {OracleCombinerFactory} from "../src/oracles/OracleCombinerFactory.sol";
import {MangroveVaultEvents} from "../src/lib/MangroveVaultEvents.sol";

/**
 * @title OracleFactoryDeployer
 * @notice Script to deploy oracle factory contracts for Mangrove
 * @dev Deploys MangroveChainlinkOracleFactoryV2, MangroveDiaOracleFactory, and OracleCombinerFactory
 */
contract OracleFactoryDeployer is Script {
  // Deployed factory contracts
  MangroveChainlinkOracleFactoryV2 public chainlinkOracleFactory;
  MangroveDiaOracleFactory public diaOracleFactory;
  OracleCombinerFactory public oracleCombinerFactory;

  function run() public {
    // Start broadcasting transactions
    vm.startBroadcast();

    // Deploy the Chainlink Oracle Factory V2
    chainlinkOracleFactory = new MangroveChainlinkOracleFactoryV2();
    console.log("MangroveChainlinkOracleFactoryV2 deployed at: %s", address(chainlinkOracleFactory));

    // Deploy the DIA Oracle Factory
    diaOracleFactory = new MangroveDiaOracleFactory();
    console.log("MangroveDiaOracleFactory deployed at: %s", address(diaOracleFactory));

    // Deploy the Oracle Combiner Factory
    oracleCombinerFactory = new OracleCombinerFactory();
    console.log("OracleCombinerFactory deployed at: %s", address(oracleCombinerFactory));

    // Stop broadcasting transactions
    vm.stopBroadcast();

    // Log deployment summary
    console.log("\n=== Oracle Factory Deployment Summary ===");
    console.log("MangroveChainlinkOracleFactoryV2: %s", address(chainlinkOracleFactory));
    console.log("MangroveDiaOracleFactory: %s", address(diaOracleFactory));
    console.log("OracleCombinerFactory: %s", address(oracleCombinerFactory));
  }
}
