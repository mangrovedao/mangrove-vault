// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library MangroveVaultEvents {
  event SwapContractAllowed(address indexed swapContract, bool allowed);
  event Swap(address pool, uint amountOut, uint amountIn, bool sellToken0);
  event Burn(address user, uint shares, uint amount0, uint amount1);
}