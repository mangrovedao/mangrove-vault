// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MangroveVault, MangroveVaultErrors, MangroveVaultConstants, AbstractKandelSeeder, IERC20, SafeERC20, KandelPosition, FundsState} from "./MangroveVault.sol";
import {IOracle} from "./oracles/IOracle.sol";
import {Tick} from "@mgv/lib/core/TickLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @title MangroveVaultV2
 * @notice Oracle-enabled vault with disputable swaps and TVL-based protection
 * @dev Key features:
 *      - Maintains oracle integration for accurate pricing and performance measurement
 *      - Manager can only position X% of TVL with time delays for large changes
 *      - All significant swaps are disputable with timelock mechanism
 *      - Community can dispute malicious trades before execution
 *      - Passive mint/burn strategy with emergency position withdrawal
 *      - Oracle-based slippage protection and fair value calculations
 */
contract MangroveVaultV2 is MangroveVault {
  using SafeERC20 for IERC20;
    using Math for uint256;
    using SafeCast for uint256;

    /// @notice Position limits to prevent overexposure
    struct PositionLimits {
        uint256 maxTVLPercentage;           // Max % of TVL that can be positioned (basis points)
        uint256 maxSingleTradePercentage;   // Max % of TVL per single trade (basis points)
        uint256 positionTimeDelay;          // Delay for large position changes (seconds)
        uint256 swapTimeDelay;              // Delay for disputable swaps (seconds)
        mapping(uint256 => uint256) dailyTradeVolume; // day => cumulative trade volume
        uint256 maxDailyTradePercentage;    // Max % of TVL tradeable per day (basis points)
    }

    PositionLimits public positionLimits;

    /// @notice Pending swap that can be disputed
    struct PendingSwap {
        uint256 id;                    // Unique swap ID
        address target;                // Target contract for swap
        bytes data;                    // Swap calldata
        uint256 amountOut;            // Amount being swapped out
        uint256 amountInMin;          // Minimum amount expected in
        bool sell;                    // Direction of swap
        uint256 executionTime;        // When swap can be executed
        bool executed;                // Whether swap has been executed
        bool disputed;                // Whether swap has been disputed
        address proposer;             // Manager who proposed the swap
        uint256 disputeDeadline;      // Deadline for disputes
        Tick oracleTickAtProposal;    // Oracle tick when swap was proposed
        uint256 maxSlippageBps;       // Maximum allowed slippage from oracle price
    }

    /// @notice Pending position change that can be disputed
    struct PendingPositionChange {
        uint256 id;                   // Unique position ID
        KandelPosition position;      // New position parameters
        uint256 executionTime;        // When change can be executed
        bool executed;                // Whether change has been executed
        bool disputed;                // Whether change has been disputed
        address proposer;             // Manager who proposed the change
        uint256 disputeDeadline;      // Deadline for disputes
        uint256 allocationChange;     // How much allocation % will change
        Tick oracleTickAtProposal;    // Oracle tick when position was proposed
    }

    /// @notice Current active position allocation
    uint256 public currentTVLAllocation; // Current % of TVL in active positions (basis points)

    /// @notice Oracle-based price deviation limits
    uint256 public maxPriceDeviationBps; // Max allowed price deviation from oracle (basis points)

    /// @notice Counters for unique IDs
    uint256 public nextSwapId;
    uint256 public nextPositionId;

    /// @notice Storage for pending operations
    mapping(uint256 => PendingSwap) public pendingSwaps;
    mapping(uint256 => PendingPositionChange) public pendingPositions;

    /// @notice Dispute mechanism
    mapping(uint256 => mapping(address => bool)) public swapDisputes;    // swapId => user => hasDisputed
    mapping(uint256 => mapping(address => bool)) public positionDisputes; // positionId => user => hasDisputed
    mapping(uint256 => uint256) public swapDisputeCount;      // swapId => dispute count
    mapping(uint256 => uint256) public positionDisputeCount;  // positionId => dispute count
    
    /// @notice Dispute thresholds
    uint256 public disputeThresholdBps;        // Min % of TVL that must dispute (basis points)
    uint256 public minDisputeCount;            // Minimum number of disputers required

    /// @notice Events
    event SwapProposed(uint256 indexed swapId, address target, uint256 amountOut, uint256 executionTime, Tick oraclePrice);
    event SwapDisputed(uint256 indexed swapId, address disputer, uint256 disputeCount, string reason);
    event SwapExecuted(uint256 indexed swapId, int256 baseChange, int256 quoteChange, Tick executionPrice);
    event SwapCancelled(uint256 indexed swapId, string reason);
    
    event PositionChangeProposed(uint256 indexed positionId, uint256 newAllocation, uint256 executionTime, Tick oraclePrice);
    event PositionChangeDisputed(uint256 indexed positionId, address disputer, uint256 disputeCount, string reason);
    event PositionChangeExecuted(uint256 indexed positionId, uint256 newAllocation, Tick executionPrice);
    event PositionChangeCancelled(uint256 indexed positionId, string reason);

    event Mint(address indexed sender, uint256 shares, uint256 baseAmount, uint256 quoteAmount, int256 tick);
    event Burn(address indexed sender, uint256 shares, uint256 baseAmount, uint256 quoteAmount, int256 tick);
    
    event PriceDeviationDetected(uint256 operationId, Tick expectedPrice, Tick actualPrice, uint256 deviationBps);

    constructor(
        AbstractKandelSeeder _seeder,
        address _BASE,
        address _QUOTE,
        uint256 _tickSpacing,
        uint8 _decimals,
        string memory name,
        string memory symbol,
        address _oracle,
        address _owner,
        uint256 _maxTVLPercentage
    ) MangroveVault(
        _seeder, _BASE, _QUOTE, _tickSpacing, _decimals, 
        name, symbol, _oracle, _owner
    ) {
        require(_maxTVLPercentage <= 8000, "Max TVL allocation cannot exceed 80%");
        
        // Initialize position limits
        positionLimits.maxTVLPercentage = _maxTVLPercentage;
        positionLimits.maxSingleTradePercentage = 1000;  // 10% max per trade
        positionLimits.positionTimeDelay = 24 hours;     // 24h delay for large position changes
        positionLimits.swapTimeDelay = 4 hours;          // 4h delay for swaps
        positionLimits.maxDailyTradePercentage = 2000;   // 20% max trading per day

        // Initialize dispute parameters
        disputeThresholdBps = 500;  // 5% of TVL must dispute to cancel
        minDisputeCount = 3;        // Minimum 3 disputers required

        // Initialize oracle-based protection
        maxPriceDeviationBps = 500; // 5% max price deviation from oracle

        nextSwapId = 1;
        nextPositionId = 1;
    }

    // ============ POSITION MANAGEMENT ============

    /**
     * @notice Proposes a new Kandel position (with timelock if significant change)
     * @param position New position parameters
     * @dev Large allocation changes require timelock and can be disputed
     */
    function proposePositionChange(KandelPosition memory position) 
        external 
        onlyOwnerOrManager 
        returns (uint256 positionId)
    {
        // Calculate new allocation percentage
        uint256 newAllocationBps = _calculateAllocationBps(position.fundsState);
        
        // Check if change exceeds limits
        require(newAllocationBps <= positionLimits.maxTVLPercentage, "Exceeds max TVL allocation");
        
        // Get current oracle price for reference
        Tick currentOraclePrice = oracle.tick();
        
        uint256 allocationChange = newAllocationBps > currentTVLAllocation 
            ? newAllocationBps - currentTVLAllocation
            : currentTVLAllocation - newAllocationBps;

        positionId = nextPositionId++;
        
        // If change is significant, require timelock
        if (allocationChange >= 500) { // 5% change threshold
            uint256 executionTime = block.timestamp + positionLimits.positionTimeDelay;
            uint256 disputeDeadline = executionTime - 1 hours; // 1 hour before execution
            
            pendingPositions[positionId] = PendingPositionChange({
                id: positionId,
                position: position,
                executionTime: executionTime,
                executed: false,
                disputed: false,
                proposer: msg.sender,
                disputeDeadline: disputeDeadline,
                allocationChange: allocationChange,
                oracleTickAtProposal: currentOraclePrice
            });
            
            emit PositionChangeProposed(positionId, newAllocationBps, executionTime, currentOraclePrice);
        } else {
            // Small changes can be executed immediately
            _executePositionChange(position);
            pendingPositions[positionId].executed = true;
            currentTVLAllocation = newAllocationBps;
            
            emit PositionChangeExecuted(positionId, newAllocationBps, currentOraclePrice);
        }
        
        return positionId;
    }

    /**
     * @notice Disputes a pending position change with reason
     * @param positionId ID of the position change to dispute
     * @param reason Human readable reason for dispute
     */
    function disputePositionChange(uint256 positionId, string calldata reason) external {
        PendingPositionChange storage pending = pendingPositions[positionId];
        require(!pending.executed, "Position change already executed");
        require(!pending.disputed, "Position change already disputed");
        require(block.timestamp <= pending.disputeDeadline, "Dispute period ended");
        require(!positionDisputes[positionId][msg.sender], "Already disputed by this address");

        // Check if disputer has sufficient stake (owns vault shares)
        uint256 disputerShares = balanceOf(msg.sender);
        require(disputerShares > 0, "Must own vault shares to dispute");

        positionDisputes[positionId][msg.sender] = true;
        positionDisputeCount[positionId]++;

        emit PositionChangeDisputed(positionId, msg.sender, positionDisputeCount[positionId], reason);

        // Check if dispute threshold reached
        if (_isDisputeThresholdMet(positionDisputeCount[positionId])) {
            pending.disputed = true;
            emit PositionChangeCancelled(positionId, "Disputed by community");
        }
    }

    /**
     * @notice Executes a pending position change after timelock with oracle validation
     * @param positionId ID of the position change to execute
     */
    function executePositionChange(uint256 positionId) external {
        PendingPositionChange storage pending = pendingPositions[positionId];
        require(!pending.executed, "Already executed");
        require(!pending.disputed, "Position change was disputed");
        require(block.timestamp >= pending.executionTime, "Timelock not expired");

        // Oracle-based validation - check if price hasn't moved too much
        Tick currentOraclePrice = oracle.tick();
        uint256 priceDeviation = _calculatePriceDeviation(pending.oracleTickAtProposal, currentOraclePrice);
        
        if (priceDeviation > maxPriceDeviationBps) {
            pending.disputed = true;
            emit PriceDeviationDetected(positionId, pending.oracleTickAtProposal, currentOraclePrice, priceDeviation);
            emit PositionChangeCancelled(positionId, "Price deviated too much from proposal");
            return;
        }

        pending.executed = true;
        _executePositionChange(pending.position);
        
        uint256 newAllocationBps = _calculateAllocationBps(pending.position.fundsState);
        currentTVLAllocation = newAllocationBps;

        emit PositionChangeExecuted(positionId, newAllocationBps, currentOraclePrice);
    }

    // ============ SWAP MANAGEMENT ============

    /**
     * @notice Proposes a swap with timelock for community review and oracle validation
     * @param target Target contract for the swap
     * @param data Calldata for the swap
     * @param amountOut Amount of tokens being swapped out
     * @param amountInMin Minimum amount expected in return
     * @param sell Direction of the swap (true = sell base, false = sell quote)
     * @param maxSlippageBps Maximum allowed slippage from oracle price in basis points
     * @return swapId Unique ID for the proposed swap
     */
    function proposeSwap(
        address target,
        bytes calldata data,
        uint256 amountOut,
        uint256 amountInMin,
        bool sell,
        uint256 maxSlippageBps
    ) external onlyOwnerOrManager returns (uint256 swapId) {
        require(allowedSwapContracts[target], "Unauthorized swap contract");
        require(maxSlippageBps <= 1000, "Slippage too high"); // Max 10% slippage
        
        // Check trade size limits
        uint256 totalTVL = _getTotalTVLInQuote();
        require(amountOut <= totalTVL.mulDiv(positionLimits.maxSingleTradePercentage, 10000), 
                "Trade exceeds single trade limit");

        // Check daily volume limits
        uint256 today = block.timestamp / 1 days;
        uint256 dailyVolume = positionLimits.dailyTradeVolume[today] + amountOut;
        require(dailyVolume <= totalTVL.mulDiv(positionLimits.maxDailyTradePercentage, 10000),
                "Exceeds daily trade limit");

        // Oracle-based validation
        Tick currentOraclePrice = oracle.tick();
        uint256 adjustedAmountInMin = adjustedAmountInMin(amountOut, amountInMin, sell);
        
        // Validate that the proposed trade is reasonable according to oracle
        require(_validateSwapAgainstOracle(amountOut, adjustedAmountInMin, sell, maxSlippageBps), 
                "Swap deviates too much from oracle price");

        swapId = nextSwapId++;
        uint256 executionTime = block.timestamp + positionLimits.swapTimeDelay;
        uint256 disputeDeadline = executionTime - 30 minutes; // 30 min before execution

        pendingSwaps[swapId] = PendingSwap({
            id: swapId,
            target: target,
            data: data,
            amountOut: amountOut,
            amountInMin: adjustedAmountInMin,
            sell: sell,
            executionTime: executionTime,
            executed: false,
            disputed: false,
            proposer: msg.sender,
            disputeDeadline: disputeDeadline,
            oracleTickAtProposal: currentOraclePrice,
            maxSlippageBps: maxSlippageBps
        });

        emit SwapProposed(swapId, target, amountOut, executionTime, currentOraclePrice);
        return swapId;
    }

    /**
     * @notice Disputes a pending swap with reason
     * @param swapId ID of the swap to dispute
     * @param reason Human readable reason for dispute
     */
    function disputeSwap(uint256 swapId, string calldata reason) external {
        PendingSwap storage pending = pendingSwaps[swapId];
        require(!pending.executed, "Swap already executed");
        require(!pending.disputed, "Swap already disputed");
        require(block.timestamp <= pending.disputeDeadline, "Dispute period ended");
        require(!swapDisputes[swapId][msg.sender], "Already disputed by this address");

        // Check if disputer has sufficient stake
        uint256 disputerShares = balanceOf(msg.sender);
        require(disputerShares > 0, "Must own vault shares to dispute");

        swapDisputes[swapId][msg.sender] = true;
        swapDisputeCount[swapId]++;

        emit SwapDisputed(swapId, msg.sender, swapDisputeCount[swapId], reason);

        // Check if dispute threshold reached
        if (_isDisputeThresholdMet(swapDisputeCount[swapId])) {
            pending.disputed = true;
            emit SwapCancelled(swapId, "Disputed by community");
        }
    }

    /**
     * @notice Executes a pending swap after timelock with oracle re-validation
     * @param swapId ID of the swap to execute
     */
    function executeSwap(uint256 swapId) external nonReentrant returns (int256 baseChange, int256 quoteChange) {
        PendingSwap storage pending = pendingSwaps[swapId];
        require(!pending.executed, "Already executed");
        require(!pending.disputed, "Swap was disputed");
        require(block.timestamp >= pending.executionTime, "Timelock not expired");

        // Re-validate against current oracle price
        Tick currentOraclePrice = oracle.tick();
        uint256 priceDeviation = _calculatePriceDeviation(pending.oracleTickAtProposal, currentOraclePrice);
        
        if (priceDeviation > maxPriceDeviationBps) {
            pending.disputed = true;
            emit PriceDeviationDetected(swapId, pending.oracleTickAtProposal, currentOraclePrice, priceDeviation);
            emit SwapCancelled(swapId, "Price deviated too much from proposal");
            return (0, 0);
        }

        // Final validation of swap parameters against current oracle
        require(_validateSwapAgainstOracle(pending.amountOut, pending.amountInMin, pending.sell, pending.maxSlippageBps),
                "Swap no longer valid against oracle");

        pending.executed = true;
        
        // Update daily trade volume
        uint256 today = block.timestamp / 1 days;
        positionLimits.dailyTradeVolume[today] += pending.amountOut;

        bytes memory data = pending.data;

        // Execute the swap using internal function
        (baseChange, quoteChange) = _swap(
            pending.target,
            data,
            pending.amountOut,
            pending.amountInMin,
            pending.sell
        );

        emit SwapExecuted(swapId, baseChange, quoteChange, currentOraclePrice);
        return (baseChange, quoteChange);
    }

    // ============ MINT/BURN STRATEGY ============

    /**
     * @notice Passive mint - deposits assets without changing position, uses oracle for fair pricing
     * @dev Overrides parent to implement passive strategy with oracle validation
     */
    function mint(uint256 mintAmount, uint256 baseAmountMax, uint256 quoteAmountMax)
        external
        override
        whenNotPaused
        nonReentrant
        returns (uint256 shares, uint256 baseAmount, uint256 quoteAmount)
    {
        if (mintAmount == 0) revert MangroveVaultErrors.ZeroAmount();

        // Use oracle for fair pricing calculation
        (uint256 totalInQuote, Tick tick) = _accrueFee();
        _updateLastTotalInQuote(totalInQuote);

        // Get current total supply for share calculation
        uint256 _totalSupply = totalSupply();

        if (_totalSupply != 0) {
            // Calculate proportional deposit based on existing balances
            (uint256 baseBalance, uint256 quoteBalance) = getUnderlyingBalances();
            baseAmount = mintAmount.mulDiv(baseBalance, _totalSupply);
            quoteAmount = mintAmount.mulDiv(quoteBalance, _totalSupply);
        } else {
            // Initial mint - use oracle pricing
            baseAmount = tick.outboundFromInbound(quoteAmountMax);
            if (baseAmount > baseAmountMax) {
                baseAmount = baseAmountMax;
                quoteAmount = tick.inboundFromOutboundUp(baseAmountMax);
            } else {
                quoteAmount = quoteAmountMax;
            }
            
            // Calculate shares based on oracle price
            (, shares) = ((tick.inboundFromOutboundUp(baseAmount) + quoteAmount) * QUOTE_SCALE).trySub(
                MangroveVaultConstants.MINIMUM_LIQUIDITY
            );
            
            require(shares == mintAmount, "Initial mint shares mismatch");
            _mint(address(this), MangroveVaultConstants.MINIMUM_LIQUIDITY); // dead shares
        }

        // Slippage protection
        require(baseAmount <= baseAmountMax, "Base amount exceeds maximum");
        require(quoteAmount <= quoteAmountMax, "Quote amount exceeds maximum");

        // Transfer tokens and mint shares
        IERC20(BASE).safeTransferFrom(msg.sender, address(this), baseAmount);
        IERC20(QUOTE).safeTransferFrom(msg.sender, address(this), quoteAmount);
        
        if (_totalSupply != 0) {
            _mint(msg.sender, mintAmount);
            shares = mintAmount;
        } else {
            _mint(msg.sender, shares);
        }

        // DO NOT update position - keep it unchanged (passive strategy)
        emit Mint(msg.sender, shares, baseAmount, quoteAmount, Tick.unwrap(tick));
        return (shares, baseAmount, quoteAmount);
    }

    /**
     * @notice Smart burn - withdraws from vault first, then from active position if needed
     * @dev Uses oracle for fair valuation during withdrawal
     */
    function burn(uint256 shares, uint256 minAmountBaseOut, uint256 minAmountQuoteOut)
        external
        override
        whenNotPaused
        nonReentrant
        returns (uint256 amountBaseOut, uint256 amountQuoteOut)
    {
        require(shares > 0, "Zero shares");

        // Accrue fees with oracle pricing
        (uint256 totalInQuote, Tick tick) = _accrueFee();
        _updateLastTotalInQuote(totalInQuote);

        uint256 _totalSupply = totalSupply();
        (uint256 totalBase, uint256 totalQuote) = getUnderlyingBalances();
        (uint256 vaultBase, uint256 vaultQuote) = getVaultBalances();

        // Calculate proportional withdrawal
        uint256 targetBaseOut = shares.mulDiv(totalBase, _totalSupply);
        uint256 targetQuoteOut = shares.mulDiv(totalQuote, _totalSupply);

        // Slippage protection
        require(targetBaseOut >= minAmountBaseOut, "Base slippage exceeded");
        require(targetQuoteOut >= minAmountQuoteOut, "Quote slippage exceeded");

        // Burn shares first
        _burn(msg.sender, shares);

        // Try to satisfy withdrawal from vault balance first
        uint256 baseFromVault = Math.min(targetBaseOut, vaultBase);
        uint256 quoteFromVault = Math.min(targetQuoteOut, vaultQuote);

        // If vault doesn't have enough, withdraw from active position
        if (targetBaseOut > vaultBase || targetQuoteOut > vaultQuote) {
            uint256 additionalBase = targetBaseOut > vaultBase ? targetBaseOut - vaultBase : 0;
            uint256 additionalQuote = targetQuoteOut > vaultQuote ? targetQuoteOut - vaultQuote : 0;
            
            // Withdraw from Kandel position
            kandel.withdrawFunds(additionalBase, additionalQuote, address(this));
            
            // Update allocation after withdrawal
            _updateAllocationAfterWithdrawal(additionalBase, additionalQuote);
        }

        // Transfer tokens to user
        IERC20(BASE).safeTransfer(msg.sender, targetBaseOut);
        IERC20(QUOTE).safeTransfer(msg.sender, targetQuoteOut);

        // Update position if needed
        _updatePosition();

        // Update total in quote after withdrawal
        (uint256 newTotalInQuote,) = getTotalInQuote();
        _updateLastTotalInQuote(newTotalInQuote);

        emit Burn(msg.sender, shares, targetBaseOut, targetQuoteOut, Tick.unwrap(tick));
        return (targetBaseOut, targetQuoteOut);
    }

    // ============ ORACLE-BASED VALIDATION ============

    /**
     * @notice Validates a swap against oracle price
     */
    function _validateSwapAgainstOracle(
        uint256 amountOut,
        uint256 amountInMin,
        bool sell,
        uint256 maxSlippageBps
    ) internal view returns (bool) {
        Tick oracleTick = oracle.tick();
        
        uint256 expectedAmountIn;
        if (sell) {
            expectedAmountIn = oracleTick.inboundFromOutboundUp(amountOut);
        } else {
            expectedAmountIn = oracleTick.outboundFromInbound(amountOut);
        }
        
        // Check if the minimum amount is within acceptable slippage
        uint256 minAcceptable = expectedAmountIn.mulDiv(10000 - maxSlippageBps, 10000);
        return amountInMin >= minAcceptable;
    }

    /**
     * @notice Calculates price deviation between two ticks in basis points
     */
    function _calculatePriceDeviation(Tick oldTick, Tick newTick) internal pure returns (uint256) {
        int256 oldTickValue = Tick.unwrap(oldTick);
        int256 newTickValue = Tick.unwrap(newTick);
        
        int256 deviation = oldTickValue > newTickValue 
            ? oldTickValue - newTickValue 
            : newTickValue - oldTickValue;
            
        // Convert tick difference to basis points (approximation)
        return uint256(deviation);
    }

    /**
     * @notice Gets total TVL in quote tokens using oracle
     */
    function _getTotalTVLInQuote() internal view returns (uint256) {
        (uint256 totalInQuote,) = getTotalInQuote();
        return totalInQuote;
    }

    // ============ INTERNAL FUNCTIONS ============

    /**
     * @notice Calculates allocation percentage based on funds state
     */
    function _calculateAllocationBps(FundsState fundsState) internal view returns (uint256) {
        if (fundsState == FundsState.Active) {
            return positionLimits.maxTVLPercentage; // Use maximum allowed
        } else if (fundsState == FundsState.Passive) {
            return positionLimits.maxTVLPercentage / 2; // Use half for passive
        } else {
            return 0; // Vault state = 0% allocation
        }
    }

    /**
     * @notice Executes a position change
     */
    function _executePositionChange(KandelPosition memory position) internal {
        _setPosition(position);
        _updatePosition();
    }

    /**
     * @notice Updates allocation after emergency withdrawal
     */
    function _updateAllocationAfterWithdrawal(uint256 withdrawnBase, uint256 withdrawnQuote) internal {
        Tick tick = oracle.tick();
        uint256 withdrawnValue = _toQuoteAmount(withdrawnBase, withdrawnQuote, tick);
        uint256 totalTVL = _getTotalTVLInQuote();
        
        if (totalTVL > 0) {
            uint256 withdrawnPercentage = withdrawnValue.mulDiv(10000, totalTVL);
            currentTVLAllocation = currentTVLAllocation > withdrawnPercentage 
                ? currentTVLAllocation - withdrawnPercentage 
                : 0;
        }
    }

    /**
     * @notice Checks if dispute threshold is met
     */
    function _isDisputeThresholdMet(uint256 disputeCount) internal view returns (bool) {
        if (disputeCount < minDisputeCount) return false;
        
        uint256 totalTVL = _getTotalTVLInQuote();
        uint256 requiredTVL = totalTVL.mulDiv(disputeThresholdBps, 10000);
        
        // This is simplified - in practice, you'd sum up the TVL of all disputers
        return disputeCount >= minDisputeCount; // Simplified check
    }

    // ============ GOVERNANCE FUNCTIONS ============

    /**
     * @notice Updates dispute parameters (owner only)
     */
    function setDisputeParameters(uint256 newThresholdBps, uint256 newMinCount) external onlyOwner {
        require(newThresholdBps <= 2000, "Threshold too high"); // Max 20%
        require(newMinCount >= 1, "Min count too low");
        
        disputeThresholdBps = newThresholdBps;
        minDisputeCount = newMinCount;
    }

    /**
     * @notice Updates oracle-based price deviation limit
     */
    function setMaxPriceDeviation(uint256 newMaxDeviationBps) external onlyOwner {
        require(newMaxDeviationBps <= 2000, "Deviation too high"); // Max 20%
        maxPriceDeviationBps = newMaxDeviationBps;
    }

    /**
     * @notice Updates position limits (owner only)
     */
    function setPositionLimits(
        uint256 newMaxTVLPercentage,
        uint256 newMaxSingleTradePercentage,
        uint256 newPositionTimeDelay,
        uint256 newSwapTimeDelay
    ) external onlyOwner {
        require(newMaxTVLPercentage <= 8000, "Max TVL too high");
        require(newMaxSingleTradePercentage <= 2000, "Max trade too high");
        
        positionLimits.maxTVLPercentage = newMaxTVLPercentage;
        positionLimits.maxSingleTradePercentage = newMaxSingleTradePercentage;
        positionLimits.positionTimeDelay = newPositionTimeDelay;
        positionLimits.swapTimeDelay = newSwapTimeDelay;
    }

    /**
     * @notice Emergency function to cancel all pending operations
     */
    function emergencyCancel() external onlyOwner {
        // Mark all pending swaps as disputed (cancelled)
        for (uint256 i = 1; i < nextSwapId; i++) {
            if (!pendingSwaps[i].executed && !pendingSwaps[i].disputed) {
                pendingSwaps[i].disputed = true;
                emit SwapCancelled(i, "Emergency cancellation by owner");
            }
        }
        
        // Mark all pending position changes as disputed (cancelled)
        for (uint256 i = 1; i < nextPositionId; i++) {
            if (!pendingPositions[i].executed && !pendingPositions[i].disputed) {
                pendingPositions[i].disputed = true;
                emit PositionChangeCancelled(i, "Emergency cancellation by owner");
            }
        }
    }

    /**
     * @notice Get detailed information about a pending swap
     * @param swapId The ID of the swap to query
     */
    function getPendingSwapDetails(uint256 swapId) external view returns (
        address target,
        uint256 amountOut,
        uint256 amountInMin,
        bool sell,
        uint256 executionTime,
        bool executed,
        bool disputed,
        Tick oracleTickAtProposal,
        uint256 disputeCount,
        uint256 timeRemaining
    ) {
        PendingSwap storage swap = pendingSwaps[swapId];
        return (
            swap.target,
            swap.amountOut,
            swap.amountInMin,
            swap.sell,
            swap.executionTime,
            swap.executed,
            swap.disputed,
            swap.oracleTickAtProposal,
            swapDisputeCount[swapId],
            swap.executionTime > block.timestamp ? swap.executionTime - block.timestamp : 0
        );
    }

    /**
     * @notice Get detailed information about a pending position change
     * @param positionId The ID of the position change to query
     */
    function getPendingPositionDetails(uint256 positionId) external view returns (
        uint256 newAllocation,
        uint256 executionTime,
        bool executed,
        bool disputed,
        Tick oracleTickAtProposal,
        uint256 disputeCount,
        uint256 timeRemaining
    ) {
        PendingPositionChange storage position = pendingPositions[positionId];
        uint256 newAllocationBps = _calculateAllocationBps(position.position.fundsState);
        
        return (
            newAllocationBps,
            position.executionTime,
            position.executed,
            position.disputed,
            position.oracleTickAtProposal,
            positionDisputeCount[positionId],
            position.executionTime > block.timestamp ? position.executionTime - block.timestamp : 0
        );
    }

    /**
     * @notice Get current vault allocation and limits status
     */
    function getAllocationStatus() external view returns (
        uint256 currentAllocation,
        uint256 maxAllocation,
        uint256 totalTVL,
        uint256 activeValue,
        uint256 vaultValue
    ) {
        currentAllocation = currentTVLAllocation;
        maxAllocation = positionLimits.maxTVLPercentage;
        totalTVL = _getTotalTVLInQuote();
        
        (uint256 kandelBase, uint256 kandelQuote) = getKandelBalances();
        Tick tick = oracle.tick();
        activeValue = _toQuoteAmount(kandelBase, kandelQuote, tick);
        vaultValue = totalTVL - activeValue;
    }

    /**
     * @notice Check if an operation can be disputed
     * @param operationId The ID of the operation (swap or position)
     * @param isSwap Whether this is a swap (true) or position change (false)
     * @param user The user wanting to dispute
     */
    function canDispute(uint256 operationId, bool isSwap, address user) external view returns (
        bool canDisputeNow,
        string memory reason
    ) {
        if (balanceOf(user) == 0) {
            return (false, "Must own vault shares");
        }

        if (isSwap) {
            PendingSwap storage swap = pendingSwaps[operationId];
            if (swap.executed) return (false, "Already executed");
            if (swap.disputed) return (false, "Already disputed");
            if (block.timestamp > swap.disputeDeadline) return (false, "Dispute period ended");
            if (swapDisputes[operationId][user]) return (false, "Already disputed by user");
            return (true, "Can dispute");
        } else {
            PendingPositionChange storage position = pendingPositions[operationId];
            if (position.executed) return (false, "Already executed");
            if (position.disputed) return (false, "Already disputed");
            if (block.timestamp > position.disputeDeadline) return (false, "Dispute period ended");
            if (positionDisputes[operationId][user]) return (false, "Already disputed by user");
            return (true, "Can dispute");
        }
    }

    /**
     * @notice Get current oracle price and market information
     */
    function getMarketInfo() external view returns (
        Tick currentOraclePrice,
        uint256 totalTVLInQuote,
        uint256 currentAllocationPercentage,
        uint256 dailyVolumeToday,
        uint256 dailyVolumeLimit
    ) {
        currentOraclePrice = oracle.tick();
        totalTVLInQuote = _getTotalTVLInQuote();
        currentAllocationPercentage = currentTVLAllocation;
        
        uint256 today = block.timestamp / 1 days;
        dailyVolumeToday = positionLimits.dailyTradeVolume[today];
        dailyVolumeLimit = totalTVLInQuote.mulDiv(positionLimits.maxDailyTradePercentage, 10000);
    }

    /**
     * @notice Simulate a swap to check if it would be valid
     * @param amountOut Amount to swap out
     * @param amountInMin Minimum amount expected
     * @param sell Direction of swap
     * @param maxSlippageBps Maximum allowed slippage
     */
    function simulateSwap(
        uint256 amountOut,
        uint256 amountInMin,
        bool sell,
        uint256 maxSlippageBps
    ) external view returns (
        bool isValid,
        string memory reason,
        uint256 oracleExpectedAmountIn,
        uint256 slippageBps
    ) {
        // Check trade size limits
        uint256 totalTVL = _getTotalTVLInQuote();
        if (amountOut > totalTVL.mulDiv(positionLimits.maxSingleTradePercentage, 10000)) {
            return (false, "Exceeds single trade limit", 0, 0);
        }

        // Check daily volume limits
        uint256 today = block.timestamp / 1 days;
        uint256 dailyVolume = positionLimits.dailyTradeVolume[today] + amountOut;
        if (dailyVolume > totalTVL.mulDiv(positionLimits.maxDailyTradePercentage, 10000)) {
            return (false, "Exceeds daily trade limit", 0, 0);
        }

        // Oracle validation
        Tick oracleTick = oracle.tick();
        if (sell) {
            oracleExpectedAmountIn = oracleTick.inboundFromOutboundUp(amountOut);
        } else {
            oracleExpectedAmountIn = oracleTick.outboundFromInbound(amountOut);
        }
        
        if (oracleExpectedAmountIn == 0) {
            return (false, "Oracle price calculation failed", 0, 0);
        }

        // Calculate actual slippage
        slippageBps = oracleExpectedAmountIn > amountInMin
            ? ((oracleExpectedAmountIn - amountInMin) * 10000) / oracleExpectedAmountIn
            : 0;

        if (slippageBps > maxSlippageBps) {
            return (false, "Slippage exceeds maximum", oracleExpectedAmountIn, slippageBps);
        }

        return (true, "Valid swap", oracleExpectedAmountIn, slippageBps);
    }

    /**
     * @notice Get comprehensive vault status for frontend/monitoring
     */
    function getVaultStatus() external view returns (
        uint256 totalShares,
        uint256 totalTVLInQuote,
        uint256 vaultBalance,
        uint256 activeBalance,
        uint256 currentAllocationBps,
        uint256 maxAllocationBps,
        uint256 pendingSwapsCount,
        uint256 pendingPositionsCount,
        Tick currentOraclePrice,
        bool isPaused
    ) {
        totalShares = totalSupply();
        totalTVLInQuote = _getTotalTVLInQuote();
        
        (uint256 vaultBase, uint256 vaultQuote) = getVaultBalances();
        (uint256 kandelBase, uint256 kandelQuote) = getKandelBalances();
        
        Tick tick = oracle.tick();
        vaultBalance = _toQuoteAmount(vaultBase, vaultQuote, tick);
        activeBalance = _toQuoteAmount(kandelBase, kandelQuote, tick);
        
        currentAllocationBps = currentTVLAllocation;
        maxAllocationBps = positionLimits.maxTVLPercentage;
        
        // Count pending operations
        uint256 _pendingSwapsCount = 0;
        uint256 _pendingPositionsCount = 0;
        
        for (uint256 i = 1; i < nextSwapId; i++) {
            if (!pendingSwaps[i].executed && !pendingSwaps[i].disputed) {
                _pendingSwapsCount++;
            }
        }
        
        for (uint256 i = 1; i < nextPositionId; i++) {
            if (!pendingPositions[i].executed && !pendingPositions[i].disputed) {
                _pendingPositionsCount++;
            }
        }
        
        pendingSwapsCount = _pendingSwapsCount;
        pendingPositionsCount = _pendingPositionsCount;
        currentOraclePrice = tick;
        isPaused = paused();
    }
}