// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MangroveChainlinkOracle} from "./MangroveChainlinkOracle.sol";
import {MangroveVaultEvents} from "../../lib/MangroveVaultEvents.sol";
/**
 * @title ChainlinkFeed
 * @notice Struct to hold Chainlink feed information
 * @param feed Address of the Chainlink price feed
 * @param baseDecimals Number of decimals for the base token
 * @param quoteDecimals Number of decimals for the quote token
 */

struct ChainlinkFeed {
  address feed;
  uint256 baseDecimals;
  uint256 quoteDecimals;
}

/**
 * @title MangroveChainlinkOracleFactory
 * @notice Factory contract for creating MangroveChainlinkOracle instances
 */
contract MangroveChainlinkOracleFactory {
  /**
   * @notice Mapping to track if an address is a created oracle
   */
  mapping(address => bool) public isOracle;

  /**
   * @notice Creates a new MangroveChainlinkOracle
   * @param baseFeed1 ChainlinkFeed struct for the first base feed
   * @param quoteFeed1 ChainlinkFeed struct for the first quote feed
   * @param baseFeed2 ChainlinkFeed struct for the second base feed
   * @param quoteFeed2 ChainlinkFeed struct for the second quote feed
   * @param salt Unique value for deterministic address generation
   * @return oracle The newly created MangroveChainlinkOracle
   */
  function create(
    ChainlinkFeed memory baseFeed1,
    ChainlinkFeed memory quoteFeed1,
    ChainlinkFeed memory baseFeed2,
    ChainlinkFeed memory quoteFeed2,
    bytes32 salt
  ) external returns (MangroveChainlinkOracle oracle) {
    oracle = new MangroveChainlinkOracle{salt: salt}(
      baseFeed1.feed,
      quoteFeed1.feed,
      baseFeed2.feed,
      quoteFeed2.feed,
      baseFeed1.baseDecimals,
      baseFeed1.quoteDecimals,
      baseFeed2.baseDecimals,
      baseFeed2.quoteDecimals,
      quoteFeed1.baseDecimals,
      quoteFeed1.quoteDecimals,
      quoteFeed2.baseDecimals,
      quoteFeed2.quoteDecimals
    );
    isOracle[address(oracle)] = true;
    emit MangroveVaultEvents.OracleCreated(msg.sender, address(oracle));
  }
}
