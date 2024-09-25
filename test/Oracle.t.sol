// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {MangroveChainlinkOracle, AggregatorV3Interface} from "../src/oracles/chainlink/MangroveChainlinkOracle.sol";

contract OracleTest is Test {
  MangroveChainlinkOracle public oracle;

  uint256 public arbitrumFork;

  function setUp() public {
    arbitrumFork = vm.createFork(vm.envString("ARBITRUM_RPC_URL"));
    vm.selectFork(arbitrumFork);
    vm.rollFork(238_624_545);
    oracle = new MangroveChainlinkOracle(
      AggregatorV3Interface(0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612),
      AggregatorV3Interface(address(0)),
      AggregatorV3Interface(0x6ce185860a4963106506C203335A2910413708e9),
      AggregatorV3Interface(address(0)),
      18,
      18,
      0,
      0,
      8,
      18,
      0,
      0
    );
  }

  function test_Tick() public {
    console.log(oracle.tick().outboundFromInbound(1e8));
  }
}
