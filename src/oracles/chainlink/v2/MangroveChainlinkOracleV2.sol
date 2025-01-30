// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOracle} from "../../IOracle.sol";
import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {Tick} from "@mgv/lib/core/TickLib.sol";
import {ChainlinkConsumer} from "../../../vendor/chainlink/ChainlinkConsumer.sol";
import {AggregatorV3Interface} from "../../../vendor/chainlink/AggregatorV3Interface.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {MangroveVaultErrors} from "../../../lib/MangroveVaultErrors.sol";
import {ERC4626Consumer} from "../../../vendor/ERC4626/ERC4626Consumer.sol";

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
 * @title ERC4626Feed
 * @notice Struct to hold ERC4626 vault information
 * @param vault Address of the ERC4626 vault
 * @param conversionSample Sample amount used for price conversion calculations in the vault
 */
struct ERC4626Feed {
  address vault;
  uint256 conversionSample;
}


/**
 * @title MangroveChainlinkOracle
 * @notice An oracle adapter for Mangrove that supports up to 4 Chainlink price feeds and 2 ERC4626 vault feeds
 * @dev This contract combines up to 4 Chainlink price feeds and 2 ERC4626 vault feeds to create a single price oracle for Mangrove.
 *      For Chainlink feeds, it supports up to 2 feeds to combine for the base price, plus two inverse feeds for the quote price.
 *      For example, if we have A/B, B/C, D/C, and E/D feeds, we can combine them into A/E.
 *      For ERC4626 vaults, it supports one vault feed for the base and one for the quote.
 *      For example, if we have a vault vA containing A tokens (vA/A feed) and a vault vE containing E tokens (vE/E feed),
 *      we can compose them into a vA/vE feed with the above composition.
 *
 * @dev The price is represented as quote/base, while on Mangrove it's inbound/outbound.
 *      Inbound tokens are received by the maker, outbound tokens are sent by the maker.
 *      The oracle outputs a tick corresponding to the price on the inbound=base/outbound=quote market.
 */
contract MangroveChainlinkOracleV2 is IOracle {
  using ChainlinkConsumer for AggregatorV3Interface;
  using Math for uint256;
  using ERC4626Consumer for IERC4626;

  /// @notice The ERC4626 vault for the base token
  IERC4626 public immutable baseVault;
  /// @notice The ERC4626 vault for the quote token 
  IERC4626 public immutable quoteVault;

  /// @notice Sample amount used for price conversion calculations in the base vault
  uint256 public immutable baseVaultConversionSample;
  /// @notice Sample amount used for price conversion calculations in the quote vault
  uint256 public immutable quoteVaultConversionSample;

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
   * @param _baseFeed1 ChainlinkFeed struct for the first base feed
   * @param _baseFeed2 ChainlinkFeed struct for the second base feed
   * @param _quoteFeed1 ChainlinkFeed struct for the first quote feed
   * @param _quoteFeed2 ChainlinkFeed struct for the second quote feed
   * @param _baseVault ERC4626Feed struct for the base vault
   * @param _quoteVault ERC4626Feed struct for the quote vault
   */
  constructor(
    ChainlinkFeed memory _baseFeed1,
    ChainlinkFeed memory _baseFeed2,
    ChainlinkFeed memory _quoteFeed1,
    ChainlinkFeed memory _quoteFeed2,
    ERC4626Feed memory _baseVault,
    ERC4626Feed memory _quoteVault
  ) {
    baseFeed1 = AggregatorV3Interface(_baseFeed1.feed);
    baseFeed2 = AggregatorV3Interface(_baseFeed2.feed);
    quoteFeed1 = AggregatorV3Interface(_quoteFeed1.feed);
    quoteFeed2 = AggregatorV3Interface(_quoteFeed2.feed);

    baseVault = IERC4626(_baseVault.vault);
    quoteVault = IERC4626(_quoteVault.vault);

    baseVaultConversionSample = _baseVault.conversionSample;
    quoteVaultConversionSample = _quoteVault.conversionSample;

    baseFeed1Decimals = baseFeed1.getDecimals();
    baseFeed2Decimals = baseFeed2.getDecimals();
    quoteFeed1Decimals = quoteFeed1.getDecimals();
    quoteFeed2Decimals = quoteFeed2.getDecimals();

    baseFeed1BaseDecimals = _baseFeed1.baseDecimals;
    baseFeed1QuoteDecimals = _baseFeed1.quoteDecimals;
    baseFeed2BaseDecimals = _baseFeed2.baseDecimals;
    baseFeed2QuoteDecimals = _baseFeed2.quoteDecimals;
    quoteFeed1BaseDecimals = _quoteFeed1.baseDecimals;
    quoteFeed1QuoteDecimals = _quoteFeed1.quoteDecimals;
    quoteFeed2BaseDecimals = _quoteFeed2.baseDecimals;
    quoteFeed2QuoteDecimals = _quoteFeed2.quoteDecimals;
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
        + baseVault.getTick(baseVaultConversionSample)
        - quoteFeed1.getTick(quoteFeed1Decimals, quoteFeed1BaseDecimals, quoteFeed1QuoteDecimals)
        - quoteFeed2.getTick(quoteFeed2Decimals, quoteFeed2BaseDecimals, quoteFeed2QuoteDecimals)
        - quoteVault.getTick(quoteVaultConversionSample)
    );
  }
}

