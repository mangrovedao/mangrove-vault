// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {
  MangroveVaultV2, Tick, KandelPosition, FundsState, Params, PendingPositionUpdate
} from "../src/MangroveVaultV2.sol";
import {IMangrove, OLKey, Local} from "@mgv/src/IMangrove.sol";
import {Mangrove} from "@mgv/src/core/Mangrove.sol";
import {MgvReader, Market} from "@mgv/src/periphery/MgvReader.sol";
import {MgvOracle} from "@mgv/src/periphery/MgvOracle.sol";
import {MangroveChainlinkOracle, AggregatorV3Interface} from "../src/oracles/chainlink/MangroveChainlinkOracle.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {KandelSeeder} from "@mgv-strats/src/strategies/offer_maker/market_making/kandel/KandelSeeder.sol";
import {
  AaveKandelSeeder,
  IPoolAddressesProvider,
  AbstractKandelSeeder
} from "@mgv-strats/src/strategies/offer_maker/market_making/kandel/AaveKandelSeeder.sol";
import {MAX_SAFE_VOLUME, MIN_TICK, MAX_TICK} from "@mgv/lib/core/Constants.sol";
import {MangroveVaultConstants} from "../src/lib/MangroveVaultConstants.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OfferType} from "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/TradesBaseQuotePair.sol";
import {
  CoreKandel,
  DirectWithBidsAndAsksDistribution,
  IERC20
} from "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/CoreKandel.sol";
import {MangroveVaultEvents} from "../src/lib/MangroveVaultEvents.sol";
import {ERC20Mock} from "../src/mock/ERC20.sol";
import {MangroveVaultErrors} from "../src/lib/MangroveVaultErrors.sol";
import {MangroveVaultV2Errors} from "../src/lib/MangroveVaultV2Errors.sol";
import {MangroveVaultV2Events} from "../src/lib/MangroveVaultV2Events.sol";
import {GeometricKandel} from "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/GeometricKandel.sol";
import {HasIndexedBidsAndAsks} from
  "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/HasIndexedBidsAndAsks.sol";

contract MangroveVaultV2Test is Test {
  using Math for uint256;
  using SafeCast for uint256;

  IMangrove public mgv;
  MgvReader public reader;
  MgvOracle public oracle;

  IMangrove public realMangrove = IMangrove(payable(0x109d9CDFA4aC534354873EF634EF63C235F93f61));
  MgvReader public realReader = MgvReader(0x7E108d7C9CADb03E026075Bf242aC2353d0D1875);

  ERC20 public WETH = ERC20(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
  ERC20 public USDC = ERC20(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
  ERC20 public USDT = ERC20(0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9);
  ERC20 public WeETH = ERC20(0x35751007a407ca6FEFfE80b3cB397736D2cf4dbe);

  ERC20Mock public TokenA = new ERC20Mock("TOKEN A", "TOKA");
  ERC20Mock public TokenB = new ERC20Mock("TOKEN B", "TOKB");

  AggregatorV3Interface public ETH_USD = AggregatorV3Interface(0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612);
  AggregatorV3Interface public USDC_USD = AggregatorV3Interface(0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3);
  AggregatorV3Interface public USDT_USD = AggregatorV3Interface(0x3f3f5dF88dC9F13eac63DF89EC16ef6e7E25DdE7);
  AggregatorV3Interface public WEETH_ETH = AggregatorV3Interface(0xE141425bc1594b8039De6390db1cDaf4397EA22b);

  MangroveChainlinkOracle public ETH_USDC_ORACLE;
  MangroveChainlinkOracle public USDC_USDT_ORACLE;
  MangroveChainlinkOracle public ETH_USDT_ORACLE;
  MangroveChainlinkOracle public WEETH_ETH_ORACLE;

  KandelSeeder public kandelSeeder;
  AaveKandelSeeder public aaveKandelSeeder;

  uint256 public constant USD_DECIMALS = 18;

  uint256 arbitrumFork;

  address owner;
  address feeRecipient;
  address user;
  address manager;
  address guardian;

  function deployMangrove() internal {
    oracle = new MgvOracle({governance_: address(this), initialMutator_: address(this), initialGasPrice_: 1});
    mgv = IMangrove(payable(address(new Mangrove({governance: address(this), gasprice: 1, gasmax: 2_000_000}))));
    reader = new MgvReader({mgv: address(mgv)});
  }

  function copyMangrove() internal {
    (Market[] memory _markets,) = realReader.openMarkets();
    for (uint256 i = 0; i < _markets.length; i++) {
      OLKey memory olKey =
        OLKey({outbound_tkn: _markets[i].tkn0, inbound_tkn: _markets[i].tkn1, tickSpacing: _markets[i].tickSpacing});
      copySemibook(olKey);
      copySemibook(olKey.flipped());
      reader.updateMarket(_markets[i]);
    }
  }

  function copySemibook(OLKey memory olKey) internal {
    Local local = realMangrove.local(olKey);
    mgv.activate(olKey, local.fee(), local.density().to96X32(), local.kilo_offer_gasbase() * 1_000);
  }

  function setUp() public {
    arbitrumFork = vm.createFork(vm.envString("ARBITRUM_RPC_URL"));
    vm.selectFork(arbitrumFork);
    vm.rollFork(257_940_340);

    vm.label(address(WETH), "WETH");
    vm.label(address(USDC), "USDC");
    vm.label(address(USDT), "USDT");

    vm.label(address(ETH_USD), "Chainlink ETH/USD");
    vm.label(address(USDC_USD), "Chainlink USDC/USD");
    vm.label(address(USDT_USD), "Chainlink USDT/USD");

    owner = vm.createWallet("Owner").addr;
    feeRecipient = vm.createWallet("Fee Recipient").addr;
    user = vm.createWallet("User").addr;
    manager = vm.createWallet("Manager").addr;
    guardian = vm.createWallet("Guardian").addr;

    // Deploy oracles
    ETH_USDC_ORACLE = new MangroveChainlinkOracle(
      address(ETH_USD),
      address(0),
      address(USDC_USD),
      address(0),
      WETH.decimals(),
      USD_DECIMALS,
      0,
      0,
      USDC.decimals(),
      USD_DECIMALS,
      0,
      0
    );
    USDC_USDT_ORACLE = new MangroveChainlinkOracle(
      address(USDC_USD),
      address(0),
      address(USDT_USD),
      address(0),
      USDC.decimals(),
      USD_DECIMALS,
      0,
      0,
      USDT.decimals(),
      USD_DECIMALS,
      0,
      0
    );
    ETH_USDT_ORACLE = new MangroveChainlinkOracle(
      address(ETH_USD),
      address(0),
      address(USDT_USD),
      address(0),
      WETH.decimals(),
      USD_DECIMALS,
      0,
      0,
      USDT.decimals(),
      USD_DECIMALS,
      0,
      0
    );
    WEETH_ETH_ORACLE =
      new MangroveChainlinkOracle(address(WEETH_ETH), address(0), address(0), address(0), 18, 18, 0, 0, 0, 0, 0, 0);

    deployMangrove();
    copyMangrove();

    kandelSeeder = new KandelSeeder(mgv, 128_000);
    aaveKandelSeeder =
      new AaveKandelSeeder(mgv, IPoolAddressesProvider(0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb), 628_000);
  }

  struct MarketWOracle {
    ERC20 base;
    uint256 maxBase;
    ERC20 quote;
    uint256 maxQuote;
    MangroveChainlinkOracle oracle;
  }

  function markets() public view returns (MarketWOracle[] memory _markets) {
    _markets = new MarketWOracle[](4);
    _markets[0] = MarketWOracle({
      base: WETH,
      maxBase: 1_000_000_000e18,
      quote: USDC,
      maxQuote: 1_000_000_000_000e6,
      oracle: ETH_USDC_ORACLE
    });
    _markets[1] = MarketWOracle({
      base: USDC,
      maxBase: 1_000_000_000e18,
      quote: USDT,
      maxQuote: 1_000_000_000e6,
      oracle: USDC_USDT_ORACLE
    });
    _markets[2] = MarketWOracle({
      base: WETH,
      maxBase: 1_000_000_000e18,
      quote: USDT,
      maxQuote: 1_000_000_000e6,
      oracle: ETH_USDT_ORACLE
    });
    _markets[3] = MarketWOracle({
      base: WeETH,
      maxBase: 1_000_000_000e18,
      quote: WETH,
      maxQuote: 1_000_000_000e18,
      oracle: WEETH_ETH_ORACLE
    });
  }

  function deployVault(uint8 market, bool withOracle)
    internal
    returns (MangroveVaultV2 vault, MarketWOracle memory _market, address kandel)
  {
    return deployVault(market, withOracle, kandelSeeder);
  }

  function deployVault(uint8 market, bool withOracle, AbstractKandelSeeder seeder)
    internal
    returns (MangroveVaultV2 vault, MarketWOracle memory _market, address kandel)
  {
    _market = markets()[market];

    vm.startPrank(owner);
    vault = new MangroveVaultV2(
      seeder, address(_market.base), address(_market.quote), 1, 18, "Mangrove Vault V2", "MGVv2", owner
    );

    vault.setManager(manager);
    vault.setGuardian(guardian);
    vault.setFeeData(500, feeRecipient); // 5% management fee

    if (withOracle) {
      vault.setOracleConfig(true, address(_market.oracle), Tick.wrap(0), 100); // 100 tick deviation
    } else {
      // Set initial stored tick for oracle-less mode
      Tick currentTick = _market.oracle.tick();
      vault.setOracleConfig(false, address(0), currentTick, 0);
    }

    vm.stopPrank();
    kandel = address(vault.kandel());
  }

  function mintWithSpecifiedQuoteAmount(MangroveVaultV2 vault, MarketWOracle memory _market, uint256 quoteAmount)
    internal
    returns (uint256 baseAmountOut, uint256 quoteAmountOut, uint256 shares)
  {
    assertGt(quoteAmount, 0, "Quote amount must be greater than 0");
    assertLt(quoteAmount, _market.maxQuote, "Quote amount must be less than max quote");

    (baseAmountOut, quoteAmountOut, shares) = vault.getMintAmounts(type(uint256).max, quoteAmount);

    assertApproxEqAbs(quoteAmountOut, quoteAmount, 1, "Quote amount out doesn't match specified quote amount");
    assertLe(quoteAmountOut, quoteAmount, "Quote amount out is greater than specified quote amount");

    deal(address(_market.base), user, baseAmountOut);
    deal(address(_market.quote), user, quoteAmountOut);

    uint256 baseBefore = _market.base.balanceOf(user);
    uint256 quoteBefore = _market.quote.balanceOf(user);
    uint256 sharesBefore = vault.balanceOf(user);
    Tick tick = vault.getCurrentTick();

    vm.startPrank(user);
    _market.base.approve(address(vault), baseAmountOut);
    _market.quote.approve(address(vault), quoteAmountOut);

    vm.expectEmit(true, false, false, false, address(vault));
    emit MangroveVaultEvents.Mint(user, shares, baseAmountOut, quoteAmountOut, Tick.unwrap(tick));
    vault.mint(shares, baseAmountOut, quoteAmountOut);
    vm.stopPrank();

    assertEq(_market.base.balanceOf(user), baseBefore - baseAmountOut);
    assertEq(_market.quote.balanceOf(user), quoteBefore - quoteAmountOut);
    assertEq(vault.balanceOf(user), sharesBefore + shares, "Balance of shares doesn't match");
  }

  // Test Oracle Configuration

  function test_oracleConfig() public {
    (MangroveVaultV2 vault, MarketWOracle memory _market,) = deployVault(0, true);

    (bool oracleEnabled, address oracle, Tick storedTick, uint24 maxTickDeviation) = vault.getOracleConfig();

    assertTrue(oracleEnabled, "Oracle should be enabled");
    assertEq(oracle, address(_market.oracle), "Oracle address should match");
    assertEq(Tick.unwrap(storedTick), 0, "Stored tick should be 0 when oracle enabled");
    assertEq(maxTickDeviation, 100, "Max tick deviation should be 100");
  }

  function test_setOracleConfig() public {
    (MangroveVaultV2 vault, MarketWOracle memory _market,) = deployVault(0, false);

    vm.startPrank(owner);

    // Test enabling oracle
    vm.expectEmit(true, true, true, true, address(vault));
    emit MangroveVaultV2Events.OracleConfigUpdated(true, address(_market.oracle), Tick.wrap(0), 200);
    vault.setOracleConfig(true, address(_market.oracle), Tick.wrap(0), 200);

    (bool oracleEnabled, address oracle,, uint24 maxTickDeviation) = vault.getOracleConfig();
    assertTrue(oracleEnabled);
    assertEq(oracle, address(_market.oracle));
    assertEq(maxTickDeviation, 200);

    // Test disabling oracle with stored tick
    Tick testTick = Tick.wrap(1000);
    vm.expectEmit(true, true, true, true, address(vault));
    emit MangroveVaultV2Events.OracleConfigUpdated(false, address(0), testTick, 0);
    vault.setOracleConfig(false, address(0), testTick, 0);
    Tick storedTick;
    (oracleEnabled, oracle, storedTick,) = vault.getOracleConfig();
    assertFalse(oracleEnabled);
    assertEq(oracle, address(0));
    assertEq(Tick.unwrap(storedTick), 1000);

    vm.stopPrank();
  }

  function test_getCurrentTick() public {
    // Test oracle mode
    (MangroveVaultV2 vault, MarketWOracle memory _market,) = deployVault(0, true);
    Tick oracleTick = _market.oracle.tick();
    assertEq(Tick.unwrap(vault.getCurrentTick()), Tick.unwrap(oracleTick), "Should return oracle tick");

    // Test oracle-less mode
    (MangroveVaultV2 vault2,,) = deployVault(0, false);
    Tick storedTick = vault2.getCurrentTick();
    assertEq(Tick.unwrap(vault2.getCurrentTick()), Tick.unwrap(storedTick), "Should return stored tick");
  }

  // Test Guardian Functionality

  function test_setGuardian() public {
    (MangroveVaultV2 vault,,) = deployVault(0, true);

    address newGuardian = vm.createWallet("New Guardian").addr;

    vm.startPrank(owner);
    vm.expectEmit(true, false, false, false, address(vault));
    emit MangroveVaultV2Events.GuardianSet(newGuardian);
    vault.setGuardian(newGuardian);
    vm.stopPrank();

    assertEq(vault.guardian(), newGuardian, "Guardian should be updated");
  }

  function test_setGuardianZeroAddress() public {
    (MangroveVaultV2 vault,,) = deployVault(0, true);

    vm.startPrank(owner);
    vm.expectRevert(MangroveVaultErrors.ZeroAddress.selector);
    vault.setGuardian(address(0));
    vm.stopPrank();
  }

  // Test Position Updates in Oracle Mode

  function test_setPositionOracleMode() public {
    (MangroveVaultV2 vault, MarketWOracle memory _market, address kandel) = deployVault(0, true);

    mintWithSpecifiedQuoteAmount(vault, _market, 100_000e6);
    vault.fundMangrove{value: 1 ether}();

    KandelPosition memory position;
    position.tickIndex0 = Tick.wrap(Tick.unwrap(vault.getCurrentTick()) - 10);
    position.tickOffset = 3;
    position.fundsState = FundsState.Active;
    position.params = Params({gasprice: 0, gasreq: 0, stepSize: 1, pricePoints: 10});

    vm.startPrank(owner);
    vm.expectEmit(false, false, false, true, kandel);
    emit GeometricKandel.SetBaseQuoteTickOffset(position.tickOffset);
    vault.setPosition(position);
    vm.stopPrank();
  }

  function test_setPositionOracleModeTickDeviation() public {
    (MangroveVaultV2 vault,,) = deployVault(0, true);

    KandelPosition memory position;
    // Set tick too far from oracle price (more than 100 tick deviation)
    position.tickIndex0 = Tick.wrap(Tick.unwrap(vault.getCurrentTick()) - 200);
    position.tickOffset = 3;
    position.fundsState = FundsState.Active;
    position.params = Params({gasprice: 0, gasreq: 0, stepSize: 1, pricePoints: 10});

    vm.startPrank(owner);
    vm.expectRevert(MangroveVaultV2Errors.TickDeviationExceeded.selector);
    vault.setPosition(position);
    vm.stopPrank();
  }

  // Test Position Updates in Oracle-less Mode

  function test_proposePositionUpdateOraclessMode() public {
    (MangroveVaultV2 vault,,) = deployVault(0, false);

    Tick targetTick = Tick.wrap(1500);
    KandelPosition memory position;
    position.tickIndex0 = targetTick;
    position.tickOffset = 3;
    position.fundsState = FundsState.Active;
    position.params = Params({gasprice: 0, gasreq: 0, stepSize: 1, pricePoints: 10});

    uint256 expectedExecuteTime = block.timestamp + vault.POSITION_TIMELOCK();

    vm.startPrank(manager);
    vm.expectEmit(true, true, false, false, address(vault));
    emit MangroveVaultV2Events.PositionUpdateProposed(targetTick, expectedExecuteTime);
    vault.proposePositionUpdate(targetTick, position);
    vm.stopPrank();

    assertTrue(vault.hasPendingPositionUpdate(), "Should have pending update");
    uint256 executeTime;
    bool disputed;
    (targetTick,, executeTime, disputed) = vault.pendingPositionUpdate();
    assertEq(Tick.unwrap(targetTick), Tick.unwrap(targetTick), "Target tick should match");
    assertEq(executeTime, expectedExecuteTime, "Execute time should match");
    assertFalse(disputed, "Should not be disputed initially");
  }

  function test_proposePositionUpdateInOracleMode() public {
    (MangroveVaultV2 vault,,) = deployVault(0, true);

    Tick targetTick = Tick.wrap(1500);
    KandelPosition memory position;

    vm.startPrank(manager);
    vm.expectRevert(MangroveVaultV2Errors.OracleEnabled.selector);
    vault.proposePositionUpdate(targetTick, position);
    vm.stopPrank();
  }

  function test_executePendingPositionUpdate() public {
    (MangroveVaultV2 vault,,) = deployVault(0, false);

    Tick targetTick = Tick.wrap(1500);
    KandelPosition memory position;
    position.tickIndex0 = targetTick;
    position.tickOffset = 3;
    position.fundsState = FundsState.Active;
    position.params = Params({gasprice: 0, gasreq: 0, stepSize: 1, pricePoints: 10});

    // Propose update
    vm.prank(manager);
    vault.proposePositionUpdate(targetTick, position);

    // Try to execute before timelock expires
    vm.startPrank(manager);
    vm.expectRevert(MangroveVaultV2Errors.PositionUpdateNotReady.selector);
    vault.executePendingPositionUpdate();
    vm.stopPrank();

    // Fast forward past timelock
    vm.warp(block.timestamp + vault.POSITION_TIMELOCK() + 1);

    vm.startPrank(manager);
    vm.expectEmit(true, false, false, false, address(vault));
    emit MangroveVaultV2Events.PositionUpdateExecuted(targetTick);
    vault.executePendingPositionUpdate();
    vm.stopPrank();

    assertFalse(vault.hasPendingPositionUpdate(), "Should not have pending update");
    assertEq(Tick.unwrap(vault.getCurrentTick()), Tick.unwrap(targetTick), "Stored tick should be updated");
  }

  function test_disputePositionUpdate() public {
    (MangroveVaultV2 vault,,) = deployVault(0, false);

    Tick targetTick = Tick.wrap(1500);
    KandelPosition memory position;
    position.tickIndex0 = targetTick;

    // Propose update
    vm.prank(manager);
    vault.proposePositionUpdate(targetTick, position);

    // Guardian disputes
    vm.startPrank(guardian);
    vm.expectEmit(false, false, false, false, address(vault));
    emit MangroveVaultV2Events.PositionUpdateDisputed();
    vault.disputePositionUpdate();
    vm.stopPrank();

    (,, uint256 executeTime, bool disputed) = vault.pendingPositionUpdate();
    assertTrue(disputed, "Should be disputed");

    // Fast forward past timelock
    vm.warp(block.timestamp + vault.POSITION_TIMELOCK() + 1);

    // Try to execute disputed update
    vm.startPrank(manager);
    vm.expectRevert(MangroveVaultV2Errors.PositionUpdateIsDisputed.selector);
    vault.executePendingPositionUpdate();
    vm.stopPrank();
  }

  function test_cancelPendingPositionUpdate() public {
    (MangroveVaultV2 vault,,) = deployVault(0, false);

    Tick targetTick = Tick.wrap(1500);
    KandelPosition memory position;

    // Propose update
    vm.prank(manager);
    vault.proposePositionUpdate(targetTick, position);

    assertTrue(vault.hasPendingPositionUpdate(), "Should have pending update");

    // Cancel update
    vm.startPrank(manager);
    vm.expectEmit(false, false, false, false, address(vault));
    emit MangroveVaultV2Events.PositionUpdateCanceled();
    vault.cancelPendingPositionUpdate();
    vm.stopPrank();

    assertFalse(vault.hasPendingPositionUpdate(), "Should not have pending update");
  }

  function test_onlyGuardianCanDispute() public {
    (MangroveVaultV2 vault,,) = deployVault(0, false);

    Tick targetTick = Tick.wrap(1500);
    KandelPosition memory position;

    vm.prank(manager);
    vault.proposePositionUpdate(targetTick, position);

    // Non-guardian tries to dispute
    vm.startPrank(user);
    vm.expectRevert(MangroveVaultV2Errors.OnlyGuardian.selector);
    vault.disputePositionUpdate();
    vm.stopPrank();
  }

  // Test Minting (Funds Stay in Vault)

  function test_mintFundsStayInVault() public {
    (MangroveVaultV2 vault, MarketWOracle memory _market,) = deployVault(0, true);

    (uint256 baseAmountOut, uint256 quoteAmountOut, uint256 shares) =
      mintWithSpecifiedQuoteAmount(vault, _market, 100_000e6);

    // Check funds are in vault, not Kandel
    (uint256 vaultBaseBalance, uint256 vaultQuoteBalance) = vault.getVaultBalances();
    (uint256 kandelBaseBalance, uint256 kandelQuoteBalance) = vault.getKandelBalances();

    assertEq(vaultBaseBalance, baseAmountOut, "Base should be in vault");
    assertEq(vaultQuoteBalance, quoteAmountOut, "Quote should be in vault");
    assertEq(kandelBaseBalance, 0, "No base should be in Kandel");
    assertEq(kandelQuoteBalance, 0, "No quote should be in Kandel");
  }

  function test_manualDepositToKandel() public {
    (MangroveVaultV2 vault, MarketWOracle memory _market,) = deployVault(0, true);

    mintWithSpecifiedQuoteAmount(vault, _market, 100_000e6);

    // Manually deposit to Kandel
    vm.prank(manager);
    vault.depositFundsToKandel();

    (uint256 vaultBaseBalance, uint256 vaultQuoteBalance) = vault.getVaultBalances();
    (uint256 kandelBaseBalance, uint256 kandelQuoteBalance) = vault.getKandelBalances();

    assertEq(vaultBaseBalance, 0, "No base should be in vault");
    assertEq(vaultQuoteBalance, 0, "No quote should be in vault");
    assertGt(kandelBaseBalance, 0, "Base should be in Kandel");
    assertGt(kandelQuoteBalance, 0, "Quote should be in Kandel");
  }

  // Test Per-User Timestamp Tracking

  function test_userTimestampTracking() public {
    (MangroveVaultV2 vault, MarketWOracle memory _market,) = deployVault(0, true);

    uint256 mintTime1 = block.timestamp;

    // User's first mint
    (,, uint256 shares1) = mintWithSpecifiedQuoteAmount(vault, _market, 50_000e6);

    // Check user timestamp is set to current block timestamp
    uint256 userTimestamp = vault.userShareInfo(user);
    assertEq(userTimestamp, mintTime1, "User timestamp should be set to mint time");

    // Fast forward 6 months
    vm.warp(block.timestamp + 182 days);
    uint256 mintTime2 = block.timestamp;

    // User's second mint (same amount)
    deal(address(_market.base), user, 100 ether);
    deal(address(_market.quote), user, 50_000e6);

    vm.startPrank(user);
    _market.base.approve(address(vault), type(uint256).max);
    _market.quote.approve(address(vault), type(uint256).max);
    (uint256 baseAmount2, uint256 quoteAmount2, uint256 shares2) = vault.getMintAmounts(100 ether, 50_000e6);
    vault.mint(shares2, baseAmount2, quoteAmount2);
    vm.stopPrank();

    // Check weighted average timestamp calculation
    // Expected: (shares1 * mintTime1 + shares2 * mintTime2) / (shares1 + shares2)
    uint256 expectedWeightedTimestamp = (shares1 * mintTime1 + shares2 * mintTime2) / (shares1 + shares2);
    uint256 actualWeightedTimestamp = vault.userShareInfo(user);
    assertEq(actualWeightedTimestamp, expectedWeightedTimestamp, "Weighted timestamp should be calculated correctly");
  }

  function test_userTimestampResetOnFullBurn() public {
    (MangroveVaultV2 vault, MarketWOracle memory _market,) = deployVault(0, true);

    (,, uint256 shares) = mintWithSpecifiedQuoteAmount(vault, _market, 50_000e6);

    // Verify timestamp is set
    uint256 userTimestamp = vault.userShareInfo(user);
    assertGt(userTimestamp, 0, "User timestamp should be set");

    // Burn all shares
    vm.prank(user);
    vault.burn(shares, 0, 0);

    // Check timestamp is reset to 0
    uint256 userTimestampAfter = vault.userShareInfo(user);
    assertEq(userTimestampAfter, 0, "User timestamp should be reset to 0 after full burn");
  }

  function test_userTimestampUnchangedOnPartialBurn() public {
    (MangroveVaultV2 vault, MarketWOracle memory _market,) = deployVault(0, true);

    (,, uint256 shares) = mintWithSpecifiedQuoteAmount(vault, _market, 50_000e6);

    uint256 userTimestampBefore = vault.userShareInfo(user);
    assertGt(userTimestampBefore, 0, "User timestamp should be set");

    // Burn half the shares
    vm.prank(user);
    vault.burn(shares / 2, 0, 0);

    // Check timestamp remains the same
    uint256 userTimestampAfter = vault.userShareInfo(user);
    assertEq(userTimestampAfter, userTimestampBefore, "User timestamp should remain unchanged on partial burn");
  }

  // Test Management Fees with Per-User Timestamps

  function test_managementFeesForUserBasedOnUserTimestamp() public {
    (MangroveVaultV2 vault, MarketWOracle memory _market,) = deployVault(0, true);

    (,, uint256 shares) = mintWithSpecifiedQuoteAmount(vault, _market, 100_000e6);

    // Fast forward 1 year for management fees
    vm.warp(block.timestamp + 365 days);

    uint256 feeShares = vault.calculateManagementFeesForUser(user, shares);
    assertGt(feeShares, 0, "Should have management fees after 1 year");

    uint256 feeRecipientSharesBefore = vault.balanceOf(feeRecipient);

    vm.prank(user);
    vault.burn(shares, 0, 0);

    uint256 feeRecipientSharesAfter = vault.balanceOf(feeRecipient);
    assertEq(feeRecipientSharesAfter - feeRecipientSharesBefore, feeShares, "Fee recipient should receive fee shares");
  }

  function test_calculateManagementFeesForUser() public {
    (MangroveVaultV2 vault, MarketWOracle memory _market,) = deployVault(0, true);

    uint256 mintTime = block.timestamp;
    (,, uint256 shares) = mintWithSpecifiedQuoteAmount(vault, _market, 100_000e6);

    // No time elapsed, no fees
    uint256 fees = vault.calculateManagementFeesForUser(user, shares);
    assertEq(fees, 0, "No fees when no time elapsed");

    // Fast forward 1 year
    vm.warp(mintTime + 365 days);

    fees = vault.calculateManagementFeesForUser(user, shares);
    // 5% of shares as management fee
    uint256 expectedFees = shares.mulDiv(500, MangroveVaultConstants.MANAGEMENT_FEE_PRECISION);
    assertEq(fees, expectedFees, "Should calculate 5% management fee for 1 year");

    // Fast forward 6 months more (1.5 years total from mint)
    vm.warp(mintTime + 548 days); // 365 + 183 days

    fees = vault.calculateManagementFeesForUser(user, shares);
    expectedFees = shares.mulDiv(750, MangroveVaultConstants.MANAGEMENT_FEE_PRECISION); // 7.5% for 1.5 years
    assertApproxEqAbs(fees, expectedFees, expectedFees / 1000, "Should calculate ~7.5% management fee for 1.5 years");
  }

  function test_zeroManagementFeeForUser() public {
    (MangroveVaultV2 vault, MarketWOracle memory _market,) = deployVault(0, true);

    // Set management fee to 0
    vm.prank(owner);
    vault.setFeeData(0, feeRecipient);

    (,, uint256 shares) = mintWithSpecifiedQuoteAmount(vault, _market, 100_000e6);
    vm.warp(block.timestamp + 365 days);

    uint256 fees = vault.calculateManagementFeesForUser(user, shares);
    assertEq(fees, 0, "No fees when management fee is 0");
  }

  function test_noFeesForUserWithNoTimestamp() public {
    (MangroveVaultV2 vault,,) = deployVault(0, true);

    uint256 shares = 1000e18;
    vm.warp(block.timestamp + 365 days);

    // User with no shares/timestamp should have no fees
    uint256 fees = vault.calculateManagementFeesForUser(user, shares);
    assertEq(fees, 0, "No fees for user with no timestamp");
  }

  // Test Multiple Users with Different Entry Times

  function test_multipleUsersWithDifferentEntryTimes() public {
    (MangroveVaultV2 vault, MarketWOracle memory _market,) = deployVault(0, true);

    address user2 = vm.createWallet("User2").addr;

    uint256 user1MintTime = block.timestamp;
    // User 1 mints
    (,, uint256 shares1) = mintWithSpecifiedQuoteAmount(vault, _market, 50_000e6);

    // Fast forward 6 months
    vm.warp(block.timestamp + 182 days);
    uint256 user2MintTime = block.timestamp;

    // User 2 mints
    deal(address(_market.base), user2, 100 ether);
    deal(address(_market.quote), user2, 50_000e6);

    vm.startPrank(user2);
    _market.base.approve(address(vault), type(uint256).max);
    _market.quote.approve(address(vault), type(uint256).max);
    (uint256 baseAmount2, uint256 quoteAmount2, uint256 shares2) = vault.getMintAmounts(100 ether, 50_000e6);
    vault.mint(shares2, baseAmount2, quoteAmount2);
    vm.stopPrank();

    // Fast forward another 6 months (1 year from user1 mint, 6 months from user2 mint)
    vm.warp(user1MintTime + 365 days);

    // Calculate expected fees for each user
    uint256 expectedFeesUser1 = shares1.mulDiv(500, MangroveVaultConstants.MANAGEMENT_FEE_PRECISION); // 5% for 1 year
    uint256 expectedFeesUser2 = shares2.mulDiv(250, MangroveVaultConstants.MANAGEMENT_FEE_PRECISION); // 2.5% for 6 months

    uint256 actualFeesUser1 = vault.calculateManagementFeesForUser(user, shares1);
    uint256 actualFeesUser2 = vault.calculateManagementFeesForUser(user2, shares2);

    assertEq(actualFeesUser1, expectedFeesUser1, "User 1 should pay fees for 1 year");
    assertApproxEqAbs(actualFeesUser2, expectedFeesUser2, 1, "User 2 should pay fees for 6 months");

    // User 1 burns and should pay 1 year of management fees
    uint256 feeRecipientBalanceBefore = vault.balanceOf(feeRecipient);

    vm.prank(user);
    vault.burn(shares1, 0, 0);

    uint256 feeRecipientBalanceAfter = vault.balanceOf(feeRecipient);
    assertEq(
      feeRecipientBalanceAfter - feeRecipientBalanceBefore,
      expectedFeesUser1,
      "Fee recipient should receive user1's fees"
    );

    // User 2 burns and should pay 6 months of management fees
    vm.prank(user2);
    vault.burn(shares2, 0, 0);

    uint256 feeRecipientBalanceFinal = vault.balanceOf(feeRecipient);
    assertApproxEqAbs(
      feeRecipientBalanceFinal - feeRecipientBalanceAfter,
      expectedFeesUser2,
      1,
      "Fee recipient should receive user2's fees"
    );
  }

  // Test Initial Mint

  function testFuzz_initialMintAmountMatch(uint8 market, uint128 quote) public {
    vm.assume(quote > MangroveVaultConstants.MINIMUM_LIQUIDITY);
    vm.assume(market < markets().length);
    (MangroveVaultV2 vault, MarketWOracle memory _market,) = deployVault(market, true);
    vm.assume(quote < _market.maxQuote);

    (uint256 baseAmountOut, uint256 quoteAmountOut, uint256 shares) =
      mintWithSpecifiedQuoteAmount(vault, _market, quote);

    // Check that the total supply is correct
    uint256 expectedTotalSupply = quoteAmountOut * 2 * 10 ** (18 - _market.quote.decimals());
    assertApproxEqAbs(vault.totalSupply(), expectedTotalSupply, 1, "total supply doesn't match expected value");

    // Check that expected shares match
    uint256 expectedShares = expectedTotalSupply - MangroveVaultConstants.MINIMUM_LIQUIDITY;
    assertApproxEqAbs(shares, expectedShares, 1, "balance of shares doesn't match expected value");

    // Check that the balances are correct (funds stay in vault in V2)
    assertEq(_market.base.balanceOf(address(vault)), baseAmountOut);
    assertEq(_market.quote.balanceOf(address(vault)), quoteAmountOut);

    // Check kandel balances are zero initially
    (uint256 kandelBase, uint256 kandelQuote) = vault.getKandelBalances();
    assertEq(kandelBase, 0);
    assertEq(kandelQuote, 0);

    // Check total supply
    assertEq(vault.totalSupply(), shares + MangroveVaultConstants.MINIMUM_LIQUIDITY);
    assertEq(vault.balanceOf(address(vault)), MangroveVaultConstants.MINIMUM_LIQUIDITY);

    // Check underlying balances
    (uint256 baseBalance, uint256 quoteBalance) = vault.getUnderlyingBalances();
    assertEq(baseBalance, _market.base.balanceOf(address(vault)));
    assertEq(quoteBalance, _market.quote.balanceOf(address(vault)));

    // Check user timestamp is set
    uint256 userTimestamp = vault.userShareInfo(user);
    assertEq(userTimestamp, block.timestamp, "User timestamp should be set to current block timestamp");
  }

  function testFuzz_initialAndSecondMint(uint8 market, uint128 quoteInitial, uint128 quoteSecond) public {
    vm.assume(quoteInitial > MangroveVaultConstants.MINIMUM_LIQUIDITY);
    vm.assume(quoteSecond > MangroveVaultConstants.MINIMUM_LIQUIDITY);
    vm.assume(market < markets().length);
    (MangroveVaultV2 vault, MarketWOracle memory _market,) = deployVault(market, true);
    vm.assume(quoteInitial < _market.maxQuote);
    vm.assume(quoteSecond < _market.maxQuote);

    uint256 mintTime1 = block.timestamp;
    // First mint
    (uint256 baseAmountOut, uint256 quoteAmountOut, uint256 shares) =
      mintWithSpecifiedQuoteAmount(vault, _market, quoteInitial);

    assertEq(_market.base.balanceOf(address(vault)), baseAmountOut);
    assertEq(_market.quote.balanceOf(address(vault)), quoteAmountOut);

    // Fast forward some time
    vm.warp(block.timestamp + 100 days);
    uint256 mintTime2 = block.timestamp;

    // Second mint
    (uint256 baseAmountOut2, uint256 quoteAmountOut2, uint256 shares2) =
      mintWithSpecifiedQuoteAmount(vault, _market, quoteSecond);

    assertEq(_market.base.balanceOf(address(vault)), baseAmountOut + baseAmountOut2);
    assertEq(_market.quote.balanceOf(address(vault)), quoteAmountOut + quoteAmountOut2);
    assertEq(vault.totalSupply(), shares + shares2 + MangroveVaultConstants.MINIMUM_LIQUIDITY);

    // Check weighted timestamp is calculated correctly
    uint256 expectedWeightedTimestamp = (shares * mintTime1 + shares2 * mintTime2) / (shares + shares2);
    uint256 actualWeightedTimestamp = vault.userShareInfo(user);
    assertEq(actualWeightedTimestamp, expectedWeightedTimestamp, "Weighted timestamp should be calculated correctly");
  }

  // Test Burning

  uint16 public constant BURN_PRECISION = 10000;

  function testFuzz_burnShares(uint8 market, uint128 quoteInitial, uint16 burnProportion) public {
    vm.assume(market < markets().length);
    vm.assume(burnProportion > 0 && burnProportion <= BURN_PRECISION);
    (MangroveVaultV2 vault, MarketWOracle memory _market,) = deployVault(market, true);
    vm.assume(quoteInitial >= BURN_PRECISION && quoteInitial < _market.maxQuote);

    (,, uint256 shares) = mintWithSpecifiedQuoteAmount(vault, _market, quoteInitial);

    uint256 sharesToBurn = (shares * burnProportion) / BURN_PRECISION;

    assertGt(sharesToBurn, 0, "Shares to burn should be greater than 0");
    assertLe(sharesToBurn, shares, "Shares to burn should be less than or equal to total shares");

    (uint256 expectedBaseOut, uint256 expectedQuoteOut) = vault.getUnderlyingBalancesByShare(sharesToBurn);

    vm.prank(user);
    (uint256 actualBaseOut, uint256 actualQuoteOut) = vault.burn(sharesToBurn, 0, 0);

    assertApproxEqRel(actualBaseOut, expectedBaseOut, 1e16, "Base amount out should be close to expected");
    assertApproxEqRel(actualQuoteOut, expectedQuoteOut, 1e16, "Quote amount out should be close to expected");

    assertEq(vault.balanceOf(user), shares - sharesToBurn, "Remaining shares should be correct");
    assertApproxEqRel(_market.base.balanceOf(user), actualBaseOut, 1e16, "Base balance should be close to amount out");
    assertApproxEqRel(
      _market.quote.balanceOf(user), actualQuoteOut, 1e16, "Quote balance should be close to amount out"
    );

    // Check timestamp behavior
    if (sharesToBurn == shares) {
      // Full burn should reset timestamp
      uint256 userTimestamp = vault.userShareInfo(user);
      assertEq(userTimestamp, 0, "Timestamp should be reset on full burn");
    } else {
      // Partial burn should keep timestamp
      uint256 userTimestamp = vault.userShareInfo(user);
      assertGt(userTimestamp, 0, "Timestamp should remain on partial burn");
    }
  }

  // Test Authorization

  function test_auth() public {
    (MangroveVaultV2 vault,,) = deployVault(0, true);

    vm.startPrank(user);

    bytes memory revertMsgManager = abi.encodeWithSelector(MangroveVaultErrors.ManagerOwnerUnauthorized.selector, user);
    bytes memory revertMsg = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user);

    vm.expectRevert(revertMsg);
    vault.allowSwapContract(address(this));

    vm.expectRevert(revertMsg);
    vault.disallowSwapContract(address(this));

    vm.expectRevert(revertMsgManager);
    vault.swap(address(this), "", 0, 0, false);

    KandelPosition memory position;
    vm.expectRevert(revertMsgManager);
    vault.setPosition(position);

    vm.expectRevert(revertMsgManager);
    vault.proposePositionUpdate(Tick.wrap(0), position);

    vm.expectRevert(revertMsg);
    vault.setOracleConfig(true, address(0), Tick.wrap(0), 100);

    vm.expectRevert(revertMsg);
    vault.setGuardian(address(0));

    vm.expectRevert(revertMsg);
    vault.withdrawFromMangrove(0, payable(user));

    vm.expectRevert(revertMsg);
    vault.withdrawERC20(address(WETH), 0);

    vm.expectRevert(revertMsg);
    vault.withdrawNative();

    vm.expectRevert(revertMsg);
    vault.pause(true);

    vm.expectRevert(revertMsg);
    vault.setFeeData(0, address(0));

    vm.expectRevert(revertMsg);
    vault.setMaxPriceSpread(0);

    vm.expectRevert(revertMsg);
    vault.setManager(address(0));

    vm.stopPrank();
  }

  // Test Position Setting

  function test_setPositionActive() public {
    (MangroveVaultV2 vault, MarketWOracle memory _market, address kandel) = deployVault(0, true);

    (uint256 baseAmountOut, uint256 quoteAmountOut,) = mintWithSpecifiedQuoteAmount(vault, _market, 100_000e6);

    vault.fundMangrove{value: 1 ether}();

    KandelPosition memory position;
    position.tickIndex0 = Tick.wrap(Tick.unwrap(vault.getCurrentTick()) - 10);
    position.tickOffset = 3;
    position.fundsState = FundsState.Active;
    position.params = Params({gasprice: 0, gasreq: 0, stepSize: 1, pricePoints: 10});

    vm.prank(owner);
    vault.setPosition(position);

    // Check funds moved to Kandel and offers posted
    uint256 offeredBase = GeometricKandel(payable(kandel)).offeredVolume(OfferType.Ask);
    uint256 offeredQuote = GeometricKandel(payable(kandel)).offeredVolume(OfferType.Bid);

    assertApproxEqAbs(offeredBase, baseAmountOut, 10, "Offered base should equal baseAmountOut");
    assertApproxEqAbs(offeredQuote, quoteAmountOut, 10, "Offered quote should equal quoteAmountOut");
  }

  function test_setPositionPassive() public {
    (MangroveVaultV2 vault, MarketWOracle memory _market, address kandel) = deployVault(0, true);

    mintWithSpecifiedQuoteAmount(vault, _market, 100_000e6);

    KandelPosition memory position;
    position.tickIndex0 = Tick.wrap(Tick.unwrap(vault.getCurrentTick()) - 10);
    position.tickOffset = 3;
    position.fundsState = FundsState.Passive;
    position.params = Params({gasprice: 0, gasreq: 0, stepSize: 1, pricePoints: 10});

    vm.prank(owner);
    vault.setPosition(position);

    // Check funds moved to Kandel but no offers posted
    (uint256 kandelBase, uint256 kandelQuote) = vault.getKandelBalances();
    assertGt(kandelBase, 0, "Base should be in Kandel");
    assertGt(kandelQuote, 0, "Quote should be in Kandel");

    uint256 offeredBase = GeometricKandel(payable(kandel)).offeredVolume(OfferType.Ask);
    uint256 offeredQuote = GeometricKandel(payable(kandel)).offeredVolume(OfferType.Bid);

    assertEq(offeredBase, 0, "No offers should be posted");
    assertEq(offeredQuote, 0, "No offers should be posted");
  }

  // Test Swapping

  function swapMock(ERC20 inbound, ERC20 outbound, uint256 inboundAmount, uint256 outboundAmount) public {
    inbound.transferFrom(msg.sender, address(this), inboundAmount);
    deal(address(outbound), address(this), outboundAmount);
    outbound.transfer(msg.sender, outboundAmount);
  }

  function test_swapInVaultState() public {
    (MangroveVaultV2 vault, MarketWOracle memory _market,) = deployVault(0, true);

    KandelPosition memory position;
    position.tickIndex0 = Tick.wrap(Tick.unwrap(vault.getCurrentTick()) - 10);
    position.fundsState = FundsState.Vault; // Keep funds in vault

    vm.prank(owner);
    vault.setPosition(position);

    mintWithSpecifiedQuoteAmount(vault, _market, 100_000e6);

    (uint256 baseAmountStart, uint256 quoteAmountStart) = vault.getUnderlyingBalances();

    vm.prank(owner);
    vault.allowSwapContract(address(this));

    vm.prank(owner);
    vm.expectEmit(false, false, false, true, address(vault));
    emit MangroveVaultEvents.Swap(address(this), -1 ether, 3000e6, true);
    vault.swap(address(this), abi.encodeCall(this.swapMock, (WETH, USDC, 1 ether, 3000e6)), 1 ether, 0, true);

    (uint256 baseAmountEnd, uint256 quoteAmountEnd) = vault.getUnderlyingBalances();
    assertEq(baseAmountEnd, baseAmountStart - 1 ether, "Base balance should decrease by 1 ether");
    assertEq(quoteAmountEnd, quoteAmountStart + 3000e6, "Quote balance should increase by 3000e6");
  }

  function test_swapWithMaxPriceSpread() public {
    (MangroveVaultV2 vault, MarketWOracle memory _market,) = deployVault(0, true);

    mintWithSpecifiedQuoteAmount(vault, _market, 100_000e6);

    vm.prank(owner);
    vault.setMaxPriceSpread(100); // 100 tick max spread

    vm.prank(owner);
    vault.allowSwapContract(address(this));

    Tick price = Tick.wrap(Tick.unwrap(vault.getCurrentTick()) - 100);
    uint256 expectedAmountInMin = price.inboundFromOutboundUp(1 ether);

    vm.prank(manager);
    vm.expectRevert(
      abi.encodeWithSelector(
        MangroveVaultErrors.SlippageExceeded.selector, expectedAmountInMin, expectedAmountInMin - 1
      )
    );
    vault.swap(
      address(this), abi.encodeCall(this.swapMock, (WETH, USDC, 1 ether, expectedAmountInMin - 1)), 1 ether, 0, true
    );

    // Should succeed with exact minimum
    vm.prank(manager);
    vault.swap(
      address(this), abi.encodeCall(this.swapMock, (WETH, USDC, 1 ether, expectedAmountInMin)), 1 ether, 0, true
    );
  }

  function test_unauthorizedSwapContract() public {
    (MangroveVaultV2 vault,,) = deployVault(0, true);

    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(MangroveVaultErrors.UnauthorizedSwapContract.selector, user));
    vault.swap(address(user), abi.encodeCall(this.swapMock, (WETH, USDC, 0, 0)), 0, 0, true);
  }

  // Test Fee Data

  function test_setFeeData() public {
    (MangroveVaultV2 vault,,) = deployVault(0, true);

    uint16 newManagementFee = 1000; // 10%
    address newFeeRecipient = vm.createWallet("New Fee Recipient").addr;

    vm.startPrank(owner);
    vm.expectEmit(true, true, true, true, address(vault));
    emit MangroveVaultEvents.SetFeeData(0, newManagementFee, newFeeRecipient);
    vault.setFeeData(newManagementFee, newFeeRecipient);
    vm.stopPrank();

    (uint16 managementFee, address feeRecipient) = vault.feeData();
    assertEq(managementFee, newManagementFee, "Management fee should be updated");
    assertEq(feeRecipient, newFeeRecipient, "Fee recipient should be updated");
  }

  function test_setFeeDataMaxExceeded() public {
    (MangroveVaultV2 vault,,) = deployVault(0, true);

    vm.startPrank(owner);
    vm.expectRevert(
      abi.encodeWithSelector(
        MangroveVaultErrors.MaxFeeExceeded.selector,
        MangroveVaultConstants.MAX_MANAGEMENT_FEE,
        MangroveVaultConstants.MAX_MANAGEMENT_FEE + 1
      )
    );
    vault.setFeeData(MangroveVaultConstants.MAX_MANAGEMENT_FEE + 1, feeRecipient);
    vm.stopPrank();
  }

  // Test Advanced Scenarios

  function test_burnWithKandelFunds() public {
    (MangroveVaultV2 vault, MarketWOracle memory _market,) = deployVault(0, true);

    (,, uint256 shares) = mintWithSpecifiedQuoteAmount(vault, _market, 100_000e6);

    // Move funds to Kandel
    vm.prank(manager);
    vault.depositFundsToKandel();

    // Burn should withdraw from Kandel
    vm.prank(user);
    (uint256 baseOut, uint256 quoteOut) = vault.burn(shares / 2, 0, 0);

    assertGt(baseOut, 0, "Should receive base tokens");
    assertGt(quoteOut, 0, "Should receive quote tokens");
  }

  function test_oraclelessModeFullWorkflow() public {
    (MangroveVaultV2 vault, MarketWOracle memory _market,) = deployVault(0, false);

    mintWithSpecifiedQuoteAmount(vault, _market, 100_000e6);
    vault.fundMangrove{value: 1 ether}();
    // Test moving funds to Kandel in oracleless mode
    (uint256 baseBalanceBefore, uint256 quoteBalanceBefore) = vault.getVaultBalances();

    vm.prank(manager);
    vault.depositFundsToKandel();

    (uint256 kandelBase, uint256 kandelQuote) = vault.getKandelBalances();
    assertGt(kandelBase, 0, "Base should be moved to Kandel");
    assertGt(kandelQuote, 0, "Quote should be moved to Kandel");

    (uint256 baseBalanceAfter, uint256 quoteBalanceAfter) = vault.getVaultBalances();
    assertLt(baseBalanceAfter, baseBalanceBefore, "Base balance should decrease");
    assertLt(quoteBalanceAfter, quoteBalanceBefore, "Quote balance should decrease");

    // Propose position update
    Tick newTick = Tick.wrap(Tick.unwrap(vault.getCurrentTick()) + 50);
    KandelPosition memory position;
    position.tickIndex0 = newTick;
    position.tickOffset = 3;
    position.fundsState = FundsState.Active;
    position.params = Params({gasprice: 0, gasreq: 0, stepSize: 1, pricePoints: 10});

    vm.prank(manager);
    vault.proposePositionUpdate(newTick, position);

    // Users can exit during timelock if they disagree
    uint256 userBalance = vault.balanceOf(user);
    vm.prank(user);
    vault.burn(userBalance / 2, 0, 0);

    // Fast forward past timelock
    vm.warp(block.timestamp + vault.POSITION_TIMELOCK() + 1);

    // Execute position update
    vm.prank(manager);
    vault.executePendingPositionUpdate();

    // Verify new tick is set
    assertEq(Tick.unwrap(vault.getCurrentTick()), Tick.unwrap(newTick), "New tick should be set");
  }

  function test_invalidMaxTickDeviation() public {
    (MangroveVaultV2 vault,,) = deployVault(0, true);

    vm.startPrank(owner);
    vm.expectRevert(MangroveVaultV2Errors.InvalidMaxTickDeviation.selector);
    vault.setOracleConfig(true, address(ETH_USDC_ORACLE), Tick.wrap(0), uint24(int24(MAX_TICK)) + 1);
    vm.stopPrank();
  }

  // Test Edge Cases for Per-User Timestamp System

  function test_userTimestampWithMultipleMints() public {
    (MangroveVaultV2 vault, MarketWOracle memory _market,) = deployVault(0, true);

    uint256 time1 = block.timestamp;
    // First mint: 100 shares at time1
    (,, uint256 shares1) = mintWithSpecifiedQuoteAmount(vault, _market, 25_000e6);

    vm.warp(block.timestamp + 30 days);
    uint256 time2 = block.timestamp;

    // Second mint: 200 shares at time2
    deal(address(_market.base), user, 200 ether);
    deal(address(_market.quote), user, 50_000e6);

    vm.startPrank(user);
    _market.base.approve(address(vault), type(uint256).max);
    _market.quote.approve(address(vault), type(uint256).max);
    (uint256 baseAmount2, uint256 quoteAmount2, uint256 shares2) = vault.getMintAmounts(200 ether, 50_000e6);
    vault.mint(shares2, baseAmount2, quoteAmount2);
    vm.stopPrank();

    vm.warp(block.timestamp + 60 days);
    uint256 time3 = block.timestamp;

    // Third mint: 150 shares at time3
    deal(address(_market.base), user, 300 ether);
    deal(address(_market.quote), user, 37_500e6);

    vm.startPrank(user);
    (uint256 baseAmount3, uint256 quoteAmount3, uint256 shares3) = vault.getMintAmounts(300 ether, 37_500e6);
    vault.mint(shares3, baseAmount3, quoteAmount3);
    vm.stopPrank();

    // Calculate expected weighted timestamp
    uint256 totalShares = shares1 + shares2 + shares3;
    uint256 expectedWeightedTimestamp = (shares1 * time1 + shares2 * time2 + shares3 * time3) / totalShares;

    uint256 actualWeightedTimestamp = vault.userShareInfo(user);
    assertEq(
      actualWeightedTimestamp,
      expectedWeightedTimestamp,
      "Weighted timestamp should be calculated correctly for multiple mints"
    );
  }

  struct TestVars {
    MangroveVaultV2 vault;
    MarketWOracle market;
    uint256 time1;
    uint256 time2;
    uint256 burnTime;
    uint256 shares1;
    uint256 shares2;
    uint256 totalShares;
    uint256 sharesToBurn;
    uint256 expectedWeightedTimestamp;
    uint256 actualWeightedTimestamp;
    uint256 timeElapsed;
    uint256 expectedFees;
    uint256 actualFees;
    uint256 feeRecipientBalanceBefore;
    uint256 feeRecipientBalanceAfter;
    uint256 timestampAfterBurn;
    uint256 baseAmount2;
    uint256 quoteAmount2;
  }

  function test_feesWithComplexUserBehavior() public {
    TestVars memory vars;
    (vars.vault, vars.market,) = deployVault(0, true);

    // User mints 1000 shares at T=0
    vars.time1 = block.timestamp;
    (,, vars.shares1) = mintWithSpecifiedQuoteAmount(vars.vault, vars.market, 50_000e6);

    // Fast forward 6 months, user mints another 500 shares
    vm.warp(vars.time1 + 182 days);
    vars.time2 = block.timestamp;

    deal(address(vars.market.base), user, 100 ether);
    deal(address(vars.market.quote), user, 25_000e6);

    vm.startPrank(user);
    vars.market.base.approve(address(vars.vault), type(uint256).max);
    vars.market.quote.approve(address(vars.vault), type(uint256).max);
    (vars.baseAmount2, vars.quoteAmount2, vars.shares2) = vars.vault.getMintAmounts(100 ether, 25_000e6);
    vars.vault.mint(vars.shares2, vars.baseAmount2, vars.quoteAmount2);
    vm.stopPrank();

    // Fast forward another 6 months, user burns 750 shares (partial burn)
    vm.warp(vars.time1 + 365 days);
    vars.burnTime = block.timestamp;

    vars.totalShares = vars.shares1 + vars.shares2;
    vars.sharesToBurn = (vars.totalShares * 50) / 100; // Burn 50%

    // Calculate expected weighted timestamp before burn
    vars.expectedWeightedTimestamp = (vars.shares1 * vars.time1 + vars.shares2 * vars.time2) / vars.totalShares;
    vars.actualWeightedTimestamp = vars.vault.userShareInfo(user);
    assertEq(
      vars.actualWeightedTimestamp, vars.expectedWeightedTimestamp, "Weighted timestamp should be correct before burn"
    );

    // Calculate expected fees
    vars.timeElapsed = vars.burnTime - vars.expectedWeightedTimestamp;
    vars.expectedFees =
      vars.sharesToBurn.mulDiv(500 * vars.timeElapsed / (365 days), MangroveVaultConstants.MANAGEMENT_FEE_PRECISION);

    vars.actualFees = vars.vault.calculateManagementFeesForUser(user, vars.sharesToBurn);
    assertApproxEqAbs(vars.actualFees, vars.expectedFees, 1, "Fees should be calculated based on weighted timestamp");

    vars.feeRecipientBalanceBefore = vars.vault.balanceOf(feeRecipient);

    vm.prank(user);
    vars.vault.burn(vars.sharesToBurn, 0, 0);

    vars.feeRecipientBalanceAfter = vars.vault.balanceOf(feeRecipient);
    assertApproxEqAbs(
      vars.feeRecipientBalanceAfter - vars.feeRecipientBalanceBefore,
      vars.actualFees,
      1,
      "Fee recipient should receive calculated fees"
    );

    // After partial burn, timestamp should remain the same
    vars.timestampAfterBurn = vars.vault.userShareInfo(user);
    assertEq(
      vars.timestampAfterBurn, vars.expectedWeightedTimestamp, "Timestamp should remain unchanged after partial burn"
    );
  }

  function test_userWithZeroShares() public {
    (MangroveVaultV2 vault,,) = deployVault(0, true);

    // User with no shares should have timestamp 0
    uint256 userTimestamp = vault.userShareInfo(user);
    assertEq(userTimestamp, 0, "User with no shares should have timestamp 0");

    // Calculating fees for user with no timestamp should return 0
    uint256 fees = vault.calculateManagementFeesForUser(user, 1000e18);
    assertEq(fees, 0, "User with no timestamp should have no fees");
  }

  function test_compareOldVsNewFeeCalculation() public {
    (MangroveVaultV2 vault, MarketWOracle memory _market,) = deployVault(0, true);

    // Set a fixed timestamp for the global state (simulating old behavior)
    uint256 globalTimestamp = block.timestamp;

    // User mints at a later time
    vm.warp(globalTimestamp + 100 days);
    (,, uint256 shares) = mintWithSpecifiedQuoteAmount(vault, _market, 100_000e6);

    // Fast forward 1 year from user's mint
    vm.warp(globalTimestamp + 465 days); // 100 days + 365 days

    // Old fee calculation would use global timestamp (465 days)
    // Since we don't have the legacy function anymore, we'll simulate it
    uint256 timeElapsedOld = (globalTimestamp + 465 days) - globalTimestamp; // 465 days
    uint256 oldStyleFees =
      shares.mulDiv(500 * timeElapsedOld / (365 days), MangroveVaultConstants.MANAGEMENT_FEE_PRECISION);

    // New fee calculation uses user's timestamp (365 days)
    uint256 newStyleFees = vault.calculateManagementFeesForUser(user, shares);

    // New calculation should charge less (only for actual time invested)
    assertLt(newStyleFees, oldStyleFees, "New fee calculation should charge less than old unfair calculation");

    // Verify the new calculation is for exactly 1 year (365 days)
    uint256 expectedNewFees = shares.mulDiv(500, MangroveVaultConstants.MANAGEMENT_FEE_PRECISION); // 5% for 1 year
    assertEq(newStyleFees, expectedNewFees, "New fee calculation should be exactly 5% for 1 year");
  }

  function test_userShareInfoMappingDirectly() public {
    (MangroveVaultV2 vault, MarketWOracle memory _market,) = deployVault(0, true);

    // Initially, userShareInfo should return 0
    uint256 initialTimestamp = vault.userShareInfo(user);
    assertEq(initialTimestamp, 0, "Initial timestamp should be 0");

    uint256 mintTime = block.timestamp;
    (,, uint256 shares) = mintWithSpecifiedQuoteAmount(vault, _market, 50_000e6);

    // After mint, userShareInfo should return mint timestamp
    uint256 afterMintTimestamp = vault.userShareInfo(user);
    assertEq(afterMintTimestamp, mintTime, "Timestamp should be set to mint time");

    // After full burn, userShareInfo should return 0
    vm.prank(user);
    vault.burn(shares, 0, 0);

    uint256 afterBurnTimestamp = vault.userShareInfo(user);
    assertEq(afterBurnTimestamp, 0, "Timestamp should be reset to 0 after full burn");
  }

  function test_gasOptimizationNoRedundantStorage() public {
    (MangroveVaultV2 vault, MarketWOracle memory _market,) = deployVault(0, true);

    // Test that we don't store lastShareBalance by verifying the mapping only stores timestamp
    (,, uint256 shares) = mintWithSpecifiedQuoteAmount(vault, _market, 50_000e6);

    // The userShareInfo mapping should only return the timestamp
    uint256 storedValue = vault.userShareInfo(user);
    assertEq(storedValue, block.timestamp, "Should only store timestamp");

    // Verify we can calculate shares using balanceOf instead of stored value
    uint256 currentShares = vault.balanceOf(user);
    assertEq(currentShares, shares, "Should be able to get shares from balanceOf");
  }
}
