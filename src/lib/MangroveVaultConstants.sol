// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library MangroveVaultConstants {
  /// @notice The precision of the performance fee.
  uint256 internal constant PERFORMANCE_FEE_PRECISION = 1e5;
  /// @notice The maximum performance fee.
  uint16 internal constant MAX_PERFORMANCE_FEE = 5e4;

  /// @notice The precision of the management fee.
  uint256 internal constant MANAGEMENT_FEE_PRECISION = 1e5 * 365 days;
  /// @notice The maximum management fee.
  uint16 internal constant MAX_MANAGEMENT_FEE = 5e3;

  /// @notice The minimum amount of liquidity to be able to withdraw (dead share value to mitigate inflation attacks)
  uint256 internal constant MINIMUM_LIQUIDITY = 1e3;
}
