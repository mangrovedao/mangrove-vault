// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FundsState, KandelPosition} from "../MangroveVault.sol";
import {Tick} from "@mgv/lib/core/TickLib.sol";

/**
 * @title MangroveVaultEvents
 * @notice Library containing events emitted by the MangroveVault contract
 * @dev This library defines events that are used to log important state changes and actions in the MangroveVault
 */
library MangroveVaultEvents {
  /**
   * @notice Emitted when a new vault is created
   * @param seeder Address of the account that created the vault
   * @param olKey Offer list key for the outbound-inbound market
   * @param loKey Offer list key for the inbound-outbound market
   * @param vault Address of the newly created vault
   * @param oracle Address of the oracle used by the vault
   * @param kandel Address of the Kandel strategy associated with the vault
   */
  event VaultCreated(
    address indexed seeder, bytes32 indexed olKey, bytes32 indexed loKey, address vault, address oracle, address kandel
  );

  /**
   * @notice Emitted when a swap contract is added or removed from the allowed list
   * @param swapContract Address of the swap contract
   * @param allowed Boolean indicating whether the contract is allowed or not
   */
  event SwapContractAllowed(address indexed swapContract, bool allowed);

  /**
   * @notice Emitted when a swap operation is performed
   * @param pool Address of the pool where the swap occurred
   * @param baseAmountChange Change in base token amount (positive for increase, negative for decrease; from vault's perspective)
   * @param quoteAmountChange Change in quote token amount (positive for increase, negative for decrease; from vault's perspective)
   * @param sell Boolean indicating whether it's a sell (true) or buy (false) operation
   */
  event Swap(address pool, int256 baseAmountChange, int256 quoteAmountChange, bool sell);

  /**
   * @notice Emitted when shares are minted
   * @param user Address of the user minting shares
   * @param shares Number of shares minted
   * @param baseAmount Amount of base tokens used for minting
   * @param quoteAmount Amount of quote tokens used for minting
   * @param tick Current tick at the time of minting
   */
  event Mint(address indexed user, uint256 shares, uint256 baseAmount, uint256 quoteAmount, int256 tick);

  /**
   * @notice Emitted when shares are burned
   * @param user Address of the user burning shares
   * @param shares Number of shares burned
   * @param baseAmount Amount of base tokens received from burning
   * @param quoteAmount Amount of quote tokens received from burning
   * @param tick Current tick at the time of burning
   */
  event Burn(address indexed user, uint256 shares, uint256 baseAmount, uint256 quoteAmount, int256 tick);

  /**
   * @notice Emitted when the Kandel position is set or updated
   * @param tickIndex0 Tick index of the first offer
   * @param tickOffset Tick offset between offers
   * @param gasprice Gas price for the Kandel strategy
   * @param gasreq Gas requirement for the Kandel strategy
   * @param stepSize Step size for the Kandel strategy
   * @param pricePoints Number of price points for the Kandel strategy
   * @param fundsState Current state of the funds
   */
  event SetKandelPosition(
    int256 tickIndex0,
    uint256 tickOffset,
    uint32 gasprice,
    uint24 gasreq,
    uint32 stepSize,
    uint32 pricePoints,
    FundsState fundsState
  );

  /**
   * @notice Emitted when interest is accrued
   * @param feeShares Number of shares allocated as fees
   * @param newTotalInQuote New total value in quote tokens after accruing interest
   * @param timestamp Timestamp when the interest was accrued
   */
  event AccrueInterest(uint256 feeShares, uint256 newTotalInQuote, uint256 timestamp);

  /**
   * @notice Emitted when the last total value in quote tokens is updated
   * @param lastTotalInQuote Updated last total value in quote tokens
   * @param timestamp Timestamp when the update occurred
   */
  event UpdateLastTotalInQuote(uint256 lastTotalInQuote, uint256 timestamp);

  /**
   * @notice Emitted when the fee data is set
   * @param performanceFee Performance fee
   * @param managementFee Management fee
   * @param feeRecipient Fee recipient
   */
  event SetFeeData(uint256 performanceFee, uint256 managementFee, address feeRecipient);

  /**
   * @notice Emitted when the maximum total value in quote token is set
   * @param maxTotalInQuote Maximum total value in quote token
   */
  event SetMaxTotalInQuote(uint256 maxTotalInQuote);

  /**
   * @notice Emitted when a new oracle is created
   * @param creator Address of the account that created the oracle
   * @param oracle Address of the newly created oracle
   */
  event OracleCreated(address creator, address oracle);

  /**
   * @notice Internal function to emit the SetKandelPosition event
   * @param position KandelPosition struct containing the position details
   */
  function emitSetKandelPosition(KandelPosition memory position) internal {
    emit SetKandelPosition(
      Tick.unwrap(position.tickIndex0),
      position.tickOffset,
      position.params.gasprice,
      position.params.gasreq,
      position.params.stepSize,
      position.params.pricePoints,
      position.fundsState
    );
  }
}
