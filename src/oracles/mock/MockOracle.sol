// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOracle} from "../IOracle.sol";
import {Tick} from "@mgv/lib/core/TickLib.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OLKey} from "@mgv/src/core/MgvLib.sol";

contract MockOracle is IOracle, Ownable(msg.sender) {
  Tick public tick;

  constructor(Tick _tick) {
    tick = _tick;
  }

  function setTick(Tick _tick) external onlyOwner {
    tick = _tick;
  }
}
