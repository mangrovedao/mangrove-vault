// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DiaOracleV2} from "./DiaOracleV2.sol";
import {Tick, TickLib} from "@mgv/lib/core/TickLib.sol";

/**
 * @title DiaOracleV2Consumer
 * @notice Library for interacting with DIA Oracle V2 to get price information in Mangrove tick format
 */
library DiaOracleV2Consumer {
  /**
   * @notice Gets the current price from the DIA Oracle
   * @param _oracle The DIA Oracle V2 instance to query
   * @param key The key identifier for the price feed
   * @return value The price value returned by the oracle
   * @dev Returns 1 if the oracle address is zero
   */
  function getPrice(DiaOracleV2 _oracle, bytes32 key) internal view returns (uint256 value) {
    if (address(_oracle) == address(0)) return 1;
    (value,) = _oracle.getValue(string(abi.encodePacked(key)));
  }

  /**
   * @notice Converts a DIA Oracle price to a Mangrove tick
   * @param _oracle The DIA Oracle V2 instance to query
   * @param key The key identifier for the price feed
   * @param priceDecimals The number of decimals in the price returned by the oracle
   * @param baseDecimals The number of decimals for the base token
   * @param quoteDecimals The number of decimals for the quote token
   * @return The price tick in Mangrove's logarithmic format
   * @dev Handles decimal normalization between tokens with different decimal places
   * @dev Returns 0 if the oracle address is zero
   */
  function getTick(DiaOracleV2 _oracle, bytes32 key, uint256 priceDecimals, uint256 baseDecimals, uint256 quoteDecimals)
    internal
    view
    returns (int256)
  {
    if (address(_oracle) == address(0)) return 0;
    uint256 price = getPrice(_oracle, key);
    if (baseDecimals > quoteDecimals) {
      return Tick.unwrap(TickLib.tickFromVolumes(price, 10 ** (baseDecimals - quoteDecimals) * 10 ** priceDecimals));
    } else {
      return Tick.unwrap(TickLib.tickFromVolumes(price * 10 ** (quoteDecimals - baseDecimals), 10 ** priceDecimals));
    }
  }
}
