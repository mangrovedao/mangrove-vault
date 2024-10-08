// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MangroveVault, InitialParams, AbstractKandelSeeder} from "./MangroveVault.sol";
import {MangroveVaultEvents} from "./lib/MangroveVaultEvents.sol";
import {OLKey} from "@mgv/src/core/MgvLib.sol";

contract MangroveVaultFactory {
  function createVault(
    AbstractKandelSeeder _seeder,
    address _BASE,
    address _QUOTE,
    uint256 _tickSpacing,
    uint256 _decimalsOffset,
    string memory name,
    string memory symbol,
    address _oracle,
    InitialParams memory _initialParams
  ) public returns (MangroveVault vault) {
    vault =
      new MangroveVault(_seeder, _BASE, _QUOTE, _tickSpacing, _decimalsOffset, name, symbol, _oracle, _initialParams);
    OLKey memory olKey = OLKey(_BASE, _QUOTE, _tickSpacing);

    emit MangroveVaultEvents.VaultCreated(
      address(_seeder), olKey.hash(), olKey.flipped().hash(), address(vault), _oracle, address(vault.kandel())
    );
  }
}
