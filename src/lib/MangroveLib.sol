// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IMangrove, OLKey, Local} from "@mgv/src/IMangrove.sol";

library MangroveLib {
  using MangroveLib for IMangrove;

  function _minVolume(IMangrove mgv, OLKey memory olKey, uint256 gasreq) internal view returns (uint256) {
    Local local = mgv.local(olKey);
    return local.density().multiplyUp(gasreq + local.offer_gasbase());
  }

  function minVolumes(IMangrove mgv, OLKey memory olKey, uint256 gasreq)
    internal
    view
    returns (uint256 bidVolume, uint256 askVolume)
  {
    askVolume = mgv._minVolume(olKey, gasreq);
    bidVolume = mgv._minVolume(olKey.flipped(), gasreq);
  }
}
