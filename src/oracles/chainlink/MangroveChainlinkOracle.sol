// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOracle} from "../IOracle.sol";
import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {Tick} from "@mgv/lib/core/TickLib.sol";
import {ChainlinkConsumer} from "../../vendor/chainlink/ChainlinkConsumer.sol";
import {AggregatorV3Interface} from "../../vendor/chainlink/AggregatorV3Interface.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MangroveVaultErrors} from "../../lib/MangroveVaultErrors.sol";
// price is quote/base, on mangrove it's inbound/outbound
// inbound is the tokens received by the maker, outbound is the tokens sent by the maker
// we want to output a tick corresponding to the price on the inbound=base/outbound=quote market.

// This oracle adapter is to support up to 2 feeds to combine, plus two inverse feeds.
// i.e. if we have A/B, B/C, D/C, and E/D feeds, we can combine them into A/E.

contract MangroveChainlinkOracle is IOracle {
  using ChainlinkConsumer for AggregatorV3Interface;
  using Math for uint256;

  AggregatorV3Interface public immutable baseFeed1;
  AggregatorV3Interface public immutable baseFeed2;
  AggregatorV3Interface public immutable quoteFeed1;
  AggregatorV3Interface public immutable quoteFeed2;

  uint256 public immutable baseFeed1Decimals;
  uint256 public immutable baseFeed2Decimals;
  uint256 public immutable quoteFeed1Decimals;
  uint256 public immutable quoteFeed2Decimals;

  uint256 public immutable baseFeed1BaseDecimals;
  uint256 public immutable baseFeed1QuoteDecimals;

  uint256 public immutable baseFeed2BaseDecimals;
  uint256 public immutable baseFeed2QuoteDecimals;

  uint256 public immutable quoteFeed1BaseDecimals;
  uint256 public immutable quoteFeed1QuoteDecimals;

  uint256 public immutable quoteFeed2BaseDecimals;
  uint256 public immutable quoteFeed2QuoteDecimals;

  constructor(
    AggregatorV3Interface _baseFeed1,
    AggregatorV3Interface _baseFeed2,
    AggregatorV3Interface _quoteFeed1,
    AggregatorV3Interface _quoteFeed2,
    uint256 _baseFeed1BaseDecimals,
    uint256 _baseFeed1QuoteDecimals,
    uint256 _baseFeed2BaseDecimals,
    uint256 _baseFeed2QuoteDecimals,
    uint256 _quoteFeed1BaseDecimals,
    uint256 _quoteFeed1QuoteDecimals,
    uint256 _quoteFeed2BaseDecimals,
    uint256 _quoteFeed2QuoteDecimals
  ) {
    baseFeed1 = _baseFeed1;
    baseFeed2 = _baseFeed2;
    quoteFeed1 = _quoteFeed1;
    quoteFeed2 = _quoteFeed2;

    baseFeed1Decimals = baseFeed1.getDecimals();
    baseFeed2Decimals = baseFeed2.getDecimals();
    quoteFeed1Decimals = quoteFeed1.getDecimals();
    quoteFeed2Decimals = quoteFeed2.getDecimals();

    baseFeed1BaseDecimals = _baseFeed1BaseDecimals;
    baseFeed1QuoteDecimals = _baseFeed1QuoteDecimals;
    baseFeed2BaseDecimals = _baseFeed2BaseDecimals;
    baseFeed2QuoteDecimals = _baseFeed2QuoteDecimals;
    quoteFeed1BaseDecimals = _quoteFeed1BaseDecimals;
    quoteFeed1QuoteDecimals = _quoteFeed1QuoteDecimals;
    quoteFeed2BaseDecimals = _quoteFeed2BaseDecimals;
    quoteFeed2QuoteDecimals = _quoteFeed2QuoteDecimals;
  }

  function tick() public view returns (Tick) {
    return Tick.wrap(
      baseFeed1.getTick(baseFeed1Decimals, baseFeed1BaseDecimals, baseFeed1QuoteDecimals)
        + baseFeed2.getTick(baseFeed2Decimals, baseFeed2BaseDecimals, baseFeed2QuoteDecimals)
        - quoteFeed1.getTick(quoteFeed1Decimals, quoteFeed1BaseDecimals, quoteFeed1QuoteDecimals)
        - quoteFeed2.getTick(quoteFeed2Decimals, quoteFeed2BaseDecimals, quoteFeed2QuoteDecimals)
    );
  }
}
