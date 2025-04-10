// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOracle} from "./IOracle.sol";
import {Tick} from "@mgv/lib/core/TickLib.sol";

/**
 * @title OracleConsumer
 * @notice Library for interacting with oracle contracts
 */
library OracleConsumer {
  /**
   * @notice Gets the tick value from an oracle
   * @param oracle The oracle contract to query
   * @return tick The unwrapped tick value as an int256
   * @dev Returns 0 if the oracle address is zero
   */
  function getTick(IOracle oracle) internal view returns (int256 tick) {
    if (address(oracle) != address(0)) {
      tick = Tick.unwrap(oracle.tick());
    }
  }
}
