// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GeometricKandel} from "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/GeometricKandel.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

library DistributionLib {
  using DistributionLib for GeometricKandel.Distribution;
  using Math for uint256;

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
