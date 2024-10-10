// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
  GeometricKandel,
  CoreKandel
} from "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/GeometricKandel.sol";
import {OfferType} from "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/TradesBaseQuotePair.sol";
import {OLKey, Local, IMangrove, Tick} from "@mgv/src/IMangrove.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {DistributionLib} from "./DistributionLib.sol";
import {MangroveVaultEvents} from "./MangroveVaultEvents.sol";

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

/**
 * @title GeometricKandelExtra
 * @notice Library providing additional functionality for GeometricKandel
 */
library GeometricKandelExtra {
  using GeometricKandelExtra for GeometricKandel;
  using SafeCast for uint256;
  using DistributionLib for GeometricKandel.Distribution;

  /**
   * @notice Retrieves the parameters of a GeometricKandel instance
   * @param kandel The GeometricKandel instance
   * @return params_ The Params struct containing the kandel parameters
   */
  function _params(GeometricKandel kandel) internal view returns (Params memory params_) {
    // (params_.gasprice, params_.gasreq, params_.stepSize, params_.pricePoints) = kandel.params();
    bytes32 selectorUnstripped = keccak256("params()");
    bytes memory data;

    assembly {
      mstore(data, selectorUnstripped)

      let success := staticcall(gas(), kandel, data, 0x04, params_, 0x80)

      // Check if the call was successful
      if iszero(success) {
        // Revert with the same error message
        let ptr := mload(0x40)
        returndatacopy(ptr, 0, returndatasize())
        revert(ptr, returndatasize())
      }
    }
  }

  /**
   * @notice Gets the current balances of base and quote tokens for a GeometricKandel instance
   * @param kandel The GeometricKandel instance
   * @return baseAmount The amount of base tokens
   * @return quoteAmount The amount of quote tokens
   */
  function getBalances(GeometricKandel kandel) internal view returns (uint256 baseAmount, uint256 quoteAmount) {
    baseAmount = kandel.reserveBalance(OfferType.Ask);
    quoteAmount = kandel.reserveBalance(OfferType.Bid);
  }

  /**
   * @notice Calculates the index of the first ask offer
   * @param tickIndex0 The tick at index 0
   * @param midPrice The mid-price tick
   * @param tickOffset The tick offset between price points
   * @param pricePoints The total number of price points
   * @return i The index of the first ask offer
   */
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

  /**
   * @notice Generates a distribution for a GeometricKandel instance
   * @param kandel The GeometricKandel instance
   * @param tickIndex0 The tick at index 0
   * @param midPrice The mid-price tick
   * @return _distribution The generated distribution
   * @return params The Kandel parameters
   * @return bidGives The amount given for bids
   * @return askGives The amount given for asks
   */
  function distribution(GeometricKandel kandel, Tick tickIndex0, Tick midPrice)
    public
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
    _distribution = DistributionLib.createGeometricDistribution(
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

  /**
   * @notice Withdraws all offers and funds to a specified address
   * @param kandel The GeometricKandel instance
   * @param to The address to withdraw to
   */
  function withdrawAllOffersAndFundsTo(GeometricKandel kandel, address to) internal {
    Params memory params = kandel._params();
    kandel.retractAndWithdraw(0, params.pricePoints, type(uint256).max, type(uint256).max, 0, payable(to));
  }

  /**
   * @notice Withdraws all offers from the Kandel strategy
   * @param kandel The GeometricKandel instance
   */
  function withdrawAllOffers(GeometricKandel kandel) internal {
    Params memory params = kandel._params();
    kandel.retractOffers(0, params.pricePoints);
  }
}
