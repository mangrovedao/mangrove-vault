// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library MangroveVaultErrors {

  error ZeroAddress();

  error NoUnderlyingBalance();

  error ZeroMintAmount();

  error IncorrectSlippage();

  error InitialMintAmountMismatch(uint expected);

  error ImpossibleMint();

  error ZeroShares();

  error ChainlinkInvalidPrice();

  error SampleAmountTooHigh();

  error InvalidManagerBalance();

  error CannotWithdrawToken(address unauthorizedToken);

  error MaxFeeExceeded();

  error QuoteAmountOverflow();

  error DepositExceedsMaxTotal();
}
