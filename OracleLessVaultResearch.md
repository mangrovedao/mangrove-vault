# MangroveVault V2: Oracle-less Architecture Design Report

## Executive Summary

This report outlines the design for MangroveVault V2, an oracle-less vault that eliminates price oracle dependencies while maintaining security and flexibility. The key innovations include **time-weighted price discovery**, **TVL-based position limits**, and **market-driven performance measurement**.

## Core Problems & Solutions

### Problem 1: Price Discovery Without Oracles

**Current Issue**: Oracle determines fair token ratios for deposits/withdrawals and Kandel positioning.

**Solution: Market-Driven Price Discovery**

#### A. Time-Weighted Average Price (TWAP) from external protocol

**Benefits**: 
- Robust and more trustless system

**Drawbacks**: 
- It works as an oracle, so we don't fully get rid of the oracle logic
- Still some room for manipulation

#### B. Fully on-chain target price calculation based on a custom algorithm

When the manager invests the funds the deposited token ratios will automatically computed on chain using a custom logic. 

**Benefits**: 
- Fully verifiable
- Secure

**Drawbacks**: 
- Reduces manager flexibility considerably


### Problem 2: Manager Rug Protection

**Current Issue**: Manager could manipulate oracle or make unfavorable trades.

**Solution: Multi-Layer Protection System**

#### A. TVL-Based Position Limits
```solidity
struct PositionLimits {
    uint256 maxTVLPercentage;    // Max % of TVL that can be positioned
    uint256 maxSingleTrade;      // Max size of individual rebalance
    uint256 timeDelay;           // Delay for large position changes
    mapping(uint256 => uint256) dailyTradeVolume;  // Daily trade limits
}
```

#### B. Disputable swaps with timelock
The vault could have a delay since the moment the manager initializes the trade till its actually excuted, leaving time to dispute this trade in case of it being malicious.

### Problem 3: Performance Measurement Without Oracles

**Current Issue**: Need oracle prices to calculate vault performance for fees.

**Solution: **

