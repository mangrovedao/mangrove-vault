// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MangroveERC4626KandelVault, AbstractKandelSeeder} from "./MangroveERC4626KandelVault.sol";
import {MangroveVaultEvents} from "../lib/MangroveVaultEvents.sol";

contract MangroveERC4626KandelVaultFactory {
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
  ) public returns (MangroveERC4626KandelVault vault) {
    vault =
      new MangroveERC4626KandelVault(_seeder, _BASE, _QUOTE, _tickSpacing, _decimals, name, symbol, _oracle, _owner);

    emit MangroveVaultEvents.VaultCreated(
      address(_seeder), _BASE, _QUOTE, _tickSpacing, address(vault), _oracle, address(vault.kandel())
    );
  }
}
