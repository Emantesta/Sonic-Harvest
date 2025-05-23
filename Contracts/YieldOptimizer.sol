// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@prb/math/PRBMathUD60x18.sol";

// Interfaces (unchanged from original)
interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
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
}

interface ICompound {
    function mint(uint256 mintAmount) external returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
    function supplyRatePerBlock() external view returns (uint256);
    function underlying() external view returns (address);
}

interface IRWAYield {
    function depositToRWA(address protocol, uint256 amount) external;
    function withdrawFromRWA(address protocol, uint256 amount) external returns (uint256);
    function isRWA(address protocol) external view returns (bool);
    function getRWAYield(address protocol) external view returns (uint256);
    function getAvailableLiquidity(address protocol) external view returns (uint256);
}

interface IDeFiYield {
    function depositToDeFi(address protocol, uint256 amount, bytes32 correlationId) external;
    function withdrawFromDeFi(address protocol, uint256 amount, bytes32 correlationId) external returns (uint256);
    function isDeFiProtocol(address protocol) external view returns (bool);
    function getAvailableLiquidity(address protocol) external view returns (uint256);
    function getTotalDeFiBalance() external view returns (uint256);
    function protocolScores(address protocol) external view returns (uint256 apy, uint256 tvl, uint256 riskScore, uint256 score);
}

interface IFlyingTulip {
    function depositToPool(address pool, uint256 amount, bool useLeverage) external returns (uint256);
    function withdrawFromPool(address pool, uint256 amount) external returns (uint256);
    function getDynamicAPY(address pool) external view returns (uint256);
    function isOFACCompliant(address user) external view returns (bool);
    function getAvailableLiquidity(address pool) external view returns (uint256);
}

interface ISonicProtocol {
    function depositFeeMonetizationRewards(address recipient, uint256 amount) external returns (bool);
    function isSonicCompliant(address protocol) external view returns (bool);
    function getSonicAPY(address protocol) external view returns (uint256);
}

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
    function getAllocationLogic(uint256 totalAmount) external view returns (string memory logicDescription);
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
    function depositRewards(uint256 amount) external;
    function claimRewards() external;
    function awardPoints(
        address user,
        uint256 amount,
        bool isDeposit,
        bool hasLockup,
        uint256 maxLockupDays
    ) external;
}

interface IGovernanceManager {
    function proposeAction(bytes32 actionHash) external;
    function executeAction(bytes32 actionHash) external;
    function updateGovernance(address newGovernance) external;
    function votingPower(address user) external view returns (uint256);
}

interface IUpkeepManager {
    function manualUpkeep(bool isRWA) external;
}

interface IGovernanceVault {
    function getFeeDiscount(address user) external view returns (uint256);
    function votingPower(address user) external view returns (uint256);
    function distributeProfits(uint256 amount) external;
}

interface IPointsTierManager {
    function assignTier(address user, uint256 totalAmount, bool hasLockup, uint256 maxLockupDays) external;
    function getUserMultiplier(address user) external view returns (uint256);
}

/**
 * @title YieldOptimizer
 * @notice DeFi yield farming aggregator for Sonic Blockchain, integrating with DeFiYield and AIYieldOptimizer.
 * @dev Uses UUPS proxy for upgradability, supports Sonic Points, lockup periods, and optimized rebalancing.
 *      Integrates with multiple protocols (Aave, Compound, FlyingTulip) and handles RWA allocations via AIYieldOptimizer.
 */
contract YieldOptimizer is UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using PRBMathUD60x18 for uint256;

    // State variables
    IERC20 public immutable stablecoin; // Stablecoin used for deposits/withdrawals (e.g., USDC)
    IRWAYield public immutable rwaYield; // Interface for RWA protocol interactions
    IDeFiYield public immutable defiYield; // Interface for DeFi protocol interactions
    IFlyingTulip public immutable flyingTulip; // Interface for FlyingTulip protocol
    IAaveV3Pool public immutable aavePool; // Interface for Aave V3 pool
    ICompound public immutable compound; // Interface for Compound protocol
    ISonicProtocol public immutable sonicProtocol; // Interface for Sonic protocol compliance and APY
    IAIYieldOptimizer public immutable aiYieldOptimizer; // Interface for AI-driven RWA allocations
    IRegistry public registry; // Registry for active protocols
    IRiskManager public riskManager; // Risk management for leverage and APY adjustments
    ILooperCore public looperCore; // Leverage application and liquidation checks
    IStakingManager public stakingManager; // Staking rewards and points
    IGovernanceManager public governanceManager; // Governance for critical actions
    IUpkeepManager public upkeepManager; // Upkeep for protocol maintenance
    IGovernanceVault public governanceVault; // Governance vault for fee discounts and voting power
    IPointsTierManager public pointsTierManager; // Points tier management for user rewards
    address public feeRecipient; // Recipient of management and performance fees
    uint256 public managementFee; // Management fee in basis points (e.g., 50 = 0.5%)
    uint256 public performanceFee; // Performance fee in basis points (e.g., 1000 = 10%)
    uint256 public maxLockups; // Maximum number of lockups per user
    uint256 public totalAllocated; // Total funds allocated to protocols
    uint256 public minRWALiquidityThreshold; // Minimum liquidity threshold for RWA protocols
    bool public allowLeverage; // Flag to enable/disable leverage
    bool public isPaused; // Pause status of the contract
    mapping(address => uint256) public userBalances; // User deposited balances
    mapping(address => Allocation) public allocations; // Protocol allocations
    mapping(address => bool) public blacklistedUsers; // Blacklisted users
    mapping(address => uint256) public lastKnownAPYs; // Last known APYs for protocols
    mapping(address => Lockup[]) public userLockups; // User lockup periods

    // Constants
    uint256 public constant BASIS_POINTS = 10000; // Basis points for fee calculations
    uint256 private constant SECONDS_PER_YEAR = 365 days; // Seconds in a year for APY calculations
    uint256 private constant MAX_APY = 10000; // Maximum APY (100%)
    uint256 private constant FIXED_POINT_SCALE = 1e18; // Fixed-point scale for calculations
    uint256 private constant MAX_EXP_INPUT = 10e18; // Maximum exponent for PRBMath
    uint256 private constant MIN_PROFIT = 1e6; // Minimum profit threshold (1 USDC)
    uint256 private constant AAVE_REFERRAL_CODE = 0; // Aave referral code
    uint256 private constant MIN_ALLOCATION = 1e16; // Minimum allocation (0.01 USDC)
    uint256 private constant MIN_GOVERNANCE_VOTING_POWER = 1000e18; // Minimum voting power for governance actions
    uint256 private constant DEFAULT_APY = 500; // Default APY (5%) for fallback
    uint256 public immutable MIN_DEPOSIT; // Minimum deposit amount based on stablecoin decimals
    uint256 private constant MAX_FEE_BPS = 2000; // Maximum total fee (20%)

    // Structs
    struct Allocation {
        address protocol; // Protocol address
        uint256 amount; // Allocated amount
        uint256 apy; // Current APY
        uint256 lastUpdated; // Timestamp of last update
        bool isLeveraged; // Whether leverage is applied
    }

    struct AllocationBreakdown {
        address protocol; // Protocol address
        uint256 amount; // Allocated amount
        uint256 apy; // Current APY
        bool isLeveraged; // Whether leverage is applied
        uint256 liquidity; // Available liquidity
        uint256 riskScore; // Protocol risk score
    }

    struct Lockup {
        uint256 amount; // Locked amount
        uint256 lockupDays; // Lockup duration in days
        uint256 startTimestamp; // Lockup start timestamp
    }

    // Events
    event Deposit(address indexed user, uint256 amount, uint256 fee, uint256 discount, bytes32 indexed correlationId);
    event Withdraw(address indexed user, uint256 amount, uint256 fee, uint256 discount, bytes32 indexed correlationId);
    event Rebalance(address indexed protocol, uint256 amount, uint256 apy, bool isLeveraged, bytes32 indexed correlationId);
    event FeesCollected(uint256 managementFee, uint256 performanceFee, bytes32 indexed correlationId);
    event FeeRecipientUpdated(address indexed newRecipient);
    event FeesUpdated(uint256 managementFee, uint256 performanceFee);
    event BlacklistUpdated(address indexed user, bool status);
    event OFACCheckFailed(address indexed user);
    event UserEmergencyWithdraw(address indexed user, uint256 amount, bytes32 indexed correlationId);
    event AIAllocationOptimized(address indexed protocol, uint256 amount, uint256 apy, bool isLeveraged, bytes32 indexed correlationId);
    event AIAllocationDetails(address[] protocols, uint256[] amounts, bool[] isLeveraged, string logicDescription, bytes32 indexed correlationId);
    event RWADelegatedToAI(address indexed aiYieldOptimizer, uint256 amount, bytes32 indexed correlationId);
    event PauseToggled(bool status);
    event GovernanceVaultUpdated(address indexed newGovernanceVault);
    event LockupCreated(address indexed user, uint256 amount, uint256 lockupDays, uint256 startTimestamp);
    event PointsTierManagerUpdated(address indexed newPointsTierManager);
    event TierUpdated(address indexed user, uint256 totalAmount, bool hasLockup, uint256 maxLockupDays);
    event MaxLockupsUpdated(uint256 newMaxLockups);
    event APYValidationFailed(address indexed protocol, string reason);

    // Modifiers
    modifier onlyGovernance() {
        require(governanceManager.votingPower(msg.sender) >= MIN_GOVERNANCE_VOTING_POWER, "Insufficient voting power");
        _;
    }

    modifier whenNotPaused() {
        require(!isPaused, "Contract paused");
        _;
    }

    /**
     * @notice Initializes the contract with external dependencies and parameters.
     * @param _stablecoin Address of the stablecoin (e.g., USDC).
     * @param _rwaYield Address of the RWAYield contract.
     * @param _defiYield Address of the DeFiYield contract.
     * @param _flyingTulip Address of the FlyingTulip contract.
     * @param _aavePool Address of the Aave V3 pool contract.
     * @param _compound Address of the Compound contract.
     * @param _sonicProtocol Address of the SonicProtocol contract.
     * @param _aiYieldOptimizer Address of the AIYieldOptimizer contract.
     * @param _registry Address of the Registry contract.
     * @param _riskManager Address of the RiskManager contract.
     * @param _looperCore Address of the LooperCore contract.
     * @param _stakingManager Address of the StakingManager contract.
     * @param _governanceManager Address of the GovernanceManager contract.
     * @param _upkeepManager Address of the UpkeepManager contract.
     * @param _governanceVault Address of the GovernanceVault contract.
     * @param _feeRecipient Address to receive fees.
     * @param _pointsTierManager Address of the PointsTierManager contract.
     */
    function initialize(
        address _stablecoin,
        address _rwaYield,
        address _defiYield,
        address _flyingTulip,
        address _aavePool,
        address _compound,
        address _sonicProtocol,
        address _aiYieldOptimizer,
        address _registry,
        address _riskManager,
        address _looperCore,
        address _stakingManager,
        address _governanceManager,
        address _upkeepManager,
        address _governanceVault,
        address _feeRecipient,
        address _pointsTierManager
    ) external initializer {
        require(_stablecoin != address(0), "Invalid stablecoin address");
        require(_rwaYield != address(0), "Invalid RWAYield address");
        require(_defiYield != address(0), "Invalid DeFiYield address");
        require(_flyingTulip != address(0), "Invalid FlyingTulip address");
        require(_aavePool != address(0), "Invalid AavePool address");
        require(_compound != address(0), "Invalid Compound address");
        require(_sonicProtocol != address(0), "Invalid SonicProtocol address");
        require(_aiYieldOptimizer != address(0), "Invalid AIYieldOptimizer address");
        require(_registry != address(0), "Invalid Registry address");
        require(_riskManager != address(0), "Invalid RiskManager address");
        require(_looperCore != address(0), "Invalid LooperCore address");
        require(_stakingManager != address(0), "Invalid StakingManager address");
        require(_governanceManager != address(0), "Invalid GovernanceManager address");
        require(_upkeepManager != address(0), "Invalid UpkeepManager address");
        require(_governanceVault != address(0), "Invalid GovernanceVault address");
        require(_feeRecipient != address(0), "Invalid fee recipient");
        require(_pointsTierManager != address(0), "Invalid PointsTierManager address");

        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        stablecoin = IERC20(_stablecoin);
        rwaYield = IRWAYield(_rwaYield);
        defiYield = IDeFiYield(_defiYield);
        flyingTulip = IFlyingTulip(_flyingTulip);
        aavePool = IAaveV3Pool(_aavePool);
        compound = ICompound(_compound);
        sonicProtocol = ISonicProtocol(_sonicProtocol);
        aiYieldOptimizer = IAIYieldOptimizer(_aiYieldOptimizer);
        registry = IRegistry(_registry);
        riskManager = IRiskManager(_riskManager);
        looperCore = ILooperCore(_looperCore);
        stakingManager = IStakingManager(_stakingManager);
        governanceManager = IGovernanceManager(_governanceManager);
        upkeepManager = IUpkeepManager(_upkeepManager);
        governanceVault = IGovernanceVault(_governanceVault);
        pointsTierManager = IPointsTierManager(_pointsTierManager);
        feeRecipient = _feeRecipient;
        managementFee = 50; // 0.5%
        performanceFee = 1000; // 10%
        maxLockups = 10; // Initial max lockups
        MIN_DEPOSIT = 10 ** IERC20Metadata(_stablecoin).decimals();
        allowLeverage = true;
        minRWALiquidityThreshold = 1e18;

        // Verify DeFiYield ownership
        require(OwnableUpgradeable(address(defiYield)).owner() == address(this), "DeFiYield owner mismatch");
    }

    /**
     * @notice Authorizes contract upgrades.
     * @param newImplementation Address of the new implementation contract.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @notice Deposits funds and allocates them to protocols.
     * @param amount Amount of stablecoin to deposit.
     * @param useLockup Whether to apply a lockup period.
     * @param lockupDays Lockup duration in days (1 to 365).
     * @param correlationId Unique identifier for tracking.
     */
    function deposit(uint256 amount, bool useLockup, uint256 lockupDays, bytes32 correlationId) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        require(amount >= MIN_DEPOSIT, "Deposit below minimum");
        require(!blacklistedUsers[msg.sender], "User blacklisted");
        require(flyingTulip.isOFACCompliant(msg.sender), "OFAC check failed");
        require(!useLockup || (lockupDays >= 1 && lockupDays <= 365), "Invalid lockup period");

        if (correlationId == bytes32(0)) {
            correlationId = keccak256(abi.encodePacked(msg.sender, block.timestamp, amount));
        }

        (uint256 managementFeeAmount, uint256 discount) = estimateFees(amount, true);
        uint256 netAmount = amount - managementFeeAmount;

        stablecoin.safeTransferFrom(msg.sender, address(this), amount);
        if (managementFeeAmount > 0) {
            stablecoin.safeTransfer(feeRecipient, managementFeeAmount);
        }

        if (useLockup && lockupDays > 0) {
            Lockup[] storage lockups = userLockups[msg.sender];
            require(lockups.length < maxLockups, "Max lockups reached");
            lockups.push(Lockup({
                amount: netAmount,
                lockupDays: lockupDays,
                startTimestamp: block.timestamp
            }));
            emit LockupCreated(msg.sender, netAmount, lockupDays, block.timestamp);
        }

        userBalances[msg.sender] += netAmount;
        totalAllocated += netAmount;

        (bool hasLockup, uint256 maxLockupDays) = getUserLockupStatus(msg.sender);
        stakingManager.awardPoints(msg.sender, netAmount, true, hasLockup, maxLockupDays);
        pointsTierManager.assignTier(msg.sender, userBalances[msg.sender], hasLockup, maxLockupDays);
        emit TierUpdated(msg.sender, userBalances[msg.sender], hasLockup, maxLockupDays);

        _allocateFunds(netAmount, 0, type(uint256).max, correlationId);

        emit Deposit(msg.sender, netAmount, managementFeeAmount, discount, correlationId);
    }

    /**
     * @notice Withdraws funds with profits.
     * @param amount Amount to withdraw.
     * @param correlationId Unique identifier for tracking.
     */
    function withdraw(uint256 amount, bytes32 correlationId) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        require(amount > 0, "Amount must be > 0");
        require(userBalances[msg.sender] >= amount, "Insufficient balance");

        if (correlationId == bytes32(0)) {
            correlationId = keccak256(abi.encodePacked(msg.sender, block.timestamp, amount));
        }

        uint256 unlockedBalance = getUnlockedBalance(msg.sender);
        require(unlockedBalance >= amount, "Locked funds");

        uint256 profit = _calculateProfit(msg.sender, amount);
        (uint256 performanceFeeAmount, uint256 discount) = estimateFees(profit, false);
        uint256 netProfit = profit > performanceFeeAmount ? profit - performanceFeeAmount : 0;

        _updateLockups(msg.sender, amount);

        userBalances[msg.sender] -= amount;
        totalAllocated -= amount;

        (bool hasLockup, uint256 maxLockupDays) = getUserLockupStatus(msg.sender);
        stakingManager.awardPoints(msg.sender, amount, false, hasLockup, maxLockupDays);
        pointsTierManager.assignTier(msg.sender, userBalances[msg.sender], hasLockup, maxLockupDays);
        emit TierUpdated(msg.sender, userBalances[msg.sender], hasLockup, maxLockupDays);

        uint256 withdrawnAmount = _deallocateFunds(amount, correlationId);
        require(withdrawnAmount >= amount, "Insufficient funds withdrawn");

        if (performanceFeeAmount > 0) {
            stablecoin.safeTransfer(feeRecipient, performanceFeeAmount);
        }
        stablecoin.safeTransfer(msg.sender, amount + netProfit);

        emit Withdraw(msg.sender, amount + netProfit, performanceFeeAmount, discount, correlationId);
        emit FeesCollected(managementFee, performanceFeeAmount, correlationId);
    }

    /**
     * @notice Allows users to withdraw funds during a pause.
     * @param amount Amount to withdraw.
     * @param correlationId Unique identifier for tracking.
     */
    function userEmergencyWithdraw(uint256 amount, bytes32 correlationId) 
        external 
        nonReentrant 
    {
        require(isPaused, "Not paused");
        require(amount > 0, "Amount must be > 0");
        require(userBalances[msg.sender] >= amount, "Insufficient balance");

        if (correlationId == bytes32(0)) {
            correlationId = keccak256(abi.encodePacked(msg.sender, block.timestamp, amount));
        }

        userBalances[msg.sender] -= amount;
        totalAllocated -= amount;
        stablecoin.safeTransfer(msg.sender, amount);

        delete userLockups[msg.sender];

        stakingManager.awardPoints(msg.sender, amount, false, false, 0);
        pointsTierManager.assignTier(msg.sender, 0, false, 0);
        emit TierUpdated(msg.sender, 0, false, 0);

        emit UserEmergencyWithdraw(msg.sender, amount, correlationId);
    }

    /**
     * @notice Updates the GovernanceVault address.
     * @param _governanceVault New GovernanceVault address.
     */
    function setGovernanceVault(address _governanceVault) 
        external 
        onlyOwner 
    {
        require(_governanceVault != address(0), "Invalid GovernanceVault");
        governanceVault = IGovernanceVault(_governanceVault);
        emit GovernanceVaultUpdated(_governanceVault);
    }

    /**
     * @notice Updates the PointsTierManager address.
     * @param _pointsTierManager New PointsTierManager address.
     */
    function setPointsTierManager(address _pointsTierManager) 
        external 
        onlyOwner 
    {
        require(_pointsTierManager != address(0), "Invalid PointsTierManager");
        pointsTierManager = IPointsTierManager(_pointsTierManager);
        emit PointsTierManagerUpdated(_pointsTierManager);
    }

    /**
     * @notice Updates the maximum number of lockups.
     * @param _maxLockups New maximum number of lockups.
     */
    function setMaxLockups(uint256 _maxLockups) 
        external 
        onlyGovernance 
    {
        require(_maxLockups >= 1 && _maxLockups <= 100, "Invalid max lockups");
        maxLockups = _maxLockups;
        emit MaxLockupsUpdated(_maxLockups);
    }

    /**
     * @notice Estimates management or performance fees for a given amount.
     * @param amount Amount to calculate fees for.
     * @param isManagementFee True for management fee, false for performance fee.
     * @return fee The calculated fee amount.
     * @return discount The applied fee discount percentage.
     */
    function estimateFees(uint256 amount, bool isManagementFee) 
        public 
        view 
        returns (uint256 fee, uint256 discount) 
    {
        discount = governanceVault.getFeeDiscount(msg.sender);
        uint256 feeRate = isManagementFee ? managementFee : performanceFee;
        feeRate = (feeRate * (100 - discount)) / 100;
        fee = (amount * feeRate) / BASIS_POINTS;
        // Cap total fees at 20%
        if (fee > amount * MAX_FEE_BPS / BASIS_POINTS) {
            fee = amount * MAX_FEE_BPS / BASIS_POINTS;
        }
        return (fee, discount);
    }

    /**
     * @notice Calculates the unlocked balance for a user.
     * @param user User address.
     * @return Unlocked balance.
     */
    function getUnlockedBalance(address user) 
        public 
        view 
        returns (uint256) 
    {
        uint256 totalBalance = userBalances[user];
        uint256 lockedAmount = 0;
        Lockup[] storage lockups = userLockups[user];

        for (uint256 i = 0; i < lockups.length; i++) {
            if (block.timestamp < lockups[i].startTimestamp + (lockups[i].lockupDays * 1 days)) {
                lockedAmount += lockups[i].amount;
            }
        }

        return totalBalance >= lockedAmount ? totalBalance - lockedAmount : 0;
    }

    /**
     * @notice Updates user lockups after withdrawal.
     * @param user User address.
     * @param withdrawAmount Amount to withdraw.
     */
    function _updateLockups(address user, uint256 withdrawAmount) 
        internal 
    {
        Lockup[] storage lockups = userLockups[user];
        uint256 remaining = withdrawAmount;

        for (uint256 i = 0; i < lockups.length && remaining > 0; i++) {
            if (block.timestamp >= lockups[i].startTimestamp + (lockups[i].lockupDays * 1 days)) {
                uint256 deduct = remaining >= lockups[i].amount ? lockups[i].amount : remaining;
                lockups[i].amount -= deduct;
                remaining -= deduct;
            }
        }

        require(remaining == 0, "Locked funds");

        uint256 writeIndex = 0;
        for (uint256 i = 0; i < lockups.length; i++) {
            if (lockups[i].amount > 0) {
                lockups[writeIndex] = lockups[i];
                writeIndex++;
            }
        }
        while (lockups.length > writeIndex) {
            lockups.pop();
        }
    }

    /**
     * @notice Retrieves user lockups.
     * @param user User address.
     * @return Array of lockup details.
     */
    function getUserLockups(address user) 
        external 
        view 
        returns (Lockup[] memory) 
    {
        return userLockups[user];
    }

    /**
     * @notice Gets user lockup status.
     * @param user User address.
     * @return hasLockup Whether the user has active lockups.
     * @return maxLockupDays Maximum lockup duration in days.
     */
    function getUserLockupStatus(address user) 
        public 
        view 
        returns (bool hasLockup, uint256 maxLockupDays) 
    {
        Lockup[] storage lockups = userLockups[user];
        hasLockup = false;
        maxLockupDays = 0;

        for (uint256 i = 0; i < lockups.length; i++) {
            if (block.timestamp < lockups[i].startTimestamp + (lockups[i].lockupDays * 1 days)) {
                hasLockup = true;
                if (lockups[i].lockupDays > maxLockupDays) {
                    maxLockupDays = lockups[i].lockupDays;
                }
            }
        }
    }

    /**
     * @notice Rebalances portfolio with pagination.
     * @param start Starting index for protocol array.
     * @param limit Number of protocols to process.
     * @param correlationId Unique identifier for tracking.
     */
    function rebalance(uint256 start, uint256 limit, bytes32 correlationId) 
        external 
        onlyGovernance 
        nonReentrant 
        whenNotPaused 
    {
        if (correlationId == bytes32(0)) {
            correlationId = keccak256(abi.encodePacked(msg.sender, block.timestamp));
        }

        address[] memory protocols = registry.getActiveProtocols(false);
        require(start < protocols.length, "Invalid start index");
        uint256 end = start.add(limit) > protocols.length ? protocols.length : start.add(limit);

        // Cache protocol data to optimize gas
        struct ProtocolData {
            address protocol;
            uint256 amount;
            uint256 apy;
            uint256 liquidity;
            uint256 riskScore;
        }
        ProtocolData[] memory protocolData = new ProtocolData[](end - start);

        // Withdraw from non-RWA protocols and fetch data
        for (uint256 i = start; i < end; i++) {
            Allocation storage alloc = allocations[protocols[i]];
            protocolData[i - start].protocol = protocols[i];
            protocolData[i - start].amount = alloc.amount;
            protocolData[i - start].apy = _fetchProtocolAPY(protocols[i]);
            protocolData[i - start].liquidity = getProtocolLiquidity(protocols[i]);
            protocolData[i - start].riskScore = registry.getProtocolRiskScore(protocols[i]);

            if (alloc.amount > 0) {
                uint256 withdrawn = _withdrawFromProtocol(protocols[i], alloc.amount, correlationId);
                alloc.amount -= withdrawn;
                if (alloc.isLeveraged) {
                    looperCore.unwindLeverage(protocols[i], withdrawn, false);
                }
            }
        }
        _cleanAllocations();

        // Calculate total balance
        uint256 totalBalance = stablecoin.balanceOf(address(this)) + aiYieldOptimizer.getTotalRWABalance();
        uint256 totalWeightedAPY = 0;
        uint256 nonRWAAmount = 0;
        uint256[] memory weights = new uint256[](end - start);

        // Calculate weights based on risk-adjusted APYs
        for (uint256 i = 0; i < end - start; i++) {
            if (!registry.isValidProtocol(protocolData[i].protocol) || 
                !_validateAPY(protocolData[i].apy, protocolData[i].protocol)) {
                emit AIAllocationOptimized(protocolData[i].protocol, 0, protocolData[i].apy, false, correlationId);
                continue;
            }
            weights[i] = riskManager.getRiskAdjustedAPY(protocolData[i].protocol, protocolData[i].apy);
            totalWeightedAPY += weights[i];
        }

        // Allocate to non-RWA protocols
        for (uint256 i = 0; i < end - start; i++) {
            if (weights[i] == 0) continue;
            uint256 allocAmount = (totalBalance * weights[i]) / (totalWeightedAPY == 0 ? 1 : totalWeightedAPY);
            if (allocAmount < MIN_ALLOCATION || allocAmount > protocolData[i].liquidity) {
                emit AIAllocationOptimized(protocolData[i].protocol, 0, protocolData[i].apy, false, correlationId);
                continue;
            }
            bool isLeveraged = allowLeverage && _assessLeverageViability(protocolData[i].protocol, allocAmount);
            if (isLeveraged && looperCore.checkLiquidationRisk(protocolData[i].protocol, allocAmount, allocAmount * _getLTV(protocolData[i].protocol, allocAmount) / FIXED_POINT_SCALE, false)) {
                isLeveraged = false; // Disable leverage if liquidation risk is high
            }
            allocations[protocolData[i].protocol] = Allocation({
                protocol: protocolData[i].protocol,
                amount: allocAmount,
                apy: protocolData[i].apy,
                lastUpdated: block.timestamp,
                isLeveraged: isLeveraged
            });
            lastKnownAPYs[protocolData[i].protocol] = protocolData[i].apy;
            _depositToProtocol(protocolData[i].protocol, allocAmount, isLeveraged, correlationId);
            nonRWAAmount += allocAmount;
            if (isLeveraged) {
                uint256 ltv = _getLTV(protocolData[i].protocol, allocAmount);
                looperCore.applyLeverage(protocolData[i].protocol, allocAmount, ltv, false);
            }
            emit AIAllocationOptimized(protocolData[i].protocol, allocAmount, protocolData[i].apy, isLeveraged, correlationId);
            emit Rebalance(protocolData[i].protocol, allocAmount, protocolData[i].apy, isLeveraged, correlationId);
        }

        // Delegate RWA reallocation
        uint256 rwaAmount = totalBalance > nonRWAAmount ? totalBalance - nonRWAAmount : 0;
        if (rwaAmount >= MIN_ALLOCATION) {
            try aiYieldOptimizer.getRecommendedAllocations(rwaAmount) returns (
                address[] memory rwaProtocols,
                uint256[] memory amounts,
                bool[] memory isLeveraged
            ) {
                require(validateAIAllocations(rwaProtocols, amounts, rwaAmount), "Invalid AI allocations");
                stablecoin.safeApprove(address(aiYieldOptimizer), 0);
                stablecoin.safeApprove(address(aiYieldOptimizer), rwaAmount);
                stablecoin.safeTransfer(address(aiYieldOptimizer), rwaAmount);
                aiYieldOptimizer.rebalancePortfolio(rwaProtocols, amounts, isLeveraged);
                string memory logicDescription = aiYieldOptimizer.getAllocationLogic(rwaAmount);
                emit AIAllocationDetails(rwaProtocols, amounts, isLeveraged, logicDescription, correlationId);
                emit RWADelegatedToAI(address(aiYieldOptimizer), rwaAmount, correlationId);
            } catch {
                // Fallback: Keep funds in contract if RWA allocation fails
                emit AIAllocationOptimized(address(aiYieldOptimizer), 0, 0, false, correlationId);
            }
        }
    }

    /**
     * @notice Validates AI-driven allocations for RWA protocols.
     * @param protocols Array of protocol addresses.
     * @param amounts Array of allocation amounts.
     * @param totalAmount Total amount to allocate.
     * @return True if allocations are valid.
     */
    function validateAIAllocations(address[] memory protocols, uint256[] memory amounts, uint256 totalAmount)
        internal
        view
        returns (bool)
    {
        if (protocols.length != amounts.length) return false;
        uint256 sum = 0;
        for (uint256 i = 0; i < protocols.length; i++) {
            if (!rwaYield.isRWA(protocols[i]) || !validateRWAProtocol(protocols[i])) return false;
            sum += amounts[i];
        }
        return sum <= totalAmount && sum >= totalAmount * 95 / 100;
    }

    /**
     * @notice Validates an RWA protocol.
     * @param protocol Protocol address.
     * @return True if the protocol is valid.
     */
    function validateRWAProtocol(address protocol) 
        internal 
        view 
        returns (bool) 
    {
        return
            rwaYield.getAvailableLiquidity(protocol) >= minRWALiquidityThreshold &&
            registry.isValidProtocol(protocol) &&
            sonicProtocol.isSonicCompliant(protocol);
    }

    /**
     * @notice Assesses leverage viability for a protocol.
     * @param protocol Protocol address.
     * @param amount Amount to leverage.
     * @return True if leverage is viable.
     */
    function _assessLeverageViability(address protocol, uint256 amount) 
        internal 
        view 
        returns (bool) 
    {
        uint256 ltv = _getLTV(protocol, amount);
        return riskManager.assessLeverageViability(protocol, amount, ltv, false);
    }

    /**
     * @notice Fetches the LTV for a protocol.
     * @param protocol Protocol address.
     * @param amount Amount to allocate.
     * @return LTV value scaled by FIXED_POINT_SCALE.
     */
    function _getLTV(address protocol, uint256 amount) 
        internal 
        view 
        returns (uint256) 
    {
        uint256 riskScore = registry.getProtocolRiskScore(protocol);
        uint256 baseLTV;
        if (protocol == address(flyingTulip)) {
            baseLTV = flyingTulip.getDynamicAPY(protocol);
        } else if (protocol == address(aavePool)) {
            baseLTV = aavePool.getReserveData(address(stablecoin)).liquidityIndex;
        } else if (registry.isValidProtocol(protocol) && compound.underlying() == protocol) {
            baseLTV = 5000; // 50% LTV
        } else {
            baseLTV = 0;
        }
        // Adjust LTV based on risk score (lower risk = higher LTV)
        return baseLTV * (100 - riskScore) / 100;
    }

    /**
     * @notice Toggles the pause state.
     */
    function pause() 
        external 
        onlyGovernance 
    {
        isPaused = true;
        emit PauseToggled(true);
    }

    /**
     * @notice Unpauses the contract.
     */
    function unpause() 
        external 
        onlyGovernance 
    {
        isPaused = false;
        emit PauseToggled(false);
    }

    /**
     * @notice Updates the blacklist status for a user.
     * @param user User address.
     * @param status Blacklist status.
     */
    function updateBlacklist(address user, bool status) 
        external 
        onlyGovernance 
    {
        blacklistedUsers[user] = status;
        emit BlacklistUpdated(user, status);
    }

    /**
     * @notice Performs manual upkeep for protocol maintenance.
     */
    function manualUpkeep() 
        external 
        onlyGovernance 
    {
        upkeepManager.manualUpkeep(false);
    }

    /**
     * @notice Allocates funds to protocols with pagination.
     * @param amount Amount to allocate.
     * @param start Starting index for protocol array.
     * @param limit Number of protocols to process.
     * @param correlationId Unique identifier for tracking.
     */
    function _allocateFunds(uint256 amount, uint256 start, uint256 limit, bytes32 correlationId) 
        internal 
    {
        address[] memory protocols = registry.getActiveProtocols(false);
        require(start < protocols.length, "Invalid start index");
        uint256 end = start.add(limit) > protocols.length ? protocols.length : start.add(limit);

        // Cache protocol data
        struct ProtocolData {
            address protocol;
            uint256 apy;
            uint256 liquidity;
            uint256 riskScore;
        }
        ProtocolData[] memory protocolData = new ProtocolData[](end - start);

        for (uint256 i = start; i < end; i++) {
            protocolData[i - start].protocol = protocols[i];
            protocolData[i - start].apy = _fetchProtocolAPY(protocols[i]);
            protocolData[i - start].liquidity = getProtocolLiquidity(protocols[i]);
            protocolData[i - start].riskScore = registry.getProtocolRiskScore(protocols[i]);
        }

        uint256 totalWeightedAPY = 0;
        uint256 nonRWAAmount = 0;
        uint256[] memory weights = new uint256[](end - start);

        for (uint256 i = 0; i < end - start; i++) {
            if (!registry.isValidProtocol(protocolData[i].protocol) || 
                !_validateAPY(protocolData[i].apy, protocolData[i].protocol)) {
                continue;
            }
            weights[i] = riskManager.getRiskAdjustedAPY(protocolData[i].protocol, protocolData[i].apy);
            totalWeightedAPY += weights[i];
        }

        for (uint256 i = 0; i < end - start; i++) {
            if (weights[i] == 0) continue;
            uint256 allocAmount = (amount * weights[i]) / (totalWeightedAPY == 0 ? 1 : totalWeightedAPY);
            if (allocAmount < MIN_ALLOCATION || allocAmount > protocolData[i].liquidity) continue;
            bool isLeveraged = allowLeverage && _assessLeverageViability(protocolData[i].protocol, allocAmount);
            if (isLeveraged && looperCore.checkLiquidationRisk(protocolData[i].protocol, allocAmount, allocAmount * _getLTV(protocolData[i].protocol, allocAmount) / FIXED_POINT_SCALE, false)) {
                isLeveraged = false;
            }
            allocations[protocolData[i].protocol] = Allocation({
                protocol: protocolData[i].protocol,
                amount: allocAmount,
                apy: protocolData[i].apy,
                lastUpdated: block.timestamp,
                isLeveraged: isLeveraged
            });
            lastKnownAPYs[protocolData[i].protocol] = protocolData[i].apy;
            _depositToProtocol(protocolData[i].protocol, allocAmount, isLeveraged, correlationId);
            nonRWAAmount += allocAmount;
            if (isLeveraged) {
                uint256 ltv = _getLTV(protocolData[i].protocol, allocAmount);
                looperCore.applyLeverage(protocolData[i].protocol, allocAmount, ltv, false);
            }
            emit AIAllocationOptimized(protocolData[i].protocol, allocAmount, protocolData[i].apy, isLeveraged, correlationId);
        }

        uint256 rwaAmount = amount > nonRWAAmount ? amount - nonRWAAmount : 0;
        if (rwaAmount >= MIN_ALLOCATION) {
            try aiYieldOptimizer.getRecommendedAllocations(rwaAmount) returns (
                address[] memory rwaProtocols,
                uint256[] memory amounts,
                bool[] memory isLeveraged
            ) {
                require(validateAIAllocations(rwaProtocols, amounts, rwaAmount), "Invalid AI allocations");
                stablecoin.safeApprove(address(aiYieldOptimizer), 0);
                stablecoin.safeApprove(address(aiYieldOptimizer), rwaAmount);
                stablecoin.safeTransfer(address(aiYieldOptimizer), rwaAmount);
                aiYieldOptimizer.submitAIAllocation(rwaProtocols, amounts, isLeveraged);
                string memory logicDescription = aiYieldOptimizer.getAllocationLogic(rwaAmount);
                emit AIAllocationDetails(rwaProtocols, amounts, isLeveraged, logicDescription, correlationId);
                emit RWADelegatedToAI(address(aiYieldOptimizer), rwaAmount, correlationId);
            } catch {
                emit AIAllocationOptimized(address(aiYieldOptimizer), 0, 0, false, correlationId);
            }
        }
    }

    /**
     * @notice Deallocates funds from protocols.
     * @param amount Amount to deallocate.
     * @param correlationId Unique identifier for tracking.
     * @return Total amount withdrawn.
     */
    function _deallocateFunds(uint256 amount, bytes32 correlationId) 
        internal 
        returns (uint256) 
    {
        uint256 totalWithdrawn = 0;
        address[] memory protocols = registry.getActiveProtocols(false);
        address[] memory rwaProtocols = aiYieldOptimizer.getSupportedProtocols();

        uint256 rwaBalance = aiYieldOptimizer.getTotalRWABalance();
        if (rwaBalance > 0) {
            uint256 rwaWithdrawAmount = (amount * rwaBalance) / (totalAllocated == 0 ? 1 : totalAllocated);
            for (uint256 i = 0; i < rwaProtocols.length && totalWithdrawn < amount; i++) {
                address protocol = rwaProtocols[i];
                uint256 availableLiquidity = rwaYield.getAvailableLiquidity(protocol);
                uint256 withdrawAmount = rwaWithdrawAmount > availableLiquidity ? availableLiquidity : rwaWithdrawAmount;
                try aiYieldOptimizer.withdrawForYieldOptimizer(protocol, withdrawAmount) returns (uint256 withdrawn) {
                    totalWithdrawn += withdrawn;
                    (bool hasLockup, uint256 maxLockupDays) = getUserLockupStatus(msg.sender);
                    stakingManager.awardPoints(msg.sender, withdrawn, false, hasLockup, maxLockupDays);
                    pointsTierManager.assignTier(msg.sender, userBalances[msg.sender], hasLockup, maxLockupDays);
                    emit TierUpdated(msg.sender, userBalances[msg.sender], hasLockup, maxLockupDays);
                } catch {
                    emit AIAllocationOptimized(protocol, 0, 0, false, correlationId);
                }
            }
        }

        for (uint256 i = 0; i < protocols.length && totalWithdrawn < amount; i++) {
            address protocol = protocols[i];
            Allocation storage alloc = allocations[protocol];
            uint256 withdrawAmount = (amount * alloc.amount) / (totalAllocated == 0 ? 1 : totalAllocated);
            if (withdrawAmount > 0) {
                uint256 availableLiquidity = getProtocolLiquidity(protocol);
                withdrawAmount = withdrawAmount > availableLiquidity ? availableLiquidity : withdrawAmount;
                uint256 withdrawn = _withdrawFromProtocol(protocol, withdrawAmount, correlationId);
                alloc.amount -= withdrawn;
                if (alloc.isLeveraged) {
                    looperCore.unwindLeverage(protocol, withdrawn, false);
                }
                totalWithdrawn += withdrawn;
                (bool hasLockup, uint256 maxLockupDays) = getUserLockupStatus(msg.sender);
                stakingManager.awardPoints(msg.sender, withdrawn, false, hasLockup, maxLockupDays);
                pointsTierManager.assignTier(msg.sender, userBalances[msg.sender], hasLockup, maxLockupDays);
                emit TierUpdated(msg.sender, userBalances[msg.sender], hasLockup, maxLockupDays);
            }
        }
        _cleanAllocations();
        return totalWithdrawn;
    }

    /**
     * @notice Deposits funds to a specific protocol.
     * @param protocol Protocol address.
     * @param amount Amount to deposit.
     * @param isLeveraged Whether to apply leverage.
     * @param correlationId Unique identifier for tracking.
     */
    function _depositToProtocol(address protocol, uint256 amount, bool isLeveraged, bytes32 correlationId) 
        internal 
    {
        // Consolidated approval
        if (stablecoin.allowance(address(this), protocol) < amount) {
            stablecoin.safeApprove(protocol, 0);
            stablecoin.safeApprove(protocol, type(uint256).max);
        }

        if (protocol == address(flyingTulip)) {
            try flyingTulip.depositToPool(protocol, amount, isLeveraged) {
                emit AIAllocationOptimized(protocol, amount, lastKnownAPYs[protocol], isLeveraged, correlationId);
            } catch {
                revert("FlyingTulip deposit failed");
            }
        } else if (protocol == address(aavePool)) {
            try aavePool.supply(address(stablecoin), amount, address(this), AAVE_REFERRAL_CODE) {
                emit AIAllocationOptimized(protocol, amount, lastKnownAPYs[protocol], isLeveraged, correlationId);
            } catch {
                revert("Aave supply failed");
            }
        } else if (registry.isValidProtocol(protocol) && compound.underlying() == protocol) {
            try compound.mint(amount) returns (uint256 err) {
                require(err == 0, "Compound mint failed");
                emit AIAllocationOptimized(protocol, amount, lastKnownAPYs[protocol], isLeveraged, correlationId);
            } catch {
                revert("Compound mint failed");
            }
        } else {
            try defiYield.depositToDeFi(protocol, amount, correlationId) {
                emit AIAllocationOptimized(protocol, amount, lastKnownAPYs[protocol], isLeveraged, correlationId);
            } catch {
                revert("DeFiYield deposit failed");
            }
        }
    }

    /**
     * @notice Withdraws funds from a specific protocol.
     * @param protocol Protocol address.
     * @param amount Amount to withdraw.
     * @param correlationId Unique identifier for tracking.
     * @return Amount withdrawn.
     */
    function _withdrawFromProtocol(address protocol, uint256 amount, bytes32 correlationId) 
        internal 
        returns (uint256) 
    {
        uint256 balanceBefore = stablecoin.balanceOf(address(this));
        uint256 withdrawn;
        try
            protocol == address(flyingTulip)
                ? flyingTulip.withdrawFromPool(protocol, amount)
                : protocol == address(aavePool)
                    ? aavePool.withdraw(address(stablecoin), amount, address(this))
                    : registry.isValidProtocol(protocol) && compound.underlying() == protocol
                        ? compound.redeemUnderlying(amount) == 0 ? amount : 0
                        : defiYield.withdrawFromDeFi(protocol, amount, correlationId)
        returns (uint256 amountWithdrawn) {
            withdrawn = amountWithdrawn;
        } catch {
            emit AIAllocationOptimized(protocol, 0, 0, false, correlationId);
            return 0;
        }
        require(stablecoin.balanceOf(address(this)) >= balanceBefore + withdrawn, "Withdrawal balance mismatch");
        return withdrawn;
    }

    /**
     * @notice Cleans up zero-amount allocations.
     */
    function _cleanAllocations() 
        internal 
    {
        address[] memory protocols = registry.getActiveProtocols(false);
        for (uint256 i = 0; i < protocols.length; i++) {
            if (allocations[protocols[i]].amount == 0) {
                delete allocations[protocols[i]];
            }
        }
    }

    /**
     * @notice Validates a protocol.
     * @param protocol Protocol address.
     * @return True if the protocol is valid.
     */
    function _isValidProtocol(address protocol) 
        internal 
        view 
        returns (bool) 
    {
        return registry.isValidProtocol(protocol) && sonicProtocol.isSonicCompliant(protocol);
    }

    /**
     * @notice Fetches and validates APY for a protocol.
     * @param protocol Protocol address.
     * @return Validated APY.
     */
    function _fetchProtocolAPY(address protocol) 
        internal 
        view 
        returns (uint256) 
    {
        uint256 apy = sonicProtocol.getSonicAPY(protocol);
        if (defiYield.isDeFiProtocol(protocol)) {
            (uint256 protocolAPY,,,) = defiYield.protocolScores(protocol);
            if (protocolAPY > 0 && protocolAPY <= MAX_APY) {
                apy = protocolAPY;
            }
        }
        if (protocol == address(flyingTulip)) {
            uint256 flyingTulipAPY = flyingTulip.getDynamicAPY(protocol);
            if (flyingTulipAPY > 0 && flyingTulipAPY <= MAX_APY && flyingTulipAPY > apy) {
                apy = flyingTulipAPY;
            }
        } else if (protocol == address(aavePool)) {
            (, , uint256 liquidityRate,,,,,,,) = aavePool.getReserveData(address(stablecoin));
            uint256 aaveAPY = (liquidityRate * BASIS_POINTS) / FIXED_POINT_SCALE;
            if (aaveAPY > 0 && aaveAPY <= MAX_APY && aaveAPY > apy) {
                apy = aaveAPY;
            }
        } else if (registry.isValidProtocol(protocol) && compound.underlying() == protocol) {
            uint256 compoundAPY = (compound.supplyRatePerBlock() * 365 * 24 * 3600 * BASIS_POINTS) / FIXED_POINT_SCALE;
            if (compoundAPY > 0 && compoundAPY <= MAX_APY && compoundAPY > apy) {
                apy = compoundAPY;
            }
        }
        if (!_validateAPY(apy, protocol)) {
            apy = DEFAULT_APY;
            emit APYValidationFailed(protocol, "Invalid or zero APY");
        }
        return apy;
    }

    /**
     * @notice Validates APY data for a protocol.
     * @param apy APY to validate.
     * @param protocol Protocol address.
     * @return True if APY is valid.
     */
    function _validateAPY(uint256 apy, address protocol) 
        internal 
        view 
        returns (bool) 
    {
        uint256 liquidity = getProtocolLiquidity(protocol);
        if (apy == 0 || apy > MAX_APY || liquidity == 0) {
            emit APYValidationFailed(protocol, "Invalid APY or liquidity");
            return false;
        }
        return true;
    }

    /**
     * @notice Retrieves liquidity for a protocol.
     * @param protocol Protocol address.
     * @return Available liquidity.
     */
    function getProtocolLiquidity(address protocol) 
        public 
        view 
        returns (uint256) 
    {
        require(_isValidProtocol(protocol), "Invalid protocol");
        try
            rwaYield.isRWA(protocol)
                ? rwaYield.getAvailableLiquidity(protocol)
                : protocol == address(flyingTulip)
                    ? flyingTulip.getAvailableLiquidity(protocol)
                    : protocol == address(aavePool)
                        ? IERC20(aavePool.getReserveData(address(stablecoin)).aTokenAddress).balanceOf(address(aavePool))
                        : registry.isValidProtocol(protocol) && compound.underlying() == protocol
                            ? IERC20(compound.underlying()).balanceOf(protocol)
                            : defiYield.getAvailableLiquidity(protocol)
        returns (uint256 available) {
            return available;
        } catch {
            emit APYValidationFailed(protocol, "Liquidity fetch failed");
            return 0;
        }
    }

    /**
     * @notice Calculates user profit with real-time DeFiYield data.
     * @param user User address.
     * @param amount Amount to calculate profit for.
     * @return Estimated profit.
     */
    function _calculateProfit(address user, uint256 amount) 
        internal 
        view 
        returns (uint256) 
    {
        uint256 userBalance = userBalances[user];
        if (userBalance == 0 || amount > userBalance) {
            return 0;
        }

        uint256 totalProfit = 0;
        uint256 userShare = (amount * FIXED_POINT_SCALE) / userBalance;
        address[] memory protocols = registry.getActiveProtocols(false);

        for (uint256 i = 0; i < protocols.length; i++) {
            Allocation memory alloc = allocations[protocols[i]];
            if (alloc.amount == 0) continue;

            uint256 apy = _fetchProtocolAPY(protocols[i]);
            uint256 timeElapsed = block.timestamp - alloc.lastUpdated;
            if (timeElapsed == 0) continue;

            uint256 apyScaled = (apy * FIXED_POINT_SCALE) / BASIS_POINTS;
            uint256 ratePerSecond = apyScaled / SECONDS_PER_YEAR;
            uint256 exponent = ratePerSecond * timeElapsed;
            if (exponent > MAX_EXP_INPUT) continue;

            uint256 profitFactor = PRBMathUD60x18.exp(exponent);
            uint256 principal = (alloc.amount * userShare) / FIXED_POINT_SCALE;
            uint256 profit = (principal * (profitFactor - FIXED_POINT_SCALE)) / FIXED_POINT_SCALE;
            totalProfit += profit;
        }

        uint256 rwaBalance = aiYieldOptimizer.getTotalRWABalance();
        if (rwaBalance > 0) {
            uint256 rwaShare = (rwaBalance * userShare) / FIXED_POINT_SCALE;
            uint256 rwaAPY = lastKnownAPYs[address(aiYieldOptimizer)] > 0 ? lastKnownAPYs[address(aiYieldOptimizer)] : DEFAULT_APY;
            uint256 timeElapsed = block.timestamp - allocations[address(aiYieldOptimizer)].lastUpdated;
            uint256 rwaProfit = (rwaShare * rwaAPY * timeElapsed) / (BASIS_POINTS * SECONDS_PER_YEAR);
            totalProfit += rwaProfit;
        }

        return totalProfit >= MIN_PROFIT ? totalProfit : 0;
    }

    /**
     * @notice Retrieves user balance and estimated profits.
     * @param user User address.
     * @return balance User balance.
     * @return estimatedProfit Estimated profit.
     */
    function getUserBalance(address user) 
        external 
        view 
        returns (uint256 balance, uint256 estimatedProfit) 
    {
        balance = userBalances[user];
        estimatedProfit = _calculateProfit(user, balance);
    }

    /**
     * @notice Retrieves allocation breakdown for all protocols.
     * @return Array of allocation details.
     */
    function getAllocationBreakdown() 
        external 
        view 
        returns (AllocationBreakdown[] memory) 
    {
        address[] memory protocols = registry.getActiveProtocols(false);
        AllocationBreakdown[] memory breakdown = new AllocationBreakdown[](protocols.length + 1);
        uint256 breakdownIndex = 0;

        for (uint256 i = 0; i < protocols.length; i++) {
            Allocation memory alloc = allocations[protocols[i]];
            if (alloc.amount == 0) continue;
            uint256 apy = _fetchProtocolAPY(protocols[i]);
            breakdown[breakdownIndex] = AllocationBreakdown({
                protocol: protocols[i],
                amount: alloc.amount,
                apy: apy,
                isLeveraged: alloc.isLeveraged,
                liquidity: getProtocolLiquidity(protocols[i]),
                riskScore: registry.getProtocolRiskScore(protocols[i])
            });
            breakdownIndex++;
        }

        uint256 rwaBalance = aiYieldOptimizer.getTotalRWABalance();
        if (rwaBalance > 0) {
            uint256 rwaAPY = lastKnownAPYs[address(aiYieldOptimizer)] > 0 ? lastKnownAPYs[address(aiYieldOptimizer)] : DEFAULT_APY;
            breakdown[breakdownIndex] = AllocationBreakdown({
                protocol: address(aiYieldOptimizer),
                amount: rwaBalance,
                apy: rwaAPY,
                isLeveraged: false,
                liquidity: rwaBalance,
                riskScore: registry.getProtocolRiskScore(address(aiYieldOptimizer))
            });
            breakdownIndex++;
        }

        AllocationBreakdown[] memory finalBreakdown = new AllocationBreakdown[](breakdownIndex);
        for (uint256 i = 0; i < breakdownIndex; i++) {
            finalBreakdown[i] = breakdown[i];
        }

        return finalBreakdown;
    }

    /**
     * @notice Prevents accidental ETH deposits.
     */
    receive() 
        external 
        payable 
    {
        revert("ETH deposits not allowed");
    }
}
