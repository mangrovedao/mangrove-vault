// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {OracleCombiner} from "../src/oracles/OracleCombiner.sol";
import {OracleCombinerFactory} from "../src/oracles/OracleCombinerFactory.sol";
import {IOracle} from "../src/oracles/IOracle.sol";
import {Tick} from "@mgv/lib/core/TickLib.sol";

/**
 * @title MockOracle
 * @notice A mock oracle contract that returns a configurable tick value
 */
contract MockOracle is IOracle {
  int256 private _tickValue;

  constructor(int256 tickValue) {
    _tickValue = tickValue;
  }

  function setTick(int256 tickValue) external {
    _tickValue = tickValue;
  }

  function tick() external view override returns (Tick) {
    return Tick.wrap(_tickValue);
  }
}

contract OracleCombinerTest is Test {
  // Constants
  int256 constant FIRST_TICK = 1000;
  int256 constant SECOND_TICK = 500;

  // Contracts
  OracleCombinerFactory factory;
  MockOracle firstOracle;
  MockOracle secondOracle;

  function setUp() public {
    // Deploy factory
    factory = new OracleCombinerFactory();

    // Deploy mock oracles with initial ticks
    firstOracle = new MockOracle(FIRST_TICK);
    secondOracle = new MockOracle(SECOND_TICK);
  }

  function test_emptyCombiner() public {
    // Create combiner with all empty oracles
    OracleCombiner combiner = new OracleCombiner(address(0), address(0), address(0), address(0));

    // Should return tick 0 since all oracles are empty
    assertEq(Tick.unwrap(combiner.tick()), 0, "Empty combiner should return tick 0");
  }

  function test_combinerWithSingleOracle() public {
    // Create combiner with only first oracle
    OracleCombiner combiner = new OracleCombiner(address(firstOracle), address(0), address(0), address(0));

    // Should return the first oracle's tick
    assertEq(Tick.unwrap(combiner.tick()), FIRST_TICK, "Combiner should return first oracle's tick");
  }

  function test_combinerWithTwoOracles() public {
    // Create combiner with two oracles
    OracleCombiner combiner = new OracleCombiner(address(firstOracle), address(secondOracle), address(0), address(0));

    // Should return the sum of both oracle ticks (1000 + 500 = 1500)
    assertEq(Tick.unwrap(combiner.tick()), FIRST_TICK + SECOND_TICK, "Combiner should return sum of oracle ticks");
  }

  function test_combinerWithAllFourOracles() public {
    // Create two more oracles with different ticks
    MockOracle thirdOracle = new MockOracle(200);
    MockOracle fourthOracle = new MockOracle(300);

    // Create combiner with all four oracles
    OracleCombiner combiner =
      new OracleCombiner(address(firstOracle), address(secondOracle), address(thirdOracle), address(fourthOracle));

    // Should return the sum of all four oracle ticks (1000 + 500 + 200 + 300 = 2000)
    assertEq(
      Tick.unwrap(combiner.tick()),
      FIRST_TICK + SECOND_TICK + 200 + 300,
      "Combiner should return sum of all oracle ticks"
    );
  }

  function test_combinerTickChange() public {
    // Create combiner with two oracles
    OracleCombiner combiner = new OracleCombiner(address(firstOracle), address(secondOracle), address(0), address(0));

    // Get initial tick
    int256 initialTick = Tick.unwrap(combiner.tick());

    // Change first oracle's tick
    firstOracle.setTick(2000);

    // Get new tick - should be 2000 + 500 = 2500
    int256 newTick = Tick.unwrap(combiner.tick());
    assertEq(newTick, 2000 + SECOND_TICK, "New tick should be updated sum of oracle ticks");

    // Verify the tick changed
    assertTrue(initialTick != newTick, "Tick should change after oracle update");
  }

  function test_factoryComputeOracleAddress() public {
    // Test salt
    bytes32 salt = keccak256(abi.encodePacked("test_salt"));

    // Compute expected address
    address expectedAddress =
      factory.computeOracleAddress(address(firstOracle), address(secondOracle), address(0), address(0), salt);

    // Deploy the oracle using the factory
    OracleCombiner combiner = factory.create(address(firstOracle), address(secondOracle), address(0), address(0), salt);

    // Verify address and factory recognition
    assertEq(address(combiner), expectedAddress, "Deployed combiner should be at the expected address");
    assertTrue(factory.isOracle(address(combiner)), "Factory should recognize the deployed combiner");
  }

  function test_factoryDeployMultipleOracles() public {
    // Test salts
    bytes32 salt1 = keccak256(abi.encodePacked("test_salt_1"));
    bytes32 salt2 = keccak256(abi.encodePacked("test_salt_2"));

    // Deploy two oracles with different parameters
    OracleCombiner combiner1 =
      factory.create(address(firstOracle), address(secondOracle), address(0), address(0), salt1);

    OracleCombiner combiner2 = factory.create(address(firstOracle), address(0), address(0), address(0), salt2);

    // Verify different addresses
    assertTrue(address(combiner1) != address(combiner2), "Different combiner instances should have different addresses");

    // Verify both are recognized by factory
    assertTrue(factory.isOracle(address(combiner1)), "Factory should recognize the first combiner");
    assertTrue(factory.isOracle(address(combiner2)), "Factory should recognize the second combiner");

    // Verify correct tick outputs
    assertEq(Tick.unwrap(combiner1.tick()), FIRST_TICK + SECOND_TICK, "First combiner should return sum of two oracles");
    assertEq(Tick.unwrap(combiner2.tick()), FIRST_TICK, "Second combiner should return only first oracle's tick");
  }
}
