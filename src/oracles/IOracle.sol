// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Tick} from "@mgv/lib/core/TickLib.sol";
import {OLKey} from "@mgv/src/core/MgvLib.sol";

interface IOracle {
  function tick() external view returns (Tick);
}