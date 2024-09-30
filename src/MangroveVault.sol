// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Mangrove
import {IMangrove, Local, OLKey} from "@mgv/src/IMangrove.sol";
import {Tick} from "@mgv/lib/core/TickLib.sol";
import {MAX_SAFE_VOLUME} from "@mgv/lib/core/Constants.sol";

// Mangrove Strategies
import {AbstractKandelSeeder} from
  "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/AbstractKandelSeeder.sol";
import {GeometricKandel} from "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/GeometricKandel.sol";

// OpenZeppelin
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Local dependencies
import {GeometricKandelExtra, Params} from "./lib/GeometricKandelExtra.sol";
import {IOracle} from "./oracles/IOracle.sol";
import {MangroveLib} from "./lib/MangroveLib.sol";
import {MangroveVaultConstants} from "./lib/MangroveVaultConstants.sol";
import {MangroveVaultErrors} from "./lib/MangroveVaultErrors.sol";
import {MangroveVaultEvents} from "./lib/MangroveVaultEvents.sol";

import {console2 as console} from "forge-std/console2.sol";

enum FundsState {
  Vault, // Funds are in the vault
  Passive, // Funds are in the kandel contract, but not actively listed on Mangrove
  Active // Funds are actively listed on Mangrove

}

// TODO: cap vault balance

struct KandelPosition {
  Tick tickIndex0;
  uint256 tickOffset;
  Params params;
  FundsState fundsState;
}

contract MangroveVault is Ownable, ERC20, ERC20Permit, Pausable, ReentrancyGuard {
  using SafeERC20 for IERC20;
  using Address for address;
  using SafeCast for uint256;
  using Math for uint256;
  using GeometricKandelExtra for GeometricKandel;
  using MangroveLib for IMangrove;
  /// @notice The GeometricKandel contract instance used for market making.

  GeometricKandel public kandel;

  /// @notice The AbstractKandelSeeder contract instance used to initialize the Kandel contract.
  AbstractKandelSeeder public immutable seeder;

  /// @notice The Mangrove deployment.
  IMangrove public immutable MGV;

  /// @notice The address of the first token in the token pair.
  address public immutable BASE;

  /// @notice The address of the second token in the token pair.
  address public immutable QUOTE;

  /// @notice The tick spacing for the Mangrove market.
  uint256 public immutable TICK_SPACING;

  /// @notice The factor to scale the quote token amount by at initial mint.
  uint256 public immutable QUOTE_SCALE;

  /// @notice The number of decimals of the LP token.
  uint8 public immutable DECIMALS;

  /// @notice The current state of the funds in the vault.
  FundsState public fundsState;

  /// @notice A mapping to track which swap contracts are allowed.
  mapping(address => bool) public allowedSwapContracts;

  /// @notice The tick index for the first offer in the Kandel contract.
  /// @dev This is the tick index for the first offer in the Kandel contract (defined as a bid on the token0/token1 offer list).
  Tick public tickIndex0;

  /// @notice The oracle used to get the price of the token pair.
  IOracle public immutable oracle;

  uint256 public lastTotalInQuote;
  uint256 public maxTotalInQuote;
  uint256 public fee; // 18 decimals

  address public feeRecipient;

  /**
   * @notice Constructor for the MangroveVault contract.
   * @param _seeder The AbstractKandelSeeder contract instance used to initialize the Kandel contract.
   * @param _BASE The address of the first token in the token pair.
   * @param _QUOTE The address of the second token in the token pair.
   * @param _tickSpacing The spacing between ticks on the Mangrove market.
   * @param _decimalsOffset The number of decimals to add to the quote token decimals.
   * @param _oracle The address of the oracle used to get the price of the token pair.
   * @param name The name of the ERC20 token, chosen to represent the Mangrove market and eventually the vault manager.
   * @param symbol The symbol of the ERC20 token, chosen to represent the Mangrove market and eventually the vault manager.
   */
  constructor(
    AbstractKandelSeeder _seeder,
    address _BASE,
    address _QUOTE,
    uint256 _tickSpacing,
    uint256 _decimalsOffset,
    string memory name,
    string memory symbol,
    address _oracle
  ) Ownable(msg.sender) ERC20(name, symbol) ERC20Permit(name) {
    seeder = _seeder;
    TICK_SPACING = _tickSpacing;
    MGV = _seeder.MGV();
    (BASE, QUOTE) = _BASE < _QUOTE ? (_BASE, _QUOTE) : (_QUOTE, _BASE);
    kandel = _seeder.sow(OLKey(BASE, QUOTE, _tickSpacing), false);
    oracle = IOracle(_oracle);
    DECIMALS = (ERC20(QUOTE).decimals() + _decimalsOffset).toUint8();
    QUOTE_SCALE = 10 ** _decimalsOffset;
  }

  /**
   * @inheritdoc ERC20
   */
  function decimals() public view override returns (uint8) {
    return DECIMALS;
  }

  /**
   * @notice Retrieves the parameters of the Kandel position.
   * @return params The parameters of the Kandel position.
   * * gasprice The gas price for the Kandel position (if 0 or lower than Mangrove gas price, will be set to Mangrove gas price).
   * * gasreq The gas request for the Kandel position (Gas used to consume one offer of the Kandel position).
   * * stepSize The step size for the Kandel position (It is the distance between an executed bid/ask and its dual offer).
   * * pricePoints The number of price points (offers) published by kandel (-1) (=> 3 price points will result in 2 live offers).
   */
  function kandelParams() public view returns (Params memory params) {
    return kandel._params();
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

  /**
   * @notice Retrieves the inferred balances of the Kandel contract for both tokens.
   * @dev The returned amounts are translations based on the origin of the funds, as underlyings could be deposited in another protocol.
   * @return baseAmount The inferred balance of base in the Kandel contract.
   * @return quoteAmount The inferred balance of quote in the Kandel contract.
   */
  function getKandelBalances() public view returns (uint256 baseAmount, uint256 quoteAmount) {
    (baseAmount, quoteAmount) = kandel.getBalances();
  }

  /**
   * @notice Retrieves the balances of the vault for both tokens minus the manager's balance.
   * @return baseAmount The balance of base in the vault.
   * @return quoteAmount The balance of quote in the vault.
   */
  function getVaultBalances() public view returns (uint256 baseAmount, uint256 quoteAmount) {
    baseAmount = IERC20(BASE).balanceOf(address(this));
    quoteAmount = IERC20(QUOTE).balanceOf(address(this));
  }

  /**
   * @notice Retrieves the total underlying balances of both tokens.
   * @dev Includes balances from both the vault and Kandel contract.
   * @dev The Kandel balances are inferred based on the origin of the funds, as underlyings could be deposited in another protocol.
   * @return baseAmount The total balance of base.
   * @return quoteAmount The total balance of quote.
   */
  function getUnderlyingBalances() public view returns (uint256 baseAmount, uint256 quoteAmount) {
    (baseAmount, quoteAmount) = getVaultBalances();
    (uint256 kandelBaseBalance, uint256 kandelQuoteBalance) = getKandelBalances();
    baseAmount += kandelBaseBalance;
    quoteAmount += kandelQuoteBalance;
  }

  /**
   * @notice Calculates the total value of the vault's assets in quote token.
   * @dev This function uses the oracle to convert the base token amount to quote token.
   * @return The total value of the vault's assets in quote token.
   */
  function getTotalInQuote() public view returns (uint256) {
    (uint256 baseAmount, uint256 quoteAmount) = getUnderlyingBalances();
    return _toQuoteAmount(baseAmount, quoteAmount);
  }

  /**
   * @notice Computes the shares that can be minted according to the maximum amounts of token0 and token1 provided.
   * @param baseAmountMax The maximum amount of base that can be used for minting.
   * @param quoteAmountMax The maximum amount of quote that can be used for minting.
   * @return baseAmountOut The actual amount of base that will be deposited.
   * @return quoteAmountOut The actual amount of quote that will be deposited.
   * @return shares The amount of shares that will be minted.
   *
   * @dev Reverts with `NoUnderlyingBalance` if both token0 and token1 balances are zero.
   * @dev Reverts with `ZeroMintAmount` if the calculated shares to be minted is zero.
   */
  function getMintAmounts(uint256 baseAmountMax, uint256 quoteAmountMax)
    public
    view
    returns (uint256 baseAmountOut, uint256 quoteAmountOut, uint256 shares)
  {
    uint256 _totalSupply = totalSupply();

    console.log("totalSupply", _totalSupply);

    // Accrue fee shares
    (uint256 feeShares,) = _accruedFeeShares();
    _totalSupply += feeShares;

    console.log("totalSupply after fee", _totalSupply);

    // If there is already a total supply of shares
    if (_totalSupply != 0) {
      (uint256 baseAmount, uint256 quoteAmount) = getUnderlyingBalances();

      // Calculate shares based on the available balances
      if (baseAmount == 0 && quoteAmount != 0) {
        shares = Math.mulDiv(quoteAmountMax, _totalSupply, quoteAmount);
      } else if (baseAmount != 0 && quoteAmount == 0) {
        shares = Math.mulDiv(baseAmountMax, _totalSupply, baseAmount);
      } else if (baseAmount == 0 && quoteAmount == 0) {
        revert MangroveVaultErrors.NoUnderlyingBalance();
      } else {
        shares = Math.min(
          Math.mulDiv(baseAmountMax, _totalSupply, baseAmount), Math.mulDiv(quoteAmountMax, _totalSupply, quoteAmount)
        );
      }

      // Revert if no shares can be minted
      if (shares == 0) {
        revert MangroveVaultErrors.ZeroMintAmount();
      }

      // Calculate the actual amounts of token0 and token1 to be deposited
      baseAmountOut = Math.mulDiv(shares, baseAmount, _totalSupply, Math.Rounding.Ceil);
      quoteAmountOut = Math.mulDiv(shares, quoteAmount, _totalSupply, Math.Rounding.Ceil);

      console.log("baseAmountOut", baseAmountOut);
      console.log("quoteAmountOut", quoteAmountOut);
    }
    // If there is no total supply, calculate initial shares
    else {
      Tick tick = _currentTick();

      // Cap the amounts at MAX_SAFE_VOLUME to prevent overflow
      quoteAmountMax = Math.min(quoteAmountMax, MAX_SAFE_VOLUME);

      baseAmountOut = tick.outboundFromInbound(quoteAmountMax);
      // Adjust the output amounts based on the maximum allowed amounts
      if (baseAmountOut > baseAmountMax) {
        // Cap the base amount at MAX_SAFE_VOLUME to prevent overflow
        baseAmountMax = Math.min(baseAmountMax, MAX_SAFE_VOLUME);
        baseAmountOut = baseAmountMax;
        quoteAmountOut = tick.inboundFromOutboundUp(baseAmountOut);
      } else {
        quoteAmountOut = quoteAmountMax;
      }

      // Calculate the shares to be minted taking dead shares into account
      (, shares) = ((tick.inboundFromOutboundUp(baseAmountOut) + quoteAmountOut) * QUOTE_SCALE).trySub(
        MangroveVaultConstants.MINIMUM_LIQUIDITY
      );
    }
  }

  /**
   * @notice Calculates the underlying token balances corresponding to a given share amount.
   * @param share The amount of shares to calculate the underlying balances for.
   * @return baseAmount The amount of base corresponding to the given share.
   * @return quoteAmount The amount of quote corresponding to the given share.
   * @dev This function returns the underlying token balances based on the current total supply of shares.
   *      If the total supply is zero, it returns (0, 0).
   */
  function getUnderlyingBalancesByShare(uint256 share) public view returns (uint256 baseAmount, uint256 quoteAmount) {
    (uint256 baseBalance, uint256 quoteBalance) = getUnderlyingBalances();
    uint256 _totalSupply = totalSupply();
    // Accrue fee shares
    (uint256 feeShares,) = _accruedFeeShares();
    _totalSupply += feeShares;
    if (_totalSupply == 0) {
      return (0, 0);
    }
    baseAmount = Math.mulDiv(share, baseBalance, _totalSupply, Math.Rounding.Floor);
    quoteAmount = Math.mulDiv(share, quoteBalance, _totalSupply, Math.Rounding.Floor);
  }

  // interact functions

  struct MintHeap {
    uint256 totalSupply;
    uint256 baseBalance;
    uint256 quoteBalance;
    uint256 baseAmount;
    uint256 quoteAmount;
    FundsState fundsState;
    Tick tick;
    uint256 computedShares;
    IERC20 base;
    IERC20 quote;
  }

  /**
   * @notice Mints new shares by depositing tokens into the vault
   * @param mintAmount The amount of shares to mint
   * @param baseAmountMax The maximum amount of base to deposit
   * @param quoteAmountMax The maximum amount of quote to deposit
   * @return shares The number of shares minted
   * @return baseAmount The actual amount of base deposited
   * @return quoteAmount The actual amount of quote deposited
   * @dev This function calculates the required token amounts based on the current state of the vault:
   *      - If the vault has existing shares, it calculates proportional amounts based on current balances
   *      - For the initial mint, it uses the current oracle price to determine token amounts
   *      - Tokens are transferred from the user, deposited into Kandel if necessary, and new shares are minted
   *      - The function updates the vault's position after minting
   * @dev Reverts if:
   *      - The vault is paused
   *      - The initial mint amount doesn't match the computed shares
   *      - Minting is impossible due to unset funds state
   *      - The required token amounts exceed the specified maximums (slippage protection)
   *      - unable to transfer tokens from user
   */
  function mint(uint256 mintAmount, uint256 baseAmountMax, uint256 quoteAmountMax)
    public
    whenNotPaused
    nonReentrant
    returns (uint256 shares, uint256 baseAmount, uint256 quoteAmount)
  {
    if (mintAmount == 0) revert MangroveVaultErrors.ZeroMintAmount();

    _updateLastTotalInQuote(_accrueFee());

    // Initialize a MintHeap struct to store temporary variables
    MintHeap memory heap;
    // Get the current total supply of shares
    heap.totalSupply = totalSupply();
    // Get the current funds state
    heap.fundsState = fundsState;

    // If there are existing shares
    if (heap.totalSupply != 0) {
      // Get the current underlying balances
      (heap.baseBalance, heap.quoteBalance) = getUnderlyingBalances();
      // Calculate proportional amounts of tokens needed based on existing balances
      heap.baseAmount = Math.mulDiv(mintAmount, heap.baseBalance, heap.totalSupply, Math.Rounding.Ceil);
      heap.quoteAmount = Math.mulDiv(mintAmount, heap.quoteBalance, heap.totalSupply, Math.Rounding.Ceil);
    }
    // If it's the initial mint and funds state is not Unset
    else {
      // Get the current oracle price
      heap.tick = _currentTick();
      // Calculate token0 amount based on max token1 amount and current price
      heap.baseAmount = heap.tick.outboundFromInbound(quoteAmountMax);
      // If calculated token0 amount exceeds max, adjust amounts
      if (heap.baseAmount > baseAmountMax) {
        heap.baseAmount = baseAmountMax;
        heap.quoteAmount = heap.tick.inboundFromOutboundUp(baseAmountMax);
      } else {
        heap.quoteAmount = quoteAmountMax;
      }
      // Calculate shares based on geometric mean of token amounts
      (, heap.computedShares) = ((heap.tick.inboundFromOutboundUp(heap.baseAmount) + heap.quoteAmount) * QUOTE_SCALE)
        .trySub(MangroveVaultConstants.MINIMUM_LIQUIDITY);
      // Ensure computed shares match the requested mint amount
      if (heap.computedShares != mintAmount) {
        revert MangroveVaultErrors.InitialMintAmountMismatch(heap.computedShares);
      }
      _mint(address(this), MangroveVaultConstants.MINIMUM_LIQUIDITY); // dead shares
    }

    // Check if required amounts exceed specified maximums (slippage protection)
    if (heap.baseAmount > baseAmountMax || heap.quoteAmount > quoteAmountMax) {
      revert MangroveVaultErrors.IncorrectSlippage();
    }

    // Get token interfaces
    heap.base = IERC20(BASE);
    heap.quote = IERC20(QUOTE);

    // Transfer tokens from user to this contract
    heap.base.safeTransferFrom(msg.sender, address(this), heap.baseAmount);
    heap.quote.safeTransferFrom(msg.sender, address(this), heap.quoteAmount);

    // Mint new shares to the user
    _mint(msg.sender, mintAmount);

    // Update the vault's position
    _updatePosition();

    _updateLastTotalInQuote(getTotalInQuote());

    // Return minted shares and deposited token amounts
    return (mintAmount, heap.baseAmount, heap.quoteAmount);
  }

  struct BurnHeap {
    uint256 totalSupply;
    uint256 vaultBalanceBase;
    uint256 vaultBalanceQuote;
    uint256 kandelBalanceBase;
    uint256 kandelBalanceQuote;
    uint256 underlyingBalanceBase;
    uint256 underlyingBalanceQuote;
  }

  /**
   * @notice Burns shares and withdraws underlying assets
   * @dev This function calculates the proportion of assets to withdraw based on the number of shares being burned,
   *      withdraws funds from Kandel if necessary, and transfers the assets to the user.
   * @param shares The number of shares to burn
   * @param minAmountBaseOut The minimum amount of base to receive (slippage protection)
   * @param minAmountQuoteOut The minimum amount of quote to receive (slippage protection)
   * @return amountBaseOut The actual amount of base withdrawn
   * @return amountQuoteOut The actual amount of quote withdrawn
   * @dev MangroveVaultErrors.ZeroShares If the number of shares to burn is zero
   * @dev MangroveVaultErrors.IncorrectSlippage If the withdrawal amounts are less than the specified minimums
   */
  function burn(uint256 shares, uint256 minAmountBaseOut, uint256 minAmountQuoteOut)
    public
    whenNotPaused
    nonReentrant
    returns (uint256 amountBaseOut, uint256 amountQuoteOut)
  {
    if (shares == 0) revert MangroveVaultErrors.ZeroShares();

    _updateLastTotalInQuote(_accrueFee());

    BurnHeap memory heap;

    // Calculate the proportion of total assets to withdraw
    heap.totalSupply = totalSupply();

    // Burn the shares
    _burn(msg.sender, shares);

    // Get current balances
    (heap.vaultBalanceBase, heap.vaultBalanceQuote) = getVaultBalances();
    (heap.kandelBalanceBase, heap.kandelBalanceQuote) = getKandelBalances();

    // Calculate the user's share of the underlying assets
    heap.underlyingBalanceBase = Math.mulDiv(shares, heap.vaultBalanceBase + heap.kandelBalanceBase, heap.totalSupply);
    heap.underlyingBalanceQuote =
      Math.mulDiv(shares, heap.vaultBalanceQuote + heap.kandelBalanceQuote, heap.totalSupply);

    // Check if the withdrawal amounts meet the minimum requirements (slippage protection)
    if (heap.underlyingBalanceBase < minAmountBaseOut || heap.underlyingBalanceQuote < minAmountQuoteOut) {
      revert MangroveVaultErrors.IncorrectSlippage();
    }

    // Withdraw from Kandel if the vault doesn't have enough balance
    if (heap.underlyingBalanceBase > heap.vaultBalanceBase || heap.underlyingBalanceQuote > heap.vaultBalanceQuote) {
      (, uint256 withdrawAmountBase) = heap.underlyingBalanceBase.trySub(heap.vaultBalanceBase);
      (, uint256 withdrawAmountQuote) = heap.underlyingBalanceQuote.trySub(heap.vaultBalanceQuote);
      kandel.withdrawFunds(withdrawAmountBase, withdrawAmountQuote, address(this));
    }

    // Transfer the assets to the user
    IERC20(BASE).safeTransfer(msg.sender, heap.underlyingBalanceBase);
    IERC20(QUOTE).safeTransfer(msg.sender, heap.underlyingBalanceQuote);

    // Update the vault's position
    _updatePosition();

    _updateLastTotalInQuote(getTotalInQuote());

    // Set the return values
    amountBaseOut = heap.underlyingBalanceBase;
    amountQuoteOut = heap.underlyingBalanceQuote;

    emit MangroveVaultEvents.Burn(msg.sender, shares, amountBaseOut, amountQuoteOut);
  }

  function updatePosition() public {
    _updatePosition();
  }

  // admin functions

  /**
   * @notice Allows a specific contract to perform swaps on behalf of the vault
   * @dev Can only be called by the owner of the contract
   * @param contractAddress The address of the contract to be allowed
   */
  function allowSwapContract(address contractAddress) public onlyOwner {
    allowedSwapContracts[contractAddress] = true;
    emit MangroveVaultEvents.SwapContractAllowed(contractAddress, true);
  }

  /**
   * @notice Disallows a previously allowed contract from performing swaps on behalf of the vault
   * @dev Can only be called by the owner of the contract
   * @param contractAddress The address of the contract to be disallowed
   */
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

  /**
   * @notice Executes a swap operation on behalf of the vault
   * @dev This function can only be called by the owner of the contract
   * @param target The address of the contract to execute the swap on
   * @param data The calldata to be sent to the target contract
   * @param amountOut The amount of tokens to be swapped out
   * @param amountInMin The minimum amount of tokens to be received
   * @param sell If true, sell BASE; otherwise, sell QUOTE
   */
  function swap(address target, bytes calldata data, uint256 amountOut, uint256 amountInMin, bool sell)
    public
    onlyOwner
    nonReentrant
  {
    // Get current balances of BASE and QUOTE tokens in the vault
    (uint256 baseBalance, uint256 quoteBalance) = getVaultBalances();

    if (sell) {
      // If selling BASE, check if we need to withdraw from Kandel
      (, uint256 missingBase) = amountOut.trySub(baseBalance);
      if (missingBase > 0) {
        // Withdraw missing BASE from Kandel
        kandel.withdrawFunds(missingBase, 0, address(this));
        baseBalance += missingBase;
      }
      // Approve the swap target to spend BASE
      IERC20(BASE).forceApprove(target, amountOut);
    } else {
      // If selling QUOTE, check if we need to withdraw from Kandel
      (, uint256 missingQuote) = amountOut.trySub(quoteBalance);
      if (missingQuote > 0) {
        // Withdraw missing QUOTE from Kandel
        kandel.withdrawFunds(0, missingQuote, address(this));
        quoteBalance += missingQuote;
      }
      // Approve the swap target to spend QUOTE
      IERC20(QUOTE).forceApprove(target, amountOut);
    }

    // Execute the swap
    target.functionCall(data);

    // Get new balances after the swap
    (uint256 newBaseBalance, uint256 newQuoteBalance) = getVaultBalances();

    // Calculate net changes in BASE and QUOTE
    int256 netBaseChange = newBaseBalance.toInt256() - baseBalance.toInt256();
    int256 netQuoteChange = newQuoteBalance.toInt256() - quoteBalance.toInt256();

    if (sell) {
      // Check if the received QUOTE meets the minimum amount
      if (netQuoteChange < amountInMin.toInt256()) revert MangroveVaultErrors.IncorrectSlippage();
      // Reset approval for BASE
      IERC20(BASE).forceApprove(target, 0);
    } else {
      // Check if the received BASE meets the minimum amount
      if (netBaseChange < amountInMin.toInt256()) revert MangroveVaultErrors.IncorrectSlippage();
      // Reset approval for QUOTE
      IERC20(QUOTE).forceApprove(target, 0);
    }
    emit MangroveVaultEvents.Swap(address(kandel), netBaseChange, netQuoteChange, sell);

    _updatePosition();
  }

  function setPosition(KandelPosition memory position) public onlyOwner {
    _setPosition(position);
    _updatePosition();
  }

  function withdrawFromMangrove(uint256 amount, address payable receiver) public onlyOwner {
    kandel.withdrawFromMangrove(amount, receiver);
  }

  function withdrawERC20(address token, uint256 amount) public onlyOwner {
    // We can not withdraw the vault's own tokens, nor BASE nor QUOTE from this function
    if (token == BASE || token == QUOTE || token == address(this)) {
      revert MangroveVaultErrors.CannotWithdrawToken(token);
    }
    IERC20(token).safeTransfer(msg.sender, amount);
  }

  function withdrawNative() public onlyOwner {
    payable(msg.sender).transfer(address(this).balance);
  }

  function pause() public onlyOwner {
    _pause();
  }

  function unpause() public onlyOwner {
    _unpause();
  }

  receive() external payable {
    _fundMangrove();
  }

  function _currentTick() internal view returns (Tick) {
    return oracle.tick();
  }

  function _toQuoteAmount(uint256 amountBase, uint256 amountQuote) internal view returns (uint256) {
    Tick tick = _currentTick();
    return amountQuote + tick.inboundFromOutboundUp(amountBase);
  }

  function _depositAllFunds() internal {
    (uint256 baseBalance, uint256 quoteBalance) = getVaultBalances();
    if (baseBalance > 0) {
      IERC20(BASE).forceApprove(address(kandel), baseBalance);
    }
    if (quoteBalance > 0) {
      IERC20(QUOTE).forceApprove(address(kandel), quoteBalance);
    }
    kandel.depositFunds(baseBalance, quoteBalance);
  }

  function _fullCurrentDistribution()
    internal
    view
    returns (GeometricKandel.Distribution memory distribution, bool valid)
  {
    Params memory params;
    uint256 bidGives;
    uint256 askGives;
    (distribution, params, bidGives, askGives) = kandel.distribution(tickIndex0, _currentTick());
    (uint256 bidVolume, uint256 askVolume) = MGV.minVolumes(OLKey(BASE, QUOTE, TICK_SPACING), params.gasreq);
    valid = bidGives >= bidVolume && askGives >= askVolume;
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
      kandel.withdrawAllOffers();
    }
  }

  function _updatePosition() internal {
    if (fundsState == FundsState.Active) {
      _depositAllFunds();
      _refillPosition();
    } else if (fundsState == FundsState.Passive) {
      _depositAllFunds();
      kandel.withdrawAllOffers();
    } else {
      kandel.withdrawAllOffersAndFundsTo(payable(address(this)));
    }
  }

  function _setPosition(KandelPosition memory position) internal {
    tickIndex0 = position.tickIndex0;

    kandel.setBaseQuoteTickOffset(position.tickOffset);

    GeometricKandel.Params memory params;
    Params memory _params = position.params;

    assembly {
      params := _params
    }

    GeometricKandel.Distribution memory distribution;

    kandel.populate{value: msg.value}(distribution, params, 0, 0);

    MangroveVaultEvents.emitSetKandelPosition(position);
  }

  function _fundMangrove() internal {
    MGV.fund{value: msg.value}(address(kandel));
  }

  function _updateLastTotalInQuote(uint256 totalInQuote) internal {
    lastTotalInQuote = totalInQuote;

    emit MangroveVaultEvents.UpdateLastTotalInQuote(totalInQuote);
  }

  function _accrueFee() internal returns (uint256 newTotalInQuote) {
    uint256 feeShares;
    (feeShares, newTotalInQuote) = _accruedFeeShares();
    if (feeShares > 0) {
      _mint(feeRecipient, feeShares);
    }
    emit MangroveVaultEvents.AccrueInterest(feeShares, newTotalInQuote);
  }

  function _accruedFeeShares() internal view returns (uint256 feeShares, uint256 newTotalInQuote) {
    newTotalInQuote = getTotalInQuote();
    (, uint256 interest) = newTotalInQuote.trySub(lastTotalInQuote);
    if (interest != 0 && fee != 0) {
      uint256 feeQuote = interest.mulDiv(fee, MangroveVaultConstants.FEE_PRECISION);
      feeShares = Math.mulDiv(feeQuote, totalSupply(), newTotalInQuote - interest, Math.Rounding.Floor);
    }
  }
}
