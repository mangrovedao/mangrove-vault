// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Tick} from "@mgv/lib/core/TickLib.sol";
import {OLKey} from "@mgv/src/core/MgvLib.sol";

/**
 * @title IOracle
 * @notice Interface for oracle contracts that provide price information in the form of a tick
 */
interface IOracle {
  /**
   * @notice Retrieves the current price tick from the oracle
   * @return Tick The current price tick
   * @dev The tick represents the price in a logarithmic scale, as used in Mangrove's order book
   */
  function tick() external view returns (Tick);
}
