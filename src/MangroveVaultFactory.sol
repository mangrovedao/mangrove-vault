// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MangroveVault, AbstractKandelSeeder} from "./MangroveVault.sol";
import {MangroveVaultEvents} from "./lib/MangroveVaultEvents.sol";

contract MangroveVaultFactory {
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
  ) public returns (MangroveVault vault) {
    vault = new MangroveVault(_seeder, _BASE, _QUOTE, _tickSpacing, _decimals, name, symbol, _oracle, _owner);

    emit MangroveVaultEvents.VaultCreated(
      address(_seeder), _BASE, _QUOTE, _tickSpacing, address(vault), _oracle, address(vault.kandel())
    );
  }
}
