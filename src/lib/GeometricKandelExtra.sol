// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GeometricKandel} from "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/GeometricKandel.sol";
import {OfferType} from "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/TradesBaseQuotePair.sol";
import {OLKey, Local, IMangrove, Tick} from "@mgv/src/IMangrove.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {DistributionLib} from "./DistributionLib.sol";

/**
 * @notice Parameters for configuring the Kandel strategy
 * @dev This struct is used to store and pass configuration parameters for the Kandel strategy
 * @param gasprice The gas price for offer execution (if zero, stays unchanged or defaults to mangrove gasprice)
 * @param gasreq The gas required for offer execution (if zero, stays unchanged or defaults to mangrove gasreq)
 * @param stepSize The step size between offers
 * @param pricePoints The number of price points in the distribution
 */
struct Params {
  uint32 gasprice;
  uint24 gasreq;
  uint32 stepSize;
  uint32 pricePoints;
}

library GeometricKandelExtra {
  using GeometricKandelExtra for GeometricKandel;
  using SafeCast for uint256;
  using DistributionLib for GeometricKandel.Distribution;

  function _params(GeometricKandel kandel) internal view returns (Params memory params_) {
    (params_.gasprice, params_.gasreq, params_.stepSize, params_.pricePoints) = kandel.params();
  }

  function getBalances(GeometricKandel kandel) internal view returns (uint256 baseAmount, uint256 quoteAmount) {
    baseAmount = kandel.reserveBalance(OfferType.Ask);
    quoteAmount = kandel.reserveBalance(OfferType.Bid);
  }

  function _firstAskIndex(Tick tickIndex0, Tick midPrice, uint256 tickOffset, uint32 pricePoints)
    internal
    pure
    returns (uint256 i)
  {
    int256 midTick = Tick.unwrap(midPrice);
    int256 tick = Tick.unwrap(tickIndex0);
    int256 offset = tickOffset.toInt256();
    for (i = 0; i < pricePoints; i++) {
      if (tick >= midTick) break;
      tick += offset;
    }
  }

  function distribution(GeometricKandel kandel, Tick tickIndex0, Tick midPrice)
    internal
    view
    returns (
      GeometricKandel.Distribution memory _distribution,
      Params memory params,
      uint256 bidGives,
      uint256 askGives
    )
  {
    params = kandel._params();
    uint256 baseQuoteTickOffset = kandel.baseQuoteTickOffset();
    uint256 firstAskIndex_ = _firstAskIndex(tickIndex0, midPrice, baseQuoteTickOffset, params.pricePoints);
    _distribution = kandel.createDistribution(
      0,
      params.pricePoints,
      tickIndex0,
      kandel.baseQuoteTickOffset(),
      firstAskIndex_,
      1,
      1,
      params.pricePoints,
      params.stepSize
    );
    (uint256 baseAmount, uint256 quoteAmount) = kandel.getBalances();
    (bidGives, askGives) = _distribution.fillOffersWith(baseAmount, quoteAmount);
  }

  function withdrawAllOffersAndFundsTo(GeometricKandel kandel, address to) internal {
    Params memory params = kandel._params();
    kandel.retractAndWithdraw(0, params.pricePoints, type(uint256).max, type(uint256).max, 0, payable(to));
  }

  function withdrawAllOffers(GeometricKandel kandel) internal {
    Params memory params = kandel._params();
    kandel.retractOffers(0, params.pricePoints);
  }
}
