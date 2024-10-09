// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MangroveVaultErrors
 * @notice A library containing custom error definitions for the MangroveVault contract
 * @dev This library defines various error types that can be thrown in the MangroveVault contract
 */
library MangroveVaultErrors {
  /**
   * @notice Thrown when a zero address is provided where a non-zero address is required
   * @dev This can occur in various functions in MangroveVault.sol where addresses are expected
   */
  error ZeroAddress();

  /**
   * @notice Thrown when attempting to perform an operation with a zero amount
   * @dev This can occur in mint and burn functions in MangroveVault.sol when the amount is zero
   */
  error ZeroAmount();

  /**
   * @notice Thrown when there's a mismatch between expected and actual initial mint shares
   * @dev This occurs in the mint function in MangroveVault.sol during the initial mint
   * @param expected The expected number of shares
   * @param actual The actual number of shares
   */
  error InitialMintSharesMismatch(uint256 expected, uint256 actual);

  /**
   * @notice Thrown when the oracle returns an invalid (negative) price
   * @dev This occurs in the getPrice function in ChainlinkConsumer.sol
   */
  error OracleInvalidPrice();

  /**
   * @notice Thrown when attempting to withdraw an unauthorized token
   * @dev This can occur in withdrawal functions in MangroveVault.sol
   * @param unauthorizedToken The address of the unauthorized token
   */
  error CannotWithdrawToken(address unauthorizedToken);

  /**
   * @notice Thrown when a fee exceeds the maximum allowed
   * @dev This can occur when setting fees in MangroveVault.sol
   * @param maxAllowed The maximum allowed fee
   * @param attempted The attempted fee
   */
  error MaxFeeExceeded(uint256 maxAllowed, uint256 attempted);

  /**
   * @notice Thrown when a quote amount calculation results in an overflow
   * @dev This can occur in various calculations involving quote amounts in MangroveVault.sol
   */
  error QuoteAmountOverflow();

  /**
   * @notice Thrown when a deposit would exceed the maximum total allowed
   * @dev This occurs in the mint function in MangroveVault.sol
   * @param currentTotal The current total in quote
   * @param nextTotal The next total in quote after the deposit
   * @param maxTotal The maximum allowed total in quote
   */
  error DepositExceedsMaxTotal(uint256 currentTotal, uint256 nextTotal, uint256 maxTotal);

  /**
   * @notice Thrown when an unauthorized contract attempts to perform a swap
   * @dev This occurs in swap-related functions in MangroveVault.sol
   * @param target The address of the unauthorized swap contract
   */
  error UnauthorizedSwapContract(address target);

  /**
   * @notice Thrown when slippage exceeds the allowed amount in a transaction
   * @dev This can occur in mint, burn, and swap functions in MangroveVault.sol
   * @param expected The expected amount
   * @param received The actual received amount
   */
  error SlippageExceeded(uint256 expected, uint256 received);
}
