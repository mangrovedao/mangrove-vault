// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GeometricKandel} from "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/GeometricKandel.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {
  AbstractKandelSeeder,
  OLKey
} from "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/AbstractKandelSeeder.sol";
import {Tick} from "@mgv/lib/core/TickLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {OfferType} from "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/TradesBaseQuotePair.sol";
import {MangroveVaultErrors} from "./lib/MangroveVaultErrors.sol";
import {MangroveVaultEvents} from "./lib/MangroveVaultEvents.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IMangrove, Local} from "@mgv/src/IMangrove.sol";

enum FundsState {
  Unset, // Funds state is not set
  Vault, // Funds are in the vault
  Passive, // Funds are in the kandel contract, but not actively listed on Mangrove
  Active // Funds are actively listed on Mangrove

}

using SafeERC20 for IERC20;
using Address for address;
using SafeCast for uint256;

contract MangroveVault is Ownable, ERC20, ERC20Permit, Pausable {
  /// @notice The GeometricKandel contract instance used for market making.
  GeometricKandel public kandel;

  /// @notice The AbstractKandelSeeder contract instance used to initialize the Kandel contract.
  AbstractKandelSeeder public immutable seeder;

  /// @notice The Mangrove deployment.
  IMangrove public immutable MGV;

  /// @notice The address of the first token in the token pair.
  address public immutable token0;

  /// @notice The address of the second token in the token pair.
  address public immutable token1;

  /// @notice The tick spacing for the Mangrove market.
  uint256 public immutable tickSpacing;

  /// @notice The current state of the funds in the vault.
  FundsState public fundsState;

  /// @notice A mapping to track which swap contracts are allowed.
  mapping(address => bool) public allowedSwapContracts;

  /// @notice The tick index for the first offer in the Kandel contract.
  /// @dev This is the tick index for the first offer in the Kandel contract (defined as a bid on the token0/token1 offer list).
  Tick public tickIndex0;

  /**
   * @notice Constructor for the MangroveVault contract.
   * @dev token0 and token1 will be ordered according to address (smaller first).
   * @param _seeder The AbstractKandelSeeder contract instance used to initialize the Kandel contract.
   * @param _token0 The address of the first token in the token pair.
   * @param _token1 The address of the second token in the token pair.
   * @param _tickSpacing The spacing between ticks on the Mangrove market.
   * @param name The name of the ERC20 token, chosen to represent the Mangrove market and eventually the vault manager.
   * @param symbol The symbol of the ERC20 token, chosen to represent the Mangrove market and eventually the vault manager.
   */
  constructor(
    AbstractKandelSeeder _seeder,
    address _token0,
    address _token1,
    uint256 _tickSpacing,
    string memory name,
    string memory symbol
  ) Ownable(msg.sender) ERC20(name, symbol) ERC20Permit(name) {
    seeder = _seeder;
    tickSpacing = _tickSpacing;
    MGV = _seeder.MGV();
    (token0, token1) = _token0 < _token1 ? (_token0, _token1) : (_token1, _token0);
    kandel = _seeder.sow(OLKey(token0, token1, _tickSpacing), false);
  }

  function _currentTick() internal view returns (Tick) {
    return Tick.wrap(0);
  }

  /**
   * @notice Retrieves the parameters of the Kandel contract.
   * @return gasprice The gas price for the Kandel contract (if 0 or lower than Mangrove gas price, will be set to Mangrove gas price).
   * @return gasreq The gas request for the Kandel contract (Gas used to consume one offer of the Kandel contract).
   * @return stepSize The step size for the Kandel contract (It is the distance between an executed bid/ask and its dual offer).
   * @return pricePoints The number of price points (offers) published by kandel (-1) (=> 3 price points will result in 2 live offers).
   */
  function kandelParams() public view returns (uint32 gasprice, uint24 gasreq, uint32 stepSize, uint32 pricePoints) {
    (gasprice, gasreq, stepSize, pricePoints) = kandel.params();
  }

  /**
   * @notice Retrieves the tick offset for the Kandel contract.
   * @return The tick offset for the Kandel contract.
   * @dev The tick offset is the tick difference between consecutive offers in the Kandel contract.
   * * Because a the price is 1.0001^tick, tick offset is the number of bips in price between consecutive offers.
   */
  function kandelTickOffset() public view returns (uint256) {
    return kandel.baseQuoteTickOffset();
  }

  function markets() public view returns (OLKey memory olKey01, OLKey memory olKey10) {
    return (OLKey(token0, token1, tickSpacing), OLKey(token1, token0, tickSpacing));
  }

  /**
   * @notice Retrieves the inferred balances of the Kandel contract for both tokens.
   * @dev The returned amounts are translations based on the origin of the funds, as underlyings could be deposited in another protocol.
   * @return amount0 The inferred balance of token0 in the Kandel contract.
   * @return amount1 The inferred balance of token1 in the Kandel contract.
   */
  function getKandelBalances() public view returns (uint256 amount0, uint256 amount1) {
    amount0 = kandel.reserveBalance(OfferType.Ask);
    amount1 = kandel.reserveBalance(OfferType.Bid);
  }

  /**
   * @notice Retrieves the balances of the vault for both tokens.
   * @return amount0 The balance of token0 in the vault.
   * @return amount1 The balance of token1 in the vault.
   */
  function getVaultBalances() public view returns (uint256 amount0, uint256 amount1) {
    amount0 = IERC20(token0).balanceOf(address(this));
    amount1 = IERC20(token1).balanceOf(address(this));
  }

  /**
   * @notice Retrieves the total underlying balances of both tokens.
   * @dev Includes balances from both the vault and Kandel contract.
   * @dev The Kandel balances are inferred based on the origin of the funds, as underlyings could be deposited in another protocol.
   * @return amount0 The total balance of token0.
   * @return amount1 The total balance of token1.
   */
  function getUnderlyingBalances() public view returns (uint256 amount0, uint256 amount1) {
    (amount0, amount1) = getVaultBalances();
    (uint256 kandelBaseBalance, uint256 kandelQuoteBalance) = getKandelBalances();
    amount0 += kandelBaseBalance;
    amount1 += kandelQuoteBalance;
  }

  /**
   * @notice Computes the shares that can be minted according to the maximum amounts of token0 and token1 provided.
   * @param amount0Max The maximum amount of token0 that can be used for minting.
   * @param amount1Max The maximum amount of token1 that can be used for minting.
   * @return amount0Out The actual amount of token0 that will be deposited.
   * @return amount1Out The actual amount of token1 that will be deposited.
   * @return shares The amount of shares that will be minted.
   *
   * @dev Reverts with `NoUnderlyingBalance` if both token0 and token1 balances are zero.
   * @dev Reverts with `ZeroMintAmount` if the calculated shares to be minted is zero.
   */
  function getMintAmounts(uint256 amount0Max, uint256 amount1Max)
    public
    view
    returns (uint256 amount0Out, uint256 amount1Out, uint256 shares)
  {
    uint256 _totalSupply = totalSupply();

    // If there is already a total supply of shares
    if (_totalSupply != 0) {
      (uint256 amount0, uint256 amount1) = getUnderlyingBalances();

      // Calculate shares based on the available balances
      if (amount0 == 0 && amount1 != 0) {
        shares = Math.mulDiv(amount1Max, _totalSupply, amount1);
      } else if (amount0 != 0 && amount1 == 0) {
        shares = Math.mulDiv(amount0Max, _totalSupply, amount0);
      } else if (amount0 == 0 && amount1 == 0) {
        revert MangroveVaultErrors.NoUnderlyingBalance();
      } else {
        shares =
          Math.min(Math.mulDiv(amount0Max, _totalSupply, amount0), Math.mulDiv(amount1Max, _totalSupply, amount1));
      }

      // Revert if no shares can be minted
      if (shares == 0) {
        revert MangroveVaultErrors.ZeroMintAmount();
      }

      // Calculate the actual amounts of token0 and token1 to be deposited
      amount0Out = Math.mulDiv(shares, amount0, _totalSupply, Math.Rounding.Ceil);
      amount1Out = Math.mulDiv(shares, amount1, _totalSupply, Math.Rounding.Ceil);
    }
    // If the funds state is not unset and there is no total supply
    else if (fundsState != FundsState.Unset) {
      Tick tick = _currentTick();
      amount0Out = tick.outboundFromInbound(amount1Max);

      // Adjust the output amounts based on the maximum allowed amounts
      if (amount0Out > amount0Max) {
        amount0Out = amount0Max;
        amount1Out = tick.inboundFromOutboundUp(amount0Max);
      } else {
        amount1Out = amount1Max;
      }

      // Calculate the shares to be minted
      shares = Math.sqrt(amount0Out * amount1Out);
    }
  }

  /**
   * @notice Calculates the underlying token balances corresponding to a given share amount.
   * @param share The amount of shares to calculate the underlying balances for.
   * @return amount0 The amount of token0 corresponding to the given share.
   * @return amount1 The amount of token1 corresponding to the given share.
   * @dev This function returns the underlying token balances based on the current total supply of shares.
   *      If the total supply is zero, it returns (0, 0).
   */
  function getUnderlyingBalancesByShare(uint256 share) public view returns (uint256 amount0, uint256 amount1) {
    (uint256 token0Balance, uint256 token1Balance) = getUnderlyingBalances();
    uint256 totalSupply = totalSupply();
    if (totalSupply == 0) {
      return (0, 0);
    }
    amount0 = Math.mulDiv(share, token0Balance, totalSupply);
    amount1 = Math.mulDiv(share, token1Balance, totalSupply);
  }

  // interact functions

  struct MintHeap {
    uint256 totalSupply;
    uint256 amount0Balance;
    uint256 amount1Balance;
    uint256 amount0;
    uint256 amount1;
    FundsState fundsState;
    Tick tick;
    uint256 computedShares;
    IERC20 token0;
    IERC20 token1;
  }

  function mint(uint256 mintAmount, uint256 amount0Max, uint256 amount1Max)
    public
    whenNotPaused
    returns (uint256 shares, uint256 amount0, uint256 amount1)
  {
    MintHeap memory heap;
    heap.totalSupply = totalSupply();
    heap.fundsState = fundsState;
    if (heap.totalSupply != 0) {
      (heap.amount0Balance, heap.amount1Balance) = getUnderlyingBalances();
      heap.amount0 = Math.mulDiv(mintAmount, heap.amount0Balance, heap.totalSupply, Math.Rounding.Ceil);
      heap.amount1 = Math.mulDiv(mintAmount, heap.amount1Balance, heap.totalSupply, Math.Rounding.Ceil);
    } else if (heap.fundsState != FundsState.Unset) {
      heap.tick = _currentTick();
      heap.amount0 = heap.tick.outboundFromInbound(amount1Max);
      if (heap.amount0 > amount0Max) {
        heap.amount0 = amount0Max;
        heap.amount1 = heap.tick.inboundFromOutboundUp(amount0Max);
      } else {
        heap.amount1 = amount1Max;
      }
      heap.computedShares = Math.sqrt(heap.amount0 * heap.amount1);
      if (heap.computedShares != mintAmount) {
        revert MangroveVaultErrors.InitialMintAmountMismatch(heap.computedShares);
      }
    } else {
      revert MangroveVaultErrors.ImpossibleMint();
    }

    if (heap.amount0 > amount0Max || heap.amount1 > amount1Max) {
      revert MangroveVaultErrors.IncorrectSlippage();
    }

    heap.token0 = IERC20(token0);
    heap.token1 = IERC20(token1);

    heap.token0.safeTransferFrom(msg.sender, address(this), heap.amount0);
    heap.token1.safeTransferFrom(msg.sender, address(this), heap.amount1);

    if (heap.fundsState == FundsState.Passive || heap.fundsState == FundsState.Active) {
      heap.token0.forceApprove(address(kandel), heap.amount0);
      heap.token1.forceApprove(address(kandel), heap.amount1);

      kandel.depositFunds(heap.amount0, heap.amount1);
    }

    _mint(msg.sender, mintAmount);

    _updatePosition();

    return (mintAmount, heap.amount0, heap.amount1);
  }

  struct BurnHeap {
    uint256 totalSupply;
    uint256 vaultBalance0;
    uint256 vaultBalance1;
    uint256 kandelBalance0;
    uint256 kandelBalance1;
    uint256 underlyingBalance0;
    uint256 underlyingBalance1;
  }

  /**
   * @notice Burns shares and withdraws underlying assets
   * @param shares The number of shares to burn
   * @param minAmount0Out The minimum amount of token0 to receive
   * @param minAmount1Out The minimum amount of token1 to receive
   * @return amount0Out The actual amount of token0 withdrawn
   * @return amount1Out The actual amount of token1 withdrawn
   */
  function burn(uint256 shares, uint256 minAmount0Out, uint256 minAmount1Out)
    public
    whenNotPaused
    returns (uint256 amount0Out, uint256 amount1Out)
  {
    if (shares == 0) revert MangroveVaultErrors.ZeroShares();

    BurnHeap memory heap;

    // Calculate the proportion of total assets to withdraw
    heap.totalSupply = totalSupply();

    _burn(msg.sender, shares);

    (heap.vaultBalance0, heap.vaultBalance1) = getVaultBalances();
    (heap.kandelBalance0, heap.kandelBalance1) = getKandelBalances();

    heap.underlyingBalance0 = Math.mulDiv(shares, heap.vaultBalance0 + heap.kandelBalance0, heap.totalSupply);
    heap.underlyingBalance1 = Math.mulDiv(shares, heap.vaultBalance1 + heap.kandelBalance1, heap.totalSupply);

    // check slippage
    if (heap.underlyingBalance0 < minAmount0Out || heap.underlyingBalance1 < minAmount1Out) {
      revert MangroveVaultErrors.IncorrectSlippage();
    }

    // Withdraw from Kandel if necessary
    if (heap.underlyingBalance0 > heap.vaultBalance0 || heap.underlyingBalance1 > heap.vaultBalance1) {
      uint256 withdrawAmount0 =
        heap.underlyingBalance0 > heap.vaultBalance0 ? heap.underlyingBalance0 - heap.vaultBalance0 : 0;
      uint256 withdrawAmount1 =
        heap.underlyingBalance1 > heap.vaultBalance1 ? heap.underlyingBalance1 - heap.vaultBalance1 : 0;
      kandel.withdrawFunds(withdrawAmount0, withdrawAmount1, address(this));
    }

    IERC20(token0).safeTransfer(msg.sender, heap.underlyingBalance0);
    IERC20(token1).safeTransfer(msg.sender, heap.underlyingBalance1);

    _updatePosition();

    emit MangroveVaultEvents.Burn(msg.sender, shares, amount0Out, amount1Out);
  }

  // admin functions

  function allowSwapContract(address contractAddress) public onlyOwner {
    allowedSwapContracts[contractAddress] = true;
    emit MangroveVaultEvents.SwapContractAllowed(contractAddress, true);
  }

  function disallowSwapContract(address contractAddress) public onlyOwner {
    allowedSwapContracts[contractAddress] = false;
    emit MangroveVaultEvents.SwapContractAllowed(contractAddress, false);
  }

  struct SwapHeap {
    IERC20 tokenOut;
    IERC20 tokenIn;
    uint256 amountOutBalance;
    uint256 amountInBalance;
    uint256 amountToWithdraw;
    uint256 newAmountOutBalance;
    uint256 newAmountInBalance;
    int256 netAmountOut;
  }

  function swap(
    address target,
    bytes calldata data,
    uint256 amountOut,
    uint256 amountInMin,
    bool sellToken0,
    bool depositAll
  ) public onlyOwner {
    SwapHeap memory heap;

    {
      (heap.tokenOut, heap.tokenIn) = sellToken0 ? (IERC20(token0), IERC20(token1)) : (IERC20(token1), IERC20(token0));
      heap.amountOutBalance = heap.tokenOut.balanceOf(address(this));
      heap.amountToWithdraw = heap.amountOutBalance >= amountOut ? 0 : amountOut - heap.amountOutBalance;
    }

    if (heap.amountToWithdraw > 0) {
      if (sellToken0) {
        kandel.withdrawFunds(heap.amountToWithdraw, 0, address(this));
      } else {
        kandel.withdrawFunds(0, heap.amountToWithdraw, address(this));
      }
    }

    {
      heap.amountOutBalance = heap.tokenOut.balanceOf(address(this));
      heap.amountInBalance = heap.tokenIn.balanceOf(address(this));
    }

    heap.tokenOut.forceApprove(target, amountOut);

    target.functionCall(data);

    heap.tokenOut.forceApprove(target, 0);

    {
      heap.newAmountOutBalance = heap.tokenOut.balanceOf(address(this));
      heap.newAmountInBalance = heap.tokenIn.balanceOf(address(this));
    }

    if (heap.newAmountInBalance < heap.amountInBalance + amountInMin) {
      revert MangroveVaultErrors.IncorrectSlippage();
    }

    if (depositAll) {
      if (heap.newAmountOutBalance > 0) {
        heap.tokenOut.forceApprove(address(kandel), heap.newAmountOutBalance);
      }
      if (heap.newAmountInBalance > 0) {
        heap.tokenIn.forceApprove(address(kandel), heap.newAmountInBalance);
      }

      if (sellToken0) {
        kandel.depositFunds(heap.newAmountOutBalance, heap.newAmountInBalance);
      } else {
        kandel.depositFunds(heap.newAmountInBalance, heap.newAmountOutBalance);
      }
    }

    heap.netAmountOut = heap.newAmountOutBalance.toInt256() - heap.amountOutBalance.toInt256();

    emit MangroveVaultEvents.Swap(
      address(kandel),
      Math.ternary(heap.netAmountOut < 0, 0, uint256(heap.netAmountOut)),
      heap.newAmountInBalance - heap.amountInBalance,
      sellToken0
    );
  }

  function withdrawFromMangrove(uint256 amount) public onlyOwner {
    kandel.withdrawFromMangrove(amount, payable(msg.sender));
  }

  function pause() public onlyOwner {
    _pause();
  }

  function unpause() public onlyOwner {
    _unpause();
  }

  // internal functions

  function _currentFirstAskIndex() private view returns (uint256 i) {
    (,,, uint32 _pricePoints) = kandelParams();
    for (; i < _pricePoints; i++) {
      if (kandel.getOffer(OfferType.Bid, i).gives() == 0) {
        break;
      }
    }
  }

  function _depositAllFunds() internal {
    IERC20 _token0 = IERC20(token0);
    IERC20 _token1 = IERC20(token1);

    uint256 token0Balance = _token0.balanceOf(address(this));
    uint256 token1Balance = _token1.balanceOf(address(this));

    if (token0Balance > 0) {
      _token0.forceApprove(address(kandel), token0Balance);
    }
    if (token1Balance > 0) {
      _token1.forceApprove(address(kandel), token1Balance);
    }
    kandel.depositFunds(token0Balance, token1Balance);
  }

  function _fullCurrentDistribution()
    internal
    view
    returns (GeometricKandel.Distribution memory distribution, bool valid)
  {
    (, uint24 gasreq, uint32 stepSize, uint32 pricePoints) = kandelParams();
    uint256 firstAskIndex = _currentFirstAskIndex();
    uint256 baseQuoteTickOffset = kandelTickOffset();
    distribution = kandel.createDistribution(
      0, pricePoints, tickIndex0, baseQuoteTickOffset, firstAskIndex, 1, 1, pricePoints, stepSize
    );

    uint256 nBids;
    uint256 nAsks;

    for (uint256 i = 0; i < pricePoints; i++) {
      if (distribution.bids[i].gives > 0) {
        nBids++;
      }
      if (distribution.asks[i].gives > 0) {
        nAsks++;
      }
    }

    // get kandel balances
    (uint256 kandelBalance0, uint256 kandelBalance1) = getKandelBalances();

    uint256 bidGives = kandelBalance0 / nBids;
    uint256 askGives = kandelBalance1 / nAsks;

    for (uint256 i = 0; i < pricePoints; i++) {
      if (distribution.bids[i].gives > 0) {
        distribution.bids[i].gives = bidGives;
      }
      if (distribution.asks[i].gives > 0) {
        distribution.asks[i].gives = askGives;
      }
    }

    // // get min bid and ask volume required on mgv
    // (OLKey memory olKeyBid, OLKey memory olKeyAsk) = markets();
    // Local localBid = MGV.local(olKeyBid);
    // Local localAsk = MGV.local(olKeyAsk);

    // uint256 minBidVolume = localBid.density().multiplyUp(gasreq + localBid.offer_gasbase());
    // uint256 minAskVolume = localAsk.density().multiplyUp(gasreq + localAsk.offer_gasbase());

    // valid = bidGives >= minBidVolume && askGives >= minAskVolume;
  }

  function _refillPosition() internal {
    (GeometricKandel.Distribution memory distribution, bool valid) = _fullCurrentDistribution();
    if (valid) {
      try kandel.populateChunk(distribution) {}
      catch {
        valid = false;
      }
    }
    if (!valid) {
      _withdrawAllOffers();
    }
  }

  function _withdrawAllOffers() internal {
    (,,, uint32 pricePoints) = kandelParams();
    kandel.retractOffers(0, pricePoints);
  }

  function _withdrawAllFundsAndOffers() internal {
    (,,, uint32 pricePoints) = kandelParams();
    kandel.retractAndWithdraw(0, pricePoints, type(uint256).max, type(uint256).max, 0, payable(address(this)));
  }

  function _updatePosition() internal {
    if (fundsState == FundsState.Active) {
      _depositAllFunds();
      _refillPosition();
    } else if (fundsState == FundsState.Passive) {
      _depositAllFunds();
      _withdrawAllOffers();
    } else {
      _withdrawAllFundsAndOffers();
    }
  }
}
