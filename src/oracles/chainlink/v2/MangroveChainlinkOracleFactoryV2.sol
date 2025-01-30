// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MangroveChainlinkOracleV2, ChainlinkFeed, ERC4626Feed} from "./MangroveChainlinkOracleV2.sol";
import {MangroveVaultEvents} from "../../../lib/MangroveVaultEvents.sol";

/**
 * @title MangroveChainlinkOracleFactory
 * @notice Factory contract for creating MangroveChainlinkOracle instances
 */
contract MangroveChainlinkOracleFactoryV2 {
  /**
   * @notice Mapping to track if an address is a created oracle
   */
  mapping(address => bool) public isOracle;

  /**
   * @notice Creates a new MangroveChainlinkOracle
   * @param baseFeed1 ChainlinkFeed struct for the first base feed
   * @param baseFeed2 ChainlinkFeed struct for the second base feed
   * @param quoteFeed1 ChainlinkFeed struct for the first quote feed
   * @param quoteFeed2 ChainlinkFeed struct for the second quote feed
   * @param baseVault ERC4626Feed struct for the base vault
   * @param quoteVault ERC4626Feed struct for the quote vault
   * @param salt Unique value for deterministic address generation
   * @return oracle The newly created MangroveChainlinkOracle
   */
  function create(
    ChainlinkFeed calldata baseFeed1,
    ChainlinkFeed calldata baseFeed2,
    ChainlinkFeed calldata quoteFeed1,
    ChainlinkFeed calldata quoteFeed2,
    ERC4626Feed calldata baseVault,
    ERC4626Feed calldata quoteVault,
    bytes32 salt
  ) external returns (MangroveChainlinkOracleV2 oracle) {
    oracle =
      new MangroveChainlinkOracleV2{salt: salt}(baseFeed1, baseFeed2, quoteFeed1, quoteFeed2, baseVault, quoteVault);
    isOracle[address(oracle)] = true;
    emit MangroveVaultEvents.OracleCreated(msg.sender, address(oracle));
  }
}
