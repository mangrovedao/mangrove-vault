// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MangroveDiaOracle, DiaFeed, ERC4626Feed} from "./MangroveDiaOracle.sol";
import {MangroveVaultEvents} from "../../lib/MangroveVaultEvents.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

/**
 * @title MangroveDiaOracleFactory
 * @notice Factory contract for creating MangroveDiaOracle instances
 */
contract MangroveDiaOracleFactory {
  /**
   * @notice Mapping to track if an address is a created oracle
   */
  mapping(address => bool) public isOracle;

  /**
   * @notice Computes the address of a MangroveDiaOracle before it is deployed
   * @param baseFeed1 DiaFeed struct for the first base feed
   * @param baseFeed2 DiaFeed struct for the second base feed
   * @param quoteFeed1 DiaFeed struct for the first quote feed
   * @param quoteFeed2 DiaFeed struct for the second quote feed
   * @param baseVault ERC4626Feed struct for the base vault
   * @param quoteVault ERC4626Feed struct for the quote vault
   * @param salt Unique value for deterministic address generation
   * @return The address where the oracle contract will be deployed
   */
  function computeOracleAddress(
    DiaFeed calldata baseFeed1,
    DiaFeed calldata baseFeed2,
    DiaFeed calldata quoteFeed1,
    DiaFeed calldata quoteFeed2,
    ERC4626Feed calldata baseVault,
    ERC4626Feed calldata quoteVault,
    bytes32 salt
  ) public view returns (address) {
    bytes memory bytecode = abi.encodePacked(
      type(MangroveDiaOracle).creationCode,
      abi.encode(baseFeed1, baseFeed2, quoteFeed1, quoteFeed2, baseVault, quoteVault)
    );

    return Create2.computeAddress(salt, keccak256(bytecode));
  }

  /**
   * @notice Creates a new MangroveDiaOracle
   * @param baseFeed1 DiaFeed struct for the first base feed
   * @param baseFeed2 DiaFeed struct for the second base feed
   * @param quoteFeed1 DiaFeed struct for the first quote feed
   * @param quoteFeed2 DiaFeed struct for the second quote feed
   * @param baseVault ERC4626Feed struct for the base vault
   * @param quoteVault ERC4626Feed struct for the quote vault
   * @param salt Unique value for deterministic address generation
   * @return oracle The newly created MangroveDiaOracle
   */
  function create(
    DiaFeed calldata baseFeed1,
    DiaFeed calldata baseFeed2,
    DiaFeed calldata quoteFeed1,
    DiaFeed calldata quoteFeed2,
    ERC4626Feed calldata baseVault,
    ERC4626Feed calldata quoteVault,
    bytes32 salt
  ) external returns (MangroveDiaOracle oracle) {
    oracle = new MangroveDiaOracle{salt: salt}(baseFeed1, baseFeed2, quoteFeed1, quoteFeed2, baseVault, quoteVault);
    isOracle[address(oracle)] = true;
    emit MangroveVaultEvents.OracleCreated(msg.sender, address(oracle));
  }
}
