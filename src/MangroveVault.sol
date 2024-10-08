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

struct InitialParams {
  uint256 initialMaxTotalInQuote;
  uint256 performanceFee;
  uint256 managementFee;
  address feeRecipient;
}

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
  using SafeCast for int256;
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

  /// @notice The oracle used to get the price of the token pair.
  IOracle public immutable oracle;

  /// @notice A mapping to track which swap contracts are allowed.
  mapping(address => bool) public allowedSwapContracts;

  /// @notice The last total in quote value.
  uint256 public lastTotalInQuote;

  /// @notice The maximum total in quote value.
  uint256 public maxTotalInQuote;

  struct State {
    /// @notice The current state of the funds in the vault.
    FundsState fundsState; // 8 bits
    /// @notice The tick index for the first offer in the Kandel contract.
    /// @dev This is the tick index for the first offer in the Kandel contract (defined as a bid on the base/quote offer list).
    int24 tickIndex0; // + 24 bits = 32 bits
    /// @notice The address of the fee recipient.
    address feeRecipient; // + 160 bits = 192 bits
    /// @notice The last timestamp when the total in quote was updated.
    uint32 lastTimestamp; // + 32 bits = 224 bits
    /// @notice The performance fee.
    uint16 performanceFee; // + 16 bits = 240 bits
    /// @notice The management fee.
    uint16 managementFee; // + 16 bits = 256 bits
  }

  State internal _state;

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
    address _oracle,
    InitialParams memory _initialParams
  ) Ownable(msg.sender) ERC20(name, symbol) ERC20Permit(name) {
    seeder = _seeder;
    TICK_SPACING = _tickSpacing;
    MGV = _seeder.MGV();
    (BASE, QUOTE) = _BASE < _QUOTE ? (_BASE, _QUOTE) : (_QUOTE, _BASE);
    kandel = _seeder.sow(OLKey(BASE, QUOTE, _tickSpacing), false);
    oracle = IOracle(_oracle);
    DECIMALS = (ERC20(QUOTE).decimals() + _decimalsOffset).toUint8();
    QUOTE_SCALE = 10 ** _decimalsOffset;

    maxTotalInQuote = _initialParams.initialMaxTotalInQuote;
    _state.performanceFee = _initialParams.performanceFee.toUint16();
    _state.managementFee = _initialParams.managementFee.toUint16();
    _state.feeRecipient = _initialParams.feeRecipient;
    _state.lastTimestamp = block.timestamp.toUint32();
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
   * @notice Retrieves the current tick at index 0 of the Kandel position.
   * @return The tick index as an int24 value.
   */
  function tickIndex0() public view returns (int24) {
    return _state.tickIndex0;
  }

  /**
   * @notice Gets the address of the current fee recipient.
   * @return The address of the fee recipient.
   */
  function feeRecipient() public view returns (address) {
    return _state.feeRecipient;
  }

  /**
   * @notice Retrieves the current performance fee rate.
   * @return The performance fee rate as a uint16 value.
   */
  function performanceFee() public view returns (uint16) {
    return _state.performanceFee;
  }

  /**
   * @notice Retrieves the current management fee rate.
   * @return The management fee rate as a uint16 value.
   */
  function managementFee() public view returns (uint16) {
    return _state.managementFee;
  }

  /**
   * @notice Gets the timestamp of the last fee accrual or relevant state update.
   * @return The last timestamp as a uint32 value.
   */
  function lastTimestamp() public view returns (uint32) {
    return _state.lastTimestamp;
  }

  /**
   * @notice Gets the current tick of the Kandel position.
   * @return The current tick
   */
  function currentTick() public view returns (Tick) {
    return _currentTick();
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
   * @return quoteAmount The total value of the vault's assets in quote token.
   * @return tick The tick at which the conversion is made.
   */
  function getTotalInQuote() public view returns (uint256 quoteAmount, Tick tick) {
    uint256 baseAmount;
    (baseAmount, quoteAmount) = getUnderlyingBalances();
    (quoteAmount, tick) = _toQuoteAmount(baseAmount, quoteAmount);
  }

  /**
   * @notice Computes the shares that can be minted according to the maximum amounts of base and quote provided.
   * @param baseAmountMax The maximum amount of base that can be used for minting.
   * @param quoteAmountMax The maximum amount of quote that can be used for minting.
   * @return baseAmountOut The actual amount of base that will be deposited.
   * @return quoteAmountOut The actual amount of quote that will be deposited.
   * @return shares The amount of shares that will be minted.
   *
   * @dev Reverts with `NoUnderlyingBalance` if both base and quote balances are zero.
   * @dev Reverts with `ZeroMintAmount` if the calculated shares to be minted is zero.
   */
  function getMintAmounts(uint256 baseAmountMax, uint256 quoteAmountMax)
    public
    view
    returns (uint256 baseAmountOut, uint256 quoteAmountOut, uint256 shares)
  {
    // Cap the max amounts to avoid overflow
    baseAmountMax = Math.min(baseAmountMax, MAX_SAFE_VOLUME);
    quoteAmountMax = Math.min(quoteAmountMax, MAX_SAFE_VOLUME);

    uint256 _totalSupply = totalSupply();

    // Accrue fee shares
    (uint256 feeShares,,) = _accruedFeeShares();
    _totalSupply += feeShares;

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

      // Calculate the actual amounts of base and quote to be deposited
      baseAmountOut = Math.mulDiv(shares, baseAmount, _totalSupply, Math.Rounding.Ceil);
      quoteAmountOut = Math.mulDiv(shares, quoteAmount, _totalSupply, Math.Rounding.Ceil);
    }
    // If there is no total supply, calculate initial shares
    else {
      Tick tick = _currentTick();

      baseAmountOut = tick.outboundFromInbound(quoteAmountMax);
      // Adjust the output amounts based on the maximum allowed amounts
      if (baseAmountOut > baseAmountMax) {
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
    (uint256 feeShares,,) = _accruedFeeShares();
    _totalSupply += feeShares;
    if (_totalSupply == 0) {
      return (0, 0);
    }
    baseAmount = share.mulDiv(baseBalance, _totalSupply, Math.Rounding.Floor);
    quoteAmount = share.mulDiv(quoteBalance, _totalSupply, Math.Rounding.Floor);
  }

  // interact functions

  function fundMangrove() public payable {
    _fundMangrove();
  }

  struct MintHeap {
    uint256 totalInQuote;
    bool totalInQuoteNoOverflow;
    uint256 newTotalInQuote;
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

    // Initialize a MintHeap struct to store temporary variables
    MintHeap memory heap;

    (heap.totalInQuote, heap.tick) = _accrueFee();

    _updateLastTotalInQuote(heap.totalInQuote);

    // Get the current total supply of shares
    heap.totalSupply = totalSupply();
    // Get the current funds state
    heap.fundsState = _state.fundsState;

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
      // Calculate base amount based on max quote amount and current price
      heap.baseAmount = heap.tick.outboundFromInbound(quoteAmountMax);
      // If calculated base amount exceeds max, adjust amounts
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

    // check if the new total in quote overflows or if it is greater than maxTotalInQuote
    (heap.totalInQuoteNoOverflow, heap.newTotalInQuote) =
      heap.totalInQuote.tryAdd(_toQuoteAmount(heap.baseAmount, heap.quoteAmount, heap.tick));

    if (!heap.totalInQuoteNoOverflow) {
      revert MangroveVaultErrors.QuoteAmountOverflow();
    }

    if (heap.newTotalInQuote > maxTotalInQuote) {
      revert MangroveVaultErrors.DepositExceedsMaxTotal();
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

    // Here we assume the sum of the previous total and the deposited amount is the new total in quote and take a snapshot
    // This then should truly account for performance from the deposit
    _updateLastTotalInQuote(heap.newTotalInQuote);

    // Return minted shares and deposited token amounts
    return (mintAmount, heap.baseAmount, heap.quoteAmount);
  }

  struct BurnHeap {
    uint256 totalInQuote;
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

    BurnHeap memory heap;

    (heap.totalInQuote,) = _accrueFee();
    _updateLastTotalInQuote(heap.totalInQuote);

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

    (uint256 quoteAmountTotal,) = getTotalInQuote();
    _updateLastTotalInQuote(quoteAmountTotal);

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
    _swap(target, data, amountOut, amountInMin, sell);
  }

  function swapAndSetPosition(
    address target,
    bytes calldata data,
    uint256 amountOut,
    uint256 amountInMin,
    bool sell,
    KandelPosition memory position
  ) public onlyOwner nonReentrant {
    _setPosition(position);
    _swap(target, data, amountOut, amountInMin, sell);
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

  function setPerformanceFee(uint256 _fee) public onlyOwner {
    if (_fee > MangroveVaultConstants.MAX_PERFORMANCE_FEE) revert MangroveVaultErrors.MaxFeeExceeded();
    _state.performanceFee = _fee.toUint16();
  }

  function setManagementFee(uint256 _fee) public onlyOwner {
    if (_fee > MangroveVaultConstants.MAX_MANAGEMENT_FEE) revert MangroveVaultErrors.MaxFeeExceeded();
    _state.managementFee = _fee.toUint16();
  }

  function setFeeRecipient(address _feeRecipient) public onlyOwner {
    if (_feeRecipient == address(0)) revert MangroveVaultErrors.ZeroAddress();
    _state.feeRecipient = _feeRecipient;
  }

  receive() external payable {
    _fundMangrove();
  }

  function _swap(address target, bytes calldata data, uint256 amountOut, uint256 amountInMin, bool sell) internal {
    if (target == address(kandel)) {
      revert MangroveVaultErrors.CannotCallKandel();
    }

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
    emit MangroveVaultEvents.Swap(target, netBaseChange, netQuoteChange, sell);

    _updatePosition();
  }

  function _currentTick() internal view returns (Tick) {
    return oracle.tick();
  }

  function _toQuoteAmount(uint256 amountBase, uint256 amountQuote)
    internal
    view
    returns (uint256 quoteAmount, Tick tick)
  {
    tick = _currentTick();
    quoteAmount = _toQuoteAmount(amountBase, amountQuote, tick);
  }

  function _toQuoteAmount(uint256 amountBase, uint256 amountQuote, Tick tick)
    internal
    pure
    returns (uint256 quoteAmount)
  {
    quoteAmount = amountQuote + tick.inboundFromOutboundUp(amountBase);
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
    (distribution, params, bidGives, askGives) = kandel.distribution(Tick.wrap(_state.tickIndex0), _currentTick());
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
    if (_state.fundsState == FundsState.Active) {
      _depositAllFunds();
      _refillPosition();
    } else if (_state.fundsState == FundsState.Passive) {
      _depositAllFunds();
      kandel.withdrawAllOffers();
    } else {
      kandel.withdrawAllOffersAndFundsTo(payable(address(this)));
    }
  }

  /**
   * @notice Sets the Kandel position for the vault
   * @dev This function updates the Kandel parameters and populates the offer distribution
   * @param position The KandelPosition struct containing the following fields:
   *   - tickIndex0: The tick index for the first price point
   *   - tickOffset: The tick offset between price points (must be a maximum of 24 bits wide)
   *   - params: The Params struct containing:
   *     - gasprice: The gas price for offer execution (if zero, stays unchanged)
   *     - gasreq: The gas required for offer execution (if zero, stays unchanged)
   *     - stepSize: The step size between offers
   *     - pricePoints: The number of price points in the distribution
   */
  function _setPosition(KandelPosition memory position) internal {
    _state.tickIndex0 = Tick.unwrap(position.tickIndex0).toInt24();
    _state.fundsState = position.fundsState;

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
    _state.lastTimestamp = block.timestamp.toUint32();
    emit MangroveVaultEvents.UpdateLastTotalInQuote(totalInQuote, block.timestamp);
  }

  function _accrueFee() internal returns (uint256 newTotalInQuote, Tick tick) {
    uint256 feeShares;
    (feeShares, newTotalInQuote, tick) = _accruedFeeShares();
    if (feeShares > 0) {
      _mint(_state.feeRecipient, feeShares);
    }
    emit MangroveVaultEvents.AccrueInterest(feeShares, newTotalInQuote, block.timestamp);
  }

  function _accruedFeeShares() internal view returns (uint256 feeShares, uint256 newTotalInQuote, Tick tick) {
    (newTotalInQuote, tick) = getTotalInQuote();
    (, uint256 interest) = newTotalInQuote.trySub(lastTotalInQuote);
    (, uint256 timeElapsed) = block.timestamp.trySub(_state.lastTimestamp);
    if (
      (interest != 0 && _state.performanceFee != 0)
        || (newTotalInQuote != 0 && _state.managementFee != 0 && timeElapsed > 0)
    ) {
      // Accrue performance fee
      uint256 feeQuote = interest.mulDiv(_state.performanceFee, MangroveVaultConstants.PERFORMANCE_FEE_PRECISION);
      // Accrue management fee
      feeQuote +=
        newTotalInQuote.mulDiv(_state.managementFee * timeElapsed, MangroveVaultConstants.MANAGEMENT_FEE_PRECISION);
      // Fee shares to be minted
      feeShares = feeQuote.mulDiv(totalSupply(), newTotalInQuote - feeQuote, Math.Rounding.Floor);
    }
  }
}
