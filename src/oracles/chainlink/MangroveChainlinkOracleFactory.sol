// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MangroveChainlinkOracle} from "./MangroveChainlinkOracle.sol";

struct ChainlinkFeed {
  address feed;
  uint256 baseDecimals;
  uint256 quoteDecimals;
}

contract MangroveChainlinkOracleFactory {
  event OracleCreated(address creator, address oracle);

  mapping(address => bool) public isOracle;

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
    emit OracleCreated(msg.sender, address(oracle));
  }
}
