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

// Interfaces (unchanged)
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

interface IOracle {
    function getAIPredictions(address protocol) external view returns (uint256 predictedAPY, uint256 riskScore, uint256 timestamp);
}

/**
 * @title AIYieldOptimizer
 * @notice A delegated contract for AI-driven RWA yield optimization with hybrid AI model and multi-oracle integration.
 * @dev Uses UUPS proxy, supports Sonic’s Fee Monetization, native USDC, RedStone oracles, and Sonic Points.
 *      Integrates with DeFiYield.sol for cross-protocol yield aggregation.
 */
contract AIYieldOptimizer is UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using PRBMathUD60x18 for uint256;

    // State variables
    IERC20 public immutable stablecoin;
    IRWAYield public immutable rwaYield;
    ISonicProtocol public immutable sonicProtocol;
    IFlyingTulip public immutable flyingTulip;
    IRegistry public registry;
    IRiskManager public riskManager;
    ILooperCore public looperCore;
    IStakingManager public stakingManager;
    IGovernanceManager public governanceManager;
    IUpkeepManager public upkeepManager;
    address public aiOracle;
    address public feeRecipient;
    uint256 public managementFee;
    uint256 public performanceFee;
    uint256 public totalRWABalance;
    mapping(address => uint256) public rwaBalances;
    mapping(address => Allocation) public allocations;
    bool public allowLeverage;
    uint256 public minRWALiquidityThreshold;
    bool public isPaused;

    // Multi-Oracle State
    address[] public oracles;
    mapping(address => uint256) public oracleWeights; // Oracle reliability weights (basis points)
    uint256 public maxOracles;
    uint256 public minOracleResponses;
    uint256 public oracleDataTimeout;
    uint256 public maxTimestampVariance; // Max allowed timestamp difference between oracles
    uint256 public hybridWeightOnChain;
    bool public oracleCircuitBreaker;

    // Fee Timelock
    struct FeeProposal {
        uint256 managementFee;
        uint256 performanceFee;
        uint256 proposedAt;
        bool executed;
    }
    mapping(bytes32 => FeeProposal) public feeProposals;
    uint256 public constant FEE_TIMELOCK = 2 days;

    // Protocol Cache for Gas Optimization
    struct ProtocolCacheData {
        bool isValid;
        uint256 liquidity;
        uint256 apy;
        uint256 riskScore;
        uint256 lastUpdated;
    }
    mapping(address => ProtocolCacheData) public protocolCache;

    // Pagination Constants
    uint256 private constant MAX_PROTOCOLS_PER_PAGE = 10;
    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant MAX_PROTOCOLS = 10;
    uint256 private constant MAX_LTV = 8000;
    uint256 private constant MAX_APY = 10000;
    uint256 private constant MIN_ALLOCATION = 1e16;
    uint256 private constant SECONDS_PER_YEAR = 365 days;
    uint256 private constant FIXED_POINT_SCALE = 1e18;
    uint256 private constant MAX_EXP_INPUT = 10e18;
    uint256 private constant MIN_PROFIT = 1e6;

    // Structs
    struct Allocation {
        address protocol;
        uint256 amount;
        uint256 apy;
        uint256 lastUpdated;
        bool isLeveraged;
    }

    struct OraclePrediction {
        uint256 predictedAPY;
        uint256 riskScore;
        uint256 timestamp;
        bool isValid;
    }

    struct ProtocolYieldWithMetadata {
        address protocol;
        uint256 apy;
        uint256 riskScore;
        bool isActive;
    }

    // Events
    event DepositRWA(address indexed protocol, uint256 amount, uint256 fee, bool isLeveraged, bytes32 indexed correlationId);
    event WithdrawRWA(address indexed protocol, uint256 amount, uint256 profit, uint256 fee, bytes32 indexed correlationId);
    event AIAllocationUpdated(address indexed protocol, uint256 amount, bool isLeveraged, bytes32 indexed correlationId);
    event AIOracleUpdated(address indexed newOracle, bytes32 indexed correlationId);
    event FeeRecipientUpdated(address indexed newRecipient, bytes32 indexed correlationId);
    event FeesUpdated(uint256 managementFee, uint256 performanceFee, bytes32 indexed correlationId);
    event FeeProposalCreated(bytes32 indexed proposalId, uint256 managementFee, uint256 performanceFee, bytes32 indexed correlationId);
    event FeeProposalExecuted(bytes32 indexed proposalId, bytes32 indexed correlationId);
    event LeverageToggled(bool status, bytes32 indexed correlationId);
    event PauseToggled(bool status, bytes32 indexed correlationId);
    event AIRecommendedAllocation(address indexed protocol, uint256 amount, bool isLeveraged, bytes32 indexed correlationId);
    event AllocationLogicUpdated(string logicDescription, bytes32 indexed correlationId);
    event ManualUpkeepTriggered(uint256 timestamp, bytes32 indexed correlationId);
    event OracleAdded(address indexed oracle, uint256 weight, bytes32 indexed correlationId);
    event OracleRemoved(address indexed oracle, bytes32 indexed correlationId);
    event OracleCircuitBreakerTriggered(bool status, bytes32 indexed correlationId);
    event HybridWeightsUpdated(uint256 onChainWeight, bytes32 indexed correlationId);
    event ProtocolCacheUpdated(address indexed protocol, uint256 liquidity, uint256 apy, uint256 riskScore, bytes32 indexed correlationId);
    event ErrorLogged(string reason, bytes32 indexed correlationId);

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

    constructor(
        address _stablecoin,
        address _rwaYield,
        address _sonicProtocol,
        address _flyingTulip
    ) {
        require(_stablecoin != address(0), "Invalid stablecoin address");
        require(_rwaYield != address(0), "Invalid RWAYield address");
        require(_sonicProtocol != address(0), "Invalid SonicProtocol address");
        require(_flyingTulip != address(0), "Invalid FlyingTulip address");

        stablecoin = IERC20(_stablecoin);
        rwaYield = IRWAYield(_rwaYield);
        sonicProtocol = ISonicProtocol(_sonicProtocol);
        flyingTulip = IFlyingTulip(_flyingTulip);
        _disableInitializers();
    }

    function initialize(
        address _registry,
        address _riskManager,
        address _looperCore,
        address _stakingManager,
        address _governanceManager,
        address _upkeepManager,
        address _aiOracle,
        address _feeRecipient
    ) external initializer {
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

        registry = IRegistry(_registry);
        riskManager = IRiskManager(_riskManager);
        looperCore = ILooperCore(_looperCore);
        stakingManager = IStakingManager(_stakingManager);
        governanceManager = IGovernanceManager(_governanceManager);
        upkeepManager = IUpkeepManager(_upkeepManager);
        aiOracle = _aiOracle;
        feeRecipient = _feeRecipient;
        managementFee = 50;
        performanceFee = 1000;
        allowLeverage = true;
        minRWALiquidityThreshold = 1e18;

        maxOracles = 5;
        minOracleResponses = 2;
        oracleDataTimeout = 1 hours;
        maxTimestampVariance = 15 minutes;
        hybridWeightOnChain = 5000;
        oracleCircuitBreaker = false;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /**
     * @notice Submits AI allocation recommendations with pagination.
     * @param protocols List of protocols.
     * @param amounts Amounts to allocate.
     * @param isLeveraged Leverage flags.
     * @param correlationId Unique ID for tracing.
     * @param start Starting index.
     * @param limit Number of protocols to process.
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
            if (!_isValidProtocol(protocols[i], correlationId)) {
                _revertReason("Invalid protocol", correlationId);
            }
            if (!flyingTulip.isProtocolHealthy(protocols[i])) {
                _revertReason("Protocol not healthy", correlationId);
            }
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
                    _getCachedAPY(protocols[i], correlationId),
                    block.timestamp,
                    isLeveraged[i] && allowLeverage
                );
                stablecoin.safeTransfer(feeRecipient, fee);
                stakingManager.earnPoints(msg.sender, netAmount, true);
                emit AIAllocationUpdated(protocols[i], netAmount, isLeveraged[i] && allowLeverage, correlationId);
                emit DepositRWA(protocols[i], netAmount, fee, isLeveraged[i] && allowLeverage, correlationId);
            }
        }
    }

    /**
     * @notice Rebalances portfolio with pagination.
     * @param protocols List of protocols.
     * @param amounts Amounts to allocate.
     * @param isLeveraged Leverage flags.
     * @param correlationId Unique ID for tracing.
     * @param start Starting index.
     * @param limit Number of protocols to process.
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

        // Batch withdraw from all protocols
        batchWithdraw(registry.getActiveProtocols(true), correlationId);

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
                    _getCachedAPY(protocols[i], correlationId),
                    block.timestamp,
                    isLeveraged[i] && allowLeverage
                );
                stablecoin.safeTransfer(feeRecipient, fee);
                stakingManager.earnPoints(msg.sender, netAmount, true);
                emit AIAllocationUpdated(protocols[i], netAmount, isLeveraged[i] && allowLeverage, correlationId);
                emit DepositRWA(protocols[i], netAmount, fee, isLeveraged[i] && allowLeverage, correlationId);
            }
        }
    }

    /**
     * @notice Batch withdraws from multiple protocols.
     * @param protocols List of protocols to withdraw from.
     * @param correlationId Unique ID for tracing.
     */
    function batchWithdraw(address[] memory protocols, bytes32 correlationId) public nonReentrant whenNotPaused onlyAIOracleOrYieldOptimizer {
        for (uint256 i = 0; i < protocols.length; i++) {
            if (rwaBalances[protocols[i]] > 0) {
                _withdrawFromRWA(protocols[i], rwaBalances[protocols[i]], false, correlationId);
            }
        }
    }

    function withdrawForYieldOptimizer(address protocol, uint256 amount, bytes32 correlationId)
        external
        nonReentrant
        returns (uint256)
    {
        require(msg.sender == owner(), "Only YieldOptimizer");
        return _withdrawFromRWA(protocol, amount, true, correlationId);
    }

    function _depositToRWA(address protocol, uint256 amount, bool isLeveraged, bytes32 correlationId) internal {
        if (!_isValidProtocol(protocol, correlationId)) {
            _revertReason("Invalid protocol", correlationId);
        }
        require(amount > 0, "Amount must be > 0");
        ProtocolCacheData memory cache = protocolCache[protocol];
        if (cache.lastUpdated < block.timestamp - oracleDataTimeout || cache.liquidity < minRWALiquidityThreshold) {
            _updateProtocolCache(protocol, correlationId);
            cache = protocolCache[protocol];
        }
        require(cache.liquidity >= minRWALiquidityThreshold, "Insufficient liquidity");

        stablecoin.safeApprove(protocol, 0);
        stablecoin.safeApprove(protocol, amount);
        rwaYield.depositToRWA(protocol, amount);
        rwaBalances[protocol] += amount;
        totalRWABalance += amount;

        if (isLeveraged && _assessLeverageViability(protocol, amount, correlationId)) {
            uint256 ltv = flyingTulip.getLTV(protocol, amount);
            ltv = ltv > MAX_LTV ? MAX_LTV : ltv;
            uint256 borrowAmount = (amount * ltv) / BASIS_POINTS;
            if (borrowAmount > 0 && looperCore.checkLiquidationRisk(protocol, amount, borrowAmount, true)) {
                looperCore.applyLeverage(protocol, amount, ltv, true);
            } else {
                isLeveraged = false;
            }
        } else {
            isLeveraged = false;
        }
    }

    function _withdrawFromRWA(address protocol, uint256 amount, bool isForYieldOptimizer, bytes32 correlationId)
        internal
        returns (uint256)
    {
        if (!_isValidProtocol(protocol, correlationId)) {
            _revertReason("Invalid protocol", correlationId);
        }
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
    }

    /**
     * @notice Proposes dynamic fee adjustments based on market conditions.
     * @param newManagementFee Proposed management fee.
     * @param newPerformanceFee Proposed performance fee.
     * @param correlationId Unique ID for tracing.
     */
    function proposeDynamicFees(uint256 newManagementFee, uint256 newPerformanceFee, bytes32 correlationId) external onlyGovernance {
        require(newManagementFee <= 200, "Management fee too high");
        require(newPerformanceFee <= 2000, "Performance fee too high");
        bytes32 proposalId = keccak256(abi.encodePacked(newManagementFee, newPerformanceFee, block.timestamp));
        feeProposals[proposalId] = FeeProposal({
            managementFee: newManagementFee,
            performanceFee: newPerformanceFee,
            proposedAt: block.timestamp,
            executed: false
        });
        emit FeeProposalCreated(proposalId, newManagementFee, newPerformanceFee, correlationId);
    }

    /**
     * @notice Executes a fee proposal after timelock.
     * @param proposalId Proposal ID.
     * @param correlationId Unique ID for tracing.
     */
    function executeFeeProposal(bytes32 proposalId, bytes32 correlationId) external onlyGovernance {
        FeeProposal storage proposal = feeProposals[proposalId];
        require(proposal.proposedAt > 0, "Proposal does not exist");
        require(!proposal.executed, "Proposal already executed");
        require(block.timestamp >= proposal.proposedAt + FEE_TIMELOCK, "Timelock not expired");
        managementFee = proposal.managementFee;
        performanceFee = proposal.performanceFee;
        proposal.executed = true;
        emit FeesUpdated(managementFee, performanceFee, correlationId);
        emit FeeProposalExecuted(proposalId, correlationId);
    }

    function toggleLeverage(bool status, bytes32 correlationId) external onlyGovernance {
        allowLeverage = status;
        emit LeverageToggled(status, correlationId);
    }

    function updateAIOracle(address newOracle, bytes32 correlationId) external onlyGovernance {
        require(newOracle != address(0), "Invalid AI Oracle address");
        aiOracle = newOracle;
        emit AIOracleUpdated(newOracle, correlationId);
    }

    function updateFeeRecipient(address newRecipient, bytes32 correlationId) external onlyGovernance {
        require(newRecipient != address(0), "Invalid fee recipient");
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(newRecipient, correlationId);
    }

    function pause(bytes32 correlationId) external onlyGovernance {
        isPaused = true;
        emit PauseToggled(true, correlationId);
    }

    function unpause(bytes32 correlationId) external onlyGovernance {
        isPaused = false;
        emit PauseToggled(false, correlationId);
    }

    function manualUpkeep(bytes32 correlationId) external onlyGovernance {
        upkeepManager.manualUpkeep(true);
        emit ManualUpkeepTriggered(block.timestamp, correlationId);
    }

    function addOracle(address oracle, uint256 weight, bytes32 correlationId) external onlyGovernance {
        require(oracle != address(0), "Invalid oracle address");
        require(weight > 0 && weight <= BASIS_POINTS, "Invalid weight");
        require(oracles.length < maxOracles, "Max oracles reached");
        for (uint256 i = 0; i < oracles.length; i++) {
            require(oracles[i] != oracle, "Oracle already exists");
        }
        oracles.push(oracle);
        oracleWeights[oracle] = weight;
        emit OracleAdded(oracle, weight, correlationId);
    }

    function removeOracle(address oracle, bytes32 correlationId) external onlyGovernance {
        for (uint256 i = 0; i < oracles.length; i++) {
            if (oracles[i] == oracle) {
                delete oracleWeights[oracle];
                oracles[i] = oracles[oracles.length - 1];
                oracles.pop();
                emit OracleRemoved(oracle, correlationId);
                return;
            }
        }
        _revertReason("Oracle not found", correlationId);
    }

    function toggleOracleCircuitBreaker(bool status, bytes32 correlationId) external onlyGovernance {
        oracleCircuitBreaker = status;
        emit OracleCircuitBreakerTriggered(status, correlationId);
    }

    function setAIHybridWeights(uint256 onChainWeight, bytes32 correlationId) external onlyGovernance {
        require(onChainWeight <= BASIS_POINTS, "Invalid weight");
        hybridWeightOnChain = onChainWeight;
        emit HybridWeightsUpdated(onChainWeight, correlationId);
    }

    function getRecommendedAllocations(uint256 totalAmount, uint256 start, uint256 limit)
        external
        view
        returns (address[] memory protocols, uint256[] memory amounts, bool[] memory isLeveraged)
    {
        address[] memory allProtocols = registry.getActiveProtocols(true);
        require(start < allProtocols.length, "Invalid start index");

        if (limit > MAX_PROTOCOLS_PER_PAGE) {
            limit = MAX_PROTOCOLS_PER_PAGE;
        }
        uint256 end = start + limit > allProtocols.length ? allProtocols.length : start + limit;
        uint256 resultCount = end - start;

        protocols = new address[](resultCount);
        amounts = new uint256[](resultCount);
        isLeveraged = new bool[](resultCount);
        uint256[] memory apys = new uint256[](resultCount);
        uint256[] memory priorities = new uint256[](resultCount); // Priority based on liquidity and risk
        uint256 totalWeightedScore;

        for (uint256 i = start; i < end; i++) {
            uint256 index = i - start;
            protocols[index] = allProtocols[i];
            ProtocolCacheData memory cache = protocolCache[allProtocols[i]];
            if (cache.lastUpdated < block.timestamp - oracleDataTimeout) {
                // Cache expired, but we avoid updating in view function
                apys[index] = 500; // Fallback APY
                priorities[index] = 0;
                continue;
            }
            uint256 onChainAPY = riskManager.getRiskAdjustedAPY(allProtocols[i], sonicProtocol.getSonicAPY(allProtocols[i]));
            uint256 offChainAPY = _aggregateOraclePredictions(allProtocols[i]).predictedAPY;
            apys[index] = (onChainAPY * hybridWeightOnChain + offChainAPY * (BASIS_POINTS - hybridWeightOnChain)) / BASIS_POINTS;
            uint256 riskScore = cache.riskScore > 0 ? cache.riskScore : registry.getProtocolRiskScore(allProtocols[i]);
            // Priority: Higher liquidity, lower risk increases score
            priorities[index] = (apys[index] * cache.liquidity) / (riskScore == 0 ? 1 : riskScore);
            totalWeightedScore += priorities[index];
        }

        uint256 allocated;
        uint256 index;
        for (uint256 i = 0; i < resultCount; i++) {
            if (priorities[i] == 0 || !_validateAPY(apys[i], protocols[i])) {
                continue;
            }
            uint256 amount = (totalAmount * priorities[i]) / (totalWeightedScore == 0 ? 1 : totalWeightedScore);
            if (amount < MIN_ALLOCATION) {
                continue;
            }
            protocols[index] = protocols[i];
            amounts[index] = amount;
            isLeveraged[index] = allowLeverage && _assessLeverageViability(protocols[i], amount, bytes32(0));
            allocated += amount;
            index++;
        }

        assembly {
            mstore(protocols, index)
            mstore(amounts, index)
            mstore(isLeveraged, index)
        }

        if (allocated < totalAmount && index > 0) {
            amounts[0] += totalAmount - allocated;
        }
    }

    function getAllocationLogic(uint256 totalAmount, uint256 start, uint256 limit, bytes32 correlationId) external returns (string memory) {
        (address[] memory protocols, uint256[] memory amounts, bool[] memory isLeveraged) = getRecommendedAllocations(totalAmount, start, limit);
        string memory logic = string(abi.encodePacked(
            "Hybrid AI allocation: ",
            _uintToString(hybridWeightOnChain / 100),
            "% on-chain, ",
            _uintToString((BASIS_POINTS - hybridWeightOnChain) / 100),
            "% off-chain. Allocations: "
        ));
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
    }

    function getAllYields(uint256 start, uint256 limit) public view returns (address[] memory, uint256[] memory) {
        address[] memory allProtocols = registry.getActiveProtocols(true);
        require(start < allProtocols.length, "Invalid start index");

        if (limit > MAX_PROTOCOLS_PER_PAGE) {
            limit = MAX_PROTOCOLS_PER_PAGE;
        }
        uint256 end = start + limit > allProtocols.length ? allProtocols.length : start + limit;
        uint256 resultCount = end - start;

        address[] memory protocols = new address[](resultCount);
        uint256[] memory apys = new uint256[](resultCount);

        for (uint256 i = start; i < end; i++) {
            uint256 index = i - start;
            protocols[index] = allProtocols[i];
            apys[index] = _getCachedAPY(protocols[index], bytes32(0));
        }
        return (protocols, apys);
    }

    function getProtocolYieldsDashboard(uint256 start, uint256 limit)
        external
        view
        returns (ProtocolYieldWithMetadata[] memory yields, uint256 totalProtocols)
    {
        address[] memory allProtocols = registry.getActiveProtocols(true);
        totalProtocols = allProtocols.length;
        require(start < totalProtocols, "Invalid start index");

        if (limit > MAX_PROTOCOLS_PER_PAGE) {
            limit = MAX_PROTOCOLS_PER_PAGE;
        }
        uint256 end = start + limit > totalProtocols ? totalProtocols : start + limit;
        uint256 resultCount = end - start;

        ProtocolYieldWithMetadata[] memory result = new ProtocolYieldWithMetadata[](resultCount);

        for (uint256 i = start; i < end; i++) {
            address protocol = allProtocols[i];
            ProtocolCacheData memory cache = protocolCache[protocol];
            uint256 apy;
            uint256 riskScore;
            if (cache.lastUpdated < block.timestamp - oracleDataTimeout || !_isValidProtocol(protocol, bytes32(0))) {
                apy = 500;
                riskScore = 0;
                result[i - start] = ProtocolYieldWithMetadata({
                    protocol: protocol,
                    apy: apy,
                    riskScore: riskScore,
                    isActive: false
                });
                continue;
            }
            apy = cache.apy;
            riskScore = cache.riskScore;
            result[i - start] = ProtocolYieldWithMetadata({
                protocol: protocol,
                apy: apy > 0 && apy <= MAX_APY ? apy : 500,
                riskScore: riskScore,
                isActive: true
            });
        }

        return (result, totalProtocols);
    }

    /**
     * @notice Updates protocol cache data.
     * @param protocol Protocol address.
     * @param correlationId Unique ID for tracing.
     */
    function _updateProtocolCache(address protocol, bytes32 correlationId) internal {
        if (!_isValidProtocol(protocol, correlationId)) {
            _revertReason("Invalid protocol for cache update", correlationId);
        }
        uint256 liquidity = rwaYield.getAvailableLiquidity(protocol);
        uint256 onChainAPY = riskManager.getRiskAdjustedAPY(protocol, sonicProtocol.getSonicAPY(protocol));
        uint256 offChainAPY = _aggregateOraclePredictions(protocol).predictedAPY;
        uint256 hybridAPY = (onChainAPY * hybridWeightOnChain + offChainAPY * (BASIS_POINTS - hybridWeightOnChain)) / BASIS_POINTS;
        uint256 riskScore = _aggregateOraclePredictions(protocol).riskScore;
        if (riskScore == 0) {
            riskScore = registry.getProtocolRiskScore(protocol);
        }
        protocolCache[protocol] = ProtocolCacheData({
            isValid: true,
            liquidity: liquidity,
            apy: hybridAPY > 0 && hybridAPY <= MAX_APY ? hybridAPY : 500,
            riskScore: riskScore,
            lastUpdated: block.timestamp
        });
        emit ProtocolCacheUpdated(protocol, liquidity, hybridAPY, riskScore, correlationId);
    }

    function _aggregateOraclePredictions(address protocol) internal view returns (OraclePrediction memory) {
        if (oracleCircuitBreaker || oracles.length < minOracleResponses) {
            return OraclePrediction(0, 0, 0, false);
        }

        uint256 validResponses;
        uint256 earliestTimestamp = block.timestamp;
        uint256 latestTimestamp = 0;
        uint256[] memory predictedAPYs = new uint256[](oracles.length);
        uint256[] memory riskScores = new uint256[](oracles.length);
        uint256[] memory weights = new uint256[](oracles.length);

        for (uint256 i = 0; i < oracles.length; i++) {
            try IOracle(oracles[i]).getAIPredictions(protocol) returns (uint256 predictedAPY, uint256 riskScore, uint256 timestamp) {
                if (
                    timestamp > block.timestamp - oracleDataTimeout &&
                    predictedAPY <= MAX_APY &&
                    riskScore <= BASIS_POINTS
                ) {
                    predictedAPYs[validResponses] = predictedAPY;
                    riskScores[validResponses] = riskScore;
                    weights[validResponses] = oracleWeights[oracles[i]];
                    earliestTimestamp = timestamp < earliestTimestamp ? timestamp : earliestTimestamp;
                    latestTimestamp = timestamp > latestTimestamp ? timestamp : latestTimestamp;
                    validResponses++;
                }
            } catch {
                // Skip failed oracles
            }
        }

        if (validResponses < minOracleResponses || latestTimestamp - earliestTimestamp > maxTimestampVariance) {
            return OraclePrediction(0, 0, 0, false);
        }

        // Outlier detection (discard values outside 1.5 * IQR)
        (uint256 apyMedian, uint256 riskMedian) = _calculateWeightedMedian(predictedAPYs, riskScores, weights, validResponses);
        return OraclePrediction(apyMedian, riskMedian, block.timestamp, true);
    }

    /**
     * @notice Calculates weighted median with outlier detection.
     * @param apys Array of APY values.
     * @param risks Array of risk scores.
     * @param weights Array of oracle weights.
     * @param count Number of valid values.
     * @return apyMedian Median APY.
     * @return riskMedian Median risk score.
     */
    function _calculateWeightedMedian(uint256[] memory apys, uint256[] memory risks, uint256[] memory weights, uint256 count)
        internal
        pure
        returns (uint256 apyMedian, uint256 riskMedian)
    {
        if (count == 0) return (0, 0);

        // Sort arrays (quickselect-inspired for gas efficiency)
        uint256[] memory sortedAPYs = new uint256[](count);
        uint256[] memory sortedRisks = new uint256[](count);
        uint256[] memory sortedWeights = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            sortedAPYs[i] = apys[i];
            sortedRisks[i] = risks[i];
            sortedWeights[i] = weights[i];
        }

        // Simple bubble sort for small arrays
        for (uint256 i = 0; i < count - 1; i++) {
            for (uint256 j = 0; j < count - i - 1; j++) {
                if (sortedAPYs[j] > sortedAPYs[j + 1]) {
                    (sortedAPYs[j], sortedAPYs[j + 1]) = (sortedAPYs[j + 1], sortedAPYs[j]);
                    (sortedRisks[j], sortedRisks[j + 1]) = (sortedRisks[j + 1], sortedRisks[j]);
                    (sortedWeights[j], sortedWeights[j + 1]) = (sortedWeights[j + 1], sortedWeights[j]);
                }
            }
        }

        // Outlier detection using IQR
        uint256 apyQ1 = sortedAPYs[count / 4];
        uint256 apyQ3 = sortedAPYs[3 * count / 4];
        uint256 riskQ1 = sortedRisks[count / 4];
        uint256 riskQ3 = sortedRisks[3 * count / 4];
        uint256 apyIQR = apyQ3 - apyQ1;
        uint256 riskIQR = riskQ3 - riskQ1;
        uint256 apyLowerBound = apyQ1 > 1.5 * apyIQR ? apyQ1 - 1.5 * apyIQR : 0;
        uint256 apyUpperBound = apyQ3 + 1.5 * apyIQR;
        uint256 riskLowerBound = riskQ1 > 1.5 * riskIQR ? riskQ1 - 1.5 * riskIQR : 0;
        uint256 riskUpperBound = riskQ3 + 1.5 * riskIQR;

        uint256 totalWeight;
        uint256 weightedAPYSum;
        uint256 weightedRiskSum;
        uint256 validCount;

        for (uint256 i = 0; i < count; i++) {
            if (
                sortedAPYs[i] >= apyLowerBound &&
                sortedAPYs[i] <= apyUpperBound &&
                sortedRisks[i] >= riskLowerBound &&
                sortedRisks[i] <= riskUpperBound
            ) {
                weightedAPYSum += sortedAPYs[i] * sortedWeights[i];
                weightedRiskSum += sortedRisks[i] * sortedWeights[i];
                totalWeight += sortedWeights[i];
                validCount++;
            }
        }

        if (validCount < count / 2) {
            return (0, 0); // Too many outliers
        }

        apyMedian = totalWeight > 0 ? weightedAPYSum / totalWeight : sortedAPYs[count / 2];
        riskMedian = totalWeight > 0 ? weightedRiskSum / totalWeight : sortedRisks[count / 2];
    }

    function _isValidProtocol(address protocol, bytes32 correlationId) internal view returns (bool) {
        ProtocolCacheData memory cache = protocolCache[protocol];
        if (cache.lastUpdated >= block.timestamp - oracleDataTimeout && cache.isValid) {
            return true;
        }
        bool isValid = registry.isValidProtocol(protocol) &&
                       rwaYield.isRWA(protocol) &&
                       sonicProtocol.isSonicCompliant(protocol) &&
                       rwaYield.getAvailableLiquidity(protocol) >= minRWALiquidityThreshold;
        if (!isValid) {
            emit ErrorLogged("Protocol validation failed", correlationId);
        }
        return isValid;
    }

    function _validateAPY(uint256 apy, address protocol) internal view returns (bool) {
        ProtocolCacheData memory cache = protocolCache[protocol];
        uint256 liquidity = cache.lastUpdated >= block.timestamp - oracleDataTimeout ? cache.liquidity : rwaYield.getAvailableLiquidity(protocol);
        return apy > 0 && apy <= MAX_APY && liquidity >= minRWALiquidityThreshold;
    }

    function _assessLeverageViability(address protocol, uint256 amount, bytes32 correlationId) internal view returns (bool) {
        uint256 ltv = flyingTulip.getLTV(protocol, amount);
        bool isViable = ltv <= MAX_LTV &&
                        riskManager.assessLeverageViability(protocol, amount, ltv, true) &&
                        looperCore.checkLiquidationRisk(protocol, amount, (amount * ltv) / BASIS_POINTS, true);
        if (!isViable) {
            emit ErrorLogged("Leverage not viable", correlationId);
        }
        return isViable;
    }

    /**
     * @notice Retrieves cached APY or fetches fresh data.
     * @param protocol Protocol address.
     * @param correlationId Unique ID for tracing.
     * @return Cached or fresh APY.
     */
    function _getCachedAPY(address protocol, bytes32 correlationId) internal view returns (uint256) {
        ProtocolCacheData memory cache = protocolCache[protocol];
        if (cache.lastUpdated >= block.timestamp - oracleDataTimeout && cache.apy > 0) {
            return cache.apy;
        }
        uint256 onChainAPY = riskManager.getRiskAdjustedAPY(protocol, sonicProtocol.getSonicAPY(protocol));
        uint256 offChainAPY = _aggregateOraclePredictions(protocol).predictedAPY;
        uint256 hybridAPY = (onChainAPY * hybridWeightOnChain + offChainAPY * (BASIS_POINTS - hybridWeightOnChain)) / BASIS_POINTS;
        return hybridAPY > 0 && hybridAPY <= MAX_APY ? hybridAPY : 500;
    }

    function getTotalRWABalance() external view returns (uint256) {
        return totalRWABalance;
    }

    function getSupportedProtocols() external view returns (address[] memory) {
        return registry.getActiveProtocols(true);
    }

    function getAllocations() external view returns (Allocation[] memory) {
        address[] memory protocols = registry.getActiveProtocols(true);
        Allocation[] memory result = new Allocation[](protocols.length);
        for (uint256 i = 0; i < protocols.length; i++) {
            result[i] = allocations[protocols[i]];
        }
        return result;
    }

    function getOracles() external view returns (address[] memory) {
        return oracles;
    }

    function _revertReason(string memory reason, bytes32 correlationId) internal {
        emit ErrorLogged(reason, correlationId);
        revert(reason);
    }

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

    receive() external payable {
        revert("ETH deposits not allowed");
    }
}
