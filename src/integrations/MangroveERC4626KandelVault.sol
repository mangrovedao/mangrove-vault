// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MangroveVault, AbstractKandelSeeder, IERC20} from "../MangroveVault.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC4626Kandel} from "../interfaces/IERC4626Kandel.sol";

/**
 * @title MangroveERC4626KandelVault
 * @author Mangrove
 * @notice This contract extends MangroveVault to implement ERC4626 vault functionality.
 */
contract MangroveERC4626KandelVault is MangroveVault {
  /**
   * @dev Error emitted when a call to another contract fails.
   */
  error FailedCall();

  /**
   * @param _seeder The Kandel seeder contract.
   * @param _BASE The base token address.
   * @param _QUOTE The quote token address.
   * @param _tickSpacing The tick spacing for the vault.
   * @param _decimals The number of decimals for the vault.
   * @param name The name of the vault.
   * @param symbol The symbol of the vault.
   * @param _oracle The oracle contract address.
   * @param _owner The owner of the vault.
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
  ) MangroveVault(_seeder, _BASE, _QUOTE, _tickSpacing, _decimals, name, symbol, _oracle, _owner) {}

  /**
   * @notice Sets the vault for a given token.
   * @dev This function can only be called by the admin.
   * @param token The token for which to set the vault.
   * @param vault The vault to be set for the token.
   * @param minAssetsOut The minimum amount of assets that must be withdrawn when moving funds to the new vault
   * @param minSharesOut The minimum amount of shares that must be withdrawn when moving funds to the new vault
   */
  function setVaultForToken(IERC20 token, IERC4626 vault, uint minAssetsOut, uint256 minSharesOut) external virtual onlyOwner {
    IERC4626Kandel(address(kandel)).setVaultForToken(token, vault, minAssetsOut, minSharesOut);
  }

  /**
   * @notice Allows the admin to withdraw tokens from the vault.
   * @dev This function can only be called by the admin.
   * @param token The token to be withdrawn.
   * @param amount The amount of tokens to be withdrawn.
   * @param recipient The address to which the tokens will be sent.
   */
  function adminWithdrawTokens(IERC20 token, uint256 amount, address recipient) public onlyOwner {
    IERC4626Kandel(address(kandel)).adminWithdrawTokens(token, amount, recipient);
  }

  /**
   * @notice Allows the admin to withdraw native tokens from the vault.
   * @dev This function can only be called by the admin.
   * @param amount The amount of native tokens to be withdrawn.
   * @param recipient The address to which the native tokens will be sent.
   */
  function adminWithdrawNative(uint256 amount, address recipient) public onlyOwner {
    IERC4626Kandel(address(kandel)).adminWithdrawNative(amount, recipient);
  }

  ///@notice Returns the current vault addresses for the base and quote tokens
  ///@return baseVault The address of the vault for the base token
  ///@return quoteVault The address of the vault for the quote token
  function currentVaults() public view returns (address baseVault, address quoteVault) {
    return IERC4626Kandel(address(kandel)).currentVaults();
  }
}
