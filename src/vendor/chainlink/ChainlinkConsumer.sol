// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "./AggregatorV3Interface.sol";
import {MangroveVaultErrors} from "../../lib/MangroveVaultErrors.sol";
import {TickLib, Tick} from "@mgv/lib/core/TickLib.sol";

/**
 * @title ChainlinkConsumer
 * @notice A library for interacting with Chainlink price feeds
 */
library ChainlinkConsumer {
  /**
   * @notice Get the latest price from a Chainlink price feed
   * @param _aggregator The Chainlink price feed aggregator
   * @return The latest price as a uint256
   * @dev If the aggregator address is zero, it returns 1 as a default value
   * @dev Reverts if the price is negative
   * @dev Notes on safety:
   * * Staleness is not checked because it's assumed that Chainlink will keep an up to date price feed
   * * Arbitrum outages and sequenced down on L2s are not checked because expected to not happen.
   * * In case this the above expected events happen, users should withdraw their shares and trusted managers should remove fees and keep the MangroveVault unpaused.
   */
  function getPrice(AggregatorV3Interface _aggregator) internal view returns (uint256) {
    if (address(_aggregator) == address(0)) return 1;
    (, int256 price,,,) = _aggregator.latestRoundData();
    if (price < 0) revert MangroveVaultErrors.OracleInvalidPrice();
    return uint256(price);
  }

  /**
   * @notice Calculate the tick value based on the price from Chainlink
   * @param _aggregator The Chainlink price feed aggregator
   * @param priceDecimals The number of decimals in the price feed
   * @param baseDecimals The number of decimals in the base token
   * @param quoteDecimals The number of decimals in the quote token
   * @return The calculated tick value as an int256
   * @dev Returns 0 if the aggregator address is zero (price is 1)
   */
  function getTick(
    AggregatorV3Interface _aggregator,
    uint256 priceDecimals,
    uint256 baseDecimals,
    uint256 quoteDecimals
  ) internal view returns (int256) {
    if (address(_aggregator) == address(0)) return 0;
    uint256 price = getPrice(_aggregator);
    if (baseDecimals > quoteDecimals) {
      return Tick.unwrap(TickLib.tickFromVolumes(price, 10 ** (baseDecimals - quoteDecimals) * 10 ** priceDecimals));
    } else {
      return Tick.unwrap(TickLib.tickFromVolumes(price * 10 ** (quoteDecimals - baseDecimals), 10 ** priceDecimals));
    }
  }

  /**
   * @notice Get the number of decimals for a Chainlink price feed
   * @param _aggregator The Chainlink price feed aggregator
   * @return decimals The number of decimals used in the price feed
   * @dev Returns 0 if the aggregator address is zero
   */
  function getDecimals(AggregatorV3Interface _aggregator) internal view returns (uint256 decimals) {
    if (address(_aggregator) != address(0)) decimals = _aggregator.decimals();
  }
}
