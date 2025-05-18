// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// OpenZeppelin imports
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

// PRBMath import
import "@prb/math/PRBMathUD60x18.sol";

// Interfaces
interface IRWAYield {
    function depositToRWA(address protocol, uint256 amount) external;
    function withdrawFromRWA(address protocol, uint256 amount) external returns (uint256);
    function isRWA(address protocol) external view returns (bool);
    function getRWAYield(address protocol) external view returns (uint256);
    function getAvailableLiquidity(address protocol) external view returns (uint256);
}

interface ISonicProtocol {
    function isSonicCompliant(address protocol) external view returns (bool);
    function getSonicAPY(address protocol) external view returns (uint256);
}

interface IFlyingTulip {
    function depositToPool(address pool, uint256 amount, bool useLeverage) external returns (uint256);
    function withdrawFromPool(address pool, uint256 amount) external returns (uint256);
    function getLTV(address pool, uint256 collateral) external view returns (uint256);
    function isProtocolHealthy(address pool) external view returns (bool);
}

interface IRegistry {
    function getActiveProtocols(bool isRWA) external view returns (address[] memory);
    function isValidProtocol(address protocol) external view returns (bool);
    function getProtocolAPYFeed(address protocol) external view returns (address);
    function getProtocolRiskScore(address protocol) external view returns (uint256);
}

interface IRiskManager {
    function getRiskAdjustedAPY(address protocol, uint256 apy) external view returns (uint256);
    function assessLeverageViability(address protocol, uint256 amount, uint256 ltv, bool isRWA) external view returns (bool);
}

interface ILooperCore {
    function applyLeverage(address protocol, uint256 amount, uint256 ltv, bool isRWA) external;
    function unwindLeverage(address protocol, uint256 repayAmount, bool isRWA) external;
    function checkLiquidationRisk(address protocol, uint256 collateral, uint256 borrowAmount, bool isRWA) external view returns (bool);
}

interface IStakingManager {
    function earnPoints(address user, uint256 amount, bool isAllocation) external;
    function claimPoints(address user) external;
}

interface IGovernanceManager {
    function proposeAction(bytes32 actionHash) external;
    function executeAction(bytes32 actionHash) external;
    function governance() external view returns (address);
}

interface IUpkeepManager {
    function manualUpkeep(bool isRWA) external;
}

// An Oracle Interface for AI Model Outputs
interface IOracle {
    function getAIPredictions(address protocol) external view returns (uint256 predictedAPY, uint256 riskScore, uint256 timestamp);
}

/**
 * @title AIYieldOptimizer
 * @notice A delegated contract for AI-driven RWA yield optimization with hybrid AI model and multi-oracle integration.
 * @dev Uses UUPS proxy, supports Sonic’s Fee Monetization, native USDC, RedStone oracles, and Sonic Points.
 */
contract AIYieldOptimizer is UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using PRBMathUD60x18 for uint256;

    // State variables
    IERC20 public immutable stablecoin; // Sonic’s native USDC
    IRWAYield public immutable rwaYield; // RWAYield contract
    ISonicProtocol public immutable sonicProtocol; // Sonic compliance and APY
    IFlyingTulip public immutable flyingTulip; // FlyingTulip for leverage
    IRegistry public registry; // Registry contract
    IRiskManager public riskManager; // RiskManager contract
    ILooperCore public looperCore; // LooperCore contract
    IStakingManager public stakingManager; // StakingManager contract
    IGovernanceManager public governanceManager; // GovernanceManager contract
    IUpkeepManager public upkeepManager; // UpkeepManager contract
    address public aiOracle; // Primary AI Oracle address (fallback)
    address public feeRecipient; // Receives management and performance fees
    uint256 public managementFee; // Management fee in basis points
    uint256 public performanceFee; // Performance fee in basis points
    uint256 public totalRWABalance; // Total stablecoins allocated to RWAs
    mapping(address => uint256) public rwaBalances; // Balances in each RWA protocol
    mapping(address => Allocation) public allocations; // Protocol allocations
    bool public allowLeverage; // Toggle for leverage support
    uint256 public minRWALiquidityThreshold; // Minimum liquidity threshold for RWA protocols
    bool public isPaused; // Emergency pause state

    // Multi-Oracle State
    address[] public oracles; // List of trusted oracles
    uint256 public maxOracles; // Maximum number of oracles (e.g., 5)
    uint256 public minOracleResponses; // Minimum oracle responses required
    uint256 public oracleDataTimeout; // Timeout for oracle data freshness (e.g., 1 hour)
    uint256 public hybridWeightOnChain; // Weight for on-chain data (basis points, e.g., 5000 = 50%)
    bool public oracleCircuitBreaker; // Pause oracle usage if triggered

    // Constants
    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant MAX_PROTOCOLS = 10; // Max supported protocols
    uint256 private constant MAX_LTV = 8000; // 80% LTV cap
    uint256 private constant MAX_APY = 10000; // 100% max APY
    uint256 private constant MIN_ALLOCATION = 1e16; // Minimum allocation (0.01 stablecoin units)
    uint256 private constant SECONDS_PER_YEAR = 365 days;
    uint256 private constant FIXED_POINT_SCALE = 1e18;
    uint256 private constant MAX_EXP_INPUT = 10e18;
    uint256 private constant MIN_PROFIT = 1e6; // Minimum profit threshold

    // Structs
    struct Allocation {
        address protocol;
        uint256 amount;
        uint256 apy; // Basis points
        uint256 lastUpdated;
        bool isLeveraged;
    }

    struct OraclePrediction {
        uint256 predictedAPY;
        uint256 riskScore;
        uint256 timestamp;
        bool isValid;
    }

    // Events
    event DepositRWA(address indexed protocol, uint256 amount, uint256 fee, bool isLeveraged, bytes32 indexed correlationId);
    event WithdrawRWA(address indexed protocol, uint256 amount, uint256 profit, uint256 fee, bytes32 indexed correlationId);
    event AIAllocationUpdated(address indexed protocol, uint256 amount, bool isLeveraged, bytes32 indexed correlationId);
    event AIOracleUpdated(address indexed newOracle);
    event FeeRecipientUpdated(address indexed newRecipient);
    event FeesUpdated(uint256 managementFee, uint256 performanceFee);
    event LeverageToggled(bool status);
    event PauseToggled(bool status);
    event AIRecommendedAllocation(address indexed protocol, uint256 amount, bool isLeveraged, bytes32 indexed correlationId);
    event AllocationLogicUpdated(string logicDescription, bytes32 indexed correlationId);
    event ManualUpkeepTriggered(uint256 timestamp, bytes32 indexed correlationId);
    event OracleAdded(address indexed oracle, bytes32 indexed correlationId);
    event OracleRemoved(address indexed oracle, bytes32 indexed correlationId);
    event OracleCircuitBreakerTriggered(bool status, bytes32 indexed correlationId);
    event HybridWeightsUpdated(uint256 onChainWeight, bytes32 indexed correlationId);

    // Modifiers
    modifier onlyGovernance() {
        require(msg.sender == governanceManager.governance(), "Not governance");
        _;
    }

    modifier onlyAIOracleOrYieldOptimizer() {
        require(msg.sender == aiOracle || msg.sender == owner(), "Not authorized");
        _;
    }

    modifier whenNotPaused() {
        require(!isPaused, "Paused");
        _;
    }

    modifier whenOracleCircuitBreakerNotTriggered() {
        require(!oracleCircuitBreaker, "Oracle circuit breaker triggered");
        _;
    }

    /**
     * @notice Initializes the contract with Sonic-specific parameters, modular integrations, and multi-oracle setup.
     */
    function initialize(
        address _stablecoin,
        address _rwaYield,
        address _sonicProtocol,
        address _flyingTulip,
        address _registry,
        address _riskManager,
        address _looperCore,
        address _stakingManager,
        address _governanceManager,
        address _upkeepManager,
        address _aiOracle,
        address _feeRecipient
    ) external initializer {
        require(_stablecoin != address(0), "Invalid stablecoin address");
        require(_rwaYield != address(0), "Invalid RWAYield address");
        require(_sonicProtocol != address(0), "Invalid SonicProtocol address");
        require(_flyingTulip != address(0), "Invalid FlyingTulip address");
        require(_registry != address(0), "Invalid Registry address");
        require(_riskManager != address(0), "Invalid RiskManager address");
        require(_looperCore != address(0), "Invalid LooperCore address");
        require(_stakingManager != address(0), "Invalid StakingManager address");
        require(_governanceManager != address(0), "Invalid GovernanceManager address");
        require(_upkeepManager != address(0), "Invalid UpkeepManager address");
        require(_aiOracle != address(0), "Invalid AI Oracle address");
        require(_feeRecipient != address(0), "Invalid fee recipient");

        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        stablecoin = IERC20(_stablecoin);
        rwaYield = IRWAYield(_rwaYield);
        sonicProtocol = ISonicProtocol(_sonicProtocol);
        flyingTulip = IFlyingTulip(_flyingTulip);
        registry = IRegistry(_registry);
        riskManager = IRiskManager(_riskManager);
        looperCore = ILooperCore(_looperCore);
        stakingManager = IStakingManager(_stakingManager);
        governanceManager = IGovernanceManager(_governanceManager);
        upkeepManager = IUpkeepManager(_upkeepManager);
        aiOracle = _aiOracle;
        feeRecipient = _feeRecipient;
        managementFee = 50; // 0.5%
        performanceFee = 1000; // 10%
        allowLeverage = true;
        minRWALiquidityThreshold = 1e18; // 1 stablecoin unit

        // Initialize multi-oracle parameters
        maxOracles = 5;
        minOracleResponses = 2;
        oracleDataTimeout = 1 hours;
        hybridWeightOnChain = 5000; // 50% on-chain, 50% off-chain
        oracleCircuitBreaker = false;

        // Testing Note: Test initialization with invalid addresses and multi-oracle parameters.
    }

    /**
     * @notice Authorizes contract upgrades.
     */
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /**
     * @notice AI Oracle or YieldOptimizer submits allocation recommendations with hybrid AI model.
     * @param protocols List of protocols to allocate to
     * @param amounts Amounts to allocate
     * @param isLeveraged Leverage flags
     * @param correlationId Unique ID for event tracing
     * @param start Starting index for pagination
     * @param limit Number of protocols to process
     */
    function submitAIAllocation(
        address[] calldata protocols,
        uint256[] calldata amounts,
        bool[] calldata isLeveraged,
        bytes32 correlationId,
        uint256 start,
        uint256 limit
    ) external nonReentrant whenNotPaused whenOracleCircuitBreakerNotTriggered onlyAIOracleOrYieldOptimizer {
        require(protocols.length == amounts.length && protocols.length == isLeveraged.length, "Mismatched arrays");
        require(protocols.length <= MAX_PROTOCOLS, "Too many protocols");
        require(start < protocols.length, "Invalid start index");
        uint256 end = start + limit > protocols.length ? protocols.length : start + limit;

        uint256 totalAmount;
        for (uint256 i = start; i < end; i++) {
            require(_isValidProtocol(protocols[i]), "Unsupported protocol");
            require(flyingTulip.isProtocolHealthy(protocols[i]), "Protocol not healthy");
            totalAmount += amounts[i];
        }
        require(totalAmount <= stablecoin.balanceOf(address(this)), "Insufficient balance");

        for (uint256 i = start; i < end; i++) {
            if (amounts[i] >= MIN_ALLOCATION) {
                uint256 fee = (amounts[i] * managementFee) / BASIS_POINTS;
                uint256 netAmount = amounts[i] - fee;
                _depositToRWA(protocols[i], netAmount, isLeveraged[i] && allowLeverage, correlationId);
                allocations[protocols[i]] = Allocation(
                    protocols[i],
                    netAmount,
                    rwaYield.getRWAYield(protocols[i]),
                    block.timestamp,
                    isLeveraged[i] && allowLeverage
                );
                stablecoin.safeTransfer(feeRecipient, fee);
                stakingManager.earnPoints(msg.sender, netAmount, true);
                emit AIAllocationUpdated(protocols[i], netAmount, isLeveraged[i] && allowLeverage, correlationId);
                emit DepositRWA(protocols[i], netAmount, fee, isLeveraged[i] && allowLeverage, correlationId);
            }
        }

        // Testing Note: Test pagination, oracle-driven allocations, failed deposits, and correlation ID tracing.
    }

    /**
     * @notice Rebalances portfolio based on hybrid AI recommendations.
     * @param protocols List of protocols to allocate to
     * @param amounts Amounts to allocate
     * @param isLeveraged Leverage flags
     * @param correlationId Unique ID for event tracing
     * @param start Starting index for pagination
     * @param limit Number of protocols to process
     */
    function rebalancePortfolio(
        address[] calldata protocols,
        uint256[] calldata amounts,
        bool[] calldata isLeveraged,
        bytes32 correlationId,
        uint256 start,
        uint256 limit
    ) external nonReentrant whenNotPaused whenOracleCircuitBreakerNotTriggered onlyAIOracleOrYieldOptimizer {
        require(protocols.length == amounts.length && protocols.length == isLeveraged.length, "Mismatched arrays");
        require(start < protocols.length, "Invalid start index");
        uint256 end = start + limit > protocols.length ? protocols.length : start + limit;

        // Withdraw from all protocols
        address[] memory activeProtocols = registry.getActiveProtocols(true);
        for (uint256 i = 0; i < activeProtocols.length; i++) {
            address protocol = activeProtocols[i];
            if (rwaBalances[protocol] > 0) {
                _withdrawFromRWA(protocol, rwaBalances[protocol], false, correlationId);
            }
        }

        // Reallocate based on AI recommendations
        uint256 totalAmount;
        for (uint256 i = start; i < end; i++) {
            totalAmount += amounts[i];
        }
        require(totalAmount <= stablecoin.balanceOf(address(this)), "Insufficient balance");

        for (uint256 i = start; i < end; i++) {
            if (amounts[i] >= MIN_ALLOCATION) {
                uint256 fee = (amounts[i] * managementFee) / BASIS_POINTS;
                uint256 netAmount = amounts[i] - fee;
                _depositToRWA(protocols[i], netAmount, isLeveraged[i] && allowLeverage, correlationId);
                allocations[protocols[i]] = Allocation(
                    protocols[i],
                    netAmount,
                    rwaYield.getRWAYield(protocols[i]),
                    block.timestamp,
                    isLeveraged[i] && allowLeverage
                );
                stablecoin.safeTransfer(feeRecipient, fee);
                stakingManager.earnPoints(msg.sender, netAmount, true);
                emit AIAllocationUpdated(protocols[i], netAmount, isLeveraged[i] && allowLeverage, correlationId);
                emit DepositRWA(protocols[i], netAmount, fee, isLeveraged[i] && allowLeverage, correlationId);
            }
        }

        // Testing Note: Test pagination, full withdrawals, reallocation failures, and correlation ID tracing.
    }

    /**
     * @notice Withdraws from RWA protocol for YieldOptimizer.sol.
     * @param protocol Protocol address
     * @param amount Amount to withdraw
     * @param correlationId Unique ID for event tracing
     * @return withdrawn Amount withdrawn
     */
    function withdrawForYieldOptimizer(address protocol, uint256 amount, bytes32 correlationId)
        external
        nonReentrant
        returns (uint256)
    {
        require(msg.sender == owner(), "Only YieldOptimizer");
        return _withdrawFromRWA(protocol, amount, true, correlationId);

        // Testing Note: Test withdrawals with insufficient balances, leverage unwinding failures, and correlation ID tracing.
    }

    /**
     * @notice Internal function to deposit to RWA protocol with optional leverage.
     * @param protocol Protocol address
     * @param amount Amount to deposit
     * @param isLeveraged Whether to apply leverage
     * @param correlationId Unique ID for event tracing
     */
    function _depositToRWA(address protocol, uint256 amount, bool isLeveraged, bytes32 correlationId) internal {
        require(_isValidProtocol(protocol), "Invalid protocol");
        require(amount > 0, "Amount must be > 0");
        require(rwaYield.getAvailableLiquidity(protocol) >= minRWALiquidityThreshold, "Insufficient liquidity");

        stablecoin.safeApprove(protocol, 0);
        stablecoin.safeApprove(protocol, amount);
        rwaYield.depositToRWA(protocol, amount);
        rwaBalances[protocol] += amount;
        totalRWABalance += amount;

        if (isLeveraged && _assessLeverageViability(protocol, amount)) {
            uint256 ltv = flyingTulip.getLTV(protocol, amount);
            ltv = ltv > MAX_LTV ? MAX_LTV : ltv;
            uint256 borrowAmount = (amount * ltv) / BASIS_POINTS;
            if (borrowAmount > 0 && looperCore.checkLiquidationRisk(protocol, amount, borrowAmount, true)) {
                looperCore.applyLeverage(protocol, amount, ltv, true);
            } else {
                isLeveraged = false; // Disable leverage if risk check fails
            }
        } else {
            isLeveraged = false;
        }

        // Testing Note: Test leverage application, insufficient liquidity, and failed deposits.
    }

    /**
     * @notice Internal function to withdraw from RWA protocol with leverage repayment.
     * @param protocol Protocol address
     * @param amount Amount to withdraw
     * @param isForYieldOptimizer Whether the withdrawal is for YieldOptimizer
     * @param correlationId Unique ID for event tracing
     * @return withdrawn Amount withdrawn
     */
    function _withdrawFromRWA(address protocol, uint256 amount, bool isForYieldOptimizer, bytes32 correlationId)
        internal
        returns (uint256)
    {
        require(_isValidProtocol(protocol), "Invalid protocol");
        require(amount > 0 && amount <= rwaBalances[protocol], "Invalid amount");

        Allocation storage alloc = allocations[protocol];
        if (alloc.isLeveraged) {
            uint256 ltv = flyingTulip.getLTV(protocol, alloc.amount);
            uint256 repayAmount = (amount * ltv) / BASIS_POINTS;
            looperCore.unwindLeverage(protocol, repayAmount, true);
            alloc.isLeveraged = false;
        }

        uint256 balanceBefore = stablecoin.balanceOf(address(this));
        uint256 withdrawn = rwaYield.withdrawFromRWA(protocol, amount);
        require(stablecoin.balanceOf(address(this)) >= balanceBefore + withdrawn, "Withdrawal balance mismatch");

        uint256 profit = withdrawn > amount ? withdrawn - amount : 0;
        uint256 performanceFeeAmount = (profit * performanceFee) / BASIS_POINTS;
        uint256 netWithdrawn = withdrawn - performanceFeeAmount;

        rwaBalances[protocol] -= amount;
        totalRWABalance -= amount;
        alloc.amount -= amount;
        if (alloc.amount == 0) {
            delete allocations[protocol];
        }

        if (performanceFeeAmount > 0) {
            stablecoin.safeTransfer(feeRecipient, performanceFeeAmount);
        }
        if (!isForYieldOptimizer) {
            stakingManager.earnPoints(msg.sender, amount, false);
        }

        emit WithdrawRWA(protocol, amount, profit, performanceFeeAmount, correlationId);
        return netWithdrawn;

        // Testing Note: Test partial withdrawals, leverage unwinding, profit calculations, and balance mismatches.
    }

    /**
     * @notice Toggles leverage support.
     * @param status Leverage enabled or disabled
     */
    function toggleLeverage(bool status) external onlyGovernance {
        allowLeverage = status;
        emit LeverageToggled(status);

        // Testing Note: Test leverage toggle impact on new allocations and existing leveraged positions.
    }

    /**
     * @notice Updates AI Oracle address (fallback oracle).
     * @param newOracle New AI Oracle address
     */
    function updateAIOracle(address newOracle) external onlyGovernance {
        require(newOracle != address(0), "Invalid AI Oracle address");
        aiOracle = newOracle;
        emit AIOracleUpdated(newOracle);

        // Testing Note: Test oracle updates and unauthorized access.
    }

    /**
     * @notice Updates fee recipient address.
     * @param newRecipient New fee recipient address
     */
    function updateFeeRecipient(address newRecipient) external onlyGovernance {
        require(newRecipient != address(0), "Invalid fee recipient");
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(newRecipient);

        // Testing Note: Test fee recipient updates and fee transfers.
    }

    /**
     * @notice Updates management and performance fees.
     * @param newManagementFee New management fee in basis points
     * @param newPerformanceFee New performance fee in basis points
     */
    function updateFees(uint256 newManagementFee, uint256 newPerformanceFee) external onlyGovernance {
        require(newManagementFee <= 200, "Management fee too high"); // Max 2%
        require(newPerformanceFee <= 2000, "Performance fee too high"); // Max 20%
        managementFee = newManagementFee;
        performanceFee = newPerformanceFee;
        emit FeesUpdated(newManagementFee, newPerformanceFee);

        // Testing Note: Test fee updates and their impact on deposits/withdrawals.
    }

    /**
     * @notice Toggles emergency pause.
     */
    function pause() external onlyGovernance {
        isPaused = true;
        emit PauseToggled(true);

        // Testing Note: Test pause functionality and its impact on operations.
    }

    /**
     * @notice Unpauses the contract.
     */
    function unpause() external onlyGovernance {
        isPaused = false;
        emit PauseToggled(false);

        // Testing Note: Test unpause and resumption of operations.
    }

    /**
     * @notice Manual upkeep for RWA protocols.
     * @param correlationId Unique ID for event tracing
     */
    function manualUpkeep(bytes32 correlationId) external onlyGovernance {
        upkeepManager.manualUpkeep(true);
        emit ManualUpkeepTriggered(block.timestamp, correlationId);

        // Testing Note: Test upkeep triggers and their effects on protocol states.
    }

    /**
     * @notice Adds a new oracle to the registry.
     * @param oracle Oracle address
     * @param correlationId Unique ID for event tracing
     */
    function addOracle(address oracle, bytes32 correlationId) external onlyGovernance {
        require(oracle != address(0), "Invalid oracle address");
        require(oracles.length < maxOracles, "Max oracles reached");
        for (uint256 i = 0; i < oracles.length; i++) {
            require(oracles[i] != oracle, "Oracle already exists");
        }
        oracles.push(oracle);
        emit OracleAdded(oracle, correlationId);

        // Testing Note: Test oracle addition, max oracle limits, and duplicates.
    }

    /**
     * @notice Removes an oracle from the registry.
     * @param oracle Oracle address
     * @param correlationId Unique ID for event tracing
     */
    function removeOracle(address oracle, bytes32 correlationId) external onlyGovernance {
        for (uint256 i = 0; i < oracles.length; i++) {
            if (oracles[i] == oracle) {
                oracles[i] = oracles[oracles.length - 1];
                oracles.pop();
                emit OracleRemoved(oracle, correlationId);
                return;
            }
        }
        revert("Oracle not found");

        // Testing Note: Test oracle removal, non-existent oracles, and empty oracle list.
    }

    /**
     * @notice Toggles oracle circuit breaker.
     * @param status Circuit breaker status
     * @param correlationId Unique ID for event tracing
     */
    function toggleOracleCircuitBreaker(bool status, bytes32 correlationId) external onlyGovernance {
        oracleCircuitBreaker = status;
        emit OracleCircuitBreakerTriggered(status, correlationId);

        // Testing Note: Test circuit breaker impact on allocation and recommendation functions.
    }

    /**
     * @notice Updates hybrid model weights.
     * @param onChainWeight Weight for on-chain data (basis points)
     * @param correlationId Unique ID for event tracing
     */
    function updateHybridWeights(uint256 onChainWeight, bytes32 correlationId) external onlyGovernance {
        require(onChainWeight <= BASIS_POINTS, "Invalid weight");
        hybridWeightOnChain = onChainWeight;
        emit HybridWeightsUpdated(onChainWeight, correlationId);

        // Testing Note: Test weight updates and their impact on allocation recommendations.
    }

    /**
     * @notice AI-driven allocation recommendations using hybrid AI model.
     * @param totalAmount Total amount to allocate
     * @return protocols List of recommended protocols
     * @return amounts Recommended amounts
     * @return isLeveraged Leverage flags
     */
    function getRecommendedAllocations(uint256 totalAmount)
        external
        view
        returns (address[] memory protocols, uint256[] memory amounts, bool[] memory isLeveraged)
    {
        address[] memory allProtocols = registry.getActiveProtocols(true);
        uint256[] memory apys = new uint256[](allProtocols.length);
        protocols = new address[](allProtocols.length);
        amounts = new uint256[](allProtocols.length);
        isLeveraged = new bool[](allProtocols.length);
        uint256 totalWeightedAPY;

        // Fetch on-chain and off-chain APYs
        for (uint256 i = 0; i < allProtocols.length; i++) {
            uint256 onChainAPY = riskManager.getRiskAdjustedAPY(allProtocols[i], sonicProtocol.getSonicAPY(allProtocols[i]));
            uint256 offChainAPY = _aggregateOraclePredictions(allProtocols[i]).predictedAPY;
            // Hybrid model: Combine on-chain and off-chain APYs
            apys[i] = (onChainAPY * hybridWeightOnChain + offChainAPY * (BASIS_POINTS - hybridWeightOnChain)) / BASIS_POINTS;
        }

        // Calculate risk-adjusted weights
        uint256[] memory weights = new uint256[](allProtocols.length);
        for (uint256 i = 0; i < allProtocols.length; i++) {
            if (!_isValidProtocol(allProtocols[i]) || !_validateAPY(apys[i], allProtocols[i])) {
                continue;
            }
            uint256 riskScore = _aggregateOraclePredictions(allProtocols[i]).riskScore;
            if (riskScore == 0) {
                riskScore = registry.getProtocolRiskScore(allProtocols[i]); // Fallback to on-chain
            }
            uint256 adjustedAPY = (apys[i] * (10000 - riskScore)) / 10000;
            weights[i] = adjustedAPY;
            totalWeightedAPY += adjustedAPY;
        }

        uint256 allocated;
        uint256 index;
        for (uint256 i = 0; i < allProtocols.length; i++) {
            if (weights[i] == 0) {
                continue;
            }
            uint256 amount = (totalAmount * weights[i]) / (totalWeightedAPY == 0 ? 1 : totalWeightedAPY);
            if (amount < MIN_ALLOCATION) {
                continue;
            }
            protocols[index] = allProtocols[i];
            amounts[index] = amount;
            isLeveraged[index] = allowLeverage && _assessLeverageViability(allProtocols[i], amount);
            allocated += amount;
            index++;
        }

        // Resize arrays
        assembly {
            mstore(protocols, index)
            mstore(amounts, index)
            mstore(isLeveraged, index)
        }

        // Adjust for rounding errors
        if (allocated < totalAmount && index > 0) {
            amounts[0] += totalAmount - allocated;
        }

        // Testing Note: Test hybrid model with varying oracle responses, zero off-chain data, and circuit breaker active.
    }

    /**
     * @notice Provides a description of the allocation logic with hybrid AI model.
     * @param totalAmount Total amount to allocate
     * @param correlationId Unique ID for event tracing
     * @return logicDescription Description of allocation logic
     */
    function getAllocationLogic(uint256 totalAmount, bytes32 correlationId) external returns (string memory) {
        (address[] memory protocols, uint256[] memory amounts, bool[] memory isLeveraged) = getRecommendedAllocations(totalAmount);
        string memory logic = "Hybrid AI allocation: 50% on-chain risk-adjusted APYs, 50% off-chain AI predictions via multi-oracle. Allocations: ";
        for (uint256 i = 0; i < protocols.length; i++) {
            if (amounts[i] == 0) continue;
            logic = string(abi.encodePacked(
                logic,
                "Protocol ",
                _addressToString(protocols[i]),
                ": ",
                _uintToString(amounts[i]),
                " (",
                isLeveraged[i] ? "leveraged" : "non-leveraged",
                "), "
            ));
            emit AIRecommendedAllocation(protocols[i], amounts[i], isLeveraged[i], correlationId);
        }
        emit AllocationLogicUpdated(logic, correlationId);
        return logic;

        // Testing Note: Test logic description accuracy, oracle influence, and event emissions.
    }

    /**
     * @notice Retrieves APY for all supported protocols using hybrid model.
     * @return protocols List of protocols
     * @return apys Corresponding APYs
     */
    function getAllYields() public view returns (address[] memory, uint256[] memory) {
        address[] memory protocols = registry.getActiveProtocols(true);
        uint256[] memory apys = new uint256[](protocols.length);
        for (uint256 i = 0; i < protocols.length; i++) {
            address protocol = protocols[i];
            uint256 onChainAPY = riskManager.getRiskAdjustedAPY(protocol, sonicProtocol.getSonicAPY(protocol));
            uint256 offChainAPY = _aggregateOraclePredictions(protocol).predictedAPY;
            uint256 hybridAPY = (onChainAPY * hybridWeightOnChain + offChainAPY * (BASIS_POINTS - hybridWeightOnChain)) / BASIS_POINTS;
            apys[i] = hybridAPY > 0 && hybridAPY <= MAX_APY ? hybridAPY : 500; // Fallback to 5%
        }
        return (protocols, apys);

        // Testing Note: Test hybrid APY calculations with missing or invalid oracle data and fallback behavior.
    }

    /**
     * @notice Aggregates predictions from multiple oracles for a protocol.
     * @param protocol Protocol address
     * @return prediction Aggregated prediction
     */
    function _aggregateOraclePredictions(address protocol) internal view returns (OraclePrediction memory) {
        if (oracleCircuitBreaker || oracles.length < minOracleResponses) {
            return OraclePrediction(0, 0, 0, false); // Fallback to on-chain data
        }

        uint256 validResponses;
        uint256[] memory predictedAPYs = new uint256[](oracles.length);
        uint256[] memory riskScores = new uint256[](oracles.length);
        for (uint256 i = 0; i < oracles.length; i++) {
            try IOracle(oracles[i]).getAIPredictions(protocol) returns (uint256 predictedAPY, uint256 riskScore, uint256 timestamp) {
                if (
                    timestamp > block.timestamp - oracleDataTimeout &&
                    predictedAPY <= MAX_APY &&
                    riskScore <= BASIS_POINTS
                ) {
                    predictedAPYs[validResponses] = predictedAPY;
                    riskScores[validResponses] = riskScore;
                    validResponses++;
                }
            } catch {
                // Skip failed oracles
            }
        }

        if (validResponses < minOracleResponses) {
            return OraclePrediction(0, 0, 0, false); // Fallback to on-chain data
        }

        // Use median for robustness
        uint256 medianAPY = _calculateMedian(predictedAPYs, validResponses);
        uint256 medianRiskScore = _calculateMedian(riskScores, validResponses);
        return OraclePrediction(medianAPY, medianRiskScore, block.timestamp, true);

        // Testing Note: Test aggregation with partial oracle failures, stale data, and insufficient responses.
    }

    /**
     * @notice Calculates the median of an array (simplified for gas efficiency).
     * @param values Array of values
     * @param count Number of valid values
     * @return median Median value
     */
    function _calculateMedian(uint256[] memory values, uint256 count) internal pure returns (uint256) {
        // Simple bubble sort for small arrays (maxOracles <= 5)
        for (uint256 i = 0; i < count - 1; i++) {
            for (uint256 j = 0; j < count - i - 1; j++) {
                if (values[j] > values[j + 1]) {
                    (values[j], values[j + 1]) = (values[j + 1], values[j]);
                }
            }
        }
        return count % 2 == 0 ? (values[count / 2 - 1] + values[count / 2]) / 2 : values[count / 2];

        // Testing Note: Test median calculation with odd/even number of values and edge cases.
    }

    /**
     * @notice Validates a protocol for allocation.
     * @param protocol Protocol address
     * @return True if valid
     */
    function _isValidProtocol(address protocol) internal view returns (bool) {
        return registry.isValidProtocol(protocol) &&
               rwaYield.isRWA(protocol) &&
               sonicProtocol.isSonicCompliant(protocol) &&
               rwaYield.getAvailableLiquidity(protocol) >= minRWALiquidityThreshold;

        // Testing Note: Test protocol validation with invalid or non-compliant protocols.
    }

    /**
     * @notice Validates APY data for a protocol.
     * @param apy APY value
     * @param protocol Protocol address
     * @return True if valid
     */
    function _validateAPY(uint256 apy, address protocol) internal view returns (bool) {
        uint256 liquidity = rwaYield.getAvailableLiquidity(protocol);
        return apy > 0 && apy <= MAX_APY && liquidity >= minRWALiquidityThreshold;

        // Testing Note: Test APY validation with edge cases like zero or excessive APYs.
    }

    /**
     * @notice Assesses leverage viability for RWA protocols.
     * @param protocol Protocol address
     * @param amount Amount to leverage
     * @return True if leverage is viable
     */
    function _assessLeverageViability(address protocol, uint256 amount) internal view returns (bool) {
        uint256 ltv = flyingTulip.getLTV(protocol, amount);
        return ltv <= MAX_LTV &&
               riskManager.assessLeverageViability(protocol, amount, ltv, true) &&
               looperCore.checkLiquidationRisk(protocol, amount, (amount * ltv) / BASIS_POINTS, true);

        // Testing Note: Test leverage viability with high LTVs and liquidation risks.
    }

    /**
     * @notice Returns total RWA balance.
     * @return Total RWA balance
     */
    function getTotalRWABalance() external view returns (uint256) {
        return totalRWABalance;

        // Testing Note: Test balance accuracy after deposits and withdrawals.
    }

    /**
     * @notice Returns supported protocols.
     * @return List of supported protocols
     */
    function getSupportedProtocols() external view returns (address[] memory) {
        return registry.getActiveProtocols(true);

        // Testing Note: Test protocol list accuracy with added/removed protocols.
    }

    /**
     * @notice Returns active allocations.
     * @return List of active allocations
     */
    function getAllocations() external view returns (Allocation[] memory) {
        address[] memory protocols = registry.getActiveProtocols(true);
        Allocation[] memory result = new Allocation[](protocols.length);
        for (uint256 i = 0; i < protocols.length; i++) {
            result[i] = allocations[protocols[i]];
        }
        return result;

        // Testing Note: Test allocation retrieval with zero or partial allocations.
    }

    /**
     * @notice Returns list of registered oracles.
     * @return List of oracles
     */
    function getOracles() external view returns (address[] memory) {
        return oracles;

        // Testing Note: Test oracle list retrieval with empty or full oracle sets.
    }

    /**
     * @notice Helper function to convert address to string.
     * @param addr Address to convert
     * @return String representation
     */
    function _addressToString(address addr) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(42);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            str[2 + i * 2] = alphabet[uint8(addr >> (8 * (19 - i)) & 0xFF) >> 4];
            str[3 + i * 2] = alphabet[uint8(addr >> (8 * (19 - i)) & 0x0F)];
        }
        return string(str);
    }

    /**
     * @notice Helper function to convert uint to string.
     * @param value Value to convert
     * @return String representation
     */
    function _uintToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits--;
            buffer[digits] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    /**
     * @notice Fallback function to prevent accidental ETH deposits.
     */
    receive() external payable {
        revert("ETH deposits not allowed");

        // Testing Note: Test fallback function with ETH transfers.
    }
}
