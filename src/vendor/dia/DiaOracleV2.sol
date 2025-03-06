// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface DiaOracleV2 {
  function getValue(string memory key) external view returns (uint128 value, uint128 timestamp);
}
