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

// Interfaces
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
 * @dev Uses UUPS proxy, supports Sonic Points, and includes optimized rebalancing.
 */
contract YieldOptimizer is UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using PRBMathUD60x18 for uint256;

    // State variables
    IERC20 public immutable stablecoin;
    IRWAYield public immutable rwaYield;
    IDeFiYield public immutable defiYield;
    IFlyingTulip public immutable flyingTulip;
    IAaveV3Pool public immutable aavePool;
    ICompound public immutable compound;
    ISonicProtocol public immutable sonicProtocol;
    IAIYieldOptimizer public immutable aiYieldOptimizer;
    IRegistry public registry;
    IRiskManager public riskManager;
    ILooperCore public looperCore;
    IStakingManager public stakingManager;
    IGovernanceManager public governanceManager;
    IUpkeepManager public upkeepManager;
    IGovernanceVault public governanceVault;
    IPointsTierManager public pointsTierManager;
    address public feeRecipient;
    uint256 public managementFee; // Basis points
    uint256 public performanceFee; // Basis points
    uint256 public totalAllocated;
    uint256 public minRWALiquidityThreshold;
    bool public allowLeverage;
    bool public isPaused;
    mapping(address => uint256) public userBalances;
    mapping(address => Allocation) public allocations;
    mapping(address => bool) public blacklistedUsers;
    mapping(address => uint256) public lastKnownAPYs;
    mapping(address => Lockup[]) public userLockups;

    // Constants
    uint256 public constant BASIS_POINTS = 10000;
    uint256 private constant SECONDS_PER_YEAR = 365 days;
    uint256 private constant MAX_APY = 10000; // 100%
    uint256 private constant FIXED_POINT_SCALE = 1e18;
    uint256 private constant MAX_EXP_INPUT = 10e18;
    uint256 private constant MIN_PROFIT = 1e6; // 1 USDC
    uint256 private constant AAVE_REFERRAL_CODE = 0;
    uint256 private constant MIN_ALLOCATION = 1e16; // 0.01 USDC
    uint256 public immutable MIN_DEPOSIT;
    uint256 private constant MAX_LOCKUPS = 10;

    // Structs
    struct Allocation {
        address protocol;
        uint256 amount;
        uint256 apy;
        uint256 lastUpdated;
        bool isLeveraged;
    }

    struct AllocationBreakdown {
        address protocol;
        uint256 amount;
        uint256 apy;
        bool isLeveraged;
        uint256 liquidity;
        uint256 riskScore;
    }

    struct Lockup {
        uint256 amount;
        uint256 lockupDays;
        uint256 startTimestamp;
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

    // Modifiers
    modifier onlyGovernance() {
        require(msg.sender == address(governanceManager), "Not governance");
        _;
    }

    modifier whenNotPaused() {
        require(!isPaused, "Paused");
        _;
    }

    /**
     * @notice Initializes the contract.
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
        MIN_DEPOSIT = 10 ** IERC20Metadata(_stablecoin).decimals();
        allowLeverage = true;
        minRWALiquidityThreshold = 1e18;
    }

    /**
     * @notice Authorizes upgrades.
     */
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /**
     * @notice Deposits funds and allocates them.
     */
    function deposit(uint256 amount, bool useLockup, uint256 lockupDays) external nonReentrant whenNotPaused {
        require(amount >= MIN_DEPOSIT, "Deposit below minimum");
        require(!blacklistedUsers[msg.sender], "User blacklisted");
        require(flyingTulip.isOFACCompliant(msg.sender), "OFAC check failed");
        require(lockupDays == 0 || lockupDays == 30 || lockupDays == 90, "Invalid lockup period");

        bytes32 correlationId = keccak256(abi.encodePacked(msg.sender, block.timestamp, amount));
        uint256 discount = governanceVault.getFeeDiscount(msg.sender);
        uint256 feeRate = (managementFee * (100 - discount)) / 100;
        uint256 fee = (amount * feeRate) / BASIS_POINTS;
        uint256 netAmount = amount - fee;

        stablecoin.safeTransferFrom(msg.sender, address(this), amount);
        stablecoin.safeTransfer(feeRecipient, fee);

        if (useLockup && lockupDays > 0) {
            Lockup[] storage lockups = userLockups[msg.sender];
            require(lockups.length < MAX_LOCKUPS, "Max lockups reached");
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
        emit TierUpdated(msg.sender, userBalances[msg.sender], hasLockup, maxLockupDays);

        _allocateFunds(netAmount, 0, type(uint256).max, correlationId);

        emit Deposit(msg.sender, netAmount, fee, discount, correlationId);

        // Testing Note: Test fee discounts, lockup limits, point awards, and allocation failures.
    }

    /**
     * @notice Withdraws funds with profits.
     */
    function withdraw(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "Amount must be > 0");
        require(userBalances[msg.sender] >= amount, "Insufficient balance");

        bytes32 correlationId = keccak256(abi.encodePacked(msg.sender, block.timestamp, amount));
        uint256 unlockedBalance = getUnlockedBalance(msg.sender);
        require(unlockedBalance >= amount, "Locked funds");

        uint256 profit = _calculateProfit(msg.sender, amount);
        uint256 discount = governanceVault.getFeeDiscount(msg.sender);
        uint256 feeRate = (performanceFee * (100 - discount)) / 100;
        uint256 performanceFeeAmount = (profit * feeRate) / BASIS_POINTS;
        uint256 netProfit = profit - performanceFeeAmount;

        _updateLockups(msg.sender, amount);

        userBalances[msg.sender] -= amount;
        totalAllocated -= amount;

        (bool hasLockup, uint256 maxLockupDays) = getUserLockupStatus(msg.sender);
        stakingManager.awardPoints(msg.sender, amount, false, hasLockup, maxLockupDays);
        emit TierUpdated(msg.sender, userBalances[msg.sender], hasLockup, maxLockupDays);

        uint256 withdrawnAmount = _deallocateFunds(amount, correlationId);
        require(withdrawnAmount >= amount, "Insufficient funds withdrawn");

        if (performanceFeeAmount > 0) {
            stablecoin.safeTransfer(feeRecipient, performanceFeeAmount);
        }
        stablecoin.safeTransfer(msg.sender, amount + netProfit);

        emit Withdraw(msg.sender, amount + netProfit, performanceFeeAmount, discount, correlationId);
        emit FeesCollected(feeRate, performanceFeeAmount, correlationId);

        // Testing Note: Test profit calculations, lockup enforcement, fee application, and partial withdrawals.
    }

    /**
     * @notice Emergency withdraw during pause.
     */
    function userEmergencyWithdraw(uint256 amount) external nonReentrant {
        require(isPaused, "Not paused");
        require(amount > 0, "Amount must be > 0");
        require(userBalances[msg.sender] >= amount, "Insufficient balance");

        bytes32 correlationId = keccak256(abi.encodePacked(msg.sender, block.timestamp, amount));
        userBalances[msg.sender] -= amount;
        totalAllocated -= amount;
        stablecoin.safeTransfer(msg.sender, amount);

        delete userLockups[msg.sender];

        stakingManager.awardPoints(msg.sender, amount, false, false, 0);
        emit TierUpdated(msg.sender, 0, false, 0);

        emit UserEmergencyWithdraw(msg.sender, amount, correlationId);

        // Testing Note: Test emergency withdrawals during pause, lockup clearing, and point updates.
    }

    /**
     * @notice Updates GovernanceVault.
     */
    function setGovernanceVault(address _governanceVault) external onlyOwner {
        require(_governanceVault != address(0), "Invalid GovernanceVault");
        governanceVault = IGovernanceVault(_governanceVault);
        emit GovernanceVaultUpdated(_governanceVault);

        // Testing Note: Test GovernanceVault updates and fee discount impacts.
    }

    /**
     * @notice Updates PointsTierManager.
     */
    function setPointsTierManager(address _pointsTierManager) external onlyOwner {
        require(_pointsTierManager != address(0), "Invalid PointsTierManager");
        pointsTierManager = IPointsTierManager(_pointsTierManager);
        emit PointsTierManagerUpdated(_pointsTierManager);

        // Testing Note: Test PointsTierManager updates and tier assignment impacts.
    }

    /**
     * @notice Calculates unlocked balance.
     */
    function getUnlockedBalance(address user) public view returns (uint256) {
        uint256 totalBalance = userBalances[user];
        uint256 lockedAmount = 0;
        Lockup[] storage lockups = userLockups[user];

        for (uint256 i = 0; i < lockups.length; i++) {
            if (block.timestamp < lockups[i].startTimestamp + (lockups[i].lockupDays * 1 days)) {
                lockedAmount += lockups[i].amount;
            }
        }

        return totalBalance >= lockedAmount ? totalBalance - lockedAmount : 0;

        // Testing Note: Test with active and expired lockups.
    }

    /**
     * @notice Updates lockups.
     */
    function _updateLockups(address user, uint256 withdrawAmount) internal {
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

        // Testing Note: Test lockup updates with partial withdrawals and expired lockups.
    }

    /**
     * @notice Gets user lockups.
     */
    function getUserLockups(address user) external view returns (Lockup[] memory) {
        return userLockups[user];

        // Testing Note: Test with no lockups and multiple lockups.
    }

    /**
     * @notice Gets lockup status.
     */
    function getUserLockupStatus(address user) public view returns (bool hasLockup, uint256 maxLockupDays) {
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

        // Testing Note: Test with active and expired lockups.
    }

    /**
     * @notice Rebalances portfolio with pagination.
     */
    function rebalance(uint256 start, uint256 limit, bytes32 correlationId)
        external
        onlyGovernance
        nonReentrant
        whenNotPaused
    {
        address[] memory protocols = registry.getActiveProtocols(false);
        require(start < protocols.length, "Invalid start index");
        uint256 end = start.add(limit) > protocols.length ? protocols.length : start.add(limit);

        // Withdraw from non-RWA protocols
        for (uint256 i = start; i < end; i++) {
            Allocation storage alloc = allocations[protocols[i]];
            if (alloc.amount > 0) {
                uint256 withdrawn = _withdrawFromProtocol(protocols[i], alloc.amount, correlationId);
                alloc.amount -= withdrawn;
            }
        }
        _cleanAllocations();

        // Fetch APYs and risk scores
        uint256[] memory apys = new uint256[](end - start);
        for (uint256 i = start; i < end; i++) {
            uint256 apy = sonicProtocol.getSonicAPY(protocols[i]);
            if (defiYield.isDeFiProtocol(protocols[i])) {
                (uint256 protocolAPY,,,) = defiYield.protocolScores(protocols[i]);
                apy = protocolAPY > 0 ? protocolAPY : apy;
            }
            apys[i - start] = riskManager.getRiskAdjustedAPY(protocols[i], apy);
        }

        uint256 totalBalance = stablecoin.balanceOf(address(this)) + aiYieldOptimizer.getTotalRWABalance();
        uint256 totalWeightedAPY = 0;
        uint256 nonRWAAmount = 0;
        uint256[] memory weights = new uint256[](end - start);

        // Calculate weights
        for (uint256 i = 0; i < end - start; i++) {
            if (!registry.isValidProtocol(protocols[start + i]) || !_validateAPY(apys[i], protocols[start + i])) {
                emit AIAllocationOptimized(protocols[start + i], 0, apys[i], false, correlationId);
                continue;
            }
            weights[i] = apys[i];
            totalWeightedAPY += apys[i];
        }

        // Allocate to non-RWA protocols
        for (uint256 i = 0; i < end - start; i++) {
            if (weights[i] == 0) continue;
            uint256 allocAmount = (totalBalance * weights[i]) / (totalWeightedAPY == 0 ? 1 : totalWeightedAPY);
            if (allocAmount < MIN_ALLOCATION) {
                emit AIAllocationOptimized(protocols[start + i], 0, apys[i], false, correlationId);
                continue;
            }
            bool isLeveraged = allowLeverage && _assessLeverageViability(protocols[start + i], allocAmount);
            allocations[protocols[start + i]] = Allocation(protocols[start + i], allocAmount, apys[i], block.timestamp, isLeveraged);
            lastKnownAPYs[protocols[start + i]] = apys[i];
            _depositToProtocol(protocols[start + i], allocAmount, isLeveraged, correlationId);
            nonRWAAmount += allocAmount;
            if (isLeveraged) {
                uint256 ltv = _getLTV(protocols[start + i], allocAmount);
                looperCore.applyLeverage(protocols[start + i], allocAmount, ltv, false);
            }
            emit AIAllocationOptimized(protocols[start + i], allocAmount, apys[i], isLeveraged, correlationId);
            emit Rebalance(protocols[start + i], allocAmount, apys[i], isLeveraged, correlationId);
        }

        // Delegate RWA reallocation
        uint256 rwaAmount = totalBalance > nonRWAAmount ? totalBalance - nonRWAAmount : 0;
        if (rwaAmount >= MIN_ALLOCATION) {
            (address[] memory rwaProtocols, uint256[] memory amounts, bool[] memory isLeveraged) =
                aiYieldOptimizer.getRecommendedAllocations(rwaAmount);
            require(validateAIAllocations(rwaProtocols, amounts, rwaAmount), "Invalid AI allocations");
            stablecoin.safeApprove(address(aiYieldOptimizer), 0);
            stablecoin.safeApprove(address(aiYieldOptimizer), rwaAmount);
            stablecoin.safeTransfer(address(aiYieldOptimizer), rwaAmount);
            aiYieldOptimizer.rebalancePortfolio(rwaProtocols, amounts, isLeveraged);
            string memory logicDescription = aiYieldOptimizer.getAllocationLogic(rwaAmount);
            emit AIAllocationDetails(rwaProtocols, amounts, isLeveraged, logicDescription, correlationId);
            emit RWADelegatedToAI(address(aiYieldOptimizer), rwaAmount, correlationId);
        }

        // Testing Note: Test pagination, partial rebalancing, RWA delegation failures, and APY synchronization.
    }

    /**
     * @notice Validates AI allocations.
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

        // Testing Note: Test with mismatched arrays and invalid RWA protocols.
    }

    /**
     * @notice Validates RWA protocol.
     */
    function validateRWAProtocol(address protocol) internal view returns (bool) {
        return
            rwaYield.getAvailableLiquidity(protocol) >= minRWALiquidityThreshold &&
            registry.isValidProtocol(protocol) &&
            sonicProtocol.isSonicCompliant(protocol);

        // Testing Note: Test with low liquidity or non-compliant protocols.
    }

    /**
     * @notice Assesses leverage viability.
     */
    function _assessLeverageViability(address protocol, uint256 amount) internal view returns (bool) {
        uint256 ltv = _getLTV(protocol, amount);
        return riskManager.assessLeverageViability(protocol, amount, ltv, false);

        // Testing Note: Test with varying LTVs and protocol types.
    }

    /**
     * @notice Gets LTV.
     */
    function _getLTV(address protocol, uint256 amount) internal view returns (uint256) {
        if (protocol == address(flyingTulip)) {
            return flyingTulip.getDynamicAPY(protocol);
        } else if (protocol == address(aavePool)) {
            return aavePool.getReserveData(address(stablecoin)).liquidityIndex;
        } else if (registry.isValidProtocol(protocol) && compound.underlying() == protocol) {
            return 5000; // 50% LTV
        }
        return 0;

        // Testing Note: Test LTV calculations for each protocol type.
    }

    /**
     * @notice Toggles pause.
     */
    function pause() external onlyGovernance {
        isPaused = true;
        emit PauseToggled(true);

        // Testing Note: Test pause/unpause transitions and emergency withdrawals.
    }

    /**
     * @notice Unpauses contract.
     */
    function unpause() external onlyGovernance {
        isPaused = false;
        emit PauseToggled(false);
    }

    /**
     * @notice Updates blacklist.
     */
    function updateBlacklist(address user, bool status) external onlyGovernance {
        blacklistedUsers[user] = status;
        emit BlacklistUpdated(user, status);

        // Testing Note: Test blacklist impacts on deposits/withdrawals.
    }

    /**
     * @notice Manual upkeep.
     */
    function manualUpkeep() external onlyGovernance {
        upkeepManager.manualUpkeep(false);

        // Testing Note: Test upkeep effects on protocol scores and allocations.
    }

    /**
     * @notice Allocates funds with pagination.
     */
    function _allocateFunds(uint256 amount, uint256 start, uint256 limit, bytes32 correlationId) internal {
        address[] memory protocols = registry.getActiveProtocols(false);
        require(start < protocols.length, "Invalid start index");
        uint256 end = start.add(limit) > protocols.length ? protocols.length : start.add(limit);

        uint256[] memory apys = new uint256[](end - start);
        for (uint256 i = start; i < end; i++) {
            uint256 apy = sonicProtocol.getSonicAPY(protocols[i]);
            if (defiYield.isDeFiProtocol(protocols[i])) {
                (uint256 protocolAPY,,,) = defiYield.protocolScores(protocols[i]);
                apy = protocolAPY > 0 ? protocolAPY : apy;
            }
            apys[i - start] = riskManager.getRiskAdjustedAPY(protocols[i], apy);
        }

        uint256 totalWeightedAPY = 0;
        uint256 nonRWAAmount = 0;
        uint256[] memory weights = new uint256[](end - start);

        for (uint256 i = 0; i < end - start; i++) {
            if (!registry.isValidProtocol(protocols[start + i]) || !_validateAPY(apys[i], protocols[start + i])) continue;
            weights[i] = apys[i];
            totalWeightedAPY += apys[i];
        }

        for (uint256 i = 0; i < end - start; i++) {
            if (weights[i] == 0) continue;
            uint256 allocAmount = (amount * weights[i]) / (totalWeightedAPY == 0 ? 1 : totalWeightedAPY);
            if (allocAmount < MIN_ALLOCATION) continue;
            bool isLeveraged = allowLeverage && _assessLeverageViability(protocols[start + i], allocAmount);
            allocations[protocols[start + i]] = Allocation(protocols[start + i], allocAmount, apys[i], block.timestamp, isLeveraged);
            lastKnownAPYs[protocols[start + i]] = apys[i];
            _depositToProtocol(protocols[start + i], allocAmount, isLeveraged, correlationId);
            nonRWAAmount += allocAmount;
            if (isLeveraged) {
                uint256 ltv = _getLTV(protocols[start + i], allocAmount);
                looperCore.applyLeverage(protocols[start + i], allocAmount, ltv, false);
            }
            emit AIAllocationOptimized(protocols[start + i], allocAmount, apys[i], isLeveraged, correlationId);
        }

        uint256 rwaAmount = amount > nonRWAAmount ? amount - nonRWAAmount : 0;
        if (rwaAmount >= MIN_ALLOCATION) {
            (address[] memory rwaProtocols, uint256[] memory amounts, bool[] memory isLeveraged) =
                aiYieldOptimizer.getRecommendedAllocations(rwaAmount);
            require(validateAIAllocations(rwaProtocols, amounts, rwaAmount), "Invalid AI allocations");
            stablecoin.safeApprove(address(aiYieldOptimizer), 0);
            stablecoin.safeApprove(address(aiYieldOptimizer), rwaAmount);
            stablecoin.safeTransfer(address(aiYieldOptimizer), rwaAmount);
            aiYieldOptimizer.submitAIAllocation(rwaProtocols, amounts, isLeveraged);
            string memory logicDescription = aiYieldOptimizer.getAllocationLogic(rwaAmount);
            emit AIAllocationDetails(rwaProtocols, amounts, isLeveraged, logicDescription, correlationId);
            emit RWADelegatedToAI(address(aiYieldOptimizer), rwaAmount, correlationId);
        }

        // Testing Note: Test pagination, allocation failures, RWA delegation, and APY synchronization.
    }

    /**
     * @notice Deallocates funds.
     */
    function _deallocateFunds(uint256 amount, bytes32 correlationId) internal returns (uint256) {
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
                totalWithdrawn += withdrawn;
                (bool hasLockup, uint256 maxLockupDays) = getUserLockupStatus(msg.sender);
                stakingManager.awardPoints(msg.sender, withdrawn, false, hasLockup, maxLockupDays);
                emit TierUpdated(msg.sender, userBalances[msg.sender], hasLockup, maxLockupDays);
            }
        }
        _cleanAllocations();
        return totalWithdrawn;

        // Testing Note: Test partial withdrawals, protocol failures, point updates, and RWA withdrawals.
    }

    /**
     * @notice Deposits funds to a protocol.
     */
    function _depositToProtocol(address protocol, uint256 amount, bool isLeveraged, bytes32 correlationId) internal {
        stablecoin.safeApprove(protocol, 0);
        stablecoin.safeApprove(protocol, amount);
        if (protocol == address(flyingTulip)) {
            flyingTulip.depositToPool(protocol, amount, isLeveraged);
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
            defiYield.depositToDeFi(protocol, amount, correlationId);
        }

        // Testing Note: Test deposits to each protocol type, handling of failed deposits, and correlation ID propagation.
    }

    /**
     * @notice Withdraws funds from a protocol.
     */
    function _withdrawFromProtocol(address protocol, uint256 amount, bytes32 correlationId) internal returns (uint256) {
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

        // Testing Note: Test withdrawals from each protocol, failure handling, and balance mismatches.
    }

    /**
     * @notice Cleans up zero-amount allocations.
     */
    function _cleanAllocations() internal {
        address[] memory protocols = registry.getActiveProtocols(false);
        for (uint256 i = 0; i < protocols.length; i++) {
            if (allocations[protocols[i]].amount == 0) {
                delete allocations[protocols[i]];
            }
        }

        // Testing Note: Test allocation cleanup with multiple zero-amount protocols.
    }

    /**
     * @notice Validates a protocol.
     */
    function _isValidProtocol(address protocol) internal view returns (bool) {
        return registry.isValidProtocol(protocol) && sonicProtocol.isSonicCompliant(protocol);

        // Testing Note: Test with invalid or non-compliant protocols.
    }

    /**
     * @notice Validates APY data.
     */
    function _validateAPY(uint256 apy, address protocol) internal view returns (bool) {
        uint256 liquidity = getProtocolLiquidity(protocol);
        return apy > 0 && apy <= MAX_APY && liquidity > 0;

        // Testing Note: Test with zero APY, excessive APY, or zero liquidity.
    }

    /**
     * @notice Gets protocol liquidity.
     */
    function getProtocolLiquidity(address protocol) public view returns (uint256 liquidity) {
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
            return 0;
        }

        // Testing Note: Test liquidity queries for each protocol and failure cases.
    }

    /**
     * @notice Calculates user profit with real-time DeFiYield data.
     */
    function _calculateProfit(address user, uint256 amount) internal view returns (uint256) {
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

            // Sync APY with DeFiYield for non-RWA protocols
            uint256 apy = alloc.apy;
            if (!rwaYield.isRWA(protocols[i]) && defiYield.isDeFiProtocol(protocols[i])) {
                (uint256 protocolAPY,,,) = defiYield.protocolScores(protocols[i]);
                apy = protocolAPY > 0 ? protocolAPY : alloc.apy;
            }

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
            uint256 rwaAPY = lastKnownAPYs[address(aiYieldOptimizer)] > 0 ? lastKnownAPYs[address(aiYieldOptimizer)] : 500;
            uint256 timeElapsed = block.timestamp - allocations[address(aiYieldOptimizer)].lastUpdated;
            uint256 rwaProfit = (rwaShare * rwaAPY * timeElapsed) / (BASIS_POINTS * SECONDS_PER_YEAR);
            totalProfit += rwaProfit;
        }

        return totalProfit >= MIN_PROFIT ? totalProfit : 0;

        // Testing Note: Test profit calculations with real-time DeFiYield APYs, zero APYs, large time intervals, and RWA balances.
    }

    /**
     * @notice Gets user balance and estimated profits.
     */
    function getUserBalance(address user) external view returns (uint256 balance, uint256 estimatedProfit) {
        balance = userBalances[user];
        estimatedProfit = _calculateProfit(user, balance);

        // Testing Note: Test balance and profit calculations for users with no allocations or lockups.
    }

    /**
     * @notice Gets allocation breakdown.
     */
    function getAllocationBreakdown() external view returns (AllocationBreakdown[] memory) {
        address[] memory protocols = registry.getActiveProtocols(false);
        AllocationBreakdown[] memory breakdown = new AllocationBreakdown[](protocols.length + 1);
        uint256 breakdownIndex = 0;

        for (uint256 i = 0; i < protocols.length; i++) {
            Allocation memory alloc = allocations[protocols[i]];
            if (alloc.amount == 0) continue;
            uint256 apy = alloc.apy;
            if (defiYield.isDeFiProtocol(protocols[i])) {
                (uint256 protocolAPY,,,) = defiYield.protocolScores(protocols[i]);
                apy = protocolAPY > 0 ? protocolAPY : alloc.apy;
            }
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
            uint256 rwaAPY = lastKnownAPYs[address(aiYieldOptimizer)] > 0 ? lastKnownAPYs[address(aiYieldOptimizer)] : 500;
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

        // Testing Note: Test breakdown accuracy with zero allocations, RWA balances, and real-time APY updates.
    }

    /**
     * @notice Prevents accidental ETH deposits.
     */
    receive() external payable {
        revert("ETH deposits not allowed");

        // Testing Note: Test fallback function with ETH transfers.
    }
}
