// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {MangroveVault, Tick, KandelPosition, FundsState, Params} from "../src/MangroveVault.sol";
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
import {MangroveVaultFactory} from "../src/MangroveVaultFactory.sol";
import {GeometricKandel} from "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/GeometricKandel.sol";
import {HasIndexedBidsAndAsks} from
  "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/HasIndexedBidsAndAsks.sol";

contract MangroveVaultTest is Test {
  using Math for uint256;

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

  MangroveVaultFactory public factory;

  uint256 public constant USD_DECIMALS = 18;

  uint256 arbitrumFork;

  address owner;
  address feeRecipient;
  address user;

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

    factory = new MangroveVaultFactory();

    // Deploy the 3 oracles

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

  function deployVault(uint8 market)
    internal
    returns (MangroveVault vault, MarketWOracle memory _market, address kandel)
  {
    return deployVault(market, kandelSeeder);
  }

  function deployVault(uint8 market, AbstractKandelSeeder seeder)
    internal
    returns (MangroveVault vault, MarketWOracle memory _market, address kandel)
  {
    _market = markets()[market];

    vm.startPrank(owner);
    vm.expectEmit(true, false, false, false, address(factory));
    emit MangroveVaultEvents.VaultCreated(
      address(seeder), address(_market.base), address(_market.quote), 1, address(0), address(0), address(0)
    );
    vault = factory.createVault(
      seeder,
      address(_market.base),
      address(_market.quote),
      1,
      18,
      "Mangrove Vault",
      "MGVv",
      address(_market.oracle),
      owner
    );
    vm.stopPrank();
    kandel = address(vault.kandel());
  }

  function mintWithSpecifiedQuoteAmount(MangroveVault vault, MarketWOracle memory _market, uint256 quoteAmount)
    internal
    returns (uint256 baseAmountOut, uint256 quoteAmountOut, uint256 shares)
  {
    // check that the quote amount is within the bounds
    assertGt(quoteAmount, 0, "Quote amount must be greater than 0");
    assertLt(quoteAmount, _market.maxQuote, "Quote amount must be less than max quote");

    // get the mint amounts
    (baseAmountOut, quoteAmountOut, shares) = vault.getMintAmounts(type(uint256).max, quoteAmount);

    // check that the quote amount out matches the specified quote amount
    assertEq(quoteAmountOut, quoteAmount, "Quote amount out doesn't match specified quote amount");

    // deal the tokens
    deal(address(_market.base), user, baseAmountOut);
    deal(address(_market.quote), user, quoteAmountOut);

    // balance snapshot
    uint256 baseBefore = _market.base.balanceOf(user);
    uint256 quoteBefore = _market.quote.balanceOf(user);
    uint256 sharesBefore = vault.balanceOf(user);
    Tick tick = _market.oracle.tick();

    vm.startPrank(user);

    _market.base.approve(address(vault), baseAmountOut);
    _market.quote.approve(address(vault), quoteAmountOut);

    vm.expectEmit(true, false, false, false, address(vault));
    emit MangroveVaultEvents.Mint(user, shares, baseAmountOut, quoteAmountOut, Tick.unwrap(tick));
    vault.mint(shares, baseAmountOut, quoteAmountOut);

    vm.stopPrank();

    // check that the balances are correct
    assertEq(_market.base.balanceOf(user), baseBefore - baseAmountOut);
    assertEq(_market.quote.balanceOf(user), quoteBefore - quoteAmountOut);

    // check the shares balance is the correct one
    assertEq(vault.balanceOf(user), sharesBefore + shares, "Balance of shares doesn't match");
  }

  uint8[] public fixtureMarket = [0, 1, 2, 3];

  function testFuzz_initialMintAmountMatch(uint8 market, uint128 quote) public {
    vm.assume(quote > MangroveVaultConstants.MINIMUM_LIQUIDITY);
    vm.assume(market < markets().length);
    (MangroveVault vault, MarketWOracle memory _market,) = deployVault(market);
    vm.assume(quote < _market.maxQuote);

    // do the initial mint
    (uint256 baseAmountOut, uint256 quoteAmountOut, uint256 shares) =
      mintWithSpecifiedQuoteAmount(vault, _market, quote);

    // check that the total supply is correct
    // should be 2 * quoteAmount on initial mint scaled to 18 decimals
    uint256 expectedTotalSupply = quoteAmountOut * 2 * 10 ** (18 - _market.quote.decimals());
    assertApproxEqAbs(vault.totalSupply(), expectedTotalSupply, 1, "total supply doesn't match expected value");

    // check that expected shares match
    uint256 expectedShares = expectedTotalSupply - MangroveVaultConstants.MINIMUM_LIQUIDITY; // subtract the minimum liquidity (dead shares)
    assertApproxEqAbs(shares, expectedShares, 1, "balance of shares doesn't match expected value");

    // check that the balances are correct (state of funds is vault so funds are on the vault)
    assertEq(_market.base.balanceOf(address(vault)), baseAmountOut);
    assertEq(_market.quote.balanceOf(address(vault)), quoteAmountOut);

    // check that the total supply is correct
    assertEq(vault.totalSupply(), shares + MangroveVaultConstants.MINIMUM_LIQUIDITY);
    // check dead shares
    assertEq(vault.balanceOf(address(vault)), MangroveVaultConstants.MINIMUM_LIQUIDITY);

    // check simple functions
    // total balances
    (uint256 baseBalance, uint256 quoteBalance) = vault.getUnderlyingBalances();
    assertEq(baseBalance, _market.base.balanceOf(address(vault)));
    assertEq(quoteBalance, _market.quote.balanceOf(address(vault)));

    // kandel balances
    (baseBalance, quoteBalance) = vault.getKandelBalances();
    assertEq(baseBalance, 0);
    assertEq(quoteBalance, 0);

    // vault balances
    (baseBalance, quoteBalance) = vault.getVaultBalances();
    assertEq(baseBalance, _market.base.balanceOf(address(vault)));
    assertEq(quoteBalance, _market.quote.balanceOf(address(vault)));

    // shares
    (baseBalance, quoteBalance) = vault.getUnderlyingBalancesByShare(shares);
    assertEq(baseBalance, _market.base.balanceOf(address(vault)) * shares / vault.totalSupply());
    assertEq(quoteBalance, _market.quote.balanceOf(address(vault)) * shares / vault.totalSupply());
  }

  function testFuzz_initialAndSecondMint(uint8 market, uint128 quoteInitial, uint128 quoteSecond) public {
    vm.assume(quoteInitial > MangroveVaultConstants.MINIMUM_LIQUIDITY);
    vm.assume(quoteSecond > MangroveVaultConstants.MINIMUM_LIQUIDITY);
    vm.assume(market < markets().length);
    (MangroveVault vault, MarketWOracle memory _market,) = deployVault(market);
    vm.assume(quoteInitial < _market.maxQuote);
    vm.assume(quoteSecond < _market.maxQuote);

    // Mint the first time
    (uint256 baseAmountOut, uint256 quoteAmountOut, uint256 shares) =
      mintWithSpecifiedQuoteAmount(vault, _market, quoteInitial);

    // Assert the initial balances and shares
    assertEq(_market.base.balanceOf(address(vault)), baseAmountOut);
    assertEq(_market.quote.balanceOf(address(vault)), quoteAmountOut);

    // Mint a second time
    (uint256 baseAmountOut2, uint256 quoteAmountOut2, uint256 shares2) =
      mintWithSpecifiedQuoteAmount(vault, _market, quoteSecond);

    // Assert the new balances and shares
    assertEq(_market.base.balanceOf(address(vault)), baseAmountOut + baseAmountOut2);
    assertEq(_market.quote.balanceOf(address(vault)), quoteAmountOut + quoteAmountOut2);

    assertEq(vault.totalSupply(), shares + shares2 + MangroveVaultConstants.MINIMUM_LIQUIDITY);
  }

  uint16 public constant BURN_PRECISION = 10000;

  uint16[] public fixtureBurnProportion = [BURN_PRECISION];

  function testFuzz_burnShares(uint8 market, uint128 quoteInitial, uint16 burnProportion) public {
    vm.assume(market < markets().length);
    vm.assume(burnProportion > 0 && burnProportion <= BURN_PRECISION);
    (MangroveVault vault, MarketWOracle memory _market,) = deployVault(market);
    vm.assume(quoteInitial >= BURN_PRECISION && quoteInitial < _market.maxQuote);

    (,, uint256 shares) = mintWithSpecifiedQuoteAmount(vault, _market, quoteInitial);

    uint256 sharesToBurn = (shares * burnProportion) / BURN_PRECISION;

    console.log("sharesToBurn", sharesToBurn);
    console.log("shares", shares);

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
  }

  struct PerformanceFeesTestHeap {
    uint256 shares;
    uint256 baseAmountUser;
    uint256 quoteAmountUser;
    uint256 baseAmount;
    uint256 quoteAmount;
    uint256 totalInQuote;
    Tick tick;
    uint256 baseAmountAfter;
    uint256 quoteAmountAfter;
    uint256 totalInQuoteAfter;
    uint256 grossBaseAfter;
    uint256 grossQuoteAfter;
    uint256 totalInQuoteBefore;
    uint256 grossTotalInQuoteAfter;
    uint256 actualTotalInQuote;
  }

  function todo_testFuzz_PerformanceFees(uint8 market, uint128 quote, uint64 baseMultiplier, uint64 quoteMultiplier)
    public
  {
    vm.assume(quote > MangroveVaultConstants.MINIMUM_LIQUIDITY);
    vm.assume(market < markets().length);
    (MangroveVault vault, MarketWOracle memory _market,) = deployVault(market);
    vm.assume(quote < _market.maxQuote);

    PerformanceFeesTestHeap memory heap;

    // Mint
    (,, heap.shares) = mintWithSpecifiedQuoteAmount(vault, _market, quote);
    // Get the actual amount per share (not taking dead shares into account)
    (heap.baseAmountUser, heap.quoteAmountUser) = vault.getUnderlyingBalancesByShare(heap.shares);
    (heap.baseAmount, heap.quoteAmount) = vault.getUnderlyingBalances();
    (heap.totalInQuote, heap.tick) = vault.getTotalInQuote();

    // change the vault balance
    deal(address(_market.base), address(vault), heap.baseAmount.mulDiv(baseMultiplier, 1e18));
    deal(address(_market.quote), address(vault), heap.quoteAmount.mulDiv(quoteMultiplier, 1e18));

    (heap.baseAmountAfter, heap.quoteAmountAfter) = vault.getUnderlyingBalancesByShare(heap.shares);
    (heap.totalInQuoteAfter,) = vault.getTotalInQuote();

    if (heap.totalInQuoteAfter > heap.totalInQuote) {
      heap.totalInQuoteBefore = heap.quoteAmountUser + heap.tick.inboundFromOutboundUp(heap.baseAmountUser);

      heap.grossBaseAfter = heap.baseAmountUser.mulDiv(baseMultiplier, 1e18);
      heap.grossQuoteAfter = heap.quoteAmountUser.mulDiv(quoteMultiplier, 1e18);

      heap.grossTotalInQuoteAfter = heap.grossQuoteAfter + heap.tick.inboundFromOutboundUp(heap.grossBaseAfter);

      // uint256 perfQuote = (heap.grossTotalInQuoteAfter - heap.totalInQuoteBefore).mulDiv(
      //   vault.performanceFee(), MangroveVaultConstants.PERFORMANCE_FEE_PRECISION
      // );

      // heap.actualTotalInQuote = heap.quoteAmountAfter + heap.tick.inboundFromOutboundUp(heap.baseAmountAfter);

      // assertApproxEqRel(
      //   heap.grossTotalInQuoteAfter - perfQuote,
      //   heap.actualTotalInQuote,
      //   0.01e16, // 0.01% precision
      //   "Gross total in quote should be equal to actual total in quote"
      // );

      // uint netBaseAfter = grossBaseAfter.mulDiv(perfUnscaled, MangroveVaultConstants.PERFORMANCE_FEE_PRECISION);
      // uint netQuoteAfter = grossQuoteAfter.mulDiv(perfUnscaled, MangroveVaultConstants.PERFORMANCE_FEE_PRECISION);

      // assertEq(baseAmountAfter, netBaseAfter, "Base amount after should be equal to net base amount");
      // assertEq(quoteAmountAfter, netQuoteAfter, "Quote amount after should be equal to net quote amount");

      // Performance fees on the whole vault
      // uint256 perfFees =
      //   uint256(quoteAfter - quote).mulDiv(vault.performanceFee(), MangroveVaultConstants.PERFORMANCE_FEE_PRECISION);

      // assertApproxEqAbs(
      //   quoteAmountAfter,
      //   (quoteAfter - perfFees).mulDiv(shares, vault.totalSupply()),
      //   1,
      //   "Quote amount after should be equal to quote amount minus fees"
      // );
    } else {
      // No performance fees are taken on counter performance
      // assertEq(
      //   quoteAmountAfter,
      //   uint256(quoteAfter).mulDiv(shares, vault.totalSupply()),
      //   "Quote amount after should be equal to quote amount"
      // );
    }
  }

  function test_auth() public {
    (MangroveVault vault,,) = deployVault(0);

    vm.startPrank(user);

    bytes memory revertMsg = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(user));

    vm.expectRevert(revertMsg);
    vault.allowSwapContract(address(this));

    vm.expectRevert(revertMsg);
    vault.disallowSwapContract(address(this));

    vm.expectRevert(revertMsg);
    vault.swap(address(this), "", 0, 0, false);

    KandelPosition memory position;
    vm.expectRevert(revertMsg);
    vault.setPosition(position);

    vm.expectRevert(revertMsg);
    vault.withdrawFromMangrove(0, payable(user));

    vm.expectRevert(revertMsg);
    vault.withdrawERC20(address(WETH), 0);

    vm.expectRevert(revertMsg);
    vault.withdrawNative();

    vm.expectRevert(revertMsg);
    vault.pause(true);

    // vm.expectRevert(revertMsg);
    // vault.unpause();

    vm.expectRevert(revertMsg);
    vault.setFeeData(0, 0, address(0));

    vm.stopPrank();
  }

  function test_setPosition() public {
    (MangroveVault vault, MarketWOracle memory _market, address kandel) = deployVault(0);

    (uint256 baseAmountOut, uint256 quoteAmountOut,) = mintWithSpecifiedQuoteAmount(vault, _market, 100_000e6); // 100_000 USD equivalent

    vault.fundMangrove{value: 1 ether}();

    KandelPosition memory position;
    position.tickIndex0 = Tick.wrap(Tick.unwrap(vault.currentTick()) - 10);
    position.tickOffset = 3;
    position.fundsState = FundsState.Active;
    position.params = Params({gasprice: 0, gasreq: 0, stepSize: 1, pricePoints: 10});

    vm.prank(owner);
    vm.expectEmit(false, false, false, true, kandel);
    emit GeometricKandel.SetBaseQuoteTickOffset(position.tickOffset);
    vm.expectEmit(false, false, false, true, kandel);
    emit HasIndexedBidsAndAsks.SetLength(position.params.pricePoints);
    vm.expectEmit(false, false, false, true, kandel);
    emit CoreKandel.SetStepSize(position.params.stepSize);
    vm.expectEmit(false, false, false, true, address(vault));
    MangroveVaultEvents.emitSetKandelPosition(position);
    vault.setPosition(position);

    uint256 offeredBase = GeometricKandel(payable(kandel)).offeredVolume(OfferType.Ask);
    uint256 offeredQuote = GeometricKandel(payable(kandel)).offeredVolume(OfferType.Bid);

    // delta is 10 due to the number of price points (floor rounding each offer amount)

    assertApproxEqAbs(offeredBase, baseAmountOut, 10, "Offered base should be equal to baseAmountOut");
    assertApproxEqAbs(offeredQuote, quoteAmountOut, 10, "Offered quote should be equal to quoteAmountOut");

    (uint256 baseAmountOut2, uint256 quoteAmountOut2,) = mintWithSpecifiedQuoteAmount(vault, _market, 100_000e6);

    offeredBase = GeometricKandel(payable(kandel)).offeredVolume(OfferType.Ask);
    offeredQuote = GeometricKandel(payable(kandel)).offeredVolume(OfferType.Bid);

    assertApproxEqAbs(
      offeredBase, baseAmountOut + baseAmountOut2, 10, "Offered base should be equal to baseAmountOut + baseAmountOut2"
    );
    assertApproxEqAbs(
      offeredQuote,
      quoteAmountOut + quoteAmountOut2,
      10,
      "Offered quote should be equal to quoteAmountOut + quoteAmountOut2"
    );

    OLKey memory bids = OLKey(address(_market.quote), address(_market.base), 1);
    OLKey memory asks = OLKey(address(_market.base), address(_market.quote), 1);

    Tick bestBid = mgv.offers(bids, mgv.best(bids)).tick();
    Tick bestAsk = mgv.offers(asks, mgv.best(asks)).tick();
    Tick currentTick = vault.currentTick();

    assertLe(
      -Tick.unwrap(bestBid), Tick.unwrap(currentTick), "Best bid tick should be lower than or equal to current tick"
    );
    assertGe(
      Tick.unwrap(bestAsk), Tick.unwrap(currentTick), "Best ask tick should be greater than or equal to current tick"
    );
  }

  function test_denssityTooLow() public {
    (MangroveVault vault,, address kandel) = deployVault(0);

    Tick tick = Tick.wrap(Tick.unwrap(vault.currentTick()) - 10);

    vm.prank(owner);
    vm.expectCall(kandel, abi.encodeWithSelector(CoreKandel.populateChunk.selector), 0);
    vm.expectCall(kandel, abi.encodeCall(DirectWithBidsAndAsksDistribution.retractOffers, (0, 10)), 1);
    vault.setPosition(
      KandelPosition({
        tickIndex0: tick,
        tickOffset: 3,
        fundsState: FundsState.Active,
        params: Params({gasprice: 0, gasreq: 0, stepSize: 1, pricePoints: 10})
      })
    );
  }

  function test_NoFunds() public {
    (MangroveVault vault, MarketWOracle memory _market, address kandel) = deployVault(0);

    Tick tick = Tick.wrap(Tick.unwrap(vault.currentTick()) - 10);

    // (uint256 baseAmountOut, uint256 quoteAmountOut, uint256 shares) =
    mintWithSpecifiedQuoteAmount(vault, _market, 100_000e6); // 100_000 USD equivalent

    vm.prank(owner);
    vm.expectCall(kandel, abi.encodeWithSelector(CoreKandel.populateChunk.selector), 1);
    vm.expectCall(kandel, abi.encodeCall(DirectWithBidsAndAsksDistribution.retractOffers, (0, 10)), 1);
    vault.setPosition(
      KandelPosition({
        tickIndex0: tick,
        tickOffset: 3,
        fundsState: FundsState.Active,
        params: Params({gasprice: 0, gasreq: 0, stepSize: 1, pricePoints: 10})
      })
    );
  }

  function test_DensityAndFunds() public {
    (MangroveVault vault, MarketWOracle memory _market, address kandel) = deployVault(0);

    Tick tick = Tick.wrap(Tick.unwrap(vault.currentTick()) - 10);

    (uint256 baseAmountOut, uint256 quoteAmountOut,) = mintWithSpecifiedQuoteAmount(vault, _market, 100_000e6); // 100_000 USD equivalent

    vault.fundMangrove{value: 1 ether}();

    KandelPosition memory position;
    position.tickIndex0 = tick;
    position.tickOffset = 3;
    position.fundsState = FundsState.Active;
    position.params = Params({gasprice: 0, gasreq: 0, stepSize: 1, pricePoints: 10});

    vm.prank(owner);
    vm.expectCall(kandel, abi.encodeWithSelector(CoreKandel.populateChunk.selector), 1);
    vm.expectCall(kandel, abi.encodeWithSelector(DirectWithBidsAndAsksDistribution.retractOffers.selector), 0);
    vault.setPosition(position);

    uint256 offeredBase = GeometricKandel(payable(kandel)).offeredVolume(OfferType.Ask);
    uint256 offeredQuote = GeometricKandel(payable(kandel)).offeredVolume(OfferType.Bid);

    assertApproxEqAbs(offeredBase, baseAmountOut, 10, "Offered base should be equal to baseAmountOut");
    assertApproxEqAbs(offeredQuote, quoteAmountOut, 10, "Offered quote should be equal to quoteAmountOut");
  }

  function test_PassivefundState() public {
    (MangroveVault vault, MarketWOracle memory _market, address kandel) = deployVault(0);

    KandelPosition memory position;
    position.tickIndex0 = Tick.wrap(Tick.unwrap(vault.currentTick()) - 10);
    position.tickOffset = 3;
    position.fundsState = FundsState.Passive;
    position.params = Params({gasprice: 0, gasreq: 0, stepSize: 1, pricePoints: 10});

    vm.prank(owner);
    vault.setPosition(position);

    (uint256 baseAmountOut, uint256 quoteAmountOut,) = mintWithSpecifiedQuoteAmount(vault, _market, 100_000e6); // 100_000 USD equivalent

    // total balances
    (uint256 baseBalance, uint256 quoteBalance) = vault.getUnderlyingBalances();
    assertEq(baseBalance, baseAmountOut, "Base balance should be equal to baseAmountOut");
    assertEq(quoteBalance, quoteAmountOut, "Quote balance should be equal to quoteAmountOut");

    // kandel balances
    (baseBalance, quoteBalance) = vault.getKandelBalances();
    assertEq(baseBalance, baseAmountOut, "Base balance should be in kandel");
    assertEq(quoteBalance, quoteAmountOut, "Quote balance should be in kandel");

    // vault balances
    (baseBalance, quoteBalance) = vault.getVaultBalances();
    assertEq(baseBalance, 0, "Base balance should not be in vault");
    assertEq(quoteBalance, 0, "Quote balance should not be in vault");

    baseBalance = GeometricKandel(payable(kandel)).offeredVolume(OfferType.Ask);
    quoteBalance = GeometricKandel(payable(kandel)).offeredVolume(OfferType.Bid);
    assertEq(baseBalance, 0, "No offers should be made");
    assertEq(quoteBalance, 0, "No offers should be made");
  }

  function test_BurningInActive() public {
    (MangroveVault vault, MarketWOracle memory _market, address kandel) = deployVault(0);

    KandelPosition memory position;
    position.tickIndex0 = Tick.wrap(Tick.unwrap(vault.currentTick()) - 10);
    position.tickOffset = 3;
    position.fundsState = FundsState.Active;
    position.params = Params({gasprice: 0, gasreq: 0, stepSize: 1, pricePoints: 10});

    vault.fundMangrove{value: 1 ether}();

    vm.prank(owner);
    vault.setPosition(position);

    (uint256 baseAmountOut, uint256 quoteAmountOut, uint256 shares) =
      mintWithSpecifiedQuoteAmount(vault, _market, 100_000e6 * 2); // 100_000 USD equivalent

    // total balances
    (uint256 baseBalance, uint256 quoteBalance) = vault.getUnderlyingBalances();
    assertEq(baseBalance, baseAmountOut, "Base balance should be equal to baseAmountOut");
    assertEq(quoteBalance, quoteAmountOut, "Quote balance should be equal to quoteAmountOut");

    // kandel balances
    (baseBalance, quoteBalance) = vault.getKandelBalances();
    assertEq(baseBalance, baseAmountOut, "Base balance should be in kandel");
    assertEq(quoteBalance, quoteAmountOut, "Quote balance should be in kandel");

    // vault balances
    (baseBalance, quoteBalance) = vault.getVaultBalances();
    assertEq(baseBalance, 0, "Base balance should not be in vault");
    assertEq(quoteBalance, 0, "Quote balance should not be in vault");

    baseBalance = GeometricKandel(payable(kandel)).offeredVolume(OfferType.Ask);
    quoteBalance = GeometricKandel(payable(kandel)).offeredVolume(OfferType.Bid);
    assertApproxEqAbs(baseBalance, baseAmountOut, 10, "Offered base should be equal to baseAmountOut");
    assertApproxEqAbs(quoteBalance, quoteAmountOut, 10, "Offered quote should be equal to quoteAmountOut");

    // Expected call for the 2 next burns
    vm.expectCall(kandel, abi.encodeWithSelector(CoreKandel.populateChunk.selector), 1);
    vm.expectCall(kandel, abi.encodeCall(DirectWithBidsAndAsksDistribution.retractOffers, (0, 10)), 1);

    // burn half of the shares to keep the active position
    uint256 sharesToBurn = shares / 2;
    vm.prank(user);
    // will successfully populate (once)
    (uint256 baseAmountReceived, uint256 quoteAmountReceived) = vault.burn(sharesToBurn, 0, 0);

    // total balances
    (baseBalance, quoteBalance) = vault.getUnderlyingBalances();
    assertEq(
      baseBalance,
      baseAmountOut - baseAmountReceived,
      "Base balance should be equal to baseAmountOut - baseAmountReceived"
    );
    assertEq(
      quoteBalance,
      quoteAmountOut - quoteAmountReceived,
      "Quote balance should be equal to quoteAmountOut - quoteAmountReceived"
    );

    // kandel balances
    (baseBalance, quoteBalance) = vault.getKandelBalances();
    assertEq(
      baseBalance,
      baseAmountOut - baseAmountReceived,
      "Base balance should be equal to baseAmountOut - baseAmountReceived"
    );
    assertEq(
      quoteBalance,
      quoteAmountOut - quoteAmountReceived,
      "Quote balance should be equal to quoteAmountOut - quoteAmountReceived"
    );

    // vault balances
    (baseBalance, quoteBalance) = vault.getVaultBalances();
    assertEq(baseBalance, 0, "Base balance should not be in vault");
    assertEq(quoteBalance, 0, "Quote balance should not be in vault");

    baseBalance = GeometricKandel(payable(kandel)).offeredVolume(OfferType.Ask);
    quoteBalance = GeometricKandel(payable(kandel)).offeredVolume(OfferType.Bid);
    assertApproxEqAbs(
      baseBalance,
      baseAmountOut - baseAmountReceived,
      10,
      "Offered base should be equal to baseAmountOut - baseAmountReceived"
    );
    assertApproxEqAbs(
      quoteBalance,
      quoteAmountOut - quoteAmountReceived,
      10,
      "Offered quote should be equal to quoteAmountOut - quoteAmountReceived"
    );

    // burn 99.9% of the remaining shares to be below density
    sharesToBurn = vault.balanceOf(user).mulDiv(999, 1000);
    vm.prank(user);
    // will not try to populate and retract offers (once)
    (uint256 baseAmountReceived2, uint256 quoteAmountReceived2) = vault.burn(sharesToBurn, 0, 0);

    // total balances
    (baseBalance, quoteBalance) = vault.getUnderlyingBalances();
    assertEq(
      baseBalance,
      baseAmountOut - baseAmountReceived - baseAmountReceived2,
      "Base balance should be equal to baseAmountOut - baseAmountReceived - baseAmountReceived2"
    );
    assertEq(
      quoteBalance,
      quoteAmountOut - quoteAmountReceived - quoteAmountReceived2,
      "Quote balance should be equal to quoteAmountOut - quoteAmountReceived - quoteAmountReceived2"
    );

    // kandel balances
    (baseBalance, quoteBalance) = vault.getKandelBalances();
    assertEq(
      baseBalance,
      baseAmountOut - baseAmountReceived - baseAmountReceived2,
      "Base balance should be equal to baseAmountOut - baseAmountReceived - baseAmountReceived2"
    );
    assertEq(
      quoteBalance,
      quoteAmountOut - quoteAmountReceived - quoteAmountReceived2,
      "Quote balance should be equal to quoteAmountOut - quoteAmountReceived - quoteAmountReceived2"
    );

    // vault balances
    (baseBalance, quoteBalance) = vault.getVaultBalances();
    assertEq(baseBalance, 0, "Base balance should not be in vault");
    assertEq(quoteBalance, 0, "Quote balance should not be in vault");

    baseBalance = GeometricKandel(payable(kandel)).offeredVolume(OfferType.Ask);
    quoteBalance = GeometricKandel(payable(kandel)).offeredVolume(OfferType.Bid);
    assertEq(baseBalance, 0, "No offers should be made");
    assertEq(quoteBalance, 0, "No offers should be made");
  }

  function test_BurningInPassive() public {
    (MangroveVault vault, MarketWOracle memory _market, address kandel) = deployVault(0);

    KandelPosition memory position;
    position.tickIndex0 = Tick.wrap(Tick.unwrap(vault.currentTick()) - 10);
    position.tickOffset = 3;
    position.fundsState = FundsState.Passive;
    position.params = Params({gasprice: 0, gasreq: 0, stepSize: 1, pricePoints: 10});

    vm.prank(owner);
    vault.setPosition(position);

    (uint256 baseAmountOut, uint256 quoteAmountOut, uint256 shares) =
      mintWithSpecifiedQuoteAmount(vault, _market, 100_000e6); // 100_000 USD equivalent

    // total balances
    (uint256 baseBalance, uint256 quoteBalance) = vault.getUnderlyingBalances();
    assertEq(baseBalance, baseAmountOut, "Base balance should be equal to baseAmountOut");
    assertEq(quoteBalance, quoteAmountOut, "Quote balance should be equal to quoteAmountOut");

    // kandel balances
    (baseBalance, quoteBalance) = vault.getKandelBalances();
    assertEq(baseBalance, baseAmountOut, "Base balance should be in kandel");
    assertEq(quoteBalance, quoteAmountOut, "Quote balance should be in kandel");

    // vault balances
    (baseBalance, quoteBalance) = vault.getVaultBalances();
    assertEq(baseBalance, 0, "Base balance should not be in vault");
    assertEq(quoteBalance, 0, "Quote balance should not be in vault");

    baseBalance = GeometricKandel(payable(kandel)).offeredVolume(OfferType.Ask);
    quoteBalance = GeometricKandel(payable(kandel)).offeredVolume(OfferType.Bid);
    assertEq(baseBalance, 0, "No offers should be made");
    assertEq(quoteBalance, 0, "No offers should be made");

    // burn half of the shares
    vm.prank(user);
    (uint256 baseAmountReceived, uint256 quoteAmountReceived) = vault.burn(shares / 2, 0, 0);

    // total balances
    (baseBalance, quoteBalance) = vault.getUnderlyingBalances();
    assertEq(
      baseBalance,
      baseAmountOut - baseAmountReceived,
      "Base balance should be equal to baseAmountOut - baseAmountReceived"
    );
    assertEq(
      quoteBalance,
      quoteAmountOut - quoteAmountReceived,
      "Quote balance should be equal to quoteAmountOut - quoteAmountReceived"
    );

    // kandel balances
    (baseBalance, quoteBalance) = vault.getKandelBalances();
    assertEq(
      baseBalance,
      baseAmountOut - baseAmountReceived,
      "Base balance should be equal to baseAmountOut - baseAmountReceived"
    );
    assertEq(
      quoteBalance,
      quoteAmountOut - quoteAmountReceived,
      "Quote balance should be equal to quoteAmountOut - quoteAmountReceived"
    );

    // vault balances
    (baseBalance, quoteBalance) = vault.getVaultBalances();
    assertEq(baseBalance, 0, "Base balance should not be in vault");
    assertEq(quoteBalance, 0, "Quote balance should not be in vault");

    baseBalance = GeometricKandel(payable(kandel)).offeredVolume(OfferType.Ask);
    quoteBalance = GeometricKandel(payable(kandel)).offeredVolume(OfferType.Bid);
    assertEq(baseBalance, 0, "No offers should be made");
    assertEq(quoteBalance, 0, "No offers should be made");
  }

  function swapMock(ERC20 inbound, ERC20 outbound, uint256 inboundAmount, uint256 outboundAmount) public {
    inbound.transferFrom(msg.sender, address(this), inboundAmount);
    deal(address(outbound), address(this), outboundAmount);
    outbound.transfer(msg.sender, outboundAmount);
  }

  function test_swap() public {
    deal(address(WETH), user, 1 ether);
    vm.startPrank(user);
    WETH.approve(address(this), 1 ether);
    MangroveVaultTest(address(this)).swapMock(WETH, USDC, 1 ether, 3000e6);
    vm.stopPrank();

    assertEq(WETH.balanceOf(user), 0, "WETH balance should be 0");
    assertEq(USDC.balanceOf(user), 3000e6, "USDC balance should be 3000e6");
  }

  function test_setUnauthorizedSwapContract() public {
    (MangroveVault vault, MarketWOracle memory _market, address kandel) = deployVault(0);

    KandelPosition memory position;
    position.tickIndex0 = Tick.wrap(Tick.unwrap(vault.currentTick()) - 10);
    position.tickOffset = 3;
    position.fundsState = FundsState.Active;
    position.params = Params({gasprice: 0, gasreq: 0, stepSize: 1, pricePoints: 10});

    vault.fundMangrove{value: 1 ether}();

    vm.prank(owner);
    vault.setPosition(position);

    mintWithSpecifiedQuoteAmount(vault, _market, 100_000e6); // 100_000 USD equivalent

    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(MangroveVaultErrors.UnauthorizedSwapContract.selector, kandel));
    vault.allowSwapContract(kandel);

    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(MangroveVaultErrors.UnauthorizedSwapContract.selector, address(0)));
    vault.allowSwapContract(address(0));

    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(MangroveVaultErrors.UnauthorizedSwapContract.selector, address(vault)));
    vault.allowSwapContract(address(vault));
  }

  function test_unauthorizedSwapContract() public {
    (MangroveVault vault,,) = deployVault(0);

    vm.prank(owner);
    vault.allowSwapContract(address(this));

    vm.prank(owner);
    vault.swap(address(this), abi.encodeCall(this.swapMock, (WETH, USDC, 0, 0)), 0, 0, true); // sell 1 WETH for USDC

    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(MangroveVaultErrors.UnauthorizedSwapContract.selector, user));
    vault.swap(address(user), abi.encodeCall(this.swapMock, (WETH, USDC, 0, 0)), 0, 0, true); // sell 1 WETH for USDC

    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(MangroveVaultErrors.UnauthorizedSwapContract.selector, address(1)));
    vault.swap(address(1), abi.encodeCall(this.swapMock, (WETH, USDC, 0, 0)), 0, 0, true); // sell 1 WETH for USDC
  }

  function test_swapIncorrectSlippage() public {
    (MangroveVault vault, MarketWOracle memory _market,) = deployVault(0);

    KandelPosition memory position;
    position.tickIndex0 = Tick.wrap(Tick.unwrap(vault.currentTick()) - 10);
    position.tickOffset = 3;
    position.fundsState = FundsState.Active;
    position.params = Params({gasprice: 0, gasreq: 0, stepSize: 1, pricePoints: 10});

    vault.fundMangrove{value: 1 ether}();

    vm.prank(owner);
    vault.setPosition(position);

    mintWithSpecifiedQuoteAmount(vault, _market, 100_000e6); // 100_000 USD equivalent

    vm.prank(owner);
    vault.allowSwapContract(address(this));

    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(MangroveVaultErrors.SlippageExceeded.selector, 3001e6, 3000e6));
    vault.swap(address(this), abi.encodeCall(this.swapMock, (WETH, USDC, 1 ether, 3000e6)), 1 ether, 3001e6, true); // sell 1 WETH for USDC
  }

  function test_swapInActive() public {
    (MangroveVault vault, MarketWOracle memory _market,) = deployVault(0);

    KandelPosition memory position;
    position.tickIndex0 = Tick.wrap(Tick.unwrap(vault.currentTick()) - 10);
    position.tickOffset = 3;
    position.fundsState = FundsState.Active;
    position.params = Params({gasprice: 0, gasreq: 0, stepSize: 1, pricePoints: 10});

    vault.fundMangrove{value: 1 ether}();

    vm.prank(owner);
    vault.setPosition(position);

    mintWithSpecifiedQuoteAmount(vault, _market, 100_000e6); // 100_000 USD equivalent

    (uint256 baseAmountStart, uint256 quoteAmountStart) = vault.getUnderlyingBalances();

    vm.prank(owner);
    vault.allowSwapContract(address(this));

    vm.prank(owner);
    vm.expectEmit(false, false, false, true, address(vault));
    emit MangroveVaultEvents.Swap(address(this), -1 ether, 3000e6, true);
    vault.swap(address(this), abi.encodeCall(this.swapMock, (WETH, USDC, 1 ether, 3000e6)), 1 ether, 0, true); // sell 1 WETH for USDC

    (uint256 baseAmountEnd, uint256 quoteAmountEnd) = vault.getUnderlyingBalances();
    assertEq(baseAmountEnd, baseAmountStart - 1 ether, "Base balance should be equal to baseAmountStart - 1 ether");
    assertEq(quoteAmountEnd, quoteAmountStart + 3000e6, "Quote balance should be equal to quoteAmountStart + 3000e6");
  }

  function test_swapInPassive() public {
    (MangroveVault vault, MarketWOracle memory _market,) = deployVault(0);

    KandelPosition memory position;
    position.tickIndex0 = Tick.wrap(Tick.unwrap(vault.currentTick()) - 10);
    position.tickOffset = 3;
    position.fundsState = FundsState.Passive;
    position.params = Params({gasprice: 0, gasreq: 0, stepSize: 1, pricePoints: 10});

    vault.fundMangrove{value: 1 ether}();

    vm.prank(owner);
    vault.setPosition(position);

    mintWithSpecifiedQuoteAmount(vault, _market, 100_000e6); // 100_000 USD equivalent

    (uint256 baseAmountStart, uint256 quoteAmountStart) = vault.getUnderlyingBalances();

    vm.prank(owner);
    vault.allowSwapContract(address(this));

    vm.prank(owner);
    vm.expectEmit(false, false, false, true, address(vault));
    emit MangroveVaultEvents.Swap(address(this), -1 ether, 3000e6, true);
    vault.swap(address(this), abi.encodeCall(this.swapMock, (WETH, USDC, 1 ether, 3000e6)), 1 ether, 0, true); // sell 1 WETH for USDC

    (uint256 baseAmountEnd, uint256 quoteAmountEnd) = vault.getUnderlyingBalances();
    assertEq(baseAmountEnd, baseAmountStart - 1 ether, "Base balance should be equal to baseAmountStart - 1 ether");
    assertEq(quoteAmountEnd, quoteAmountStart + 3000e6, "Quote balance should be equal to quoteAmountStart + 3000e6");
  }

  function test_swapInVaults() public {
    (MangroveVault vault, MarketWOracle memory _market,) = deployVault(0);

    KandelPosition memory position;
    position.tickIndex0 = Tick.wrap(Tick.unwrap(vault.currentTick()) - 10);
    position.tickOffset = 3;
    position.fundsState = FundsState.Vault;
    position.params = Params({gasprice: 0, gasreq: 0, stepSize: 1, pricePoints: 10});

    vault.fundMangrove{value: 1 ether}();

    vm.prank(owner);
    vault.setPosition(position);

    mintWithSpecifiedQuoteAmount(vault, _market, 100_000e6); // 100_000 USD equivalent

    (uint256 baseAmountStart, uint256 quoteAmountStart) = vault.getUnderlyingBalances();

    vm.prank(owner);
    vault.allowSwapContract(address(this));

    vm.prank(owner);
    vm.expectEmit(false, false, false, true, address(vault));
    emit MangroveVaultEvents.Swap(address(this), -1 ether, 3000e6, true);
    vault.swap(address(this), abi.encodeCall(this.swapMock, (WETH, USDC, 1 ether, 3000e6)), 1 ether, 0, true); // sell 1 WETH for USDC

    (uint256 baseAmountEnd, uint256 quoteAmountEnd) = vault.getUnderlyingBalances();
    assertEq(baseAmountEnd, baseAmountStart - 1 ether, "Base balance should be equal to baseAmountStart - 1 ether");
    assertEq(quoteAmountEnd, quoteAmountStart + 3000e6, "Quote balance should be equal to quoteAmountStart + 3000e6");
  }

  // TODO: test aave
  function test_aave() public {
    (MangroveVault vault, MarketWOracle memory _market,) = deployVault(0, aaveKandelSeeder);

    KandelPosition memory position;
    position.tickIndex0 = Tick.wrap(Tick.unwrap(vault.currentTick()) - 10);
    position.tickOffset = 3;
    position.fundsState = FundsState.Active;
    position.params = Params({gasprice: 0, gasreq: 0, stepSize: 1, pricePoints: 10});

    vault.fundMangrove{value: 1 ether}();

    vm.prank(owner);
    vault.setPosition(position);

    // (uint256 baseAmountOut, uint256 quoteAmountOut, uint256 shares) =
    mintWithSpecifiedQuoteAmount(vault, _market, 100_000e6); // 100_000 USD equivalent
  }

  function test_deployKandel() public {
    // MangroveVault vault = new MangroveVault(
    //   kandelSeeder, address(WETH), address(USDC), 1, 12, "Mangrove Vault", "MGVv", address(ETH_USDC_ORACLE)
    // );

    // (uint256 baseAmountOut, uint256 quoteAmountOut, uint256 shares) = vault.getMintAmounts(1 ether, 3000e6);
    // deal(address(WETH), address(this), baseAmountOut);
    // deal(address(USDC), address(this), quoteAmountOut);
    // WETH.approve(address(vault), baseAmountOut);
    // USDC.approve(address(vault), quoteAmountOut);
    // vault.mint(shares, baseAmountOut, quoteAmountOut);

    // deal(address(WETH), address(this), 1 ether);
    // deal(address(WETH), address(this), 1 ether);
    // revert();
  }
}
