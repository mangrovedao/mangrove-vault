// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOracle} from "../IOracle.sol";
import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {Tick} from "@mgv/lib/core/TickLib.sol";
import {ChainlinkConsumer} from "../../vendor/chainlink/ChainlinkConsumer.sol";
import {AggregatorV3Interface} from "../../vendor/chainlink/AggregatorV3Interface.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MangroveVaultErrors} from "../../lib/MangroveVaultErrors.sol";

/**
 * @title MangroveChainlinkOracle
 * @notice An oracle adapter for Mangrove that supports up to 4 Chainlink price feeds
 * @dev This contract combines up to 4 Chainlink price feeds to create a single price oracle for Mangrove
 *      It supports up to 2 feeds to combine for the base price, plus two inverse feeds for the quote price.
 *      For example, if we have A/B, B/C, D/C, and E/D feeds, we can combine them into A/E.
 *
 * @dev The price is represented as quote/base, while on Mangrove it's inbound/outbound.
 *      Inbound tokens are received by the maker, outbound tokens are sent by the maker.
 *      The oracle outputs a tick corresponding to the price on the inbound=base/outbound=quote market.
 */
contract MangroveChainlinkOracle is IOracle {
  using ChainlinkConsumer for AggregatorV3Interface;
  using Math for uint256;

  /// @notice The first Chainlink price feed for the base token
  AggregatorV3Interface public immutable baseFeed1;
  /// @notice The second Chainlink price feed for the base token
  AggregatorV3Interface public immutable baseFeed2;
  /// @notice The first Chainlink price feed for the quote token
  AggregatorV3Interface public immutable quoteFeed1;
  /// @notice The second Chainlink price feed for the quote token
  AggregatorV3Interface public immutable quoteFeed2;

  /// @notice The number of decimals in the price returned by baseFeed1
  uint256 public immutable baseFeed1Decimals;
  /// @notice The number of decimals in the price returned by baseFeed2
  uint256 public immutable baseFeed2Decimals;
  /// @notice The number of decimals in the price returned by quoteFeed1
  uint256 public immutable quoteFeed1Decimals;
  /// @notice The number of decimals in the price returned by quoteFeed2
  uint256 public immutable quoteFeed2Decimals;

  /// @notice The number of decimals for the base token in baseFeed1
  uint256 public immutable baseFeed1BaseDecimals;
  /// @notice The number of decimals for the quote token in baseFeed1
  uint256 public immutable baseFeed1QuoteDecimals;

  /// @notice The number of decimals for the base token in baseFeed2
  uint256 public immutable baseFeed2BaseDecimals;
  /// @notice The number of decimals for the quote token in baseFeed2
  uint256 public immutable baseFeed2QuoteDecimals;

  /// @notice The number of decimals for the base token in quoteFeed1
  uint256 public immutable quoteFeed1BaseDecimals;
  /// @notice The number of decimals for the quote token in quoteFeed1
  uint256 public immutable quoteFeed1QuoteDecimals;

  /// @notice The number of decimals for the base token in quoteFeed2
  uint256 public immutable quoteFeed2BaseDecimals;
  /// @notice The number of decimals for the quote token in quoteFeed2
  uint256 public immutable quoteFeed2QuoteDecimals;

  /**
   * @notice Constructs a new MangroveChainlinkOracle
   * @param _baseFeed1 Address of the first base price feed
   * @param _baseFeed2 Address of the second base price feed
   * @param _quoteFeed1 Address of the first quote price feed
   * @param _quoteFeed2 Address of the second quote price feed
   * @param _baseFeed1BaseDecimals Number of decimals for the base token in baseFeed1
   * @param _baseFeed1QuoteDecimals Number of decimals for the quote token in baseFeed1
   * @param _baseFeed2BaseDecimals Number of decimals for the base token in baseFeed2
   * @param _baseFeed2QuoteDecimals Number of decimals for the quote token in baseFeed2
   * @param _quoteFeed1BaseDecimals Number of decimals for the base token in quoteFeed1
   * @param _quoteFeed1QuoteDecimals Number of decimals for the quote token in quoteFeed1
   * @param _quoteFeed2BaseDecimals Number of decimals for the base token in quoteFeed2
   * @param _quoteFeed2QuoteDecimals Number of decimals for the quote token in quoteFeed2
   */
  constructor(
    address _baseFeed1,
    address _baseFeed2,
    address _quoteFeed1,
    address _quoteFeed2,
    uint256 _baseFeed1BaseDecimals,
    uint256 _baseFeed1QuoteDecimals,
    uint256 _baseFeed2BaseDecimals,
    uint256 _baseFeed2QuoteDecimals,
    uint256 _quoteFeed1BaseDecimals,
    uint256 _quoteFeed1QuoteDecimals,
    uint256 _quoteFeed2BaseDecimals,
    uint256 _quoteFeed2QuoteDecimals
  ) {
    baseFeed1 = AggregatorV3Interface(_baseFeed1);
    baseFeed2 = AggregatorV3Interface(_baseFeed2);
    quoteFeed1 = AggregatorV3Interface(_quoteFeed1);
    quoteFeed2 = AggregatorV3Interface(_quoteFeed2);

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

  /**
   * @notice Calculates the current price tick based on the Chainlink price feeds
   * @dev This function combines up to four price feeds to determine the final tick:
   *      - Two base feeds (baseFeed1 and baseFeed2) are added together
   *      - Two quote feeds (quoteFeed1 and quoteFeed2) are subtracted
   *      This allows for complex price calculations, such as A/E derived from A/B, B/C, D/C, and E/D feeds
   * @return Tick The calculated price tick for use in Mangrove's order book
   */
  function tick() public view returns (Tick) {
    return Tick.wrap(
      baseFeed1.getTick(baseFeed1Decimals, baseFeed1BaseDecimals, baseFeed1QuoteDecimals)
        + baseFeed2.getTick(baseFeed2Decimals, baseFeed2BaseDecimals, baseFeed2QuoteDecimals)
        - quoteFeed1.getTick(quoteFeed1Decimals, quoteFeed1BaseDecimals, quoteFeed1QuoteDecimals)
        - quoteFeed2.getTick(quoteFeed2Decimals, quoteFeed2BaseDecimals, quoteFeed2QuoteDecimals)
    );
  }
}
