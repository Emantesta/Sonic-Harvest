// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// OpenZeppelin imports
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

// PRBMath import
import "@prb/math/PRBMathUD60x18.sol";

// Chainlink imports
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";

// Aave V3 interface
interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf) external;
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf) external returns (uint256);
    function getReserveData(address asset) external view returns (
        uint256 configuration,
        uint256 liquidityIndex,
        uint256 currentLiquidityRate,
        uint256 variableBorrowRate,
        uint256 stableBorrowRate,
        uint40 lastUpdateTimestamp,
        address aTokenAddress,
        address stableDebtTokenAddress,
        address variableDebtTokenAddress,
        address interestRateStrategyAddress,
        uint128 accruedToTreasury,
        uint128 totalStableDebt,
        uint128 totalVariableDebt
    );
    function getUserAccountData(address user) external view returns (
        uint256 totalCollateralBase,
        uint256 totalDebtBase,
        uint256 availableBorrowsBase,
        uint256 currentLiquidationThreshold,
        uint256 ltv,
        uint256 healthFactor
    );
}

// Compound interface
interface ICompound {
    function mint(uint256 mintAmount) external returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
    function borrow(uint256 borrowAmount) external returns (uint256);
    function repayBorrow(uint256 repayAmount) external returns (uint256);
    function supplyRatePerBlock() external view returns (uint256);
    function borrowBalanceCurrent(address account) external returns (uint256);
    function getAccountLiquidity(address account) external view returns (uint256, uint256, uint256);
    function underlying() external view returns (address);
    function balanceOfUnderlying(address account) external returns (uint256);
}

// RWA yield interface
interface IRWAYield {
    function depositToRWA(address protocol, uint256 amount) external;
    function withdrawFromRWA(address protocol, uint256 amount) external returns (uint256);
    function isRWA(address protocol) external view returns (bool);
    function getRWAYield(address protocol) external view returns (uint256);
    function getAvailableLiquidity(address protocol) external view returns (uint256);
}

// DeFi yield interface
interface IDeFiYield {
    function depositToDeFi(address protocol, uint256 amount) external;
    function withdrawFromDeFi(address protocol, uint256 amount) external returns (uint256);
    function isDeFiProtocol(address protocol) external view returns (bool);
    function getAvailableLiquidity(address protocol) external view returns (uint256);
}

// FlyingTulip interface
interface IFlyingTulip {
    function depositToPool(address pool, uint256 amount, bool useLeverage) external returns (uint256);
    function withdrawFromPool(address pool, uint256 amount) external returns (uint256);
    function getDynamicAPY(address pool) external view returns (uint256);
    function getLTV(address pool, uint256 collateral) external view returns (uint256);
    function borrowWithLTV(address pool, uint256 collateral, uint256 borrowAmount) external;
    function repayBorrow(address pool, uint256 amount) external;
    function isOFACCompliant(address user) external view returns (bool);
    function isProtocolHealthy(address pool) external view returns (bool);
    function getAvailableLiquidity(address pool) external view returns (uint256);
}

// Sonic Protocol interface
interface ISonicProtocol {
    function depositFeeMonetizationRewards(address recipient, uint256 amount) external returns (bool);
    function isSonicCompliant(address protocol) external view returns (bool);
    function getSonicAPY(address protocol) external view returns (uint256);
}

// AIYieldOptimizer interface
interface IAIYieldOptimizer {
    function submitAIAllocation(address[] calldata protocols, uint256[] calldata amounts, bool[] calldata isLeveraged) external;
    function rebalancePortfolio(address[] calldata protocols, uint256[] calldata amounts, bool[] calldata isLeveraged) external;
    function getSupportedProtocols() external view returns (address[] memory);
    function getTotalRWABalance() external view returns (uint256);
    function getRecommendedAllocations(uint256 totalAmount)
        external
        view
        returns (address[] memory protocols, uint256[] memory amounts, bool[] memory isLeveraged);
    function withdrawForYieldOptimizer(address protocol, uint256 amount) external returns (uint256);
    // New: Expose AI allocation logic
    function getAllocationLogic(uint256 totalAmount) external view returns (string memory logicDescription);
}

/**
 * @title YieldOptimizer
 * @notice A DeFi yield farming aggregator optimized for Sonic Blockchain, supporting Aave V3, Compound, FlyingTulip, RWA, and Sonic-native protocols with AI-driven strategies.
 * @dev Uses UUPS proxy, integrates with Sonic’s Fee Monetization, native USDC, RedStone oracles, Sonic Points, and delegates RWA allocations to AIYieldOptimizer.
 */
contract YieldOptimizer is UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuard, PausableUpgradeable, AutomationCompatibleInterface {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using PRBMathUD60x18 for uint256;

    // State variables
    IERC20 public immutable sonicSToken;
    IERC20 public immutable stablecoin;
    IRWAYield public immutable rwaYield;
    IDeFiYield public immutable defiYield;
    IFlyingTulip public immutable flyingTulip;
    IAaveV3Pool public immutable aavePool;
    ICompound public immutable compound;
    ISonicProtocol public immutable sonicProtocol;
    IERC20 public immutable sonicPointsToken;
    IAIYieldOptimizer public immutable aiYieldOptimizer;
    address public governance;
    address public feeRecipient;
    address public sonicNativeUSDC;
    uint256 public managementFee;
    uint256 public performanceFee;
    uint256 public feeMonetizationShare;
    uint256 public totalFeeMonetizationRewards;
    uint256 public totalAllocated;
    uint256 public lastUpkeepTimestamp;
    uint256 public immutable MIN_DEPOSIT;
    uint256 public constant MAX_PROTOCOLS = 10;
    uint256 public constant MAX_LTV = 8000; // 80%
    uint256 public constant MIN_ALLOCATION = 1e16;
    bool public allowLeverage;
    bool public emergencyPaused;
    uint256 public pauseTimestamp;
    address public pendingGovernance;
    uint256 public governanceUpdateTimestamp;
    address public pendingImplementation;
    uint256 public upgradeTimestamp;
    bool private initializedImplementation;
    uint256 public riskTolerance; // Basis points (e.g., 500 = 5% max loss)
    // New: RWA liquidity threshold and volatility tracking
    uint256 public minRWALiquidityThreshold; // Minimum liquidity for RWA protocols
    uint256 public volatilityThreshold; // Basis points for leverage adjustment (e.g., 1000 = 10%)
    AggregatorV3Interface public priceFeed; // Chainlink price feed for volatility

    // Mappings
    mapping(address => AggregatorV3Interface) public protocolAPYFeeds;
    mapping(address => uint256) public lastKnownAPYs;
    mapping(address => bool) public whitelistedProtocols;
    mapping(address => bool) public isCompoundProtocol;
    mapping(address => uint256) public manualLiquidityOverrides;
    mapping(address => bool) public blacklistedUsers;
    mapping(address => uint256) public sonicPointsEarned;
    mapping(address => Allocation) public allocations;
    mapping(address => bool) public isActiveProtocol;
    mapping(address => uint256) public protocolRiskScores; // AI-driven risk scores (0-10000)
    mapping(address => uint256) public userBalances;
    mapping(bytes32 => TimelockAction) public timelockActions;

    address[] public activeProtocols;

    // Constants
    uint256 public constant BASIS_POINTS = 10000;
    uint256 private constant SECONDS_PER_YEAR = 365 days;
    uint256 private constant BLOCKS_PER_YEAR = 2628000;
    uint256 private constant MAX_APY = 10000; // 100%
    uint256 private constant FIXED_POINT_SCALE = 1e18;
    uint256 private constant MAX_EXP_INPUT = 10e18;
    uint256 private constant MIN_PROFIT = 1e6;
    uint256 private constant AAVE_REFERRAL_CODE = 0;
    uint256 private constant MAX_BORROW_AMOUNT = 1e24;
    uint256 private constant MIN_HEALTH_FACTOR = 1.5e18;
    uint256 private constant MIN_COLLATERAL_FACTOR = 1.5e18;
    uint256 private constant MAX_STALENESS = 30 minutes;
    uint256 private constant MAX_FEED_FAILURES = 50;
    uint256 private constant UPKEEP_INTERVAL = 1 days;
    uint256 private constant MAX_PAUSE_DURATION = 3 days; // Reduced from 7 days
    uint256 private constant GOVERNANCE_UPDATE_DELAY = 2 days;
    uint256 private constant UPGRADE_DELAY = 2 days;
    uint256 public constant TIMELOCK_DELAY = 2 days;

    // Structs
    struct Allocation {
        address protocol;
        uint256 amount;
        uint256 apy;
        uint256 lastUpdated;
        bool isLeveraged;
    }

    struct TimelockAction {
        bytes32 actionHash;
        uint256 timestamp;
        bool executed;
    }

    // New: Struct for allocation breakdown
    struct AllocationBreakdown {
        address protocol;
        uint256 amount;
        uint256 apy;
        bool isLeveraged;
        uint256 liquidity;
        uint256 riskScore;
    }

    // Events
    event Deposit(address indexed user, uint256 amount, uint256 fee);
    event Withdraw(address indexed user, uint256 amount, uint256 fee);
    event Rebalance(address indexed protocol, uint256 amount, uint256 apy, bool isLeveraged);
    event FeesCollected(uint256 managementFee, uint256 performanceFee);
    event FeeRecipientUpdated(address indexed newRecipient);
    event FeesUpdated(uint256 managementFee, uint256 performanceFee);
    event GovernanceUpdated(address indexed newGovernance);
    event GovernanceUpdateProposed(address indexed newGovernance);
    event ProtocolWhitelisted(address indexed protocol, bool status);
    event APYFeedUpdated(address indexed protocol, address feed);
    event LastKnownAPYUpdated(address indexed protocol, uint256 apy);
    event WithdrawalFailed(address indexed protocol, uint256 amount);
    event AllocationSkipped(address indexed protocol, string reason);
    event LeverageToggled(bool status);
    event LTVBorrow(address indexed protocol, uint256 collateral, uint256 borrowAmount);
    event LTVRepaid(address indexed protocol, uint256 amount);
    event OFACCheckFailed(address indexed user);
    event BlacklistUpdated(address indexed user, bool status);
    event EmergencyPause(bool status);
    event FundsRecovered(address indexed protocol, uint256 amount);
    event UserEmergencyWithdraw(address indexed user, uint256 amount);
    event EmergencyTransfer(address indexed user, uint256 amount);
    event FundsWithdrawnForRepayment(address indexed protocol, uint256 amount);
    event CircuitBreakerTriggered(uint256 failedFeeds, uint256 totalFeeds);
    event RebalanceResumed();
    event ManualUpkeepTriggered(uint256 timestamp);
    event FeedHealthCheckPassed(uint256 validFeeds, uint256 totalFeeds);
    event FeedHealthCheckFailed(uint256 validFeeds, uint256 totalFeeds);
    event LiquidityOverrideSet(address indexed protocol, uint256 liquidity);
    event LiquidityCheckFailed(address indexed protocol);
    event UpgradeProposed(address indexed newImplementation);
    event UpkeepStale(uint256 lastUpkeepTimestamp, uint256 currentTimestamp);
    event TimelockActionProposed(bytes32 indexed actionHash, uint256 timestamp);
    event TimelockActionExecuted(bytes32 indexed actionHash);
    event AaveSupply(address indexed protocol, uint256 amount, address aToken);
    event AaveWithdraw(address indexed protocol, uint256 amount);
    event AaveSupplyFailed(address indexed protocol, uint256 amount, string reason);
    event AaveWithdrawFailed(address indexed protocol, uint256 amount, string reason);
    event CompoundSupply(address indexed protocol, uint256 amount, address cToken);
    event CompoundWithdraw(address indexed protocol, uint256 amount);
    event CompoundSupplyFailed(address indexed protocol, uint256 amount, string reason);
    event CompoundWithdrawFailed(address indexed protocol, uint256 amount, string reason);
    event LeverageUnwound(address indexed protocol, uint256 repayAmount);
    event FeeMonetizationRewardsDeposited(address indexed sender, uint256 amount);
    event SonicSTokenUpdated(address indexed oldToken, address indexed newToken);
    event SonicProtocolUpdated(address indexed oldProtocol, address indexed newProtocol);
    event FeeMonetizationRewardsClaimed(address indexed recipient, uint256 amount);
    event SonicPointsClaimed(address indexed user, uint256 points);
    event RWADelegatedToAI(address indexed aiYieldOptimizer, uint256 amount);
    event AIRiskAssessmentUpdated(address indexed protocol, uint256 riskScore);
    event AIAllocationOptimized(address indexed protocol, uint256 amount, uint256 apy, bool isLeveraged);
    // New: Event for AI allocation transparency
    event AIAllocationDetails(address[] protocols, uint256[] amounts, bool[] isLeveraged, string logicDescription);
    // New: Event for dynamic leverage adjustment
    event LeverageAdjusted(address indexed protocol, uint256 newLTV, uint256 volatility);

    // Modifiers
    modifier onlyGovernance() {
        require(msg.sender == governance, "Not governance");
        _;
    }

    modifier whenNotEmergencyPaused() {
        require(!emergencyPaused, "Contract is emergency paused");
        _;
    }

    modifier sonicFeeMonetization() {
        uint256 gasUsed = gasleft();
        _;
        uint256 gasConsumed = gasUsed - gasleft();
        // New: Cap gas-based fees to prevent abuse
        uint256 feeShare = Math.min(((gasConsumed * tx.gasprice * feeMonetizationShare) / 100), 1e18); // Cap at 1e18
        totalFeeMonetizationRewards += feeShare;
        emit FeeMonetizationRewardsDeposited(address(this), feeShare);
    }

    /**
     * @notice Initializes the contract with Sonic-specific parameters and AI-driven settings.
     */
    function initialize(
        address _sonicSToken,
        address _stablecoin,
        address _rwaYield,
        address _defiYield,
        address _flyingTulip,
        address _aavePool,
        address _compound,
        address _sonicProtocol,
        address _sonicPointsToken,
        address _feeRecipient,
        address _governance,
        address _aiYieldOptimizer,
        address _priceFeed // New: Chainlink price feed for volatility
    ) external initializer {
        require(!initializedImplementation, "Implementation already initialized");
        initializedImplementation = true;

        require(_stablecoin != address(0), "Invalid stablecoin address");
        require(_sonicSToken != address(0), "Invalid Sonic S token address");
        require(_rwaYield != address(0), "Invalid RWAYield address");
        require(_defiYield != address(0), "Invalid DeFiYield address");
        require(_flyingTulip != address(0), "Invalid FlyingTulip address");
        require(_aavePool != address(0), "Invalid AavePool address");
        require(_compound != address(0), "Invalid Compound address");
        require(_sonicProtocol != address(0), "Invalid SonicProtocol address");
        require(_sonicPointsToken != address(0), "Invalid SonicPointsToken address");
        require(_feeRecipient != address(0), "Invalid fee recipient");
        require(_governance != address(0), "Invalid governance");
        require(_aiYieldOptimizer != address(0), "Invalid AIYieldOptimizer address");
        require(_priceFeed != address(0), "Invalid price feed");

        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        sonicSToken = IERC20(_sonicSToken);
        stablecoin = IERC20(_stablecoin);
        sonicNativeUSDC = _stablecoin;
        rwaYield = IRWAYield(_rwaYield);
        defiYield = IDeFiYield(_defiYield);
        flyingTulip = IFlyingTulip(_flyingTulip);
        compound = ICompound(_compound);
        aavePool = IAaveV3Pool(_aavePool);
        sonicProtocol = ISonicProtocol(_sonicProtocol);
        sonicPointsToken = IERC20(_sonicPointsToken);
        aiYieldOptimizer = IAIYieldOptimizer(_aiYieldOptimizer);
        priceFeed = AggregatorV3Interface(_priceFeed); // New: Initialize price feed
        feeRecipient = _feeRecipient;
        governance = _governance;
        managementFee = 50; // 0.5%
        performanceFee = 1000; // 10%
        feeMonetizationShare = 90; // 90%
        MIN_DEPOSIT = 10 ** IERC20Metadata(_stablecoin).decimals();
        allowLeverage = true;
        emergencyPaused = false;
        lastUpkeepTimestamp = block.timestamp;
        riskTolerance = 500; // 5% default risk tolerance
        minRWALiquidityThreshold = 1e18; // New: Default 1e18 for RWA liquidity
        volatilityThreshold = 1000; // New: 10% volatility threshold
    }

    /**
     * @notice Proposes a contract upgrade with a timelock.
     */
    function proposeUpgrade(address newImplementation) external onlyOwner {
        require(newImplementation != address(0), "Invalid implementation");
        pendingImplementation = newImplementation;
        upgradeTimestamp = block.timestamp + UPGRADE_DELAY;
        emit UpgradeProposed(newImplementation);
    }

    /**
     * @notice Authorizes contract upgrades after timelock delay.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        require(newImplementation == pendingImplementation, "Invalid implementation");
        require(block.timestamp >= upgradeTimestamp, "Delay not elapsed");
        pendingImplementation = address(0);
        upgradeTimestamp = 0;
    }

    /**
     * @notice Sets risk tolerance for AI-driven allocations.
     */
    function setRiskTolerance(uint256 _riskTolerance) external onlyGovernance sonicFeeMonetization {
        require(_riskTolerance <= 1000, "Risk tolerance too high"); // Max 10%
        riskTolerance = _riskTolerance;
    }

    /**
     * @notice Updates protocol risk score based on AI assessment.
     */
    function updateProtocolRiskScore(address protocol, uint256 riskScore) external onlyGovernance sonicFeeMonetization {
        require(riskScore <= 10000, "Invalid risk score");
        protocolRiskScores[protocol] = riskScore;
        emit AIRiskAssessmentUpdated(protocol, riskScore);
    }

    /**
     * @notice Sets minimum liquidity threshold for RWA protocols.
     */
    function setMinRWALiquidityThreshold(uint256 _threshold) external onlyGovernance sonicFeeMonetization {
        require(_threshold > 0, "Invalid threshold");
        minRWALiquidityThreshold = _threshold;
        emit LiquidityOverrideSet(address(0), _threshold);
    }

    /**
     * @notice Sets volatility threshold for dynamic leverage adjustments.
     */
    function setVolatilityThreshold(uint256 _threshold) external onlyGovernance sonicFeeMonetization {
        require(_threshold <= 5000, "Volatility threshold too high"); // Max 50%
        volatilityThreshold = _threshold;
    }

    /**
     * @notice Deposits funds and allocates them to protocols with Sonic points tracking.
     */
    function deposit(uint256 amount) external nonReentrant whenNotPaused whenNotEmergencyPaused sonicFeeMonetization {
        require(amount >= MIN_DEPOSIT, "Deposit below minimum");
        require(!blacklistedUsers[msg.sender], "User blacklisted");
        require(stablecoin == IERC20(sonicNativeUSDC), "Invalid stablecoin");
        if (!flyingTulip.isOFACCompliant(msg.sender)) {
            emit OFACCheckFailed(msg.sender);
            revert("OFAC check failed");
        }

        uint256 fee = (amount * managementFee) / BASIS_POINTS;
        uint256 netAmount = amount - fee;

        stablecoin.safeTransferFrom(msg.sender, address(this), amount);
        stablecoin.safeTransfer(feeRecipient, fee);

        userBalances[msg.sender] += netAmount;
        totalAllocated += netAmount;
        sonicPointsEarned[msg.sender] += netAmount * 2;
        _allocateFunds(netAmount, 0, activeProtocols.length);

        emit Deposit(msg.sender, netAmount, fee);
    }

    /**
     * @notice Withdraws funds and distributes profits.
     */
    function withdraw(uint256 amount) external nonReentrant whenNotPaused whenNotEmergencyPaused sonicFeeMonetization {
        require(amount > 0, "Amount must be > 0");
        require(userBalances[msg.sender] >= amount, "Insufficient balance");

        uint256 profit = _calculateProfit(msg.sender, amount);
        uint256 performanceFeeAmount = (profit * performanceFee) / BASIS_POINTS;
        uint256 netProfit = profit - performanceFeeAmount;

        userBalances[msg.sender] -= amount;
        totalAllocated -= amount;
        sonicPointsEarned[msg.sender] += amount;

        uint256 withdrawnAmount = _deallocateFunds(amount, 0, activeProtocols.length);
        require(withdrawnAmount >= amount, "Insufficient funds withdrawn");

        if (performanceFeeAmount > 0) {
            stablecoin.safeTransfer(feeRecipient, performanceFeeAmount);
        }
        stablecoin.safeTransfer(msg.sender, amount + netProfit);

        emit Withdraw(msg.sender, amount + netProfit, performanceFeeAmount);
        emit FeesCollected(fee, performanceFeeAmount);
    }

    /**
     * @notice Allows users to withdraw funds during an emergency pause.
     */
    function userEmergencyWithdraw(uint256 amount) external nonReentrant whenPaused {
        require(emergencyPaused, "Not emergency paused");
        require(amount > 0, "Amount must be > 0");
        require(userBalances[msg.sender] >= amount, "Insufficient balance");

        userBalances[msg.sender] -= amount;
        totalAllocated -= amount;
        stablecoin.safeTransfer(msg.sender, amount);

        emit UserEmergencyWithdraw(msg.sender, amount);
    }

    /**
     * @notice AI-driven rebalance with risk-adjusted allocations and Sonic compliance.
     */
    function rebalance() external onlyGovernance nonReentrant whenNotPaused whenNotEmergencyPaused sonicFeeMonetization {
        // Gas Optimization: Cache activeProtocols length
        uint256 protocolCount = activeProtocols.length;

        // Withdraw from non-RWA protocols
        for (uint256 i = 0; i < protocolCount; i++) {
            address protocol = activeProtocols[i];
            Allocation storage alloc = allocations[protocol];
            if (alloc.amount > 0 && !rwaYield.isRWA(protocol)) {
                uint256 withdrawn = _withdrawFromProtocol(protocol, alloc.amount);
                alloc.amount -= withdrawn;
            }
        }
        _cleanAllocations();

        // Fetch APYs and risk scores
        (address[] memory protocols, uint256[] memory apys) = _getAPYsFromChainlink();
        require(protocols.length <= MAX_PROTOCOLS, "Too many protocols");
        require(protocols.length == apys.length, "APY data mismatch");

        uint256 totalBalance = stablecoin.balanceOf(address(this)) + aiYieldOptimizer.getTotalRWABalance();
        uint256 totalWeightedAPY = 0;
        uint256 nonRWAAmount = 0;

        // Gas Optimization: Cache weights in memory
        uint256[] memory weights = new uint256[](protocols.length);
        for (uint256 i = 0; i < protocols.length; i++) {
            if (!_isValidProtocol(protocols[i]) || !_validateAPY(apys[i], protocols[i])) {
                emit Allocation skipped(protocols[i], "Invalid protocol or APY");
                continue;
            }
            // New: Stricter RWA validation
            if (rwaYield.isRWA(protocols[i]) && !validateRWAProtocol(protocols[i])) {
                emit AllocationSkipped(protocols[i], "RWA validation failed");
                continue;
            }
            uint256 riskScore = protocolRiskScores[protocols[i]] > 0 ? protocolRiskScores[protocols[i]] : 5000;
            uint256 riskAdjustedAPY = (apys[i] * (10000 - riskScore)) / 10000;
            weights[i] = riskAdjustedAPY;
            totalWeightedAPY += riskAdjustedAPY;
        }

        // Allocate to non-RWA protocols
        for (uint256 i = 0; i < protocols.length; i++) {
            if (rwaYield.isRWA(protocols[i]) || weights[i] == 0) {
                continue;
            }
            uint256 allocAmount = (totalBalance * weights[i]) / (totalWeightedAPY == 0 ? 1 : totalWeightedAPY);
            if (allocAmount < MIN_ALLOCATION) {
                emit AllocationSkipped(protocols[i], "Amount below minimum");
                continue;
            }
            bool isLeveraged = allowLeverage && _assessLeverageViability(protocols[i], allocAmount);
            // New: Dynamic leverage adjustment
            if (isLeveraged) {
                isLeveraged = adjustLeverageDynamically(protocols[i], allocAmount);
            }
            allocations[protocols[i]] = Allocation(protocols[i], allocAmount, apys[i], block.timestamp, isLeveraged);
            lastKnownAPYs[protocols[i]] = apys[i];
            if (!isActiveProtocol[protocols[i]]) {
                activeProtocols.push(protocols[i]);
                isActiveProtocol[protocols[i]] = true;
            }
            _depositToProtocol(protocols[i], allocAmount, isLeveraged);
            nonRWAAmount += allocAmount;
            if (isLeveraged) {
                _applyLeverage(protocols[i], allocAmount);
            }
            emit AIAllocationOptimized(protocols[i], allocAmount, apys[i], isLeveraged);
            emit Rebalance(protocols[i], allocAmount, apys[i], isLeveraged);
        }

        // Delegate RWA reallocation
        uint256 rwaAmount = totalBalance > nonRWAAmount ? totalBalance - nonRWAAmount : 0;
        if (rwaAmount >= MIN_ALLOCATION) {
            (address[] memory rwaProtocols, uint256[] memory amounts, bool[] memory isLeveraged) = aiYieldOptimizer.getRecommendedAllocations(rwaAmount);
            // New: Validate AI allocations
            require(validateAIAllocations(rwaProtocols, amounts, rwaAmount), "Invalid AI allocations");
            stablecoin.safeApprove(address(aiYieldOptimizer), 0);
            stablecoin.safeApprove(address(aiYieldOptimizer), rwaAmount);
            stablecoin.safeTransfer(address(aiYieldOptimizer), rwaAmount);
            aiYieldOptimizer.rebalancePortfolio(rwaProtocols, amounts, isLeveraged);
            // New: Emit AI allocation details
            string memory logicDescription = aiYieldOptimizer.getAllocationLogic(rwaAmount);
            emit AIAllocationDetails(rwaProtocols, amounts, isLeveraged, logicDescription);
            emit RWADelegatedToAI(address(aiYieldOptimizer), rwaAmount);
        }
    }

    /**
     * @notice Validates AI-driven allocations to ensure correctness.
     */
    function validateAIAllocations(address[] memory protocols, uint256[] memory amounts, uint256 totalAmount) internal view returns (bool) {
        if (protocols.length != amounts.length) return false;
        uint256 sum = 0;
        for (uint256 i = 0; i < protocols.length; i++) {
            if (!rwaYield.isRWA(protocols[i]) || !validateRWAProtocol(protocols[i])) return false;
            sum += amounts[i];
        }
        return sum <= totalAmount && sum >= totalAmount * 95 / 100; // Allow 5% tolerance
    }

    /**
     * @notice Validates RWA protocol liquidity and vetting.
     */
    function validateRWAProtocol(address protocol) internal view returns (bool) {
        return rwaYield.getAvailableLiquidity(protocol) >= minRWALiquidityThreshold &&
               whitelistedProtocols[protocol] &&
               sonicProtocol.isSonicCompliant(protocol);
    }

    /**
     * @notice Assesses leverage viability based on AI-driven risk parameters and volatility.
     */
    function _assessLeverageViability(address protocol, uint256 amount) internal view returns (bool) {
        uint256 riskScore = protocolRiskScores[protocol] > 0 ? protocolRiskScores[protocol] : 5000;
        uint256 ltv = _getLTV(protocol, amount);
        uint256 volatility = getMarketVolatility();
        return riskScore < 7000 && // Max 70% risk score
               ltv <= MAX_LTV &&
               volatility <= volatilityThreshold &&
               _checkLiquidationRisk(protocol, amount, (amount * ltv) / BASIS_POINTS);
    }

    /**
     * @notice Dynamically adjusts leverage based on market volatility.
     */
    function adjustLeverageDynamically(address protocol, uint256 amount) internal returns (bool) {
        uint256 volatility = getMarketVolatility();
        uint256 ltv = _getLTV(protocol, amount);
        if (volatility > volatilityThreshold) {
            uint256 reducedLTV = ltv * (BASIS_POINTS - volatility) / BASIS_POINTS;
            if (reducedLTV < ltv) {
                uint256 repayAmount = (amount * (ltv - reducedLTV)) / BASIS_POINTS;
                _withdrawForRepayment(repayAmount);
                stablecoin.safeApprove(protocol, 0);
                stablecoin.safeApprove(protocol, repayAmount);
                if (protocol == address(flyingTulip)) {
                    flyingTulip.repayBorrow(protocol, repayAmount);
                } else if (protocol == address(aavePool)) {
                    aavePool.repay(address(stablecoin), repayAmount, 2, address(this));
                } else if (isCompoundProtocol[protocol]) {
                    require(compound.repayBorrow(repayAmount) == 0, "Compound repay failed");
                }
                emit LeverageAdjusted(protocol, reducedLTV, volatility);
                return reducedLTV > 0;
            }
        }
        emit LeverageAdjusted(protocol, ltv, volatility);
        return true;
    }

    /**
     * @notice Calculates market volatility using Chainlink price feed.
     */
    function getMarketVolatility() public view returns (uint256) {
        (, int256 price1, , uint256 updatedAt1, ) = priceFeed.latestRoundData();
        (, int256 price2, , uint256 updatedAt2, ) = priceFeed.getRoundData(uint80(priceFeed.latestRound() - 1));
        if (updatedAt1 <= updatedAt2 || price1 <= 0 || price2 <= 0) return volatilityThreshold;
        uint256 timeDiff = updatedAt1 - updatedAt2;
        uint256 priceDiff = price1 > price2 ? uint256(price1 - price2) : uint256(price2 - price1);
        uint256 volatility = (priceDiff * BASIS_POINTS) / uint256(price1); // In basis points
        return volatility;
    }

    /**
     * @notice Applies leverage to a protocol.
     */
    function _applyLeverage(address protocol, uint256 amount) internal {
        uint256 ltv = _getLTV(protocol, amount);
        uint256 borrowAmount = (amount * ltv) / BASIS_POINTS;
        if (borrowAmount > 0 && borrowAmount <= MAX_BORROW_AMOUNT && _checkLiquidationRisk(protocol, amount, borrowAmount)) {
            if (protocol == address(flyingTulip)) {
                flyingTulip.borrowWithLTV(protocol, amount, borrowAmount);
            } else if (protocol == address(aavePool)) {
                _borrowFromAave(protocol, amount, borrowAmount);
            } else if (isCompoundProtocol[protocol]) {
                _borrowFromCompound(protocol, amount, borrowAmount);
            }
            emit LTVBorrow(protocol, amount, borrowAmount);
        } else {
            emit AllocationSkipped(protocol, "Liquidation risk too high");
        }
    }

    /**
     * @notice Gets LTV for a protocol.
     */
    function _getLTV(address protocol, uint256 amount) internal view returns (uint256) {
        if (protocol == address(flyingTulip)) {
            return flyingTulip.getLTV(protocol, amount);
        } else if (protocol == address(aavePool)) {
            return aavePool.getUserAccountData(address(this)).ltv;
        } else if (isCompoundProtocol[protocol]) {
            (, uint256 collateralFactor, ) = compound.getAccountLiquidity(address(this));
            return (collateralFactor * BASIS_POINTS) / 1e18;
        }
        return 0;
    }

    /**
     * @notice Borrows from Aave V3 with safety checks.
     */
    function _borrowFromAave(address protocol, uint256 collateral, uint256 borrowAmount) internal {
        require(protocol == address(aavePool), "Invalid protocol");
        (, , uint256 availableBorrowsBase, , , uint256 healthFactor) = aavePool.getUserAccountData(address(this));
        require(healthFactor >= MIN_HEALTH_FACTOR, "Health factor too low");
        require(borrowAmount <= availableBorrowsBase, "Exceeds available borrow");
        stablecoin.safeApprove(protocol, 0);
        stablecoin.safeApprove(protocol, borrowAmount);
        aavePool.borrow(address(stablecoin), borrowAmount, 2, AAVE_REFERRAL_CODE, address(this));
    }

    /**
     * @notice Borrows from Compound with safety checks.
     */
    function _borrowFromCompound(address protocol, uint256 collateral, uint256 borrowAmount) internal {
        require(isCompoundProtocol[protocol], "Invalid protocol");
        (, uint256 collateralFactor, uint256 liquidity) = compound.getAccountLiquidity(address(this));
        require(collateralFactor >= MIN_COLLATERAL_FACTOR, "Collateral factor too low");
        require(borrowAmount <= liquidity, "Exceeds available liquidity");
        stablecoin.safeApprove(protocol, 0);
        stablecoin.safeApprove(protocol, borrowAmount);
        require(compound.borrow(borrowAmount) == 0, "Compound borrow failed");
    }

    /**
     * @notice Unwinds leveraged positions during an emergency pause.
     */
    function unwindLeverage(address protocol) external onlyGovernance whenPaused nonReentrant sonicFeeMonetization {
        Allocation storage alloc = allocations[protocol];
        require(alloc.isLeveraged && (protocol == address(flyingTulip) || protocol == address(aavePool) || isCompoundProtocol[protocol]), "Invalid leveraged protocol");
        uint256 repayAmount;
        if (protocol == address(flyingTulip)) {
            repayAmount = (alloc.amount * flyingTulip.getLTV(protocol, alloc.amount)) / BASIS_POINTS;
            _withdrawForRepayment(repayAmount);
            stablecoin.safeApprove(protocol, 0);
            stablecoin.safeApprove(protocol, repayAmount);
            flyingTulip.repayBorrow(protocol, repayAmount);
        } else if (protocol == address(aavePool)) {
            (, uint256 totalDebtBase, , , , ) = aavePool.getUserAccountData(address(this));
            repayAmount = totalDebtBase;
            _withdrawForRepayment(repayAmount);
            stablecoin.safeApprove(protocol, 0);
            stablecoin.safeApprove(protocol, repayAmount);
            aavePool.repay(address(stablecoin), repayAmount, 2, address(this));
        } else if (isCompoundProtocol[protocol]) {
            repayAmount = compound.borrowBalanceCurrent(address(this));
            _withdrawForRepayment(repayAmount);
            stablecoin.safeApprove(protocol, 0);
            stablecoin.safeApprove(protocol, repayAmount);
            require(compound.repayBorrow(repayAmount) == 0, "Compound repay failed");
        }
        alloc.isLeveraged = false;
        emit LeverageUnwound(protocol, repayAmount);
    }

    /**
     * @notice Validates Chainlink/RedStone feeds before resuming rebalancing.
     */
    function checkFeedHealth() public view returns (bool) {
        uint256 totalFeeds = 0;
        uint256 validFeeds = 0;

        for (uint256 i = 0; i < activeProtocols.length; i++) {
            AggregatorV3Interface feed = protocolAPYFeeds[activeProtocols[i]];
            if (address(feed) != address(0)) {
                totalFeeds++;
                try feed.latestRoundData() returns (uint80, int256 answer, , uint256 updatedAt, uint80) {
                    if (answer > 0 && block.timestamp <= updatedAt + MAX_STALENESS && uint256(answer) <= MAX_APY) {
                        validFeeds++;
                    }
                } catch {
                    // Count as invalid
                }
            }
        }

        bool isHealthy = totalFeeds == 0 || (validFeeds * 100) / totalFeeds >= (100 - MAX_FEED_FAILURES);
        if (isHealthy) {
            emit FeedHealthCheckPassed(validFeeds, totalFeeds);
        } else {
            emit FeedHealthCheckFailed(validFeeds, totalFeedsruleid: 135346
        }
        emit FeedHealthCheckFailed(validFeeds, totalFeeds);
    }

    /**
     * @notice Resumes rebalancing after a circuit breaker pause.
     */
    function rebalanceResume() external onlyGovernance {
        require(paused(), "Contract is not paused");
        require(checkFeedHealth(), "Feed health check failed");
        _unpause();
        emit RebalanceResumed();
    }

    /**
     * @notice Toggles leverage for FlyingTulip, Aave, and Compound pools.
     */
    function toggleLeverage(bool status) external onlyGovernance sonicFeeMonetization {
        allowLeverage = status;
        emit LeverageToggled(status);
    }

    /**
     * @notice Adjusts leverage positions to maintain safe LTV.
     */
    function adjustLeverage(address protocol, uint256 maxLTV) external onlyGovernance nonReentrant sonicFeeMonetization {
        Allocation storage alloc = allocations[protocol];
        require(alloc.isLeveraged && (protocol == address(flyingTulip) || protocol == address(aavePool) || isCompoundProtocol[protocol]), "Invalid leveraged protocol");
        uint256 currentLTV = _getLTV(protocol, alloc.amount);
        if (currentLTV > maxLTV) {
            uint256 excessLTV = currentLTV - maxLTV;
            uint256 repayAmount = (alloc.amount * excessLTV) / BASIS_POINTS;
            uint256 balance = stablecoin.balanceOf(address(this));
            if (balance < repayAmount) {
                uint256 needed = repayAmount - balance;
                _withdrawForRepayment(needed);
            }
            stablecoin.safeApprove(protocol, 0);
            stablecoin.safeApprove(protocol, repayAmount);
            if (protocol == address(flyingTulip)) {
                flyingTulip.repayBorrow(protocol, repayAmount);
            } else if (protocol == address(aavePool)) {
                aavePool.repay(address(stablecoin), repayAmount, 2, address(this));
            } else if (isCompoundProtocol[protocol]) {
                require(compound.repayBorrow(repayAmount) == 0, "Compound repay failed");
            }
            emit LTVRepaid(protocol, repayAmount);
        }
    }

    /**
     * @notice Withdraws funds from protocols to cover repayment needs.
     */
    function withdrawForRepayment(uint256 amount) external onlyGovernance nonReentrant sonicFeeMonetization {
        _withdrawForRepayment(amount);
    }

    /**
     * @notice Manual upkeep triggered by governance if automation fails.
     */
    function manualUpkeep() external onlyGovernance sonicFeeMonetization {
        lastUpkeepTimestamp = block.timestamp;

        for (uint256 i = 0; i < activeProtocols.length; i++) {
            address protocol = activeProtocols[i];
            AggregatorV3Interface feed = protocolAPYFeeds[protocol];
            if (address(feed) != address(0)) {
                try feed.latestRoundData() returns (uint80, int256 answer, , uint256 updatedAt, uint80) {
                    if (answer > 0 && block.timestamp <= updatedAt + MAX_STALENESS && uint256(answer) <= MAX_APY) {
                        lastKnownAPYs[protocol] = uint256(answer);
                        emit LastKnownAPYUpdated(protocol, uint256(answer));
                    }
                } catch {
                    // Skip failed feeds
                }
            } else if (protocol == address(aavePool)) {
                uint256 apy = _getAaveAPY(address(stablecoin));
                if (apy > 0 && apy <= MAX_APY) {
                    lastKnownAPYs[protocol] = apy;
                    emit LastKnownAPYUpdated(protocol, apy);
                }
            } else if (isCompoundProtocol[protocol]) {
                uint256 apy = _getCompoundAPY(protocol);
                if (apy > 0 && apy <= MAX_APY) {
                    lastKnownAPYs[protocol] = apy;
                    emit LastKnownAPYUpdated(protocol, apy);
                }
            } else {
                uint256 apy = sonicProtocol.getSonicAPY(protocol);
                if (apy > 0 && apy <= MAX_APY) {
                    lastKnownAPYs[protocol] = apy  {
                    lastKnownAPYs[protocol] = apy;
                    emit LastKnownAPYUpdated(protocol, apy);
                }
            }
        }
        emit ManualUpkeepTriggered(block.timestamp);
    }

    /**
     * @notice Receives Fee Monetization rewards from Sonic Blockchain or ISonicProtocol.
     */
    function depositFeeMonetizationRewards(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "Invalid amount");
        if (msg.sender != address(sonicProtocol)) {
            sonicSToken.safeTransferFrom(msg.sender, address(this), amount);
        } else {
            require(sonicProtocol.depositFeeMonetizationRewards(address(this), amount), "Deposit failed");
        }
        totalFeeMonetizationRewards += amount;
        emit FeeMonetizationRewardsDeposited(msg.sender, amount);
    }

    /**
     * @notice Claims accumulated Fee Monetization rewards in Sonic S tokens.
     */
    function claimFeeMonetizationRewards() external onlyGovernance nonReentrant sonicFeeMonetization whenNotPaused {
        uint256 rewards = totalFeeMonetizationRewards;
        require(rewards > 0, "No rewards available");
        require(sonicSToken.balanceOf(address(this)) >= rewards, "Insufficient Sonic S balance");

        totalFeeMonetizationRewards = 0;
        sonicSToken.safeTransfer(governance, rewards);
        emit FeeMonetizationRewardsClaimed(governance, rewards);
    }

    /**
     * @notice Proposes updating the Sonic S token address.
     */
    function proposeUpdateSonicSToken(address newToken) external onlyGovernance {
        require(newToken != address(0), "Invalid token address");
        bytes32 actionHash = keccak256(abi.encode("updateSonicSToken", newToken));
        require(timelockActions[actionHash].timestamp == 0, "Action already proposed");

        timelockActions[actionHash] = TimelockAction({
            actionHash: actionHash,
            timestamp: block.timestamp + TIMELOCK_DELAY,
            executed: false
        });
        emit TimelockActionProposed(actionHash, timelockActions[actionHash].timestamp);
    }

    /**
     * @notice Executes updating the Sonic S token address after timelock.
     */
    function executeUpdateSonicSToken(address newToken) external onlyGovernance nonReentrant {
        require(newToken != address(0), "Invalid token address");
        bytes32 actionHash = keccak256(abi.encode("updateSonicSToken", newToken));
        TimelockAction storage action = timelockActions[actionHash];
        require(action.timestamp != 0, "Action not proposed");
        require(block.timestamp >= action.timestamp, "Timelock not elapsed");
        require(!action.executed, "Action already executed");

        address oldToken = address(sonicSToken);
        sonicSToken = IERC20(newToken);
        action.executed = true;
        emit SonicSTokenUpdated(oldToken, newToken);
        emit TimelockActionExecuted(actionHash);
    }

    /**
     * @notice Proposes updating the Sonic protocol address.
     */
    function proposeUpdateSonicProtocol(address newProtocol) external onlyGovernance {
        require(newProtocol != address(0), "Invalid protocol address");
        bytes32 actionHash = keccak256(abi.encode("updateSonicProtocol", newProtocol));
        require(timelockActions[actionHash].timestamp == 0, "Action already proposed");

        timelockActions[actionHash] = TimelockAction({
            actionHash: actionHash,
            timestamp: block.timestamp + TIMELOCK_DELAY,
            executed: false
        });
        emit TimelockActionProposed(actionHash, timelockActions[actionHash].timestamp);
    }

    /**
     * @notice Executes updating the Sonic protocol address after timelock.
     */
    function executeUpdateSonicProtocol(address newProtocol) external onlyGovernance nonReentrant {
        require(newProtocol != address(0), "Invalid protocol address");
        bytes32 actionHash = keccak256(abi.encode("updateSonicProtocol", newProtocol));
        TimelockAction storage action = timelockActions[actionHash];
        require(action.timestamp != 0, "Action not proposed");
        require(block.timestamp >= action.timestamp, "Timelock not elapsed");
        require(!action.executed, "Action already executed");

        address oldProtocol = address(sonicProtocol);
        sonicProtocol = ISonicProtocol(newProtocol);
        action.executed = true;
        emit SonicProtocolUpdated(oldProtocol, newProtocol);
        emit TimelockActionExecuted(actionHash);
    }

    /**
     * @notice Claims Sonic Points for airdrop eligibility.
     */
    function claimSonicPoints(address user) external nonReentrant sonicFeeMonetization {
        uint256 points = sonicPointsEarned[user];
        require(points > 0, "No points earned");
        sonicPointsEarned[user] = 0;
        sonicPointsToken.safeTransfer(user, points);
        emit SonicPointsClaimed(user, points);
    }

    /**
     * @notice Gets the actual liquidity available in a protocol.
     */
    function getProtocolLiquidity(address protocol) public view returns (uint256 liquidity) {
        require(_isValidProtocol(protocol), "Invalid protocol");
        if (manualLiquidityOverrides[protocol] > 0) {
            return manualLiquidityOverrides[protocol];
        }
        try
            rwaYield.isRWA(protocol)
                ? rwaYield.getAvailableLiquidity(protocol)
                : protocol == address(flyingTulip)
                    ? flyingTulip.getAvailableLiquidity(protocol)
                    : protocol == address(aavePool)
                        ? IERC20(aavePool.getReserveData(address(stablecoin)).aTokenAddress).balanceOf(address(aavePool))
                        : isCompoundProtocol[protocol]
                            ? IERC20(compound.underlying()).balanceOf(protocol)
                            : defiYield.getAvailableLiquidity(protocol)
        returns (uint256 available) {
            return available;
        } catch {
            emit LiquidityCheckFailed(protocol);
            return manualLiquidityOverrides[protocol] > 0 ? manualLiquidityOverrides[protocol] : 0;
        }
    }

    /**
     * @notice Sets the last known APY for a protocol.
     */
    function setLastKnownAPY(address protocol, uint256 apy) external onlyGovernance sonicFeeMonetization {
        require(protocol != address(0), "Invalid protocol");
        require(apy <= MAX_APY, "APY exceeds maximum");
        lastKnownAPYs[protocol] = apy;
        emit LastKnownAPYUpdated(protocol, apy);
    }

    /**
     * @notice Sets emergency pause state.
     */
    function setEmergencyPause(bool status) external onlyGovernance sonicFeeMonetization {
        emergencyPaused = status;
        if (status) {
            _pause();
            pauseTimestamp = block.timestamp;
        } else {
            _unpause();
            pauseTimestamp = 0;
        }
        emit EmergencyPause(status);
    }

    /**
     * @notice Automatically unpauses after max pause duration.
     */
    function autoUnpause() external sonicFeeMonetization {
        require(emergencyPaused && block.timestamp >= pauseTimestamp + MAX_PAUSE_DURATION, "Pause not expired");
        emergencyPaused = false;
        _unpause();
        pauseTimestamp = 0;
        emit EmergencyPause(false);
    }

    /**
     * @notice Proposes updating management and performance fees.
     */
    function proposeUpdateFees(uint256 newManagementFee, uint256 newPerformanceFee) external onlyGovernance sonicFeeMonetization {
        require(newManagementFee <= 200 && newPerformanceFee <= 2000, "Fees too high");
        bytes32 actionHash = keccak256(abi.encode("updateFees", newManagementFee, newPerformanceFee));
        timelockActions[actionHash] = TimelockAction(actionHash, block.timestamp + TIMELOCK_DELAY, false);
        emit TimelockActionProposed(actionHash, block.timestamp + TIMELOCK_DELAY);
    }

    /**
     * @notice Executes fee update after timelock.
     */
    function executeUpdateFees(uint256 newManagementFee, uint256 newPerformanceFee) external onlyGovernance sonicFeeMonetization {
        bytes32 actionHash = keccak256(abi.encode("updateFees", newManagementFee, newPerformanceFee));
        TimelockAction memory action = timelockActions[actionHash];
        require(action.timestamp > 0 && block.timestamp >= action.timestamp, "Timelock not elapsed");
        require(!action.executed, "Action already executed");
        managementFee = newManagementFee;
        performanceFee = newPerformanceFee;
        timelockActions[actionHash].executed = true;
        emit FeesUpdated(newManagementFee, newPerformanceFee);
        emit TimelockActionExecuted(actionHash);
    }

    /**
     * @notice Updates fee recipient address with timelock.
     */
    function proposeFeeRecipientUpdate(address newRecipient) external onlyGovernance sonicFeeMonetization {
        require(newRecipient != address(0), "Invalid address");
        bytes32 actionHash = keccak256(abi.encode("updateFeeRecipient", newRecipient));
        timelockActions[actionHash] = TimelockAction(actionHash, block.timestamp + TIMELOCK_DELAY, false);
        emit TimelockActionProposed(actionHash, block.timestamp + TIMELOCK_DELAY);
    }

    function executeFeeRecipientUpdate(address newRecipient) external onlyGovernance sonicFeeMonetization {
        bytes32 actionHash = keccak256(abi.encode("updateFeeRecipient", newRecipient));
        TimelockAction memory action = timelockActions[actionHash];
        require(action.timestamp > 0 && block.timestamp >= action.timestamp, "Timelock not elapsed");
        require(!action.executed, "Action already executed");
        feeRecipient = newRecipient;
        timelockActions[actionHash].executed = true;
        emit FeeRecipientUpdated(newRecipient);
        emit TimelockActionExecuted(actionHash);
    }

    /**
     * @notice Proposes a new governance address.
     */
    function updateGovernance(address newGovernance) external onlyGovernance sonicFeeMonetization {
        require(newGovernance != address(0), "Invalid address");
        pendingGovernance = newGovernance;
        governanceUpdateTimestamp = block.timestamp + GOVERNANCE_UPDATE_DELAY;
        emit GovernanceUpdateProposed(newGovernance);
    }

    /**
     * @notice Confirms governance update after delay.
     */
    function confirmGovernanceUpdate() external onlyGovernance sonicFeeMonetization {
        require(block.timestamp >= governanceUpdateTimestamp, "Delay not elapsed");
        require(pendingGovernance != address(0), "No pending governance");
        governance = pendingGovernance;
        pendingGovernance = address(0);
        governanceUpdateTimestamp = 0;
        emit GovernanceUpdated(governance);
    }

    /**
     * @notice Sets liquidity override for a protocol.
     */
    function setLiquidityOverride(address protocol, uint256 liquidity) external onlyGovernance sonicFeeMonetization {
        require(protocol != address(0), "Invalid protocol");
        manualLiquidityOverrides[protocol] = liquidity;
        emit LiquidityOverrideSet(protocol, liquidity);
    }

    /**
     * @notice Updates user blacklist status.
     */
    function updateBlacklist(address user, bool status) external onlyGovernance sonicFeeMonetization {
        require(user != address(0), "Invalid user");
        blacklistedUsers[user] = status;
        emit BlacklistUpdated(user, status);
    }

    /**
     * @notice Whitelists or blacklists a protocol and sets its APY feed.
     */
    function setProtocolWhitelist(address protocol, bool status, address apyFeed, bool isCompound) external onlyGovernance sonicFeeMonetization {
        require(protocol != address(0), "Invalid protocol");
        whitelistedProtocols[protocol] = status;
        isCompoundProtocol[protocol] = isCompound && status;
        if (status && apyFeed != address(0)) {
            protocolAPYFeeds[protocol] = AggregatorV3Interface(apyFeed);
            emit APYFeedUpdated(protocol, apyFeed);
        } else if (!status) {
            delete protocolAPYFeeds[protocol];
            delete isCompoundProtocol[protocol];
            emit APYFeedUpdated(protocol, address(0));
        }
        emit ProtocolWhitelisted(protocol, status);
    }

    /**
     * @notice Proposes recovering funds from a failed protocol.
     */
    function proposeRecoverFunds(address protocol, uint256 amount) external onlyGovernance sonicFeeMonetization {
        require(amount > 0, "Amount must be > 0");
        bytes32 actionHash = keccak256(abi.encode("recoverFunds", protocol, amount));
        timelockActions[actionHash] = TimelockAction(actionHash, block.timestamp + TIMELOCK_DELAY, false);
        emit TimelockActionProposed(actionHash, block.timestamp + TIMELOCK_DELAY);
    }

    /**
     * @notice Executes fund recovery after timelock.
     */
    function executeRecoverFunds(address protocol, uint256 amount) external onlyGovernance nonReentrant sonicFeeMonetization {
        bytes32 actionHash = keccak256(abi.encode("recoverFunds", protocol, amount));
        TimelockAction memory action = timelockActions[actionHash];
        require(action.timestamp > 0 && block.timestamp >= action.timestamp, "Timelock not elapsed");
        require(!action.executed, "Action already executed");
        uint256 withdrawn = _withdrawFromProtocol(protocol, amount);
        require(withdrawn > 0, "No funds recovered");
        allocations[protocol].amount -= withdrawn;
        _cleanAllocations();
        timelockActions[actionHash].executed = true;
        emit FundsRecovered(protocol, withdrawn);
        emit TimelockActionExecuted(actionHash);
    }

    /**
     * @notice Proposes an emergency withdrawal for a user.
     */
    function proposeEmergencyWithdraw(address user, uint256 amount) external onlyGovernance sonicFeeMonetization {
        require(userBalances[user] >= amount, "Insufficient balance");
        bytes32 actionHash = keccak256(abi.encode("emergencyWithdraw", user, amount));
        timelockActions[actionHash] = TimelockAction(actionHash, block.timestamp + TIMELOCK_DELAY, false);
        emit TimelockActionProposed(actionHash, block.timestamp + TIMELOCK_DELAY);
    }

    /**
     * @notice Executes an emergency withdrawal after timelock.
     */
    function executeEmergencyWithdraw(address user, uint256 amount) external onlyGovernance sonicFeeMonetization {
        bytes32 actionHash = keccak256(abi.encode("emergencyWithdraw", user, amount));
        TimelockAction memory action = timelockActions[actionHash];
        require(action.timestamp > 0 && block.timestamp >= action.timestamp, "Timelock not elapsed");
        require(!action.executed, "Action already executed");
        require(emergencyPaused, "Not emergency paused");
        require(userBalances[user] >= amount, "Insufficient balance");
        userBalances[user] -= amount;
        totalAllocated -= amount;
        stablecoin.safeTransfer(user, amount);
        timelockActions[actionHash].executed = true;
        emit EmergencyTransfer(user, amount);
        emit TimelockActionExecuted(actionHash);
    }

    /**
     * @notice Proposes an emergency transfer of stuck funds.
     */
    function proposeEmergencyTransfer(address user, uint256 amount) external onlyGovernance sonicFeeMonetization {
        require(stablecoin.balanceOf(address(this)) >= amount, "Insufficient balance");
        bytes32 actionHash = keccak256(abi.encode("emergencyTransfer", user, amount));
        timelockActions[actionHash] = TimelockAction(actionHash, block.timestamp + TIMELOCK_DELAY, false);
        emit TimelockActionProposed(actionHash, block.timestamp + TIMELOCK_DELAY);
    }

    /**
     * @notice Executes an emergency transfer after timelock.
     */
    function executeEmergencyTransfer(address user, uint256 amount) external onlyGovernance sonicFeeMonetization {
        bytes32 actionHash = keccak256(abi.encode("emergencyTransfer", user, amount));
        TimelockAction memory action = timelockActions[actionHash];
        require(action.timestamp > 0 && block.timestamp >= action.timestamp, "Timelock not elapsed");
        require(!action.executed, "Action already executed");
        require(emergencyPaused, "Not emergency paused");
        require(stablecoin.balanceOf(address(this)) >= amount, "Insufficient balance");
        stablecoin.safeTransfer(user, amount);
        timelockActions[actionHash].executed = true;
        emit EmergencyTransfer(user, amount);
        emit TimelockActionExecuted(actionHash);
    }

    /**
     * @notice Checks APY staleness for active protocols.
     */
    function checkAPYStaleness() external view returns (address[] memory protocols, uint256[] memory staleness) {
        protocols = new address[](activeProtocols.length);
        staleness = new uint256[](activeProtocols.length);
        for (uint256 i = 0; i < activeProtocols.length; i++) {
            protocols[i] = activeProtocols[i];
            staleness[i] = block.timestamp - allocations[activeProtocols[i]].lastUpdated;
        }
    }

    /**
     * @notice Checks if upkeep is needed for Chainlink Automation.
     */
    function checkUpkeep(bytes calldata checkData) external view override returns (bool upkeepNeeded, bytes memory performData) {
        upkeepNeeded = (block.timestamp >= lastUpkeepTimestamp + UPKEEP_INTERVAL);
        if (block.timestamp >= lastUpkeepTimestamp + UPKEEP_INTERVAL * 2) {
            emit UpkeepStale(lastUpkeepTimestamp, block.timestamp);
        }
        performData = checkData;
        return (upkeepNeeded, performData);
    }

    /**
     * @notice Performs upkeep to update lastKnownAPYs.
     */
    function performUpkeep(bytes calldata performData) external override sonicFeeMonetization {
        require(block.timestamp >= lastUpkeepTimestamp + UPKEEP_INTERVAL, "Upkeep not yet due");
        lastUpkeepTimestamp = block.timestamp;

        for (uint256 i = 0; i < activeProtocols.length; i++) {
            address protocol = activeProtocols[i];
            AggregatorV3Interface feed = protocolAPYFeeds[protocol];
            if (address(feed) != address(0)) {
                try feed.latestRoundData() returns (uint80, int256 answer, , uint256 updatedAt, uint80) {
                    if (answer > 0 && block.timestamp <= updatedAt + MAX_STALENESS && uint256(answer) <= MAX_APY) {
                        lastKnownAPYs[protocol] = uint256(answer);
                        emit LastKnownAPYUpdated(protocol, uint256(answer));
                    }
                } catch {
                    // Skip failed feeds
                }
            } else if (protocol == address(aavePool)) {
                uint256 apy = _getAaveAPY(address(stablecoin));
                if (apy > 0 && apy <= MAX_APY) {
                    lastKnownAPYs[protocol] = apy;
                    emit LastKnownAPYUpdated(protocol, apy);
                }
            } else if (isCompoundProtocol[protocol]) {
                uint256 apy = _getCompoundAPY(protocol);
                if (apy > 0 && apy <= MAX_APY) {
                    lastKnownAPYs[protocol] = apy;
                    emit LastKnownAPYUpdated(protocol, apy);
                }
            } else {
                uint256 apy = sonicProtocol.getSonicAPY(protocol);
                if (apy > 0 && apy <= MAX_APY) {
                    lastKnownAPYs[protocol] = apy;
                    emit LastKnownAPYUpdated(protocol, apy);
                }
            }
        }
    }

    /**
     * @notice Allocates funds to protocols, delegating RWA allocations to AIYieldOptimizer.
     */
    function _allocateFunds(uint256 amount, uint256 startIndex, uint256 endIndex) internal {
        require(endIndex <= activeProtocols.length && startIndex <= endIndex, "Invalid indices");
        (address[] memory protocols, uint256[] memory apys) = _getAPYsFromChainlink();
        require(protocols.length <= MAX_PROTOCOLS, "Too many protocols");
        if (protocols.length == 0) {
            emit AllocationSkipped(address(0), "No valid protocols");
            return;
        }
        require(protocols.length == apys.length, "APY data mismatch");

        uint256 totalWeightedAPY = 0;
        uint256 nonRWAAmount = 0;

        // Gas Optimization: Cache weights in memory
        uint256[] memory weights = new uint256[](protocols.length);
        for (uint256 i = 0; i < protocols.length; i++) {
            if (!_isValidProtocol(protocols[i]) || !_validateAPY(apys[i], protocols[i])) {
                continue;
            }
            // New: Stricter RWA validation
            if (rwaYield.isRWA(protocols[i]) && !validateRWAProtocol(protocols[i])) {
                emit AllocationSkipped(protocols[i], "RWA validation failed");
                continue;
            }
            uint256 riskScore = protocolRiskScores[protocols[i]] > 0 ? protocolRiskScores[protocols[i]] : 5000;
            uint256 riskAdjustedAPY = (apys[i] * (10000 - riskScore)) / 10000;
            weights[i] = riskAdjustedAPY;
            totalWeightedAPY += riskAdjustedAPY;
        }

        // Allocate to non-RWA protocols
        for (uint256 i = startIndex; i < endIndex && i < protocols.length; i++) {
            if (rwaYield.isRWA(protocols[i]) || weights[i] == 0) {
                continue;
            }
            uint256 allocAmount = (amount * weights[i]) / (totalWeightedAPY == 0 ? 1 : totalWeightedAPY);
            if (allocAmount < MIN_ALLOCATION) {
                emit AllocationSkipped(protocols[i], "Amount below minimum");
                continue;
            }
            bool isLeveraged = allowLeverage && _assessLeverageViability(protocols[i], allocAmount);
            // New: Dynamic leverage adjustment
            if (isLeveraged) {
                isLeveraged = adjustLeverageDynamically(protocols[i], allocAmount);
            }
            allocations[protocols[i]] = Allocation(protocols[i], allocAmount, apys[i], block.timestamp, isLeveraged);
            lastKnownAPYs[protocols[i]] = apys[i];
            if (!isActiveProtocol[protocols[i]]) {
                activeProtocols.push(protocols[i]);
                isActiveProtocol[protocols[i]] = true;
            }
            _depositToProtocol(protocols[i], allocAmount, isLeveraged);
            nonRWAAmount += allocAmount;
            sonicPointsEarned[msg.sender] += allocAmount * 2;
            if (isLeveraged) {
                _applyLeverage(protocols[i], allocAmount);
            }
            emit AIAllocationOptimized(protocols[i], allocAmount, apys[i], isLeveraged);
            emit Rebalance(protocols[i], allocAmount, apys[i], isLeveraged);
        }

        // Delegate RWA allocation
        uint256 rwaAmount = amount > nonRWAAmount ? amount - nonRWAAmount : 0;
        if (rwaAmount >= MIN_ALLOCATION) {
            (address[] memory rwaProtocols, uint256[] memory amounts, bool[] memory isLeveraged) = aiYieldOptimizer.getRecommendedAllocations(rwaAmount);
            // New: Validate AI allocations
            require(validateAIAllocations(rwaProtocols, amounts, rwaAmount), "Invalid AI allocations");
            stablecoin.safeApprove(address(aiYieldOptimizer), 0);
            stablecoin.safeApprove(address(aiYieldOptimizer), rwaAmount);
            stablecoin.safeTransfer(address(aiYieldOptimizer), rwaAmount);
            aiYieldOptimizer.submitAIAllocation(rwaProtocols, amounts, isLeveraged);
            // New: Emit AI allocation details
            string memory logicDescription = aiYieldOptimizer.getAllocationLogic(rwaAmount);
            emit AIAllocationDetails(rwaProtocols, amounts, isLeveraged, logicDescription);
            sonicPointsEarned[msg.sender] += rwaAmount * 2;
            emit RWADelegatedToAI(address(aiYieldOptimizer), rwaAmount);
        }
    }

    /**
     * @notice Deallocates funds from protocols with Sonic points tracking.
     */
    function _deallocateFunds(uint256 amount, uint256 startIndex, uint256 endIndex) internal returns (uint256) {
        require(endIndex <= activeProtocols.length && startIndex <= endIndex, "Invalid indices");
        uint256 totalWithdrawn = 0;
        address[] memory sortedProtocols = _sortProtocolsByLiquidity();
        address[] memory rwaProtocols = aiYieldOptimizer.getSupportedProtocols();

        // Withdraw from RWA protocols
        uint256 rwaBalance = aiYieldOptimizer.getTotalRWABalance();
        if (rwaBalance > 0) {
            uint256 rwaWithdrawAmount = (amount * rwaBalance) / (totalAllocated == 0 ? 1 : totalAllocated);
            for (uint256 i = 0; i < rwaProtocols.length && totalWithdrawn < amount; i++) {
                address protocol = rwaProtocols[i];
                if (rwaWithdrawAmount > 0) {
                    uint256 availableLiquidity = rwaYield.getAvailableLiquidity(protocol);
                    uint256 withdrawAmount = rwaWithdrawAmount > availableLiquidity ? availableLiquidity : rwaWithdrawAmount;
                    try aiYieldOptimizer.withdrawForYieldOptimizer(protocol, withdrawAmount) returns (uint256 withdrawn) {
                        totalWithdrawn += withdrawn;
                        sonicPointsEarned[msg.sender] += withdrawn;
                    } catch {
                        emit WithdrawalFailed(protocol, withdrawAmount);
                    }
                }
            }
        }

        // Withdraw from non-RWA protocols
        for (uint256 i = startIndex; i < endIndex && totalWithdrawn < amount; i++) {
            address protocol = sortedProtocols[i];
            if (rwaYield.isRWA(protocol)) {
                continue;
            }
            Allocation storage alloc = allocations[protocol];
            uint256 withdrawAmount = (amount * alloc.amount) / (totalAllocated == 0 ? 1 : totalAllocated);
            if (withdrawAmount > 0) {
                uint256 availableLiquidity = getProtocolLiquidity(protocol);
                withdrawAmount = withdrawAmount > availableLiquidity ? availableLiquidity : withdrawAmount;
                uint256 withdrawn = _withdrawFromProtocol(protocol, withdrawAmount);
                alloc.amount -= withdrawn;
                totalWithdrawn += withdrawn;
                sonicPointsEarned[msg.sender] += withdrawn;
            }
        }
        _cleanAllocations();
        return totalWithdrawn;
    }

    /**
     * @notice Deposits funds to a protocol.
     */
    function _depositToProtocol(address protocol, uint256 amount, bool isLeveraged) internal {
        stablecoin.safeApprove(protocol, 0);
        stablecoin.safeApprove(protocol, amount);
        if (rwaYield.isRWA(protocol)) {
            rwaYield.depositToRWA(protocol, amount);
        } else if (protocol == address(flyingTulip)) {
            flyingTulip.depositToPool(protocol, amount, isLeveraged);
        } else if (protocol == address(aavePool)) {
            try aavePool.supply(address(stablecoin), amount, address(this), AAVE_REFERRAL_CODE) {
                (, , , , , , address aTokenAddress, , , , , , ) = aavePool.getReserveData(address(stablecoin));
                emit AaveSupply(protocol, amount, aTokenAddress);
            } catch {
                emit AaveSupplyFailed(protocol, amount, "Supply failed");
                revert("Aave supply failed");
            }
        } else if (isCompoundProtocol[protocol]) {
            try compound.mint(amount) returns (uint256 err) {
                require(err == 0, "Compound mint failed");
                emit CompoundSupply(protocol, amount, protocol);
            } catch {
                emit CompoundSupplyFailed(protocol, amount, "Mint failed");
                revert("Compound mint failed");
            }
        } else {
            defiYield.depositToDeFi(protocol, amount);
        }
    }

    /**
     * @notice Withdraws funds from a protocol, handling partial withdrawals.
     */
    function _withdrawFromProtocol(address protocol, uint256 amount) internal returns (uint256) {
        uint256 balanceBefore = stablecoin.balanceOf(address(this));
        uint256 withdrawn = 0;
        try
            rwaYield.isRWA(protocol)
                ? rwaYield.withdrawFromRWA(protocol, amount)
                : protocol == address(flyingTulip)
                    ? flyingTulip.withdrawFromPool(protocol, amount)
                    : protocol == address(aavePool)
                        ? aavePool.withdraw(address(stablecoin), amount, address(this))
                        : isCompoundProtocol[protocol]
                            ? compound.redeemUnderlying(amount) == 0 ? amount : 0
                            : defiYield.withdrawFromDeFi(protocol, amount)
        returns (uint256 amountWithdrawn) {
            withdrawn = amountWithdrawn;
            if (protocol == address(aavePool)) {
                emit AaveWithdraw(protocol, withdrawn);
            } else if (isCompoundProtocol[protocol]) {
                emit CompoundWithdraw(protocol, withdrawn);
            }
        } catch {
            emit WithdrawalFailed(protocol, amount);
            if (protocol == address(aavePool)) {
                emit AaveWithdrawFailed(protocol, amount, "Withdraw failed");
            } else if (isCompoundProtocol[protocol]) {
                emit CompoundWithdrawFailed(protocol, amount, "Redeem failed");
            }
        }
        require(stablecoin.balanceOf(address(this)) >= balanceBefore + withdrawn, "Withdrawal balance mismatch");
        return withdrawn;
    }

    /**
     * @notice Withdraws funds from protocols to cover repayment needs.
     */
    function _withdrawForRepayment(uint256 amount) internal nonReentrant {
        uint256 totalWithdrawn = 0;
        address[] memory sortedProtocols = _sortProtocolsByLiquidity();
        address[] memory rwaProtocols = aiYieldOptimizer.getSupportedProtocols();

        // Withdraw from RWA protocols
        uint256 rwaBalance = aiYieldOptimizer.getTotalRWABalance();
        if (rwaBalance > 0) {
            uint256 rwaWithdrawAmount = amount > rwaBalance ? rwaBalance : amount;
            for (uint256 i = 0; i < rwaProtocols.length && totalWithdrawn < amount; i++) {
                address protocol = rwaProtocols[i];
                uint256 availableLiquidity = rwaYield.getAvailableLiquidity(protocol);
                uint256 withdrawAmount = rwaWithdrawAmount > availableLiquidity ? availableLiquidity : rwaWithdrawAmount;
                try aiYieldOptimizer.withdrawForYieldOptimizer(protocol, withdrawAmount) returns (uint256 withdrawn) {
                    totalWithdrawn += withdrawn;
                    emit FundsWithdrawnForRepayment(protocol, withdrawn);
                } catch {
                    emit WithdrawalFailed(protocol, withdrawAmount);
                }
            }
        }

        // Withdraw from non-RWA protocols
        for (uint256 i = 0; i < sortedProtocols.length && totalWithdrawn < amount; i++) {
            address protocol = sortedProtocols[i];
            if (rwaYield.isRWA(protocol)) {
                continue;
            }
            Allocation storage alloc = allocations[protocol];
            uint256 availableLiquidity = getProtocolLiquidity(protocol);
            if (alloc.amount > 0 && availableLiquidity > 0) {
                uint256 withdrawAmount = amount - totalWithdrawn;
                withdrawAmount = withdrawAmount > alloc.amount ? alloc.amount : withdrawAmount;
                withdrawAmount = withdrawAmount > availableLiquidity ? availableLiquidity : withdrawAmount;
                uint256 withdrawn = _withdrawFromProtocol(protocol, withdrawAmount);
                alloc.amount -= withdrawn;
                totalWithdrawn += withdrawn;
                emit FundsWithdrawnForRepayment(protocol, withdrawn);
            }
        }
        _cleanAllocations();
        require(totalWithdrawn >= amount, "Insufficient funds withdrawn for repayment");
    }

    /**
     * @notice Pauses leverage for a protocol due to withdrawal failure.
     */
    function _pauseLeverage(address protocol) internal {
        Allocation storage alloc = allocations[protocol];
        if (alloc.isLeveraged) {
            alloc.isLeveraged = false;
            emit AllocationSkipped(protocol, "Leverage paused due to withdrawal failure");
        }
    }

    /**
     * @notice Cleans up zero-amount allocations efficiently.
     */
    function _cleanAllocations() internal {
        // Gas Optimization: Single-pass cleanup with dynamic resize
        uint256 writeIndex = 0;
        address[] memory tempProtocols = activeProtocols;
        for (uint256 i = 0; i < tempProtocols.length; i++) {
            address protocol = tempProtocols[i];
            if (allocations[protocol].amount > 0) {
                if (i != writeIndex) {
                    activeProtocols[writeIndex] = protocol;
                }
                writeIndex++;
            } else {
                delete allocations[protocol];
                isActiveProtocol[protocol] = false;
            }
        }
        // Resize activeProtocols array
        while (activeProtocols.length > writeIndex) {
            activeProtocols.pop();
        }
    }

        /**
     * @notice Validates a protocol for allocation with Sonic compliance.
     */
    function _isValidProtocol(address protocol) internal view returns (bool) {
        return whitelistedProtocols[protocol] &&
            (address(protocolAPYFeeds[protocol]) != address(0) || lastKnownAPYs[protocol] > 0 || protocol == address(aavePool) || isCompoundProtocol[protocol]) &&
            (rwaYield.isRWA(protocol) || protocol == address(flyingTulip) || protocol == address(aavePool) || isCompoundProtocol[protocol] || defiYield.isDeFiProtocol(protocol)) &&
            sonicProtocol.isSonicCompliant(protocol);
    }

    /**
     * @notice Validates APY data for a protocol.
     */
    function _validateAPY(uint256 apy, address protocol) internal view returns (bool) {
        uint256 liquidity = getProtocolLiquidity(protocol);
        return apy > 0 && apy <= MAX_APY && liquidity > 0;
    }

    /**
     * @notice Fetches APYs from Chainlink/RedStone oracles with fallback to protocol-direct sources.
     */
    function _getAPYsFromChainlink() internal view returns (address[] memory protocols, uint256[] memory apys) {
        // Gas Optimization: Pre-allocate arrays with max size
        address[] memory tempProtocols = new address[](MAX_PROTOCOLS);
        uint256[] memory tempAPYs = new uint256[](MAX_PROTOCOLS);
        uint256 count = 0;

        for (uint256 i = 0; i < activeProtocols.length && count < MAX_PROTOCOLS; i++) {
            address protocol = activeProtocols[i];
            if (!_isValidProtocol(protocol)) {
                continue;
            }
            uint256 apy;
            AggregatorV3Interface feed = protocolAPYFeeds[protocol];
            bool feedValid = false;

            // Try Chainlink/RedStone feed first
            if (address(feed) != address(0)) {
                try feed.latestRoundData() returns (uint80, int256 answer, , uint256 updatedAt, uint80) {
                    if (answer > 0 && block.timestamp <= updatedAt + MAX_STALENESS && uint256(answer) <= MAX_APY) {
                        apy = uint256(answer);
                        feedValid = true;
                    }
                } catch {
                    // Fallback to protocol-direct APY
                }
            }

            // Fallback to protocol-direct APY sources
            if (!feedValid) {
                try this._getProtocolDirectAPY(protocol) returns (uint256 directAPY) {
                    if (directAPY > 0 && directAPY <= MAX_APY) {
                        apy = directAPY;
                    } else {
                        apy = lastKnownAPYs[protocol];
                    }
                } catch {
                    apy = lastKnownAPYs[protocol];
                }
            }

            if (apy > 0) {
                tempProtocols[count] = protocol;
                tempAPYs[count] = apy;
                count++;
            }
        }

        // Resize arrays to actual size
        protocols = new address[](count);
        apys = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            protocols[i] = tempProtocols[i];
            apys[i] = tempAPYs[i];
        }
    }

    /**
     * @notice Fetches APY directly from protocol interfaces (Aave, Compound, etc.).
     */
    function _getProtocolDirectAPY(address protocol) external view returns (uint256) {
        if (protocol == address(aavePool)) {
            return _getAaveAPY(address(stablecoin));
        } else if (isCompoundProtocol[protocol]) {
            return _getCompoundAPY(protocol);
        } else if (protocol == address(flyingTulip)) {
            return flyingTulip.getDynamicAPY(protocol);
        } else if (rwaYield.isRWA(protocol)) {
            return rwaYield.getRWAYield(protocol);
        } else {
            return sonicProtocol.getSonicAPY(protocol);
        }
    }

    /**
     * @notice Gets Aave APY for a given asset.
     */
    function _getAaveAPY(address asset) internal view returns (uint256) {
        try aavePool.getReserveData(asset) returns (
            uint256, uint256, uint256 currentLiquidityRate, , , , , , , , , ,
        ) {
            // Convert liquidity rate to APY (simplified)
            return (currentLiquidityRate * BASIS_POINTS) / 1e27;
        } catch {
            return 0;
        }
    }

    /**
     * @notice Gets Compound APY for a given protocol.
     */
    function _getCompoundAPY(address protocol) internal view returns (uint256) {
        try compound.supplyRatePerBlock() returns (uint256 ratePerBlock) {
            // Convert rate per block to annual APY
            return (ratePerBlock * BLOCKS_PER_YEAR * BASIS_POINTS) / 1e18;
        } catch {
            return 0;
        }
    }

    /**
     * @notice Sorts protocols by available liquidity for efficient withdrawals.
     */
    function _sortProtocolsByLiquidity() internal view returns (address[] memory) {
        address[] memory sortedProtocols = new address[](activeProtocols.length);
        uint256[] memory liquidities = new uint256[](activeProtocols.length);

        // Collect liquidities
        for (uint256 i = 0; i < activeProtocols.length; i++) {
            sortedProtocols[i] = activeProtocols[i];
            liquidities[i] = getProtocolLiquidity(activeProtocols[i]);
        }

        // Gas Optimization: Simple bubble sort for small arrays
        for (uint256 i = 0; i < activeProtocols.length; i++) {
            for (uint256 j = i + 1; j < activeProtocols.length; j++) {
                if (liquidities[i] < liquidities[j]) {
                    (sortedProtocols[i], sortedProtocols[j]) = (sortedProtocols[j], sortedProtocols[i]);
                    (liquidities[i], liquidities[j]) = (liquidities[j], liquidities[i]);
                }
            }
        }

        return sortedProtocols;
    }

    /**
     * @notice Checks liquidation risk for leveraged positions.
     */
    function _checkLiquidationRisk(address protocol, uint256 collateral, uint256 borrowAmount) internal view returns (bool) {
        if (protocol == address(flyingTulip)) {
            uint256 ltv = flyingTulip.getLTV(protocol, collateral);
            return ltv <= MAX_LTV && borrowAmount <= collateral * ltv / BASIS_POINTS;
        } else if (protocol == address(aavePool)) {
            (, , , , , uint256 healthFactor) = aavePool.getUserAccountData(address(this));
            return healthFactor >= MIN_HEALTH_FACTOR;
        } else if (isCompoundProtocol[protocol]) {
            (, uint256 collateralFactor, uint256 liquidity) = compound.getAccountLiquidity(address(this));
            return collateralFactor >= MIN_COLLATERAL_FACTOR && borrowAmount <= liquidity;
        }
        return false;
    }

    /**
     * @notice Calculates user profit with PRBMath for compound interest.
     */
    function _calculateProfit(address user, uint256 amount) internal view returns (uint256) {
        uint256 userBalance = userBalances[user];
        if (userBalance == 0 || amount > userBalance) {
            return 0;
        }

        uint256 totalProfit = 0;
        uint256 userShare = (amount * FIXED_POINT_SCALE) / userBalance;

        for (uint256 i = 0; i < activeProtocols.length; i++) {
            address protocol = activeProtocols[i];
            Allocation memory alloc = allocations[protocol];
            if (alloc.amount == 0 || alloc.apy == 0) {
                continue;
            }
            uint256 timeElapsed = block.timestamp - alloc.lastUpdated;
            if (timeElapsed == 0) {
                continue;
            }

            // Simplified compound interest using PRBMath
            uint256 apyScaled = (alloc.apy * FIXED_POINT_SCALE) / BASIS_POINTS;
            uint256 ratePerSecond = apyScaled / SECONDS_PER_YEAR;
            uint256 exponent = ratePerSecond * timeElapsed;
            if (exponent > MAX_EXP_INPUT) {
                continue;
            }

            uint256 profitFactor = PRBMathUD60x18.exp(exponent);
            uint256 principal = (alloc.amount * userShare) / FIXED_POINT_SCALE;
            uint256 profit = (principal * (profitFactor - FIXED_POINT_SCALE)) / FIXED_POINT_SCALE;
            totalProfit += profit;
        }

        // Include RWA profits from AIYieldOptimizer
        uint256 rwaBalance = aiYieldOptimizer.getTotalRWABalance();
        if (rwaBalance > 0) {
            uint256 rwaShare = (rwaBalance * userShare) / FIXED_POINT_SCALE;
            // Assume average RWA APY (simplified)
            uint256 rwaAPY = lastKnownAPYs[address(aiYieldOptimizer)] > 0 ? lastKnownAPYs[address(aiYieldOptimizer)] : 500; // 5% default
            uint256 timeElapsed = block.timestamp - lastUpkeepTimestamp;
            uint256 rwaProfit = (rwaShare * rwaAPY * timeElapsed) / (BASIS_POINTS * SECONDS_PER_YEAR);
            totalProfit += rwaProfit;
        }

        return totalProfit >= MIN_PROFIT ? totalProfit : 0;
    }

    /**
     * @notice Gets user balance with estimated profits and Sonic Points.
     */
    function getUserBalance(address user) external view returns (uint256 balance, uint256 estimatedProfit, uint256 points) {
        balance = userBalances[user];
        estimatedProfit = _calculateProfit(user, balance);
        points = sonicPointsEarned[user];
    }

    /**
     * @notice Gets estimated profit for a user with detailed breakdown.
     */
    function getEstimatedProfit(address user) external view returns (uint256 totalProfit, AllocationBreakdown[] memory breakdown) {
        uint256 userBalance = userBalances[user];
        if (userBalance == 0) {
            return (0, new AllocationBreakdown[](0));
        }

        // Initialize breakdown array
        breakdown = new AllocationBreakdown[](activeProtocols.length + 1); // +1 for RWA
        uint256 breakdownIndex = 0;
        uint256 totalProfit = 0;
        uint256 userShare = (userBalance * FIXED_POINT_SCALE) / userBalance;

        // Calculate profits for non-RWA protocols
        for (uint256 i = 0; i < activeProtocols.length; i++) {
            address protocol = activeProtocols[i];
            Allocation memory alloc = allocations[protocol];
            if (alloc.amount == 0 || alloc.apy == 0) {
                continue;
            }
            uint256 timeElapsed = block.timestamp - alloc.lastUpdated;
            if (timeElapsed == 0) {
                continue;
            }

            uint256 apyScaled = (alloc.apy * FIXED_POINT_SCALE) / BASIS_POINTS;
            uint256 ratePerSecond = apyScaled / SECONDS_PER_YEAR;
            uint256 exponent = ratePerSecond * timeElapsed;
            if (exponent > MAX_EXP_INPUT) {
                continue;
            }

            uint256 profitFactor = PRBMathUD60x18.exp(exponent);
            uint256 principal = (alloc.amount * userShare) / FIXED_POINT_SCALE;
            uint256 profit = (principal * (profitFactor - FIXED_POINT_SCALE)) / FIXED_POINT_SCALE;

            breakdown[breakdownIndex] = AllocationBreakdown({
                protocol: protocol,
                amount: principal,
                apy: alloc.apy,
                isLeveraged: alloc.isLeveraged,
                liquidity: getProtocolLiquidity(protocol),
                riskScore: protocolRiskScores[protocol]
            });
            totalProfit += profit;
            breakdownIndex++;
        }

        // Include RWA profits
        uint256 rwaBalance = aiYieldOptimizer.getTotalRWABalance();
        if (rwaBalance > 0) {
            uint256 rwaShare = (rwaBalance * userShare) / FIXED_POINT_SCALE;
            uint256 rwaAPY = lastKnownAPYs[address(aiYieldOptimizer)] > 0 ? lastKnownAPYs[address(aiYieldOptimizer)] : 500;
            uint256 timeElapsed = block.timestamp - lastUpkeepTimestamp;
            uint256 rwaProfit = (rwaShare * rwaAPY * timeElapsed) / (BASIS_POINTS * SECONDS_PER_YEAR);

            breakdown[breakdownIndex] = AllocationBreakdown({
                protocol: address(aiYieldOptimizer),
                amount: rwaShare,
                apy: rwaAPY,
                isLeveraged: false,
                liquidity: rwaBalance,
                riskScore: protocolRiskScores[address(aiYieldOptimizer)]
            });
            totalProfit += rwaProfit;
            breakdownIndex++;
        }

        // Resize breakdown array
        AllocationBreakdown[] memory finalBreakdown = new AllocationBreakdown[](breakdownIndex);
        for (uint256 i = 0; i < breakdownIndex; i++) {
            finalBreakdown[i] = breakdown[i];
        }

        return (totalProfit >= MIN_PROFIT ? totalProfit : 0, finalBreakdown);
    }

    /**
     * @notice Gets detailed allocation breakdown for transparency.
     */
    function getAllocationBreakdown() external view returns (AllocationBreakdown[] memory) {
        // Initialize breakdown array
        AllocationBreakdown[] memory breakdown = new AllocationBreakdown[](activeProtocols.length + 1); // +1 for RWA
        uint256 breakdownIndex = 0;

        // Non-RWA protocols
        for (uint256 i = 0; i < activeProtocols.length; i++) {
            address protocol = activeProtocols[i];
            Allocation memory alloc = allocations[protocol];
            if (alloc.amount == 0) {
                continue;
            }
            breakdown[breakdownIndex] = AllocationBreakdown({
                protocol: protocol,
                amount: alloc.amount,
                apy: alloc.apy,
                isLeveraged: alloc.isLeveraged,
                liquidity: getProtocolLiquidity(protocol),
                riskScore: protocolRiskScores[protocol]
            });
            breakdownIndex++;
        }

        // RWA allocations
        uint256 rwaBalance = aiYieldOptimizer.getTotalRWABalance();
        if (rwaBalance > 0) {
            uint256 rwaAPY = lastKnownAPYs[address(aiYieldOptimizer)] > 0 ? lastKnownAPYs[address(aiYieldOptimizer)] : 500;
            breakdown[breakdownIndex] = AllocationBreakdown({
                protocol: address(aiYieldOptimizer),
                amount: rwaBalance,
                apy: rwaAPY,
                isLeveraged: false,
                liquidity: rwaBalance,
                riskScore: protocolRiskScores[address(aiYieldOptimizer)]
            });
            breakdownIndex++;
        }

        // Resize breakdown array
        AllocationBreakdown[] memory finalBreakdown = new AllocationBreakdown[](breakdownIndex);
        for (uint256 i = 0; i < breakdownIndex; i++) {
            finalBreakdown[i] = breakdown[i];
        }

        return finalBreakdown;
    }

    /**
     * @notice Gets AI allocation details for transparency.
     */
    function getAIAllocationDetails(uint256 amount) external view returns (
        address[] memory protocols,
        uint256[] memory amounts,
        bool[] memory isLeveraged,
        string memory logicDescription
    ) {
        (protocols, amounts, isLeveraged) = aiYieldOptimizer.getRecommendedAllocations(amount);
        logicDescription = aiYieldOptimizer.getAllocationLogic(amount);
    }

    /**
     * @notice Fallback function to prevent accidental ETH deposits.
     */
    receive() external payable {
        revert("ETH deposits not allowed");
    }
}  
