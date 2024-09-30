// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {MangroveVault, Tick} from "../src/MangroveVault.sol";
import {IMangrove, OLKey, Local} from "@mgv/src/IMangrove.sol";
import {Mangrove} from "@mgv/src/core/Mangrove.sol";
import {MgvReader, Market} from "@mgv/src/periphery/MgvReader.sol";
import {MgvOracle} from "@mgv/src/periphery/MgvOracle.sol";
import {MangroveChainlinkOracle, AggregatorV3Interface} from "../src/oracles/chainlink/MangroveChainlinkOracle.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {KandelSeeder} from "@mgv-strats/src/strategies/offer_maker/market_making/kandel/KandelSeeder.sol";
import {MAX_SAFE_VOLUME} from "@mgv/lib/core/Constants.sol";
import {MangroveVaultConstants} from "../src/lib/MangroveVaultConstants.sol";

contract MangroveVaultTest is Test {
  IMangrove public mgv;
  MgvReader public reader;
  MgvOracle public oracle;

  IMangrove public realMangrove = IMangrove(payable(0x109d9CDFA4aC534354873EF634EF63C235F93f61));
  MgvReader public realReader = MgvReader(0x7E108d7C9CADb03E026075Bf242aC2353d0D1875);

  ERC20 public WETH = ERC20(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
  ERC20 public USDC = ERC20(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
  ERC20 public USDT = ERC20(0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9);
  ERC20 public WeETH = ERC20(0x35751007a407ca6FEFfE80b3cB397736D2cf4dbe);

  AggregatorV3Interface public ETH_USD = AggregatorV3Interface(0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612);
  AggregatorV3Interface public USDC_USD = AggregatorV3Interface(0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3);
  AggregatorV3Interface public USDT_USD = AggregatorV3Interface(0x3f3f5dF88dC9F13eac63DF89EC16ef6e7E25DdE7);
  AggregatorV3Interface public WEETH_ETH = AggregatorV3Interface(0xE141425bc1594b8039De6390db1cDaf4397EA22b);

  MangroveChainlinkOracle public ETH_USDC_ORACLE;
  MangroveChainlinkOracle public USDC_USDT_ORACLE;
  MangroveChainlinkOracle public ETH_USDT_ORACLE;
  MangroveChainlinkOracle public WEETH_ETH_ORACLE;

  KandelSeeder public kandelSeeder;

  uint256 public constant USD_DECIMALS = 18;

  uint256 arbitrumFork;

  function deployMangrove() internal {
    oracle = new MgvOracle({governance_: address(this), initialMutator_: address(this), initialGasPrice_: 1});
    mgv = IMangrove(payable(address(new Mangrove({governance: address(this), gasprice: 1, gasmax: 2_000_000}))));
    reader = new MgvReader({mgv: address(mgv)});
  }

  function copyMangrove() internal {
    (Market[] memory markets,) = realReader.openMarkets();
    for (uint256 i = 0; i < markets.length; i++) {
      OLKey memory olKey =
        OLKey({outbound_tkn: markets[i].tkn0, inbound_tkn: markets[i].tkn1, tickSpacing: markets[i].tickSpacing});
      copySemibook(olKey);
      copySemibook(olKey.flipped());
      reader.updateMarket(markets[i]);
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

  uint8[] public fixtureMarket = [0, 1, 2, 3];

  function testFuzz_initialMintAmountMatch(uint8 market, uint128 quote) public {
    vm.assume(quote > MangroveVaultConstants.MINIMUM_LIQUIDITY);
    vm.assume(market < markets().length);
    MarketWOracle memory _market = markets()[market];
    vm.assume(quote < _market.maxQuote);

    MangroveVault vault = new MangroveVault(
      kandelSeeder,
      address(_market.base),
      address(_market.quote),
      1,
      18 - _market.quote.decimals(),
      "Mangrove Vault",
      "MGVv",
      address(_market.oracle)
    );

    (uint256 baseAmountOut, uint256 quoteAmountOut, uint256 shares) = vault.getMintAmounts(type(uint256).max, quote);
    vm.assertTrue(quoteAmountOut == quote, "base or quote amount doesn't match");
    deal(address(_market.base), address(this), baseAmountOut);
    deal(address(_market.quote), address(this), quoteAmountOut);
    _market.base.approve(address(vault), baseAmountOut);
    _market.quote.approve(address(vault), quoteAmountOut);
    vault.mint(shares, baseAmountOut, quoteAmountOut);
    assertEq(vault.balanceOf(address(this)), shares);

    assertEq(_market.base.balanceOf(address(this)), 0);
    assertEq(_market.quote.balanceOf(address(this)), 0);

    assertEq(_market.base.balanceOf(address(vault)), baseAmountOut);
    assertEq(_market.quote.balanceOf(address(vault)), quoteAmountOut);

    assertEq(vault.totalSupply(), shares + MangroveVaultConstants.MINIMUM_LIQUIDITY);
    assertEq(vault.balanceOf(address(vault)), MangroveVaultConstants.MINIMUM_LIQUIDITY);
  }

  function testFuzz_initialAndSecondMint(uint8 market, uint128 quoteInitial, uint128 quoteSecond) public {
    vm.assume(quoteInitial > MangroveVaultConstants.MINIMUM_LIQUIDITY);
    vm.assume(quoteSecond > MangroveVaultConstants.MINIMUM_LIQUIDITY);
    vm.assume(market < markets().length);
    MarketWOracle memory _market = markets()[market];
    vm.assume(quoteInitial < _market.maxQuote);
    vm.assume(quoteSecond < _market.maxQuote);

    MangroveVault vault = new MangroveVault(
      kandelSeeder,
      address(_market.base),
      address(_market.quote),
      1,
      18 - _market.quote.decimals(),
      "Mangrove Vault",
      "MGVv",
      address(_market.oracle)
    );

    (uint256 baseAmountOut, uint256 quoteAmountOut, uint256 shares) =
      vault.getMintAmounts(type(uint256).max, quoteInitial);

    deal(address(_market.base), address(this), baseAmountOut);
    deal(address(_market.quote), address(this), quoteAmountOut);

    _market.base.approve(address(vault), baseAmountOut);
    _market.quote.approve(address(vault), quoteAmountOut);

    vault.mint(shares, baseAmountOut, quoteAmountOut);

    assertEq(_market.base.balanceOf(address(vault)), baseAmountOut);
    assertEq(_market.quote.balanceOf(address(vault)), quoteAmountOut);

    assertEq(vault.balanceOf(address(this)), shares);
    assertEq(_market.base.balanceOf(address(this)), 0);
    assertEq(_market.quote.balanceOf(address(this)), 0);

    // Mint a second time
    (uint256 baseAmountOut2, uint256 quoteAmountOut2, uint256 shares2) =
      vault.getMintAmounts(type(uint256).max, quoteSecond);

    deal(address(_market.base), address(this), baseAmountOut2);
    deal(address(_market.quote), address(this), quoteAmountOut2);

    _market.base.approve(address(vault), baseAmountOut2);
    _market.quote.approve(address(vault), quoteAmountOut2);

    vault.mint(shares2, baseAmountOut2, quoteAmountOut2);

    // Assert the new balances and shares
    assertEq(_market.base.balanceOf(address(vault)), baseAmountOut + baseAmountOut2);
    assertEq(_market.quote.balanceOf(address(vault)), quoteAmountOut + quoteAmountOut2);

    assertEq(vault.balanceOf(address(this)), shares + shares2);
    assertEq(_market.base.balanceOf(address(this)), 0);
    assertEq(_market.quote.balanceOf(address(this)), 0);

    assertEq(vault.totalSupply(), shares + shares2 + MangroveVaultConstants.MINIMUM_LIQUIDITY);
  }

  uint16 public constant BURN_PRECISION = 10000;

  uint16[] public fixtureBurnProportion = [BURN_PRECISION];

  function testFuzz_burnShares(uint8 market, uint128 quoteInitial, uint16 burnProportion) public {
    vm.assume(market < markets().length);

    MarketWOracle memory _market = markets()[market];
    vm.assume(quoteInitial >= MangroveVaultConstants.MINIMUM_LIQUIDITY && quoteInitial < _market.maxQuote);
    vm.assume(burnProportion > 0 && burnProportion <= BURN_PRECISION);

    _market.oracle.tick().outboundFromInbound(quoteInitial);

    MangroveVault vault = new MangroveVault(
      kandelSeeder,
      address(_market.base),
      address(_market.quote),
      1,
      18 - _market.quote.decimals(),
      "Mangrove Vault",
      "MGVv",
      address(_market.oracle)
    );

    (uint256 baseAmountOut, uint256 quoteAmountOut, uint256 shares) =
      vault.getMintAmounts(type(uint256).max, quoteInitial);

    deal(address(_market.base), address(this), baseAmountOut);
    deal(address(_market.quote), address(this), quoteAmountOut);

    _market.base.approve(address(vault), baseAmountOut);
    _market.quote.approve(address(vault), quoteAmountOut);

    vault.mint(shares, baseAmountOut, quoteAmountOut);

    uint256 sharesToBurn = (shares * burnProportion) / BURN_PRECISION;
    assertGt(sharesToBurn, 0, "Shares to burn should be greater than 0");

    (uint256 expectedBaseOut, uint256 expectedQuoteOut) = vault.getUnderlyingBalancesByShare(sharesToBurn);

    (uint256 actualBaseOut, uint256 actualQuoteOut) = vault.burn(sharesToBurn, 0, 0);

    assertApproxEqRel(actualBaseOut, expectedBaseOut, 1e16, "Base amount out should be close to expected");
    assertApproxEqRel(actualQuoteOut, expectedQuoteOut, 1e16, "Quote amount out should be close to expected");

    assertEq(vault.balanceOf(address(this)), shares - sharesToBurn, "Remaining shares should be correct");
    assertApproxEqRel(
      _market.base.balanceOf(address(this)), actualBaseOut, 1e16, "Base balance should be close to amount out"
    );
    assertApproxEqRel(
      _market.quote.balanceOf(address(this)), actualQuoteOut, 1e16, "Quote balance should be close to amount out"
    );
  }

  function test_deployKandel() public {
    MangroveVault vault = new MangroveVault(
      kandelSeeder, address(WETH), address(USDC), 1, 12, "Mangrove Vault", "MGVv", address(ETH_USDC_ORACLE)
    );

    (uint256 baseAmountOut, uint256 quoteAmountOut, uint256 shares) = vault.getMintAmounts(1 ether, 3000e6);
    deal(address(WETH), address(this), baseAmountOut);
    deal(address(USDC), address(this), quoteAmountOut);
    WETH.approve(address(vault), baseAmountOut);
    USDC.approve(address(vault), quoteAmountOut);
    vault.mint(shares, baseAmountOut, quoteAmountOut);
    console.log(vault.balanceOf(address(this)));
  }
}
