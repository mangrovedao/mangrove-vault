// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {
  MangroveChainlinkOracleV2,
  ChainlinkFeed,
  ERC4626Feed,
  ERC4626Consumer,
  IERC4626,
  Tick
} from "../src/oracles/chainlink/v2/MangroveChainlinkOracleV2.sol";
import {ERC20 as AbstractERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626 as AbstractERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

contract ERC20 is AbstractERC20 {
  function mint(address to, uint256 amount) public {
    _mint(to, amount);
  }

  constructor(string memory name, string memory symbol) AbstractERC20(name, symbol) {}
}

contract ERC4626 is AbstractERC4626 {
  function mint(address to, uint256 amount) public {
    _mint(to, amount);
  }

  constructor(string memory name, string memory symbol, IERC20 asset)
    AbstractERC20(name, symbol)
    AbstractERC4626(asset)
  {}
}

contract ChainlinkOracleV2Test is Test {
  function test_assetEqualsShares() public {
    ERC20 asset = new ERC20("Asset", "ASSET");
    ERC4626 vault = new ERC4626("Vault", "VAULT", asset);
    asset.mint(address(vault), 1 ether);
    vault.mint(address(this), 1 ether);
    assertEq(vault.convertToAssets(1 ether), 1 ether, "Asset should be equal to shares");
    assertEq(ERC4626Consumer.getTick(vault, 1 ether), 0, "Tick should be 0");
  }

  function test_AssetMoreThanShares() public {
    ERC20 asset = new ERC20("Asset", "ASSET");
    ERC4626 vault = new ERC4626("Vault", "VAULT", asset);
    asset.mint(address(vault), 2 ether);
    vault.mint(address(this), 1 ether);
    assertApproxEqAbs(vault.convertToAssets(1 ether), 2 ether, 1, "Asset should be 2x shares");
    assertApproxEqAbs(ERC4626Consumer.getTick(vault, 1 ether), 6932, 1, "Tick should be 6932");
  }

  function test_AssetLessThanShares() public {
    ERC20 asset = new ERC20("Asset", "ASSET");
    ERC4626 vault = new ERC4626("Vault", "VAULT", asset);
    asset.mint(address(vault), 1 ether);
    vault.mint(address(this), 2 ether);
    assertApproxEqAbs(vault.convertToAssets(1 ether), 0.5 ether, 1, "Asset should be 0.5x shares");
    assertApproxEqAbs(ERC4626Consumer.getTick(vault, 1 ether), -6932, 1, "Tick should be -6932");
  }

  function test_emptyOracle() public {
    ChainlinkFeed memory feed;
    ERC4626Feed memory vault;
    MangroveChainlinkOracleV2 oracle = new MangroveChainlinkOracleV2(feed, feed, feed, feed, vault, vault);
    assertEq(Tick.unwrap(oracle.tick()), 0, "Tick should be 0");
  }

  function test_oracleWith4626Feed() public {
    ERC20 asset = new ERC20("Asset", "ASSET");
    ERC4626 vault = new ERC4626("Vault", "VAULT", asset);
    asset.mint(address(vault), 1 ether);
    vault.mint(address(this), 1 ether);
    ChainlinkFeed memory feed;
    ERC4626Feed memory vaultFeed;
    MangroveChainlinkOracleV2 oracle =
      new MangroveChainlinkOracleV2(feed, feed, feed, feed, ERC4626Feed(address(vault), 1 ether), vaultFeed);
    assertEq(Tick.unwrap(oracle.tick()), 0, "Tick should be 0");
  }

  function test_oracleWith4626FeedHigherThanAsset() public {
    ERC20 asset = new ERC20("Asset", "ASSET");
    ERC4626 vault = new ERC4626("Vault", "VAULT", asset);
    asset.mint(address(vault), 1 ether);
    vault.mint(address(this), 2 ether);
    ChainlinkFeed memory feed;
    ERC4626Feed memory vaultFeed;
    MangroveChainlinkOracleV2 oracle =
      new MangroveChainlinkOracleV2(feed, feed, feed, feed, ERC4626Feed(address(vault), 1 ether), vaultFeed);
    assertApproxEqAbs(Tick.unwrap(oracle.tick()), -6932, 1, "Tick should be -6932");

    // put on the quote side
    oracle =
      new MangroveChainlinkOracleV2(feed, feed, feed, feed, vaultFeed, ERC4626Feed(address(vault), 1 ether));
    assertApproxEqAbs(Tick.unwrap(oracle.tick()), 6932, 1, "Tick should be 6932");
  }

  function test_oracleWith4626FeedLowerThanAsset() public {
    ERC20 asset = new ERC20("Asset", "ASSET");
    ERC4626 vault = new ERC4626("Vault", "VAULT", asset);
    asset.mint(address(vault), 2 ether);
    vault.mint(address(this), 1 ether);
    ChainlinkFeed memory feed;
    ERC4626Feed memory vaultFeed;
    MangroveChainlinkOracleV2 oracle =
      new MangroveChainlinkOracleV2(feed, feed, feed, feed, vaultFeed, ERC4626Feed(address(vault), 1 ether));
    assertApproxEqAbs(Tick.unwrap(oracle.tick()), -6932, 1, "Tick should be -6932");

    // put on the base side
    oracle =
      new MangroveChainlinkOracleV2(feed, feed, feed, feed, ERC4626Feed(address(vault), 1 ether), vaultFeed);
    assertApproxEqAbs(Tick.unwrap(oracle.tick()), 6932, 1, "Tick should be 6932");
  }

  function test_oracleWithComposedERC4626Feed() public {
    ERC20 asset1 = new ERC20("Asset1", "ASSET1");
    ERC20 asset2 = new ERC20("Asset2", "ASSET2");
    ERC4626 vault1 = new ERC4626("Vault1", "VAULT1", asset1);
    ERC4626 vault2 = new ERC4626("Vault2", "VAULT2", asset2);
    asset1.mint(address(vault1), 3 ether);
    asset2.mint(address(vault2), 2 ether);
    vault1.mint(address(this), 1 ether);
    vault2.mint(address(this), 1 ether);

    ChainlinkFeed memory feed;
    MangroveChainlinkOracleV2 oracle =
      new MangroveChainlinkOracleV2(feed, feed, feed, feed, ERC4626Feed(address(vault1), 1 ether), ERC4626Feed(address(vault2), 1 ether));

    assertApproxEqAbs(Tick.unwrap(oracle.tick()), 4054, 1, "Tick should be 4054");

    // reverse the sides
    oracle =
      new MangroveChainlinkOracleV2(feed, feed, feed, feed, ERC4626Feed(address(vault2), 1 ether), ERC4626Feed(address(vault1), 1 ether));
    assertApproxEqAbs(Tick.unwrap(oracle.tick()), -4054, 1, "Tick should be -4054");
  }
}
