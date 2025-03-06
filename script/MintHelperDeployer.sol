// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MintHelperV1} from "../src/mint-helper/MintHelperV1.sol";

/**
 * @title MintHelperDeployer
 * @notice Deployment script for the MintHelperV1 contract
 * @dev This script deploys the MintHelperV1 contract and logs its address
 */
contract MintHelperDeployer is Script {
  MintHelperV1 public mintHelper;

  function run() public {
    // Start broadcasting transactions
    vm.broadcast();

    // Deploy the MintHelperV1 contract
    mintHelper = new MintHelperV1();

    // Log the deployed contract address
    console.log("MintHelperV1 deployed at: %s", address(mintHelper));
  }
}
