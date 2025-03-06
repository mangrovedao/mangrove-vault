// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {MangroveDiaOracle, DiaFeed, ERC4626Feed} from "../src/oracles/dia/MangroveDiaOracle.sol";
import {MangroveDiaOracleFactory} from "../src/oracles/dia/MangroveDiaOracleFactory.sol";
import {DiaOracleV2} from "../src/vendor/dia/DiaOracleV2.sol";
import {DiaOracleV2Consumer} from "../src/vendor/dia/DiaOracleV2Consumer.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Tick} from "@mgv/lib/core/TickLib.sol";
import {ERC4626Consumer} from "../src/vendor/ERC4626/ERC4626Consumer.sol";

// Mock DiaOracleV2 contract that returns configurable values
contract MockDiaOracleV2 is DiaOracleV2 {
  mapping(string => uint256) public prices;
  mapping(string => uint256) public timestamps;

  function setPrice(bytes32 key, uint256 price, uint256 timestamp) external {
    string memory keyString = string(abi.encodePacked(key));
    prices[keyString] = price;
    timestamps[keyString] = timestamp;
  }

  function getValue(string memory key) external view override returns (uint128, uint128) {
    return (uint128(prices[key]), uint128(timestamps[key]));
  }
}

// Mock ERC20 contract for testing
contract MockERC20 is ERC20 {
  constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }
}

// Mock ERC4626 contract for testing
contract MockERC4626 is ERC4626 {
  constructor(string memory name, string memory symbol, IERC20 asset) ERC20(name, symbol) ERC4626(asset) {}

  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }
}

contract DiaOracleTest is Test {
  // Constants
  bytes32 constant SUPER_OETH_USD_KEY = bytes32("SUPEROETHB/USD");
  bytes32 constant ETH_USD_KEY = bytes32("ETH/USD");
  uint256 constant PRICE_DECIMALS = 8;

  // Contracts
  MockDiaOracleV2 mockDiaOracle;
  MangroveDiaOracleFactory factory;

  // Tokens and vaults
  MockERC20 baseToken;
  MockERC20 quoteToken;
  MockERC4626 baseVault;
  MockERC4626 quoteVault;

  function setUp() public {
    mockDiaOracle = new MockDiaOracleV2();
    factory = new MangroveDiaOracleFactory();

    // Setup tokens
    baseToken = new MockERC20("Base Token", "BASE");
    quoteToken = new MockERC20("Quote Token", "QUOTE");

    // Setup vaults
    baseVault = new MockERC4626("Base Vault", "bBASE", baseToken);
    quoteVault = new MockERC4626("Quote Vault", "bQUOTE", quoteToken);

    // Initial price setup
    mockDiaOracle.setPrice(SUPER_OETH_USD_KEY, 3012 * 10 ** PRICE_DECIMALS, block.timestamp);
    mockDiaOracle.setPrice(ETH_USD_KEY, 3000 * 10 ** PRICE_DECIMALS, block.timestamp);
  }

  function test_emptyDiaOracle() public {
    // Create feeds with empty keys
    DiaFeed memory emptyFeed =
      DiaFeed({oracle: address(0), key: bytes32(0), priceDecimals: PRICE_DECIMALS, baseDecimals: 18, quoteDecimals: 18});

    // Empty vault feed
    ERC4626Feed memory emptyVaultFeed = ERC4626Feed({vault: address(0), conversionSample: 0});

    // Create oracle with empty feeds
    MangroveDiaOracle oracle = new MangroveDiaOracle(
      emptyFeed, emptyFeed, emptyFeed, emptyFeed, emptyVaultFeed, emptyVaultFeed
    );

    // Should return tick 0 since all feeds are empty
    assertEq(Tick.unwrap(oracle.tick()), 0, "Empty oracle should return tick 0");
  }

  function test_diaOracleWithSingleFeed() public {
    // Create active feed for first base feed only
    DiaFeed memory activeFeed =
      DiaFeed({oracle: address(mockDiaOracle), key: SUPER_OETH_USD_KEY, priceDecimals: PRICE_DECIMALS, baseDecimals: 18, quoteDecimals: 18});

    DiaFeed memory emptyFeed =
      DiaFeed({oracle: address(0), key: bytes32(0), priceDecimals: PRICE_DECIMALS, baseDecimals: 18, quoteDecimals: 18});

    // Empty vault feed
    ERC4626Feed memory emptyVaultFeed = ERC4626Feed({vault: address(0), conversionSample: 0});

    // Create oracle with single active feed
    MangroveDiaOracle oracle = new MangroveDiaOracle(
      activeFeed, emptyFeed, emptyFeed, emptyFeed, emptyVaultFeed, emptyVaultFeed
    );

    // Expected tick: log_1.0001(3012) ≈ 80107 (approximate)
    int256 tick = Tick.unwrap(oracle.tick());
    assertApproxEqAbs(tick, 80107, 100, "Tick should be approximately 80107");
  }

  function test_diaOracleWithCombinedFeeds() public {
    // Create feeds for base and quote
    DiaFeed memory baseFeed =
      DiaFeed({oracle: address(mockDiaOracle), key: SUPER_OETH_USD_KEY, priceDecimals: PRICE_DECIMALS, baseDecimals: 18, quoteDecimals: 18});

    DiaFeed memory quoteFeed =
      DiaFeed({oracle: address(mockDiaOracle), key: ETH_USD_KEY, priceDecimals: PRICE_DECIMALS, baseDecimals: 18, quoteDecimals: 18});

    DiaFeed memory emptyFeed =
      DiaFeed({oracle: address(0), key: bytes32(0), priceDecimals: PRICE_DECIMALS, baseDecimals: 18, quoteDecimals: 18});

    // Empty vault feed
    ERC4626Feed memory emptyVaultFeed = ERC4626Feed({vault: address(0), conversionSample: 0});

    // Create oracle with SUPEROETHB/USD as base and ETH/USD as quote
    // This should give us SUPEROETHB/ETH price which is approximately 3012/3000 = 1.004
    MangroveDiaOracle oracle = new MangroveDiaOracle(
      baseFeed, emptyFeed, quoteFeed, emptyFeed, emptyVaultFeed, emptyVaultFeed
    );

    // Expected tick: log_1.0001(3012/3000) = log_1.0001(1.004) ≈ 40 (approximate)
    int256 tick = Tick.unwrap(oracle.tick());
    assertApproxEqAbs(tick, 40, 1, "Tick should be approximately 40");
  }

  function test_diaOracleWithERC4626() public {
    // Setup tokens and vaults with specific exchange rates
    baseToken.mint(address(baseVault), 2 ether);
    quoteToken.mint(address(quoteVault), 1 ether);
    baseVault.mint(address(this), 1 ether);
    quoteVault.mint(address(this), 1 ether);

    // Create feeds
    DiaFeed memory emptyFeed =
      DiaFeed({oracle: address(0), key: bytes32(0), priceDecimals: PRICE_DECIMALS, baseDecimals: 18, quoteDecimals: 18});

    // Set up vault feeds - baseVault has 2:1 ratio, quoteVault has 1:1 ratio
    ERC4626Feed memory baseVaultFeed = ERC4626Feed({vault: address(baseVault), conversionSample: 1 ether});

    ERC4626Feed memory quoteVaultFeed = ERC4626Feed({vault: address(quoteVault), conversionSample: 1 ether});

    // Create oracle with only ERC4626 feeds
    MangroveDiaOracle oracle = new MangroveDiaOracle(
      emptyFeed, emptyFeed, emptyFeed, emptyFeed, baseVaultFeed, quoteVaultFeed
    );

    // Expected tick: log_1.0001(2/1) = log_1.0001(2) ≈ 6932 (approximate)
    int256 tick = Tick.unwrap(oracle.tick());
    assertApproxEqAbs(tick, 6932, 1, "Tick should be approximately 6932");
  }

  function test_diaOracleWithCombinedDiaAndERC4626() public {
    // Setup tokens and vaults
    baseToken.mint(address(baseVault), 2 ether);
    quoteToken.mint(address(quoteVault), 1 ether);
    baseVault.mint(address(this), 1 ether);
    quoteVault.mint(address(this), 1 ether);

    // Create DIA feeds
    DiaFeed memory baseFeed =
      DiaFeed({oracle: address(mockDiaOracle), key: SUPER_OETH_USD_KEY, priceDecimals: PRICE_DECIMALS, baseDecimals: 18, quoteDecimals: 18});

    DiaFeed memory quoteFeed =
      DiaFeed({oracle: address(mockDiaOracle), key: ETH_USD_KEY, priceDecimals: PRICE_DECIMALS, baseDecimals: 18, quoteDecimals: 18});

    DiaFeed memory emptyFeed =
      DiaFeed({oracle: address(0), key: bytes32(0), priceDecimals: PRICE_DECIMALS, baseDecimals: 18, quoteDecimals: 18});

    // Set up vault feeds - baseVault has 2:1 ratio, quoteVault has 1:1 ratio
    ERC4626Feed memory baseVaultFeed = ERC4626Feed({vault: address(baseVault), conversionSample: 1 ether});

    ERC4626Feed memory quoteVaultFeed = ERC4626Feed({vault: address(quoteVault), conversionSample: 1 ether});

    // Create oracle with both DIA and ERC4626 feeds
    // SUPEROETHB/USD * (baseVault/baseToken) / (ETH/USD * quoteVault/quoteToken)
    // (3012 * 2) / (3000 * 1) = 2.008
    MangroveDiaOracle oracle = new MangroveDiaOracle(
      baseFeed, emptyFeed, quoteFeed, emptyFeed, baseVaultFeed, quoteVaultFeed
    );

    // Expected tick: log_1.0001((3012*2)/(3000*1)) = log_1.0001(2.008) ≈ 6971
    int256 tick = Tick.unwrap(oracle.tick());
    assertApproxEqAbs(tick, 6971, 1, "Tick should be approximately 6971");
  }

  function test_diaOracleWithPriceChange() public {
    // Create feeds
    DiaFeed memory baseFeed =
      DiaFeed({oracle: address(mockDiaOracle), key: SUPER_OETH_USD_KEY, priceDecimals: PRICE_DECIMALS, baseDecimals: 18, quoteDecimals: 18});

    DiaFeed memory quoteFeed =
      DiaFeed({oracle: address(mockDiaOracle), key: ETH_USD_KEY, priceDecimals: PRICE_DECIMALS, baseDecimals: 18, quoteDecimals: 18});

    DiaFeed memory emptyFeed =
      DiaFeed({oracle: address(0), key: bytes32(0), priceDecimals: PRICE_DECIMALS, baseDecimals: 18, quoteDecimals: 18});

    // Empty vault feed
    ERC4626Feed memory emptyVaultFeed = ERC4626Feed({vault: address(0), conversionSample: 0});

    // Create oracle
    MangroveDiaOracle oracle = new MangroveDiaOracle(
      baseFeed, emptyFeed, quoteFeed, emptyFeed, emptyVaultFeed, emptyVaultFeed
    );

    // Get initial tick
    int256 initialTick = Tick.unwrap(oracle.tick());

    // Change price
    mockDiaOracle.setPrice(SUPER_OETH_USD_KEY, 3000 * 10 ** PRICE_DECIMALS, block.timestamp);

    // Get new tick - should be log_1.0001(3000/3000) = log_1.0001(1) ≈ 0
    int256 newTick = Tick.unwrap(oracle.tick());
    assertApproxEqAbs(newTick, 0, 1, "New tick should be approximately 0");

    // Verify the tick changed
    assertTrue(initialTick != newTick, "Tick should change after price update");
  }

  function test_factoryComputeOracleAddress() public {
    // Create feeds
    DiaFeed memory baseFeed =
      DiaFeed({oracle: address(mockDiaOracle), key: SUPER_OETH_USD_KEY, priceDecimals: PRICE_DECIMALS, baseDecimals: 18, quoteDecimals: 18});

    DiaFeed memory quoteFeed =
      DiaFeed({oracle: address(mockDiaOracle), key: ETH_USD_KEY, priceDecimals: PRICE_DECIMALS, baseDecimals: 18, quoteDecimals: 18});

    DiaFeed memory emptyFeed =
      DiaFeed({oracle: address(0), key: bytes32(0), priceDecimals: PRICE_DECIMALS, baseDecimals: 18, quoteDecimals: 18});

    // Empty vault feed
    ERC4626Feed memory emptyVaultFeed = ERC4626Feed({vault: address(0), conversionSample: 0});

    // Test salt
    bytes32 salt = keccak256(abi.encodePacked("test_salt"));

    // Compute expected address
    address expectedAddress = factory.computeOracleAddress(
      baseFeed, emptyFeed, quoteFeed, emptyFeed, emptyVaultFeed, emptyVaultFeed, salt
    );

    // Deploy the oracle using the factory
    MangroveDiaOracle oracle = factory.create(
      baseFeed, emptyFeed, quoteFeed, emptyFeed, emptyVaultFeed, emptyVaultFeed, salt
    );

    // Verify address and factory recognition
    assertEq(address(oracle), expectedAddress, "Deployed oracle should be at the expected address");
    assertTrue(factory.isOracle(address(oracle)), "Factory should recognize the deployed oracle");
  }
}
