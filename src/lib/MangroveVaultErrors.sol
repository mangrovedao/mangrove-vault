// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library MangroveVaultErrors {

  error NoUnderlyingBalance();

  error ZeroMintAmount();

  error IncorrectSlippage();

  error InitialMintAmountMismatch(uint expected);

  error ImpossibleMint();

  error ZeroShares();

  error ChainlinkInvalidPrice();

  error SampleAmountTooHigh();
}