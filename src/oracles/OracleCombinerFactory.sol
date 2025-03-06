// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOracle} from "./IOracle.sol";
import {OracleCombiner} from "./OracleCombiner.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {MangroveVaultEvents} from "../lib/MangroveVaultEvents.sol";

/**
 * @title OracleCombinerFactory
 * @notice Factory for creating OracleCombiner contracts with deterministic addresses
 * @dev This factory uses CREATE2 to deploy OracleCombiner contracts at deterministic addresses.
 *      It keeps track of all oracles that it creates to allow for verification.
 *      The created oracles combine up to 4 other oracles by adding their ticks together.
 */
contract OracleCombinerFactory {
  /// @notice Mapping of oracle addresses to boolean indicating if they were created by this factory
  mapping(address => bool) public isOracle;

  /**
   * @notice Computes the address of an oracle before it is created
   * @param _oracle1 The first oracle to combine
   * @param _oracle2 The second oracle to combine
   * @param _oracle3 The third oracle to combine
   * @param _oracle4 The fourth oracle to combine
   * @param _salt A salt used for address derivation
   * @return The address where the oracle would be deployed
   */
  function computeOracleAddress(
    address _oracle1,
    address _oracle2,
    address _oracle3,
    address _oracle4,
    bytes32 _salt
  ) public view returns (address) {
    return Create2.computeAddress(
      _salt,
      keccak256(
        abi.encodePacked(
          type(OracleCombiner).creationCode,
          abi.encode(_oracle1, _oracle2, _oracle3, _oracle4)
        )
      )
    );
  }

  /**
   * @notice Creates a new OracleCombiner contract
   * @param _oracle1 The first oracle to combine
   * @param _oracle2 The second oracle to combine (optional, can be zero address)
   * @param _oracle3 The third oracle to combine (optional, can be zero address)
   * @param _oracle4 The fourth oracle to combine (optional, can be zero address)
   * @param _salt A salt used for address derivation
   * @return oracle The created OracleCombiner contract
   * @dev Any oracle address that is set to zero will be ignored in the tick calculation
   */
  function create(
    address _oracle1,
    address _oracle2,
    address _oracle3,
    address _oracle4,
    bytes32 _salt
  ) public returns (OracleCombiner oracle) {
    oracle = new OracleCombiner{salt: _salt}(
      _oracle1,
      _oracle2,
      _oracle3,
      _oracle4
    );
    
    isOracle[address(oracle)] = true;
    
    emit MangroveVaultEvents.OracleCreated(msg.sender, address(oracle));
    
    return oracle;
  }
} 