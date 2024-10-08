// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOracle} from "../IOracle.sol";
import {Tick} from "@mgv/lib/core/TickLib.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OLKey} from "@mgv/src/core/MgvLib.sol";

/**
 * @title MockOracle
 * @notice A mock implementation of the IOracle interface for testing purposes
 * @dev This contract allows setting and retrieving a mock tick value
 */
contract MockOracle is IOracle, Ownable(msg.sender) {
  /// @notice The current tick value of the mock oracle
  Tick public tick;

  /**
   * @notice Constructs a new MockOracle with an initial tick value
   * @param _tick The initial tick value to set
   */
  constructor(Tick _tick) {
    tick = _tick;
  }

  /**
   * @notice Sets a new tick value
   * @param _tick The new tick value to set
   * @dev This function can only be called by the contract owner
   */
  function setTick(Tick _tick) external onlyOwner {
    tick = _tick;
  }
}
