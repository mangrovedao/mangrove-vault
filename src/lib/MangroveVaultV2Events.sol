// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Tick} from "@mgv/lib/core/TickLib.sol";

/**
 * @title MangroveVaultV2Events
 * @notice Library containing events emitted by the MangroveVault contract
 * @dev This library defines events that are used to log important state changes and actions in the MangroveVault
 */
library MangroveVaultV2Events {
  /**
   * @notice Emitted when oracle configuration is updated
   * @param oracleEnabled Whether the oracle is enabled
   * @param oracle Address of the oracle contract
   * @param storedTick The stored tick value
   * @param maxTickDeviation Maximum allowed deviation in ticks
   */
  event OracleConfigUpdated(bool oracleEnabled, address oracle, Tick storedTick, uint24 maxTickDeviation);

  /**
   * @notice Emitted when a new guardian is set
   * @param newGuardian Address of the new guardian
   */
  event GuardianSet(address indexed newGuardian);

  /**
   * @notice Emitted when a position update is proposed
   * @param targetTick The target tick for the position update
   * @param executeTime Timestamp when the update can be executed
   */
  event PositionUpdateProposed(Tick targetTick, uint256 executeTime);

  /**
   * @notice Emitted when a proposed position update is disputed
   */
  event PositionUpdateDisputed();

  /**
   * @notice Emitted when a position update is executed
   * @param targetTick The tick that was set during execution
   */
  event PositionUpdateExecuted(Tick targetTick);

  /**
   * @notice Emitted when a position update is canceled
   */
  event PositionUpdateCanceled();
}
