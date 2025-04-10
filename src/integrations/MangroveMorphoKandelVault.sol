// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MangroveERC4626KandelVault, AbstractKandelSeeder, IERC20} from "./MangroveERC4626KandelVault.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IMorphoKandel} from "../interfaces/IMorphoKandel.sol";

/**
 * @title MangroveMorphoKandelVault
 * @author Mangrove
 * @notice This contract extends MangroveERC4626KandelVault to interact with MorphoKandel strategies.
 * @dev It adds functionality to claim rewards from Morpho protocol through the Kandel strategy.
 */
contract MangroveMorphoKandelVault is MangroveERC4626KandelVault {
  /**
   * @notice Constructor for the MangroveMorphoKandelVault
   * @param _seeder The AbstractKandelSeeder contract instance used to initialize the Kandel contract
   * @param _BASE The address of the base token in the token pair
   * @param _QUOTE The address of the quote token in the token pair
   * @param _tickSpacing The tick spacing for the Mangrove market
   * @param _decimals The number of decimals of the LP token
   * @param name The name of the ERC20 token
   * @param symbol The symbol of the ERC20 token
   * @param _oracle The address of the oracle used to get the price of the token pair
   * @param _owner The owner of the vault
   */
  constructor(
    AbstractKandelSeeder _seeder,
    address _BASE,
    address _QUOTE,
    uint256 _tickSpacing,
    uint8 _decimals,
    string memory name,
    string memory symbol,
    address _oracle,
    address _owner
  ) MangroveERC4626KandelVault(_seeder, _BASE, _QUOTE, _tickSpacing, _decimals, name, symbol, _oracle, _owner) {}

  /**
   * @notice Claims rewards from Morpho protocol for a specific token
   * @param token The token for which to claim rewards
   * @param amount The amount of rewards to claim
   * @param proof The proof required for claiming rewards
   * @param receiver The address that will receive the claimed rewards
   * @dev This function can only be called by the owner of the contract
   */
  function claimRewardsForToken(IERC20 token, uint256 amount, bytes32[] calldata proof, address receiver)
    external
    onlyOwner
  {
    IMorphoKandel(address(kandel)).claimRewardsForToken(token, amount, proof, receiver);
  }
}