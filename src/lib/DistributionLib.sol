// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GeometricKandel} from "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/GeometricKandel.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {OfferType} from "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/TradesBaseQuotePair.sol";
import {DirectWithBidsAndAsksDistribution} from
  "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/KandelLib.sol";
import {Tick} from "@mgv/lib/core/TickLib.sol";

/**
 * @title DistributionLib
 * @notice Library for creating and manipulating distributions of bids and asks for Kandel strategies
 */
library DistributionLib {
  using DistributionLib for GeometricKandel.Distribution;
  using Math for uint256;

  /**
   * @notice Returns the destination index to transport received liquidity to - a better (for Kandel) price index for the offer type
   * @dev This function has been audited
   * @param ba The offer type to transport to
   * @param index The price index one is willing to improve
   * @param step The number of price steps improvements
   * @param pricePoints The number of price points
   * @return better The destination index
   */
  function transportDestination(OfferType ba, uint256 index, uint256 step, uint256 pricePoints)
    internal
    pure
    returns (uint256 better)
  {
    if (ba == OfferType.Ask) {
      better = index + step;
      if (better >= pricePoints) {
        better = pricePoints - 1;
      }
    } else {
      if (index >= step) {
        better = index - step;
      }
      // else better = 0
    }
  }

  /**
   * @notice Creates a distribution of bids and asks given by the parameters. Dual offers are included with gives=0
   * @dev This function has been audited
   * @param from Populate offers starting from this index (inclusive). Must be at most `pricePoints`
   * @param to Populate offers until this index (exclusive). Must be at most `pricePoints`
   * @param baseQuoteTickIndex0 The tick for the price point at index 0 given as a tick on the `base, quote` offer list
   * @param _baseQuoteTickOffset The tick offset used for the geometric progression deployment
   * @param firstAskIndex The (inclusive) index after which offer should be an ask
   * @param bidGives The initial amount of quote to give for all bids
   * @param askGives The initial amount of base to give for all asks
   * @param pricePoints The number of price points for the Kandel instance
   * @param stepSize The amount of price points to jump for posting dual offer
   * @return distribution The distribution of bids and asks to populate
   */
  function createGeometricDistribution(
    uint256 from,
    uint256 to,
    Tick baseQuoteTickIndex0,
    uint256 _baseQuoteTickOffset,
    uint256 firstAskIndex,
    uint256 bidGives,
    uint256 askGives,
    uint256 pricePoints,
    uint256 stepSize
  ) internal pure returns (GeometricKandel.Distribution memory distribution) {
    require(bidGives != type(uint256).max || askGives != type(uint256).max, "Kandel/bothGivesVariable");

    // First we restrict boundaries of bids and asks.

    // Create live bids up till first ask, except stop where live asks will have a dual bid.
    uint256 bidBound;
    {
      // Rounding - we skip an extra live bid if stepSize is odd.
      uint256 bidHoleSize = stepSize / 2 + stepSize % 2;
      // If first ask is close to start, then there are no room for live bids.
      bidBound = firstAskIndex > bidHoleSize ? firstAskIndex - bidHoleSize : 0;
      // If stepSize is large there is not enough room for dual outside
      uint256 lastBidWithPossibleDualAsk = pricePoints - stepSize;
      if (bidBound > lastBidWithPossibleDualAsk) {
        bidBound = lastBidWithPossibleDualAsk;
      }
    }
    // Here firstAskIndex becomes the index of the first actual ask, and not just the boundary - we need to take `stepSize` and `from` into account.
    firstAskIndex = firstAskIndex + stepSize / 2;
    // We should not place live asks near the beginning, there needs to be room for the dual bid.
    if (firstAskIndex < stepSize) {
      firstAskIndex = stepSize;
    }

    // Finally, account for the from/to boundaries
    if (to < bidBound) {
      bidBound = to;
    }
    if (firstAskIndex < from) {
      firstAskIndex = from;
    }

    // Allocate distributions - there should be room for live bids and asks, and their duals.
    {
      uint256 count = (from < bidBound ? bidBound - from : 0) + (firstAskIndex < to ? to - firstAskIndex : 0);
      distribution.bids = new DirectWithBidsAndAsksDistribution.DistributionOffer[](count);
      distribution.asks = new DirectWithBidsAndAsksDistribution.DistributionOffer[](count);
    }

    // Start bids at from
    uint256 index = from;
    // Calculate the taker relative tick of the first price point
    int256 tick = -(Tick.unwrap(baseQuoteTickIndex0) + int256(_baseQuoteTickOffset) * int256(index));
    // A counter for insertion in the distribution structs
    uint256 i = 0;
    for (; index < bidBound; ++index) {
      // Add live bid
      // Use askGives unless it should be derived from bid at the price
      distribution.bids[i] = DirectWithBidsAndAsksDistribution.DistributionOffer({
        index: index,
        tick: Tick.wrap(tick),
        gives: bidGives == type(uint256).max ? Tick.wrap(tick).outboundFromInbound(askGives) : bidGives
      });

      // Add dual (dead) ask
      uint256 dualIndex = transportDestination(OfferType.Ask, index, stepSize, pricePoints);
      distribution.asks[i] = DirectWithBidsAndAsksDistribution.DistributionOffer({
        index: dualIndex,
        tick: Tick.wrap((Tick.unwrap(baseQuoteTickIndex0) + int256(_baseQuoteTickOffset) * int256(dualIndex))),
        gives: 0
      });

      // Next tick
      tick -= int256(_baseQuoteTickOffset);
      ++i;
    }

    // Start asks from (adjusted) firstAskIndex
    index = firstAskIndex;
    // Calculate the taker relative tick of the first ask
    tick = (Tick.unwrap(baseQuoteTickIndex0) + int256(_baseQuoteTickOffset) * int256(index));
    for (; index < to; ++index) {
      // Add live ask
      // Use askGives unless it should be derived from bid at the price
      distribution.asks[i] = DirectWithBidsAndAsksDistribution.DistributionOffer({
        index: index,
        tick: Tick.wrap(tick),
        gives: askGives == type(uint256).max ? Tick.wrap(tick).outboundFromInbound(bidGives) : askGives
      });
      // Add dual (dead) bid
      uint256 dualIndex = transportDestination(OfferType.Bid, index, stepSize, pricePoints);
      distribution.bids[i] = DirectWithBidsAndAsksDistribution.DistributionOffer({
        index: dualIndex,
        tick: Tick.wrap(-(Tick.unwrap(baseQuoteTickIndex0) + int256(_baseQuoteTickOffset) * int256(dualIndex))),
        gives: 0
      });

      // Next tick
      tick += int256(_baseQuoteTickOffset);
      ++i;
    }
  }

  /**
   * @notice Counts the number of live bids and asks in a distribution
   * @param distribution The distribution to count offers in
   * @return nBids The number of live bids
   * @return nAsks The number of live asks
   */
  function _countOffers(GeometricKandel.Distribution memory distribution)
    internal
    pure
    returns (uint256 nBids, uint256 nAsks)
  {
    // bids and asks array are the same length
    for (uint256 i = 0; i < distribution.bids.length; i++) {
      if (distribution.bids[i].gives > 0) {
        nBids++;
      }
      if (distribution.asks[i].gives > 0) {
        nAsks++;
      }
    }
  }

  /**
   * @notice Fills all live offers in a distribution with the specified amounts
   * @param distribution The distribution to fill offers in
   * @param bidGives The amount to set for all live bids
   * @param askGives The amount to set for all live asks
   */
  function _fillOffers(GeometricKandel.Distribution memory distribution, uint256 bidGives, uint256 askGives)
    internal
    pure
  {
    for (uint256 i = 0; i < distribution.bids.length; i++) {
      if (distribution.bids[i].gives > 0) {
        distribution.bids[i].gives = bidGives;
      }
      if (distribution.asks[i].gives > 0) {
        distribution.asks[i].gives = askGives;
      }
    }
  }

  /**
   * @notice Fills all live offers in a distribution with amounts calculated from the total base and quote amounts
   * @param distribution The distribution to fill offers in
   * @param baseAmount The total base amount to distribute among asks
   * @param quoteAmount The total quote amount to distribute among bids
   * @return bidGives The amount set for each live bid
   * @return askGives The amount set for each live ask
   */
  function fillOffersWith(GeometricKandel.Distribution memory distribution, uint256 baseAmount, uint256 quoteAmount)
    internal
    pure
    returns (uint256 bidGives, uint256 askGives)
  {
    (uint256 nBids, uint256 nAsks) = distribution._countOffers();
    (, askGives) = baseAmount.tryDiv(nAsks);
    (, bidGives) = quoteAmount.tryDiv(nBids);
    distribution._fillOffers(bidGives, askGives);
  }
}
