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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";

// Local dependencies
import {GeometricKandelExtra, Params} from "./lib/GeometricKandelExtra.sol";
import {IOracle} from "./oracles/IOracle.sol";
import {MangroveLib} from "./lib/MangroveLib.sol";
import {MangroveVaultConstants} from "./lib/MangroveVaultConstants.sol";
import {MangroveVaultErrors} from "./lib/MangroveVaultErrors.sol";
import {MangroveVaultEvents} from "./lib/MangroveVaultEvents.sol";

/**
 * @notice Enum representing the state of funds in the vault
 * @dev This enum is used to track where the funds are currently located and their activity status
 * @dev Vault: Funds are held in the vault and not deployed to Mangrove
 * @dev Passive: Funds are deployed to Mangrove but not actively market making
 * @dev Active: Funds are deployed to Mangrove and actively market making
 */
enum FundsState {
  Vault,
  Passive,
  Active
}

/**
 * @notice Struct representing the Kandel position configuration
 * @dev This struct is used to set and update the Kandel strategy parameters
 * @param tickIndex0 The tick index for the first price point
 * @param tickOffset The tick offset between price points
 * @param params The Kandel strategy parameters
 * @param fundsState The current state of the funds
 */
struct KandelPosition {
  Tick tickIndex0;
  uint256 tickOffset;
  Params params;
  FundsState fundsState;
}

contract MangroveVault is Ownable, ERC20, Pausable, ReentrancyGuard {
  using SafeERC20 for IERC20;
  using Address for address;
  using SafeCast for uint256;
  using SafeCast for int256;
  using SignedMath for int256;
  using Math for uint256;
  using GeometricKandelExtra for GeometricKandel;
  using MangroveLib for IMangrove;
  /// @notice The GeometricKandel contract instance used for market making.

  GeometricKandel public immutable kandel;

  /// @notice The AbstractKandelSeeder contract instance used to initialize the Kandel contract.
  AbstractKandelSeeder public seeder;

  /// @notice The Mangrove deployment.
  IMangrove public immutable MGV;

  /// @notice The address of the first token in the token pair.
  address internal immutable BASE;

  /// @notice The address of the second token in the token pair.
  address internal immutable QUOTE;

  /// @notice The tick spacing for the Mangrove market.
  uint256 internal immutable TICK_SPACING;

  /// @notice The factor to scale the quote token amount by at initial mint.
  uint256 internal immutable QUOTE_SCALE;

  /// @notice The number of decimals of the LP token.
  uint8 internal DECIMALS;

  /// @notice The oracle used to get the price of the token pair.
  IOracle public immutable oracle;

  /// @notice A mapping to track which swap contracts are allowed.
  mapping(address => bool) public allowedSwapContracts;

  /**
   * @notice The current state of the vault
   * @dev This struct is packed into a single 256-bit storage slot
   * @param fundsState The current state of the funds in the vault.
   * @param tickIndex0 The tick index for the first offer in the Kandel contract (defined as a bid on the base/quote offer list).
   * @param feeRecipient The address of the fee recipient.
   * @param lastTimestamp The last timestamp when the total in quote was updated.
   * @param performanceFee The performance fee.
   * @param managementFee The management fee.
   * @param lastTotalInQuote The last total in quote value.
   * @param maxTotalInQuote The maximum total in quote value.
   */
  struct State {
    FundsState fundsState; // 8 bits
    int24 tickIndex0; // + 24 bits = 32 bits
    address feeRecipient; // + 160 bits = 192 bits
    uint32 lastTimestamp; // + 32 bits = 224 bits
    uint16 performanceFee; // + 16 bits = 240 bits
    uint16 managementFee; // + 16 bits = 256 bits
    uint128 lastTotalInQuote; // + 128 bits = 384 bits
    uint128 maxTotalInQuote; // + 128 bits = 512 bits
  }

  /// @notice The current state of the vault.
  State internal _state;

  /**
   * @notice Constructor for the MangroveVault contract.
   * @param _seeder The AbstractKandelSeeder contract instance used to initialize the Kandel contract.
   * @param _BASE The address of the first token in the token pair.
   * @param _QUOTE The address of the second token in the token pair.
   * @param _tickSpacing The spacing between ticks on the Mangrove market.
   * @param _decimals The number of decimals of the LP token.
   * @param _oracle The address of the oracle used to get the price of the token pair.
   * @param name The name of the ERC20 token, chosen to represent the Mangrove market and eventually the vault manager.
   * @param symbol The symbol of the ERC20 token, chosen to represent the Mangrove market and eventually the vault manager.
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
  ) Ownable(_owner) ERC20(name, symbol) {
    seeder = _seeder;
    TICK_SPACING = _tickSpacing;
    MGV = _seeder.MGV();
    BASE = _BASE;
    QUOTE = _QUOTE;
    kandel = _seeder.sow(OLKey(_BASE, _QUOTE, _tickSpacing), false);
    oracle = IOracle(_oracle);
    uint8 offset = _decimals - ERC20(_QUOTE).decimals();
    DECIMALS = _decimals;
    QUOTE_SCALE = 10 ** offset; // offset should not be larger than 19 decimals

    _state.maxTotalInQuote = type(uint128).max;
    emit MangroveVaultEvents.SetMaxTotalInQuote(_state.maxTotalInQuote);

    _state.feeRecipient = _owner;
    emit MangroveVaultEvents.SetFeeData(0, 0, _owner);
  }

  /**
   * @inheritdoc ERC20
   */
  function decimals() public view override returns (uint8) {
    return DECIMALS;
  }

  /**
   * @notice Retrieves the current market information for the vault
   * @dev This function returns the base token address, quote token address, and tick spacing for the market
   * @return base The address of the base token in the market
   * @return quote The address of the quote token in the market
   * @return tickSpacing The tick spacing used in the market
   */
  function market() external view returns (address base, address quote, uint256 tickSpacing) {
    return (BASE, QUOTE, TICK_SPACING);
  }

  /**
   * @notice Retrieves the parameters of the Kandel position.
   * @return params The parameters of the Kandel position.
   * * gasprice The gas price for the Kandel position (if 0 or lower than Mangrove gas price, will be set to Mangrove gas price).
   * * gasreq The gas request for the Kandel position (Gas used to consume one offer of the Kandel position).
   * * stepSize The step size for the Kandel position (It is the distance between an executed bid/ask and its dual offer).
   * * pricePoints The number of price points (offers) published by kandel (-1) (=> 3 price points will result in 2 live offers).
   */
  function kandelParams() external view returns (Params memory params) {
    return kandel._params();
  }

  /**
   * @notice Retrieves the tick offset for the Kandel contract.
   * @return The tick offset for the Kandel contract.
   * @dev The tick offset is the tick difference between consecutive offers in the Kandel contract.
   * * Because a the price is 1.0001^tick, tick offset is the number of bips in price between consecutive offers.
   */
  function kandelTickOffset() external view returns (uint256) {
    return kandel.baseQuoteTickOffset();
  }

  /**
   * @notice Retrieves the current state of the funds in the vault.
   * @return The current FundsState, which can be one of the following:
   * - 0: Vault - Funds are held in the vault contract
   * - 1: Passive - Funds are in the Kandel contract but not actively listed on Mangrove
   * - 2: Active - Funds are actively listed on Mangrove through the Kandel contract
   * @dev This function returns the funds state as a uint8 value (0-2) corresponding to the FundsState enum.
   */
  function fundsState() external view returns (FundsState) {
    return _state.fundsState;
  }

  /**
   * @notice Retrieves the current tick at index 0 of the Kandel position.
   * @return The tick index as an int24 value.
   */
  function tickIndex0() external view returns (int24) {
    return _state.tickIndex0;
  }

  /**
   * @notice Retrieves the current fee data for the vault
   * @dev This function returns the performance fee, management fee, and fee recipient address
   * @return performanceFee The current performance fee percentage as a uint16
   * @return managementFee The current management fee percentage as a uint16
   * @return feeRecipient The address of the current fee recipient
   */
  function feeData() external view returns (uint16 performanceFee, uint16 managementFee, address feeRecipient) {
    return (_state.performanceFee, _state.managementFee, _state.feeRecipient);
  }

  /**
   * @notice Gets the timestamp of the last fee accrual or relevant state update.
   * @return The last timestamp as a uint32 value.
   */
  function lastTimestamp() external view returns (uint32) {
    return _state.lastTimestamp;
  }

  /**
   * @notice Gets the current tick of the Kandel position.
   * @return The current tick
   */
  function currentTick() external view returns (Tick) {
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
   * @dev Reverts with `NoUnderlyingTokens` if both base and quote balances are zero.
   * @dev Reverts with `ZeroAmount` if the calculated shares to be minted is zero.
   */
  function getMintAmounts(uint256 baseAmountMax, uint256 quoteAmountMax)
    external
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

      uint256 baseShares = baseAmount != 0 ? baseAmountMax.mulDiv(_totalSupply, baseAmount) : 0;
      uint256 quoteShares = quoteAmount != 0 ? quoteAmountMax.mulDiv(_totalSupply, quoteAmount) : 0;

      shares = Math.min(baseShares, quoteShares);

      // Revert if no shares can be minted
      if (shares == 0) {
        revert MangroveVaultErrors.ZeroAmount();
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

  function fundMangrove() external payable {
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
    external
    whenNotPaused
    nonReentrant
    returns (uint256 shares, uint256 baseAmount, uint256 quoteAmount)
  {
    if (mintAmount == 0) revert MangroveVaultErrors.ZeroAmount();

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
        revert MangroveVaultErrors.InitialMintSharesMismatch(mintAmount, heap.computedShares);
      }
      _mint(address(this), MangroveVaultConstants.MINIMUM_LIQUIDITY); // dead shares
    }

    // Check if required base amount exceeds specified maximum (slippage protection)
    if (heap.baseAmount > baseAmountMax) {
      revert MangroveVaultErrors.SlippageExceeded(baseAmountMax, heap.baseAmount);
    }
    // Check if required quote amount exceeds specified maximum (slippage protection)
    if (heap.quoteAmount > quoteAmountMax) {
      revert MangroveVaultErrors.SlippageExceeded(quoteAmountMax, heap.quoteAmount);
    }

    // check if the new total in quote overflows or if it is greater than maxTotalInQuote
    (heap.totalInQuoteNoOverflow, heap.newTotalInQuote) =
      heap.totalInQuote.tryAdd(_toQuoteAmount(heap.baseAmount, heap.quoteAmount, heap.tick));

    if (!heap.totalInQuoteNoOverflow) {
      revert MangroveVaultErrors.QuoteAmountOverflow();
    }

    if (heap.newTotalInQuote > _state.maxTotalInQuote) {
      revert MangroveVaultErrors.DepositExceedsMaxTotal(heap.totalInQuote, heap.newTotalInQuote, _state.maxTotalInQuote);
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

    emit MangroveVaultEvents.Mint(msg.sender, mintAmount, heap.baseAmount, heap.quoteAmount, Tick.unwrap(heap.tick));

    // Return minted shares and deposited token amounts
    return (mintAmount, heap.baseAmount, heap.quoteAmount);
  }

  struct BurnHeap {
    uint256 totalInQuote;
    Tick tick;
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
   * @dev Reverts with MangroveVaultErrors.ZeroAmount if the number of shares to burn is zero
   * @dev Reverts with MangroveVaultErrors.SlippageExceeded if the withdrawal amounts are less than the specified minimums
   */
  function burn(uint256 shares, uint256 minAmountBaseOut, uint256 minAmountQuoteOut)
    external
    whenNotPaused
    nonReentrant
    returns (uint256 amountBaseOut, uint256 amountQuoteOut)
  {
    if (shares == 0) revert MangroveVaultErrors.ZeroAmount();

    BurnHeap memory heap;

    (heap.totalInQuote, heap.tick) = _accrueFee();
    _updateLastTotalInQuote(heap.totalInQuote);

    // Calculate the proportion of total assets to withdraw
    heap.totalSupply = totalSupply();

    // Burn the shares
    _burn(msg.sender, shares);

    // Get current balances
    (heap.vaultBalanceBase, heap.vaultBalanceQuote) = getVaultBalances();
    (heap.kandelBalanceBase, heap.kandelBalanceQuote) = getKandelBalances();

    // Calculate the user's share of the underlying assets
    heap.underlyingBalanceBase =
      Math.mulDiv(shares, heap.vaultBalanceBase + heap.kandelBalanceBase, heap.totalSupply, Math.Rounding.Floor);
    heap.underlyingBalanceQuote =
      Math.mulDiv(shares, heap.vaultBalanceQuote + heap.kandelBalanceQuote, heap.totalSupply, Math.Rounding.Floor);

    // Check if the base withdrawal amount meets the minimum requirement (slippage protection)
    if (heap.underlyingBalanceBase < minAmountBaseOut) {
      revert MangroveVaultErrors.SlippageExceeded(minAmountBaseOut, heap.underlyingBalanceBase);
    }
    // Check if the quote withdrawal amount meets the minimum requirement (slippage protection)
    if (heap.underlyingBalanceQuote < minAmountQuoteOut) {
      revert MangroveVaultErrors.SlippageExceeded(minAmountQuoteOut, heap.underlyingBalanceQuote);
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

    emit MangroveVaultEvents.Burn(msg.sender, shares, amountBaseOut, amountQuoteOut, Tick.unwrap(heap.tick));
  }

  /**
   * @notice Updates the vault's position in the Kandel strategy
   * @dev This function can be called by anyone to update the vault's position
   *      It internally calls the private _updatePosition function
   */
  function updatePosition() external {
    _updatePosition();
  }

  receive() external payable {}

  // admin functions

  /**
   * @notice Allows a specific contract to perform swaps on behalf of the vault
   * @dev Can only be called by the owner of the contract
   * @param contractAddress The address of the contract to be allowed
   */
  function allowSwapContract(address contractAddress) external onlyOwner {
    if (contractAddress == address(0) || contractAddress == address(this) || contractAddress == address(kandel)) {
      revert MangroveVaultErrors.UnauthorizedSwapContract(contractAddress);
    }

    allowedSwapContracts[contractAddress] = true;
    emit MangroveVaultEvents.SwapContractAllowed(contractAddress, true);
  }

  /**
   * @notice Disallows a previously allowed contract from performing swaps on behalf of the vault
   * @dev Can only be called by the owner of the contract
   * @param contractAddress The address of the contract to be disallowed
   */
  function disallowSwapContract(address contractAddress) external onlyOwner {
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
    external
    onlyOwner
    nonReentrant
  {
    _swap(target, data, amountOut, amountInMin, sell);
  }

  /**
   * @notice Executes a swap operation and updates the Kandel position in a single transaction
   * @dev This function can only be called by the owner of the contract
   * @param target The address of the contract to execute the swap on
   * @param data The calldata to be sent to the target contract
   * @param amountOut The amount of tokens to be swapped out
   * @param amountInMin The minimum amount of tokens to be received
   * @param sell If true, sell BASE; otherwise, sell QUOTE
   * @param position The new Kandel position to be set
   */
  function swapAndSetPosition(
    address target,
    bytes calldata data,
    uint256 amountOut,
    uint256 amountInMin,
    bool sell,
    KandelPosition memory position
  ) external onlyOwner nonReentrant {
    _setPosition(position);
    _swap(target, data, amountOut, amountInMin, sell);
  }

  /**
   * @notice Updates the Kandel position
   * @dev This function can only be called by the owner of the contract
   * @param position The new Kandel position to be set
   */
  function setPosition(KandelPosition memory position) external onlyOwner {
    _setPosition(position);
    _updatePosition();
  }

  /**
   * @notice Withdraws funds from Mangrove to a specified receiver
   * @dev This function can only be called by the owner of the contract
   * @param amount The amount of funds to withdraw
   * @param receiver The address to receive the withdrawn funds
   */
  function withdrawFromMangrove(uint256 amount, address payable receiver) external onlyOwner {
    kandel.withdrawFromMangrove(amount, receiver);
  }

  /**
   * @notice Withdraws ERC20 tokens from the vault
   * @dev This function can only be called by the owner of the contract
   * @dev Cannot withdraw BASE, QUOTE, or the vault's own tokens
   * @param token The address of the ERC20 token to withdraw
   * @param amount The amount of tokens to withdraw
   */
  function withdrawERC20(address token, uint256 amount) external onlyOwner {
    // We can not withdraw the vault's own tokens, nor BASE nor QUOTE from this function
    if (token == BASE || token == QUOTE || token == address(this)) {
      revert MangroveVaultErrors.CannotWithdrawToken(token);
    }
    IERC20(token).safeTransfer(msg.sender, amount);
  }

  /**
   * @notice Withdraws native currency (e.g., ETH) from the vault
   * @dev This function can only be called by the owner of the contract
   */
  function withdrawNative() external onlyOwner {
    payable(msg.sender).transfer(address(this).balance);
  }

  /**
   * @notice Pauses the vault operations
   * @param pause_ If true, the vault will be paused; if false, the vault will be unpaused
   * @dev This function can only be called by the owner of the contract
   */
  function pause(bool pause_) external onlyOwner {
    if (pause_) {
      _pause();
    } else {
      _unpause();
    }
  }

  /**
   * @notice Sets the fee data for the vault
   * @dev This function can only be called by the owner of the contract
   * @param performanceFee The performance fee to be set
   * @param managementFee The management fee to be set
   * @param feeRecipient The address to receive the fees
   */
  function setFeeData(uint16 performanceFee, uint16 managementFee, address feeRecipient) external onlyOwner {
    if (performanceFee > MangroveVaultConstants.MAX_PERFORMANCE_FEE) {
      revert MangroveVaultErrors.MaxFeeExceeded(MangroveVaultConstants.MAX_PERFORMANCE_FEE, performanceFee);
    }
    if (managementFee > MangroveVaultConstants.MAX_MANAGEMENT_FEE) {
      revert MangroveVaultErrors.MaxFeeExceeded(MangroveVaultConstants.MAX_MANAGEMENT_FEE, managementFee);
    }
    if (feeRecipient == address(0)) revert MangroveVaultErrors.ZeroAddress();
    (uint256 totalInQuote,) = _accrueFee();
    _updateLastTotalInQuote(totalInQuote);
    _state.performanceFee = performanceFee;
    _state.managementFee = managementFee;
    _state.feeRecipient = feeRecipient;
    emit MangroveVaultEvents.SetFeeData(performanceFee, managementFee, feeRecipient);
  }

  /**
   * @notice Sets the maximum total value in quote token
   * @dev This function can only be called by the owner of the contract
   * @dev This is limited by 128 bits
   * @param maxTotalInQuote The new maximum total value in quote token
   */
  function setMaxTotalInQuote(uint128 maxTotalInQuote) external onlyOwner {
    _state.maxTotalInQuote = maxTotalInQuote;
    emit MangroveVaultEvents.SetMaxTotalInQuote(maxTotalInQuote);
  }

  /**
   * @notice Executes a swap operation using an external contract
   * @dev This function can only be called by the owner of the contract
   * @param target The address of the external swap contract
   * @param data The calldata to be sent to the swap contract
   * @param amountOut The amount of tokens to be swapped out
   * @param amountInMin The minimum amount of tokens to be received in return
   * @param sell If true, selling BASE token; if false, selling QUOTE token
   * @dev This function performs the following steps:
   * 1. Verifies that the target contract is authorized for swaps
   * 2. Checks current token balances in the vault
   * 3. Withdraws additional tokens from Kandel if necessary
   * 4. Approves the swap contract to spend tokens
   * 5. Executes the swap by calling the target contract
   * 6. Verifies that the received amount meets the minimum requirement
   * 7. Calculates and returns the net changes in token balances
   *
   */
  function _swap(address target, bytes calldata data, uint256 amountOut, uint256 amountInMin, bool sell) internal {
    if (!allowedSwapContracts[target]) {
      revert MangroveVaultErrors.UnauthorizedSwapContract(target);
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
      (bool success, uint256 receivedQuote) = newQuoteBalance.trySub(quoteBalance);

      if (!success || receivedQuote < amountInMin) {
        revert MangroveVaultErrors.SlippageExceeded(amountInMin, receivedQuote);
      }

      // Reset approval for BASE
      IERC20(BASE).forceApprove(target, 0);
    } else {
      (bool success, uint256 receivedBase) = newBaseBalance.trySub(baseBalance);

      if (!success || receivedBase < amountInMin) {
        revert MangroveVaultErrors.SlippageExceeded(amountInMin, receivedBase);
      }
      // Reset approval for QUOTE
      IERC20(QUOTE).forceApprove(target, 0);
    }
    emit MangroveVaultEvents.Swap(target, netBaseChange, netQuoteChange, sell);

    _updatePosition();
  }

  /**
   * @notice Retrieves the current tick from the oracle
   * @return The current tick value
   */
  function _currentTick() internal view returns (Tick) {
    return oracle.tick();
  }

  /**
   * @notice Converts base and quote amounts to a total quote amount using the current tick
   * @param amountBase The amount of base tokens
   * @param amountQuote The amount of quote tokens
   * @return quoteAmount The total amount in quote tokens
   * @return tick The current tick used for the conversion
   */
  function _toQuoteAmount(uint256 amountBase, uint256 amountQuote)
    internal
    view
    returns (uint256 quoteAmount, Tick tick)
  {
    tick = _currentTick();
    quoteAmount = _toQuoteAmount(amountBase, amountQuote, tick);
  }

  /**
   * @notice Converts base and quote amounts to a total quote amount using a specified tick
   * @param amountBase The amount of base tokens
   * @param amountQuote The amount of quote tokens
   * @param tick The tick to use for the conversion
   * @return quoteAmount The total amount in quote tokens
   */
  function _toQuoteAmount(uint256 amountBase, uint256 amountQuote, Tick tick)
    internal
    pure
    returns (uint256 quoteAmount)
  {
    quoteAmount = amountQuote + tick.inboundFromOutboundUp(amountBase);
  }

  /**
   * @notice Deposits all available funds from the vault to Kandel
   */
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

  /**
   * @notice Retrieves the full current distribution of Kandel
   * @return distribution The current Kandel distribution
   * @return valid A boolean indicating if the distribution is valid
   */
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

  /**
   * @notice Refills the Kandel position with offers
   * @dev This function attempts to post the distribution of offers to Mangrove.
   *      It can revert if there is not enough provision (native token balance)
   *      for this Kandel on Mangrove to cover the bounties required for posting offers.
   */
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

  /**
   * @notice Updates the Kandel position based on the current funds state
   * @dev This function performs the following actions for each state:
   *      - Active: Deposits all funds to Kandel and refills the position with offers
   *      - Passive: Deposits all funds to Kandel and withdraws all offers
   *      - Vault: Withdraws all offers and funds from Kandel back to the vault
   */
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

  /**
   * @notice Updates the last recorded total value in quote token and timestamp
   * @dev This function is called internally to update the state after significant changes
   * @param totalInQuote The new total value in quote token
   */
  function _updateLastTotalInQuote(uint256 totalInQuote) internal {
    _state.lastTotalInQuote = totalInQuote.toUint128();
    _state.lastTimestamp = block.timestamp.toUint32();
    emit MangroveVaultEvents.UpdateLastTotalInQuote(totalInQuote, block.timestamp);
  }

  /**
   * @notice Calculates and mints fee shares, and returns the updated total value in quote
   * @dev This function is called internally to accrue fees
   * @return newTotalInQuote The updated total value in quote token
   * @return tick The current tick from the oracle
   */
  function _accrueFee() internal returns (uint256 newTotalInQuote, Tick tick) {
    uint256 feeShares;
    (feeShares, newTotalInQuote, tick) = _accruedFeeShares();
    if (feeShares > 0) {
      _mint(_state.feeRecipient, feeShares);
    }
    emit MangroveVaultEvents.AccrueInterest(feeShares, newTotalInQuote, block.timestamp);
  }

  /**
   * @notice Calculates the number of fee shares to be minted based on performance and management fees
   * @dev This function is called internally to compute accrued fees
   * @return feeShares The number of fee shares to be minted
   * @return newTotalInQuote The updated total value in quote token
   * @return tick The current tick from the oracle
   */
  function _accruedFeeShares() internal view returns (uint256 feeShares, uint256 newTotalInQuote, Tick tick) {
    (newTotalInQuote, tick) = getTotalInQuote();
    (, uint256 interest) = newTotalInQuote.trySub(_state.lastTotalInQuote);
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
