// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MangroveMorphoKandelVault, AbstractKandelSeeder} from "./MangroveMorphoKandelVault.sol";
import {MangroveVaultEvents} from "../lib/MangroveVaultEvents.sol";

/**
 * @title MangroveMorphoKandelVaultFactory
 * @notice Factory contract for creating MangroveMorphoKandelVault instances
 * @dev This factory contract provides a standard way to deploy MangroveMorphoKandelVault vaults
 */
contract MangroveMorphoKandelVaultFactory {
  /**
   * @notice Creates a new MangroveMorphoKandelVault instance
   * @param _seeder The AbstractKandelSeeder contract instance
   * @param _BASE The address of the base token in the token pair
   * @param _QUOTE The address of the quote token in the token pair
   * @param _tickSpacing The tick spacing for the Mangrove market
   * @param _decimals The number of decimals of the LP token
   * @param name The name of the ERC20 token
   * @param symbol The symbol of the ERC20 token
   * @param _oracle The address of the oracle used to get the price of the token pair
   * @param _owner The address that will own the vault
   * @return vault The created MangroveMorphoKandelVault contract
   */
  function createVault(
    AbstractKandelSeeder _seeder,
    address _BASE,
    address _QUOTE,
    uint256 _tickSpacing,
    uint8 _decimals,
    string memory name,
    string memory symbol,
    address _oracle,
    address _owner
  ) public returns (MangroveMorphoKandelVault vault) {
    vault = new MangroveMorphoKandelVault(
      _seeder, _BASE, _QUOTE, _tickSpacing, _decimals, name, symbol, _oracle, _owner
    );

    emit MangroveVaultEvents.VaultCreated(
      address(_seeder), _BASE, _QUOTE, _tickSpacing, address(vault), _oracle, address(vault.kandel())
    );
  }
}