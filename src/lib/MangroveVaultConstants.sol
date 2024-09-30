// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library MangroveVaultConstants {
  uint internal constant FEE_PRECISION = 1e18;
  uint internal constant MAX_PERFORMANCE_FEE = 0.5e18;
  /// @notice The minimum amount of liquidity to be able to withdraw (dead share value to mitigate inflation attacks)
  uint256 internal constant MINIMUM_LIQUIDITY = 10 ** 3;
}
