// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FundsState, KandelPosition} from "../MangroveVault.sol";
import {Tick} from "@mgv/lib/core/TickLib.sol";

library MangroveVaultEvents {
  event SwapContractAllowed(address indexed swapContract, bool allowed);

  event Swap(address pool, int256 baseAmountChange, int256 quoteAmountChange, bool sell);

  event Burn(address user, uint256 shares, uint256 amount0, uint256 amount1);

  event SetKandelPosition(
    int256 tickIndex0,
    uint256 tickOffset,
    uint32 gasprice,
    uint24 gasreq,
    uint32 stepSize,
    uint32 pricePoints,
    FundsState fundsState
  );

  event AccrueInterest(uint256 feeShares, uint256 newTotalInQuote, uint256 timestamp);

  event UpdateLastTotalInQuote(uint256 lastTotalInQuote, uint256 timestamp);

  function emitSetKandelPosition(KandelPosition memory position) internal {
    emit SetKandelPosition(
      Tick.unwrap(position.tickIndex0),
      position.tickOffset,
      position.params.gasprice,
      position.params.gasreq,
      position.params.stepSize,
      position.params.pricePoints,
      position.fundsState
    );
  }
}
