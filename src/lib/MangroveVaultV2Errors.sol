// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MangroveVaultV2Errors
 * @notice A library containing custom error definitions for the MangroveVault contract
 * @dev This library defines various error types that can be thrown in the MangroveVault contract
 */
library MangroveVaultV2Errors {
  /**
   * @notice Thrown when trying to use oracle functionality while the oracle is disabled
   */
  error OracleNotEnabled();

  /**
   * @notice Thrown when trying to disable oracle that is already enabled
   */
  error OracleEnabled();

  /**
   * @notice Thrown when the tick deviation exceeds the maximum allowed deviation
   */
  error TickDeviationExceeded();

  /**
   * @notice Thrown when attempting to execute a position update before the required delay has passed
   */
  error PositionUpdateNotReady();

  /**
   * @notice Thrown when attempting to operate on a non-existent position update
   */
  error NoPositionUpdatePending();

  /**
   * @notice Thrown when attempting to execute a position update that has been disputed
   */
  error PositionUpdateIsDisputed();

  /**
   * @notice Thrown when a function restricted to the guardian is called by another address
   */
  error OnlyGuardian();

  /**
   * @notice Thrown when an invalid maximum tick deviation value is provided
   */
  error InvalidMaxTickDeviation();
}
