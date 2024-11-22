// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MangroveVault} from "../MangroveVault.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title MintHelperV1
 * @notice Helper contract to simplify minting MangroveVault shares
 * @dev The MangroveVault requires specifying both the mint amount and max token amounts when minting shares.
 *      However, the optimal mint amount can change quickly between blocks due to price/balance changes.
 *      This helper calculates and executes the mint with just the desired token deposit amounts.
 *
 * @dev Key features:
 * - Takes desired base and quote token amounts to deposit
 * - Calculates optimal mint amount based on current vault state
 * - Handles approval and minting in a single transaction
 * - Ensures up-to-date information is used for minting
 * - Protects against slippage via minimum shares parameter
 */
contract MintHelperV1 is Ownable(msg.sender), ReentrancyGuard {
  using SafeERC20 for IERC20;

  /**
   * @notice Thrown when the minimum shares requirement is not met
   * @param minShares The minimum number of shares required
   * @param mintAmount The actual number of shares that would be minted
   * @dev This error occurs when the calculated mint amount is less than the specified minimum shares,
   *      which protects users from receiving fewer shares than expected due to price movements or other factors
   */
  error InvalidMinShares(uint256 minShares, uint256 mintAmount);

  /**
   * @notice Mints MangroveVault shares by depositing tokens
   * @param vault The MangroveVault contract to mint shares in
   * @param maxBaseAmount The maximum amount of base token to deposit
   * @param maxQuoteAmount The maximum amount of quote token to deposit
   * @param minShares The minimum number of shares that must be minted
   * @return mintAmount The number of shares minted
   * @return baseAmount The amount of base token deposited
   * @return quoteAmount The amount of quote token deposited
   * @dev This function:
   *      - Calculates optimal mint amount based on current vault state
   *      - Transfers tokens from sender to this contract
   *      - Approves vault to spend tokens
   *      - Mints vault shares
   *      - Transfers shares and any remaining tokens back to sender
   * @dev Reverts if:
   *      - The calculated mint amount is less than minShares
   *      - Any token transfers fail
   *      - The vault mint operation fails
   */
  function mint(MangroveVault vault, uint256 maxBaseAmount, uint256 maxQuoteAmount, uint256 minShares)
    public
    nonReentrant
    returns (uint256 mintAmount, uint256 baseAmount, uint256 quoteAmount)
  {
    // get the minting amounts
    (baseAmount, quoteAmount, mintAmount) = vault.getMintAmounts(maxBaseAmount, maxQuoteAmount);

    // check that the mint amount is greater than the minimum shares
    if (mintAmount < minShares) {
      revert InvalidMinShares(minShares, mintAmount);
    }

    (address _base, address _quote,) = vault.market();

    IERC20 base = IERC20(_base);
    IERC20 quote = IERC20(_quote);

    // transfer the amounts to this contract
    base.safeTransferFrom(msg.sender, address(this), baseAmount);
    quote.safeTransferFrom(msg.sender, address(this), quoteAmount);

    // set the allowance for the vault
    base.forceApprove(address(vault), baseAmount);
    quote.forceApprove(address(vault), quoteAmount);

    // mint the shares
    vault.mint(mintAmount, baseAmount, quoteAmount);

    // transfer vault shares to the sender
    IERC20(vault).safeTransfer(msg.sender, vault.balanceOf(address(this)));

    // reset the allowances
    base.forceApprove(address(vault), 0);
    quote.forceApprove(address(vault), 0);

    // transfer any remaining tokens to the sender
    _transferRemainingTokens(base, msg.sender);
    _transferRemainingTokens(quote, msg.sender);
  }

  /**
   * @notice Transfers any remaining tokens from this contract to the specified recipient
   * @param token The ERC20 token to transfer
   * @param to The recipient address
   * @dev This function is used internally to sweep any leftover tokens after minting
   * @dev Only transfers if there is a non-zero balance
   */
  function _transferRemainingTokens(IERC20 token, address to) internal {
    uint256 balance = token.balanceOf(address(this));
    if (balance > 0) {
      token.safeTransfer(to, balance);
    }
  }

  /**
   * @notice Allows the owner to withdraw any remaining tokens from this contract
   * @param token The ERC20 token to withdraw
   * @param to The recipient address
   * @dev This function can only be called by the contract owner
   * @dev Uses _transferRemainingTokens internally to handle the transfer
   */
  function withdrawTokens(IERC20 token, address to) public onlyOwner {
    _transferRemainingTokens(token, to);
  }
}
