// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {GeometricKandelExtra, Tick} from "../src/lib/GeometricKandelExtra.sol";
import {DistributionLib} from "../src/lib/DistributionLib.sol";
import {GeometricKandel} from "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/GeometricKandel.sol";

contract GeometricKandelExtraTest is Test {
  function testFuzz_firstAskIndex(int24 tickIndex0, int24 midPrice, uint8 tickOffset, uint8 pricePoints) public pure {
    vm.assume(tickIndex0 < 100_000 && tickIndex0 > -100_000);
    vm.assume(midPrice < 100_000 && midPrice > -100_000);
    vm.assume(tickOffset > 0 && tickOffset <= 100);
    vm.assume(pricePoints > 1 && pricePoints <= 100);

    uint256 index =
      GeometricKandelExtra._firstAskIndex(Tick.wrap(tickIndex0), Tick.wrap(midPrice), tickOffset, pricePoints);

    GeometricKandel.Distribution memory distribution = DistributionLib.createGeometricDistribution(
      0, pricePoints, Tick.wrap(tickIndex0), tickOffset, index, 1, 1, pricePoints, 1
    );

    // All active bids should be less than midPrice
    for (uint256 i = 0; i < distribution.bids.length; i++) {
      if (distribution.bids[i].gives > 0) {
        assertLt(-Tick.unwrap(distribution.bids[i].tick), midPrice, "Bid tick is not less than midPrice");
      }
    }

    // All active asks should be greater or equal to midPrice
    for (uint256 i = 0; i < distribution.asks.length; i++) {
      if (distribution.asks[i].gives > 0) {
        assertGe(Tick.unwrap(distribution.asks[i].tick), midPrice, "Ask tick is not greater than midPrice");
      }
    }
  }
}
