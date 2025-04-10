// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {TickLib, Tick} from "@mgv/lib/core/TickLib.sol";

/**
 * @title ERC4626Consumer
 * @notice Library for interacting with ERC4626 vaults to get price information in Mangrove tick format
 */
library ERC4626Consumer {
  /**
   * @notice Gets the current price tick for an ERC4626 vault
   * @dev Calculates the tick based on the ratio of assets to shares using convertToAssets
   * @param vault The ERC4626 vault to get the price for
   * @param conversion_sample The amount of shares to use as a sample for price conversion
   * @return The price tick representing assets per share
   */
  function getTick(IERC4626 vault, uint256 conversion_sample) internal view returns (int256) {
    if (address(vault) == address(0)) return 0;
    uint256 assets = vault.convertToAssets(conversion_sample);
    return Tick.unwrap(TickLib.tickFromVolumes(assets, conversion_sample));
  }
}
