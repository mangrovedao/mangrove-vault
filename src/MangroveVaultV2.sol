// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Mangrove
import {IMangrove, Local, OLKey} from "@mgv/src/IMangrove.sol";
import {Tick} from "@mgv/lib/core/TickLib.sol";
import {MAX_SAFE_VOLUME, MAX_TICK} from "@mgv/lib/core/Constants.sol";

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
import {MangroveVaultV2Errors} from "./lib/MangroveVaultV2Errors.sol";
import {MangroveVaultV2Events} from "./lib/MangroveVaultV2Events.sol";
import {FundsState, KandelPosition} from "./MangroveVault.sol";

/**
 * @notice Struct representing a pending position update (for oracle-less mode)
 * @param targetTick The proposed target tick
 * @param position The proposed Kandel position
 * @param executeTime The timestamp when this position can be executed
 * @param disputed Whether this position has been disputed by the guardian
 */
struct PendingPositionUpdate {
  Tick targetTick;
  KandelPosition position;
  uint256 executeTime;
  bool disputed;
}

/**
 * @notice Oracle configuration struct packed into a single storage slot
 * @dev Total size: 216 bits (27 bytes)
 * @param oracleEnabled Whether oracle is enabled (1 bit)
 * @param maxTickDeviation Maximum allowed tick deviation (24 bits)
 * @param storedTick Stored tick value for oracle-less mode (24 bits)
 * @param oracle Oracle contract address (160 bits)
 */
struct OracleConfig {
  bool oracleEnabled; // 8 bits
  uint24 maxTickDeviation; // 24 bits
  int24 storedTick; // 24 bits
  address oracle; // 160 bits
}

contract MangroveVaultV2 is Ownable, ERC20, Pausable, ReentrancyGuard {
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
  uint8 internal immutable DECIMALS;

  /// @notice A mapping to track which swap contracts are allowed.
  mapping(address => bool) public allowedSwapContracts;

  /// @notice Mapping to track per-user share information for timestamp-weighted fee calculations
  mapping(address => uint256 shareWeightedTimestamp) public userShareInfo;

  /// @notice The timelock duration for position updates in oracle-less mode (1 hour)
  uint256 public constant POSITION_TIMELOCK = 1 hours;

  /// @notice The oracle configuration for the vault
  OracleConfig private _oracleConfig;

  /**
   * @notice The current state of the vault
   * @dev This struct is packed into multiple storage slots (480 bits total)
   * @param fundsState The current state of the funds in the vault.
   * @param tickIndex0 The tick index for the first offer in the Kandel contract.
   * @param feeRecipient The address of the fee recipient.
   * @param managementFee The management fee (applied on exit).
   * @param maxTotalInQuote The maximum total in quote value.
   * @param lastTotalInQuote The last recorded total value in quote units.
   */
  struct State {
    FundsState fundsState; // 8 bits
    int24 tickIndex0; // + 24 bits = 32 bits
    address feeRecipient; // + 160 bits = 192 bits
    uint16 managementFee; // + 16 bits = 208 bits
    uint128 maxTotalInQuote; // + 128 bits = 352 bits
    uint128 lastTotalInQuote; // + 128 bits = 480 bits
  }

  /// @notice The current state of the vault.
  State internal _state;

  /// @notice The address of the manager of the vault.
  address public manager;

  /// @notice The address of the guardian who can dispute position updates.
  address public guardian;

  /// @notice The maximum price spread for the rebalance function.
  uint256 public maxPriceSpread;

  /// @notice Pending position update for oracle-less mode
  PendingPositionUpdate public pendingPositionUpdate;

  /// @notice Whether there is a pending position update
  bool public hasPendingPositionUpdate;

  modifier onlyOwnerOrManager() {
    if (msg.sender != owner() && msg.sender != manager) {
      revert MangroveVaultErrors.ManagerOwnerUnauthorized(msg.sender);
    }
    _;
  }

  modifier onlyGuardian() {
    if (msg.sender != guardian) {
      revert MangroveVaultV2Errors.OnlyGuardian();
    }
    _;
  }

  /**
   * @notice Constructor for the MangroveVaultV2 contract.
   */
  constructor(
    AbstractKandelSeeder _seeder,
    address _BASE,
    address _QUOTE,
    uint256 _tickSpacing,
    uint8 _decimals,
    string memory name,
    string memory symbol,
    address _owner
  ) Ownable(_owner) ERC20(name, symbol) {
    seeder = _seeder;
    TICK_SPACING = _tickSpacing;
    MGV = _seeder.MGV();
    BASE = _BASE;
    QUOTE = _QUOTE;
    kandel = _seeder.sow(OLKey(_BASE, _QUOTE, _tickSpacing), false);

    uint8 offset = _decimals - ERC20(_QUOTE).decimals();
    DECIMALS = _decimals;
    QUOTE_SCALE = 10 ** offset;

    _state.maxTotalInQuote = type(uint128).max;
    emit MangroveVaultEvents.SetMaxTotalInQuote(_state.maxTotalInQuote);

    _state.feeRecipient = _owner;
    emit MangroveVaultEvents.SetFeeData(0, 0, _owner);

    manager = _owner;
    emit MangroveVaultEvents.SetManager(_owner);

    guardian = _owner;
    emit MangroveVaultV2Events.GuardianSet(_owner);

    maxPriceSpread = type(uint256).max;
    emit MangroveVaultEvents.SetMaxPriceSpread(type(uint256).max);

    // Initialize with oracle disabled and stored tick at 0
    _setOracleConfig(false, address(0), Tick.wrap(0), 0);
  }

  /**
   * @inheritdoc ERC20
   */
  function decimals() public view override returns (uint8) {
    return DECIMALS;
  }

  /**
   * @notice Retrieves the current market information for the vault
   */
  function market() external view returns (address base, address quote, uint256 tickSpacing) {
    return (BASE, QUOTE, TICK_SPACING);
  }

  /**
   * @notice Retrieves the oracle configuration
   * @return oracleEnabled Whether oracle is enabled
   * @return oracle The oracle address (if enabled)
   * @return storedTick The stored tick (if oracle disabled)
   * @return maxTickDeviation The maximum allowed tick deviation
   */
  function getOracleConfig()
    external
    view
    returns (bool oracleEnabled, address oracle, Tick storedTick, uint24 maxTickDeviation)
  {
    return _getOracleConfig();
  }

  /**
   * @notice Internal function to get oracle configuration
   */
  function _getOracleConfig()
    internal
    view
    returns (bool oracleEnabled, address oracle, Tick storedTick, uint24 maxTickDeviation)
  {
    OracleConfig memory config = _oracleConfig;
    oracleEnabled = config.oracleEnabled;
    oracle = config.oracle;
    storedTick = Tick.wrap(config.storedTick);
    maxTickDeviation = config.maxTickDeviation;
  }

  /**
   * @notice Internal function to set oracle configuration
   */
  function _setOracleConfig(bool oracleEnabled, address oracle, Tick storedTick, uint24 maxTickDeviation) internal {
    if (maxTickDeviation > uint24(uint256(MAX_TICK))) {
      revert MangroveVaultV2Errors.InvalidMaxTickDeviation();
    }

    _oracleConfig = OracleConfig({
      oracleEnabled: oracleEnabled,
      maxTickDeviation: maxTickDeviation,
      storedTick: int24(Tick.unwrap(storedTick)),
      oracle: oracle
    });

    emit MangroveVaultV2Events.OracleConfigUpdated(oracleEnabled, oracle, storedTick, maxTickDeviation);
  }

  /**
   * @notice Sets the oracle configuration
   * @param oracleEnabled Whether to enable oracle mode
   * @param oracle The oracle address (required if enabling oracle)
   * @param storedTick The tick to store (used if disabling oracle)
   * @param maxTickDeviation Maximum allowed tick deviation from oracle
   */
  function setOracleConfig(bool oracleEnabled, address oracle, Tick storedTick, uint24 maxTickDeviation)
    external
    onlyOwner
  {
    if (oracleEnabled && oracle == address(0)) {
      revert MangroveVaultErrors.ZeroAddress();
    }
    _setOracleConfig(oracleEnabled, oracle, storedTick, maxTickDeviation);
  }

  /**
   * @notice Sets the guardian address
   */
  function setGuardian(address newGuardian) external onlyOwner {
    if (newGuardian == address(0)) revert MangroveVaultErrors.ZeroAddress();
    guardian = newGuardian;
    emit MangroveVaultV2Events.GuardianSet(newGuardian);
  }

  /**
   * @notice Gets the current tick based on oracle configuration
   */
  function getCurrentTick() public view returns (Tick) {
    (bool oracleEnabled, address oracle, Tick storedTick,) = _getOracleConfig();

    if (oracleEnabled) {
      return IOracle(oracle).tick();
    } else {
      return storedTick;
    }
  }

  /**
   * @notice Validates a tick against the current tick and max deviation
   */
  function _validateTick(Tick proposedTick) internal view {
    (bool oracleEnabled,,, uint24 maxTickDeviation) = _getOracleConfig();

    if (oracleEnabled) {
      Tick currentTick = getCurrentTick();
      int24 deviation = int24(Tick.unwrap(proposedTick) - Tick.unwrap(currentTick));
      if (uint24(SignedMath.abs(deviation)) > maxTickDeviation) {
        revert MangroveVaultV2Errors.TickDeviationExceeded();
      }
    }
  }

  /**
   * @notice Retrieves the current state of the funds in the vault.
   */
  function fundsState() external view returns (FundsState) {
    return _state.fundsState;
  }

  /**
   * @notice Retrieves the current tick at index 0 of the Kandel position.
   */
  function tickIndex0() external view returns (int24) {
    return _state.tickIndex0;
  }

  /**
   * @notice Retrieves the current fee data for the vault
   */
  function feeData() external view returns (uint16 managementFee, address feeRecipient) {
    return (_state.managementFee, _state.feeRecipient);
  }

  /**
   * @notice Retrieves the balances of the vault for both tokens.
   */
  function getVaultBalances() public view returns (uint256 baseAmount, uint256 quoteAmount) {
    baseAmount = IERC20(BASE).balanceOf(address(this));
    quoteAmount = IERC20(QUOTE).balanceOf(address(this));
  }

  /**
   * @notice Retrieves the inferred balances of the Kandel contract for both tokens.
   */
  function getKandelBalances() public view returns (uint256 baseAmount, uint256 quoteAmount) {
    (baseAmount, quoteAmount) = kandel.getBalances();
  }

  /**
   * @notice Retrieves the total underlying balances of both tokens.
   */
  function getUnderlyingBalances() public view returns (uint256 baseAmount, uint256 quoteAmount) {
    (baseAmount, quoteAmount) = getVaultBalances();
    (uint256 kandelBaseBalance, uint256 kandelQuoteBalance) = getKandelBalances();
    baseAmount += kandelBaseBalance;
    quoteAmount += kandelQuoteBalance;
  }

  /**
   * @notice Calculates the total value of the vault's assets in quote token.
   */
  function getTotalInQuote() public view returns (uint256 quoteAmount, Tick tick) {
    uint256 baseAmount;
    (baseAmount, quoteAmount) = getUnderlyingBalances();
    tick = getCurrentTick();
    quoteAmount = quoteAmount + tick.inboundFromOutboundUp(baseAmount);
  }

  /**
   * @notice Computes the shares that can be minted according to the maximum amounts of base and quote provided.
   */
  function getMintAmounts(uint256 baseAmountMax, uint256 quoteAmountMax)
    external
    view
    returns (uint256 baseAmountOut, uint256 quoteAmountOut, uint256 shares)
  {
    baseAmountMax = Math.min(baseAmountMax, MAX_SAFE_VOLUME);
    quoteAmountMax = Math.min(quoteAmountMax, MAX_SAFE_VOLUME);

    uint256 _totalSupply = totalSupply();

    if (_totalSupply != 0) {
      (uint256 baseAmount, uint256 quoteAmount) = getUnderlyingBalances();

      if (baseAmount == 0 && quoteAmount != 0) {
        shares = quoteAmountMax.mulDiv(_totalSupply, quoteAmount);
      } else if (baseAmount != 0 && quoteAmount == 0) {
        shares = baseAmountMax.mulDiv(_totalSupply, baseAmount);
      } else if (baseAmount != 0 && quoteAmount != 0) {
        shares =
          Math.min(baseAmountMax.mulDiv(_totalSupply, baseAmount), quoteAmountMax.mulDiv(_totalSupply, quoteAmount));
      }

      if (shares == 0) {
        revert MangroveVaultErrors.ZeroAmount();
      }

      baseAmountOut = shares.mulDiv(baseAmount, _totalSupply);
      quoteAmountOut = shares.mulDiv(quoteAmount, _totalSupply);
    } else {
      Tick tick = getCurrentTick();

      baseAmountOut = tick.outboundFromInbound(quoteAmountMax);
      if (baseAmountOut > baseAmountMax) {
        baseAmountOut = baseAmountMax;
        quoteAmountOut = tick.inboundFromOutboundUp(baseAmountOut);
      } else {
        quoteAmountOut = quoteAmountMax;
      }

      (, shares) = ((tick.inboundFromOutboundUp(baseAmountOut) + quoteAmountOut) * QUOTE_SCALE).trySub(
        MangroveVaultConstants.MINIMUM_LIQUIDITY
      );
    }
  }

  /**
   * @notice Calculates the underlying token balances corresponding to a given share amount.
   */
  function getUnderlyingBalancesByShare(uint256 share) public view returns (uint256 baseAmount, uint256 quoteAmount) {
    (uint256 baseBalance, uint256 quoteBalance) = getUnderlyingBalances();
    uint256 _totalSupply = totalSupply();

    if (_totalSupply == 0) {
      return (0, 0);
    }

    baseAmount = share.mulDiv(baseBalance, _totalSupply, Math.Rounding.Floor);
    quoteAmount = share.mulDiv(quoteBalance, _totalSupply, Math.Rounding.Floor);
  }

  /**
   * @notice Updates user's share-weighted timestamp when minting/burning shares
   * @param user The user address
   * @param shareChange The change in shares (positive for mint, negative for burn)
   * @param timestamp The timestamp of the operation
   */
  function _updateUserTimestamp(address user, int256 shareChange, uint256 timestamp) internal {
    uint256 currentShares = balanceOf(user);

    if (shareChange > 0) {
      // Minting shares
      uint256 newShares = uint256(shareChange);
      if (currentShares == 0) {
        // First mint for this user
        userShareInfo[user] = timestamp;
      } else {
        // Calculate new weighted average timestamp
        uint256 totalValue = currentShares * userShareInfo[user] + newShares * timestamp;
        userShareInfo[user] = totalValue / (currentShares + newShares);
      }
    } else if (shareChange < 0) {
      // Burning shares
      uint256 burnShares = uint256(-shareChange);
      if (burnShares >= currentShares) {
        // Burning all shares
        userShareInfo[user] = 0;
      }
      // For partial burns, timestamp remains the same (no update needed)
    }
  }

  /**
   * @notice Calculates management fees for a specific user based on their share-weighted timestamp
   * @param user The user address
   * @param shares The number of shares to calculate fees for
   * @return feeShares The management fee shares to be deducted
   */
  function calculateManagementFeesForUser(address user, uint256 shares) public view returns (uint256 feeShares) {
    if (_state.managementFee == 0) return 0;

    uint256 shareWeightedTimestamp = userShareInfo[user];
    if (shareWeightedTimestamp == 0) return 0;

    (, uint256 timeElapsed) = block.timestamp.trySub(shareWeightedTimestamp);
    if (timeElapsed == 0) return 0;

    // Calculate annual management fee proportion
    uint256 annualFeeRate = _state.managementFee;
    uint256 feeRate = annualFeeRate * timeElapsed / (365 days);

    // Calculate fee shares based on time elapsed
    feeShares = shares.mulDiv(feeRate, MangroveVaultConstants.MANAGEMENT_FEE_PRECISION);
  }

  // Interaction functions

  function fundMangrove() external payable {
    MGV.fund{value: msg.value}(address(kandel));
  }

  /**
   * @notice Mints new shares by depositing tokens into the vault
   * @dev Funds are kept in the vault and not immediately pushed to Kandel
   */
  function mint(uint256 mintAmount, uint256 baseAmountMax, uint256 quoteAmountMax)
    external
    whenNotPaused
    nonReentrant
    returns (uint256 shares, uint256 baseAmount, uint256 quoteAmount)
  {
    if (mintAmount == 0) revert MangroveVaultErrors.ZeroAmount();

    uint256 _totalSupply = totalSupply();
    Tick tick = getCurrentTick();

    if (_totalSupply != 0) {
      (uint256 baseBalance, uint256 quoteBalance) = getUnderlyingBalances();
      baseAmount = mintAmount.mulDiv(baseBalance, _totalSupply);
      quoteAmount = mintAmount.mulDiv(quoteBalance, _totalSupply);
    } else {
      baseAmount = tick.outboundFromInbound(quoteAmountMax);
      if (baseAmount > baseAmountMax) {
        baseAmount = baseAmountMax;
        quoteAmount = tick.inboundFromOutboundUp(baseAmountMax);
      } else {
        quoteAmount = quoteAmountMax;
      }

      uint256 computedShares;
      (, computedShares) = ((tick.inboundFromOutboundUp(baseAmount) + quoteAmount) * QUOTE_SCALE).trySub(
        MangroveVaultConstants.MINIMUM_LIQUIDITY
      );

      if (computedShares != mintAmount) {
        revert MangroveVaultErrors.InitialMintSharesMismatch(mintAmount, computedShares);
      }
      _mint(address(this), MangroveVaultConstants.MINIMUM_LIQUIDITY);
    }

    if (baseAmount > baseAmountMax) {
      revert MangroveVaultErrors.SlippageExceeded(baseAmountMax, baseAmount);
    }
    if (quoteAmount > quoteAmountMax) {
      revert MangroveVaultErrors.SlippageExceeded(quoteAmountMax, quoteAmount);
    }

    // Check max total in quote
    uint256 newTotalInQuote = _toQuoteAmount(baseAmount, quoteAmount, tick);
    (uint256 currentTotalInQuote,) = getTotalInQuote();

    (bool noOverflow, uint256 totalAfterDeposit) = currentTotalInQuote.tryAdd(newTotalInQuote);
    if (!noOverflow) {
      revert MangroveVaultErrors.QuoteAmountOverflow();
    }

    if (totalAfterDeposit > _state.maxTotalInQuote) {
      revert MangroveVaultErrors.DepositExceedsMaxTotal(currentTotalInQuote, totalAfterDeposit, _state.maxTotalInQuote);
    }

    // Transfer tokens from user to vault (not to Kandel)
    IERC20(BASE).safeTransferFrom(msg.sender, address(this), baseAmount);
    IERC20(QUOTE).safeTransferFrom(msg.sender, address(this), quoteAmount);

    // Update user's share-weighted timestamp before minting
    _updateUserTimestamp(msg.sender, int256(mintAmount), block.timestamp);

    _mint(msg.sender, mintAmount);

    emit MangroveVaultEvents.Mint(msg.sender, mintAmount, baseAmount, quoteAmount, Tick.unwrap(tick));

    return (mintAmount, baseAmount, quoteAmount);
  }

  /**
   * @notice Burns shares and withdraws underlying assets
   * @dev Management fees are applied on exit based on user's share-weighted timestamp
   */
  function burn(uint256 shares, uint256 minAmountBaseOut, uint256 minAmountQuoteOut)
    external
    whenNotPaused
    nonReentrant
    returns (uint256 amountBaseOut, uint256 amountQuoteOut)
  {
    if (shares == 0) revert MangroveVaultErrors.ZeroAmount();

    // Get current state
    Tick tick = getCurrentTick();

    // Calculate fee shares and process them using user-specific timestamp
    (uint256 effectiveShares, uint256 _totalSupply) = _processFeesForUser(msg.sender, shares);

    // Update user's share-weighted timestamp before burning
    _updateUserTimestamp(msg.sender, -int256(shares), block.timestamp);

    // Burn user shares
    _burn(msg.sender, shares);

    // Calculate output amounts
    (amountBaseOut, amountQuoteOut) = _calculateAndWithdrawAssets(effectiveShares, _totalSupply);

    // Check slippage
    if (amountBaseOut < minAmountBaseOut) {
      revert MangroveVaultErrors.SlippageExceeded(minAmountBaseOut, amountBaseOut);
    }
    if (amountQuoteOut < minAmountQuoteOut) {
      revert MangroveVaultErrors.SlippageExceeded(minAmountQuoteOut, amountQuoteOut);
    }

    // Transfer assets to user
    IERC20(BASE).safeTransfer(msg.sender, amountBaseOut);
    IERC20(QUOTE).safeTransfer(msg.sender, amountQuoteOut);

    emit MangroveVaultEvents.Burn(msg.sender, shares, amountBaseOut, amountQuoteOut, Tick.unwrap(tick));
  }

  /**
   * @notice Processes management fees for a specific user based on their share-weighted timestamp
   * @param user The user address
   * @param shares The number of shares being burned
   * @return effectiveShares The shares after deducting fees
   * @return _totalSupply The total supply after minting fee shares
   */
  function _processFeesForUser(address user, uint256 shares)
    internal
    returns (uint256 effectiveShares, uint256 _totalSupply)
  {
    _totalSupply = totalSupply();

    // Calculate management fees using user-specific timestamp
    uint256 feeShares = calculateManagementFeesForUser(user, shares);
    effectiveShares = shares - feeShares;

    // Mint fee shares to fee recipient
    if (feeShares > 0) {
      _mint(_state.feeRecipient, feeShares);
      _totalSupply += feeShares;
    }
  }

  function _calculateAndWithdrawAssets(uint256 effectiveShares, uint256 _totalSupply)
    internal
    returns (uint256 underlyingBalanceBase, uint256 underlyingBalanceQuote)
  {
    // Get current balances
    (uint256 vaultBalanceBase, uint256 vaultBalanceQuote) = getVaultBalances();
    (uint256 kandelBalanceBase, uint256 kandelBalanceQuote) = getKandelBalances();

    // Calculate user's share of underlying assets (after fees)
    underlyingBalanceBase = effectiveShares.mulDiv(vaultBalanceBase + kandelBalanceBase, _totalSupply);
    underlyingBalanceQuote = effectiveShares.mulDiv(vaultBalanceQuote + kandelBalanceQuote, _totalSupply);

    // Withdraw from Kandel if vault doesn't have enough balance
    if (underlyingBalanceBase > vaultBalanceBase || underlyingBalanceQuote > vaultBalanceQuote) {
      (, uint256 withdrawAmountBase) = underlyingBalanceBase.trySub(vaultBalanceBase);
      (, uint256 withdrawAmountQuote) = underlyingBalanceQuote.trySub(vaultBalanceQuote);
      kandel.withdrawFunds(withdrawAmountBase, withdrawAmountQuote, address(this));
    }
  }

  /**
   * @notice Proposes a position update (oracle-less mode only)
   */
  function proposePositionUpdate(Tick targetTick, KandelPosition memory position) external onlyOwnerOrManager {
    (bool oracleEnabled,,,) = _getOracleConfig();
    if (oracleEnabled) {
      revert MangroveVaultV2Errors.OracleEnabled();
    }

    // Cancel any existing pending update
    if (hasPendingPositionUpdate) {
      delete pendingPositionUpdate;
      emit MangroveVaultV2Events.PositionUpdateCanceled();
    }

    uint256 executeTime = block.timestamp + POSITION_TIMELOCK;

    pendingPositionUpdate =
      PendingPositionUpdate({targetTick: targetTick, position: position, executeTime: executeTime, disputed: false});

    hasPendingPositionUpdate = true;

    emit MangroveVaultV2Events.PositionUpdateProposed(targetTick, executeTime);
  }

  /**
   * @notice Executes a pending position update
   */
  function executePendingPositionUpdate() external onlyOwnerOrManager {
    if (!hasPendingPositionUpdate) {
      revert MangroveVaultV2Errors.NoPositionUpdatePending();
    }

    PendingPositionUpdate memory pending = pendingPositionUpdate;

    if (block.timestamp < pending.executeTime) {
      revert MangroveVaultV2Errors.PositionUpdateNotReady();
    }

    if (pending.disputed) {
      revert MangroveVaultV2Errors.PositionUpdateIsDisputed();
    }

    // Update stored tick to target tick
    (bool oracleEnabled, address oracle,, uint24 maxTickDeviation) = _getOracleConfig();
    _setOracleConfig(oracleEnabled, oracle, pending.targetTick, maxTickDeviation);

    // Set the position
    _setPosition(pending.position);
    _updatePosition();

    // Clear pending update
    delete pendingPositionUpdate;
    hasPendingPositionUpdate = false;

    emit MangroveVaultV2Events.PositionUpdateExecuted(pending.targetTick);
  }

  /**
   * @notice Disputes a pending position update (guardian only)
   */
  function disputePositionUpdate() external onlyGuardian {
    if (!hasPendingPositionUpdate) {
      revert MangroveVaultV2Errors.NoPositionUpdatePending();
    }

    pendingPositionUpdate.disputed = true;
    emit MangroveVaultV2Events.PositionUpdateDisputed();
  }

  /**
   * @notice Cancels a pending position update
   */
  function cancelPendingPositionUpdate() external onlyOwnerOrManager {
    if (!hasPendingPositionUpdate) {
      revert MangroveVaultV2Errors.NoPositionUpdatePending();
    }

    delete pendingPositionUpdate;
    hasPendingPositionUpdate = false;
    emit MangroveVaultV2Events.PositionUpdateCanceled();
  }

  /**
   * @notice Sets position immediately (oracle mode only)
   */
  function setPosition(KandelPosition memory position) external onlyOwnerOrManager {
    (bool oracleEnabled,,,) = _getOracleConfig();
    if (!oracleEnabled) {
      revert MangroveVaultV2Errors.OracleNotEnabled();
    }

    // Validate the position tick against oracle + max deviation
    _validateTick(position.tickIndex0);

    _setPosition(position);
    _updatePosition();
  }

  /**
   * @notice Updates the vault's position in the Kandel strategy
   */
  function updatePosition() external {
    _updatePosition();
  }

  receive() external payable {}

  // Admin functions

  /**
   * @notice Allows a specific contract to perform swaps on behalf of the vault
   */
  function allowSwapContract(address contractAddress) external onlyOwner {
    if (
      contractAddress == address(0) || contractAddress == address(this) || contractAddress == address(kandel)
        || contractAddress == BASE || contractAddress == QUOTE
    ) {
      revert MangroveVaultErrors.UnauthorizedSwapContract(contractAddress);
    }

    allowedSwapContracts[contractAddress] = true;
    emit MangroveVaultEvents.SwapContractAllowed(contractAddress, true);
  }

  /**
   * @notice Disallows a previously allowed contract from performing swaps
   */
  function disallowSwapContract(address contractAddress) external onlyOwner {
    allowedSwapContracts[contractAddress] = false;
    emit MangroveVaultEvents.SwapContractAllowed(contractAddress, false);
  }

  /**
   * @notice Executes a swap operation on behalf of the vault
   */
  function swap(address target, bytes calldata data, uint256 amountOut, uint256 amountInMin, bool sell)
    external
    onlyOwnerOrManager
    nonReentrant
    returns (int256 netBaseChange, int256 netQuoteChange)
  {
    return _swap(target, data, amountOut, amountInMin, sell);
  }

  /**
   * @notice Executes a swap operation and updates the Kandel position in a single transaction
   */
  function swapAndSetPosition(
    address target,
    bytes calldata data,
    uint256 amountOut,
    uint256 amountInMin,
    bool sell,
    KandelPosition memory position
  ) external onlyOwnerOrManager nonReentrant returns (int256 netBaseChange, int256 netQuoteChange) {
    (bool oracleEnabled,,,) = _getOracleConfig();
    if (!oracleEnabled) {
      revert MangroveVaultV2Errors.OracleNotEnabled();
    }

    _validateTick(position.tickIndex0);
    _setPosition(position);
    return _swap(target, data, amountOut, amountInMin, sell);
  }

  /**
   * @notice Withdraws funds from Mangrove to a specified receiver
   */
  function withdrawFromMangrove(uint256 amount, address payable receiver) external onlyOwner {
    kandel.withdrawFromMangrove(amount, receiver);
  }

  /**
   * @notice Withdraws ERC20 tokens from the vault
   */
  function withdrawERC20(address token, uint256 amount) external onlyOwner {
    if (token == BASE || token == QUOTE || token == address(this)) {
      revert MangroveVaultErrors.CannotWithdrawToken(token);
    }
    IERC20(token).safeTransfer(msg.sender, amount);
  }

  /**
   * @notice Withdraws native currency from the vault
   */
  function withdrawNative() external onlyOwner {
    (bool success,) = payable(msg.sender).call{value: address(this).balance}("");
    if (!success) {
      revert MangroveVaultErrors.NativeTransferFailed();
    }
  }

  /**
   * @notice Pauses the vault operations
   */
  function pause(bool pause_) external onlyOwner {
    if (pause_) {
      _pause();
    } else {
      _unpause();
    }
  }

  /**
   * @notice Sets the fee data for the vault (management fee only)
   */
  function setFeeData(uint16 managementFee, address feeRecipient) external onlyOwner {
    if (managementFee > MangroveVaultConstants.MAX_MANAGEMENT_FEE) {
      revert MangroveVaultErrors.MaxFeeExceeded(MangroveVaultConstants.MAX_MANAGEMENT_FEE, managementFee);
    }
    if (feeRecipient == address(0)) revert MangroveVaultErrors.ZeroAddress();

    _state.managementFee = managementFee;
    _state.feeRecipient = feeRecipient;

    emit MangroveVaultEvents.SetFeeData(0, managementFee, feeRecipient);
  }

  /**
   * @notice Sets the maximum total value in quote token
   */
  function setMaxTotalInQuote(uint128 _maxTotalInQuote) external onlyOwner {
    _state.maxTotalInQuote = _maxTotalInQuote;
    emit MangroveVaultEvents.SetMaxTotalInQuote(_maxTotalInQuote);
  }

  /**
   * @notice Sets the manager of the vault
   */
  function setManager(address newManager) external onlyOwner {
    if (newManager == address(0)) revert MangroveVaultErrors.ZeroAddress();
    manager = newManager;
    emit MangroveVaultEvents.SetManager(newManager);
  }

  /**
   * @notice Sets the maximum price spread for the rebalance function
   */
  function setMaxPriceSpread(uint256 newMaxPriceSpread) external onlyOwner {
    if (newMaxPriceSpread != type(uint256).max && newMaxPriceSpread > 2 * uint256(MAX_TICK)) {
      revert MangroveVaultErrors.InvalidMaxPriceSpread(newMaxPriceSpread);
    }
    maxPriceSpread = newMaxPriceSpread;
    emit MangroveVaultEvents.SetMaxPriceSpread(newMaxPriceSpread);
  }

  /**
   * @notice Manually deposits funds to Kandel
   */
  function depositFundsToKandel() external onlyOwnerOrManager {
    _depositAllFunds();
  }

  // Internal functions

  /**
   * @notice Calculates the adjusted minimum amount for a swap based on price spread
   */
  function adjustedAmountInMin(uint256 amountOut, uint256 _amountInMin, bool sell)
    public
    view
    returns (uint256 amountInMin)
  {
    if (maxPriceSpread == type(uint256).max) {
      return _amountInMin;
    }

    Tick tick = getCurrentTick();
    uint256 _maxPriceSpread = maxPriceSpread;

    if (sell) {
      tick = Tick.wrap(Tick.unwrap(tick) - _maxPriceSpread.toInt256());
      amountInMin = tick.inboundFromOutboundUp(amountOut);
    } else {
      tick = Tick.wrap(Tick.unwrap(tick) + _maxPriceSpread.toInt256());
      amountInMin = tick.outboundFromInbound(amountOut);
    }
    amountInMin = Math.max(amountInMin, _amountInMin);
  }

  /**
   * @notice Executes a swap operation using an external contract
   */
  function _swap(address target, bytes calldata data, uint256 amountOut, uint256 amountInMin, bool sell)
    internal
    returns (int256 netBaseChange, int256 netQuoteChange)
  {
    if (!allowedSwapContracts[target]) {
      revert MangroveVaultErrors.UnauthorizedSwapContract(target);
    }

    (uint256 baseBalance, uint256 quoteBalance) = getVaultBalances();
    amountInMin = adjustedAmountInMin(amountOut, amountInMin, sell);

    if (sell) {
      (, uint256 missingBase) = amountOut.trySub(baseBalance);
      if (missingBase > 0) {
        kandel.withdrawFunds(missingBase, 0, address(this));
        baseBalance += missingBase;
      }
      IERC20(BASE).forceApprove(target, amountOut);
    } else {
      (, uint256 missingQuote) = amountOut.trySub(quoteBalance);
      if (missingQuote > 0) {
        kandel.withdrawFunds(0, missingQuote, address(this));
        quoteBalance += missingQuote;
      }
      IERC20(QUOTE).forceApprove(target, amountOut);
    }

    target.functionCall(data);

    (uint256 newBaseBalance, uint256 newQuoteBalance) = getVaultBalances();
    netBaseChange = newBaseBalance.toInt256() - baseBalance.toInt256();
    netQuoteChange = newQuoteBalance.toInt256() - quoteBalance.toInt256();

    if (sell) {
      (bool success, uint256 receivedQuote) = newQuoteBalance.trySub(quoteBalance);
      if (!success || receivedQuote < amountInMin) {
        revert MangroveVaultErrors.SlippageExceeded(amountInMin, receivedQuote);
      }
      IERC20(BASE).forceApprove(target, 0);
    } else {
      (bool success, uint256 receivedBase) = newBaseBalance.trySub(baseBalance);
      if (!success || receivedBase < amountInMin) {
        revert MangroveVaultErrors.SlippageExceeded(amountInMin, receivedBase);
      }
      IERC20(QUOTE).forceApprove(target, 0);
    }

    emit MangroveVaultEvents.Swap(target, netBaseChange, netQuoteChange, sell);
    _updatePosition();
  }

  /**
   * @notice Converts base and quote amounts to a total quote amount using a specified tick
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
   */
  function _fullCurrentDistribution()
    internal
    view
    returns (GeometricKandel.Distribution memory distribution, bool valid)
  {
    Params memory params;
    uint256 bidGives;
    uint256 askGives;
    (distribution, params, bidGives, askGives) = kandel.distribution(Tick.wrap(_state.tickIndex0), getCurrentTick());
    (uint256 bidVolume, uint256 askVolume) = MGV.minVolumes(OLKey(BASE, QUOTE, TICK_SPACING), params.gasreq);
    valid = (bidGives == 0 || bidGives >= bidVolume) && (askGives == 0 || askGives >= askVolume);
  }

  /**
   * @notice Refills the Kandel position with offers
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
}
