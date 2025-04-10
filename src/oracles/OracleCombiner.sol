// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOracle} from "./IOracle.sol";
import {OracleConsumer} from "./OracleComsumer.sol";
import {Tick} from "@mgv/lib/core/TickLib.sol";

/**
 * @title OracleCombiner
 * @notice An oracle that combines up to 4 other oracles by adding their ticks together
 * @dev This contract adds the ticks from up to 4 different oracles to create a single price oracle.
 *      Unlike some other oracle combiners, this one only performs addition of ticks (no subtraction).
 *      For example, if you have ticks from oracles A, B, C, and D, the resulting tick will be A+B+C+D.
 *      This is useful for creating complex pricing relationships where multiple factors need to be combined.
 */
contract OracleCombiner is IOracle {
  using OracleConsumer for IOracle;

  /// @notice The first oracle to combine
  IOracle public immutable oracle1;
  /// @notice The second oracle to combine
  IOracle public immutable oracle2;
  /// @notice The third oracle to combine
  IOracle public immutable oracle3;
  /// @notice The fourth oracle to combine
  IOracle public immutable oracle4;

  /**
   * @notice Constructs a new OracleCombiner
   * @param _oracle1 The first oracle to combine (required)
   * @param _oracle2 The second oracle to combine (optional, can be zero address)
   * @param _oracle3 The third oracle to combine (optional, can be zero address)
   * @param _oracle4 The fourth oracle to combine (optional, can be zero address)
   * @dev Any oracle that is set to the zero address will be ignored in the tick calculation
   */
  constructor(address _oracle1, address _oracle2, address _oracle3, address _oracle4) {
    oracle1 = IOracle(_oracle1);
    oracle2 = IOracle(_oracle2);
    oracle3 = IOracle(_oracle3);
    oracle4 = IOracle(_oracle4);
  }

  /**
   * @notice Calculates the current price tick by combining all oracles
   * @dev This function adds the ticks from all non-zero oracle addresses to produce a single tick.
   *      For any oracle address that is set to zero, its tick contribution will be 0.
   * @return _tick The calculated combined price tick for use in Mangrove's order book
   */
  function tick() public view returns (Tick _tick) {
    _tick = Tick.wrap(
      OracleConsumer.getTick(oracle1) + OracleConsumer.getTick(oracle2) + OracleConsumer.getTick(oracle3)
        + OracleConsumer.getTick(oracle4)
    );
  }
}
