a// SPDX-License-Identifier: MIT
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

// Sonic protocol interface
interface ISonicProtocol {
    function isSonicCompliant(address protocol) external view returns (bool);
    function getSonicAPY(address protocol) external view returns (uint256);
}

// AIYieldOptimizer interface
interface IAIYieldOptimizer {
    function submitAIAllocation(address[] calldata protocols, uint256[] calldata amounts, bool[] calldata isLeveraged) external;
    function rebalancePortfolio(address[] calldata protocols, uint256[] calldata amounts, bool[] calldata isLeveraged) external;
    function getSupportedProtocols() external view returns (address[] memory);
    function getTotalRWABalance() external view returns (uint256);
}

/**
 * @title YieldOptimizer
 * @notice A DeFi yield farming aggregator optimized for Sonic Blockchain, supporting Aave V3, Compound, FlyingTulip, RWA, and Sonic-native protocols.
 * @dev Uses UUPS proxy, integrates with Sonic’s Fee Monetization, native USDC, RedStone oracles, Sonic Points for airdrop eligibility, and delegates RWA allocations to AIYieldOptimizer.
 */
contract YieldOptimizer is UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuard, PausableUpgradeable, AutomationCompatibleInterface {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // State variables
    IERC20 public immutable stablecoin; // Sonic’s native USDC
    IRWAYield public immutable rwaYield;
    IDeFiYield public immutable defiYield;
    IFlyingTulip public immutable flyingTulip;
    IAaveV3Pool public immutable aavePool;
    ISonicProtocol public immutable sonicProtocol; // Sonic compliance and APY
    IERC20 public immutable sonicPointsToken; // Sonic Points for airdrop
    IAIYieldOptimizer public immutable aiYieldOptimizer; // AIYieldOptimizer for RWA allocations
    address public governance; // Multi-sig or DAO
    address public feeRecipient; // Receives management/performance fees
    address public sonicNativeUSDC; // Sonic’s native USDC address
    uint256 public managementFee; // Basis points (e.g., 50 = 0.5%)
    uint256 public performanceFee; // Basis points (e.g., 1000 = 10%)
    uint256 public feeMonetizationShare; // Sonic FeeM share (default 90%)
    uint256 public totalFeeMonetizationRewards; // Accumulated FeeM rewards
    uint256 public immutable MIN_DEPOSIT;
    uint256 public constant MAX_PROTOCOLS = 10;
    uint256 public constant MAX_LTV = 8000; // 80% LTV cap
    uint256 public constant MIN_ALLOCATION = 1e16; // 0.01 stablecoin units
    bool public allowLeverage;
    bool public emergencyPaused;
    uint256 public pauseTimestamp;
    address public pendingGovernance;
    uint256 public governanceUpdateTimestamp;
    address public pendingImplementation;
    uint256 public upgradeTimestamp;
    bool private initializedImplementation;

    // Chainlink feeds and protocol data
    mapping(address => AggregatorV3Interface) public protocolAPYFeeds; // Chainlink or RedStone feeds
    mapping(address => uint256) public lastKnownAPYs; // Fallback APYs
    mapping(address => bool) public whitelistedProtocols; // Allowed protocols
    mapping(address => bool) public isCompoundProtocol; // Compound cTokens
    mapping(address => uint256) public manualLiquidityOverrides; // Manual liquidity settings
    mapping(address => bool) public blacklistedUsers; // Compliance blacklist
    mapping(address => uint256) public sonicPointsEarned; // User airdrop points
    mapping(address => Allocation) public allocations; // Protocol allocations
    mapping(address => bool) public isActiveProtocol; // Active protocols
    address[] public activeProtocols; // List of active protocols
    mapping(address => uint256) public userBalances; // User deposits
    uint256 public totalAllocated; // Total funds allocated
    uint256 public lastUpkeepTimestamp; // Last Chainlink upkeep

    // Governance timelock actions
    struct TimelockAction {
        bytes32 actionHash;
        uint256 timestamp;
    }
    mapping(bytes32 => TimelockAction) public timelockActions;

    // Constants
    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant SECONDS_PER_YEAR = 365 days;
    uint256 private constant BLOCKS_PER_YEAR = 2628000; // ~13.5s per block, adjusted for Sonic
    uint256 private constant MAX_APY = 10000; // 100% max APY
    uint256 private constant FIXED_POINT_SCALE = 1e18;
    uint256 private constant MAX_EXP_INPUT = 10e18; // Cap for _exp
    uint256 private constant MIN_PROFIT = 1e6; // 0.000001 stablecoin
    uint256 private constant AAVE_REFERRAL_CODE = 0;
    uint256 private constant MAX_BORROW_AMOUNT = 1e24; // 1M stablecoin units
    uint256 private constant MIN_HEALTH_FACTOR = 1.5e18; // Aave health factor
    uint256 private constant MIN_COLLATERAL_FACTOR = 1.5e18; // Compound collateral factor
    uint256 private constant MAX_STALENESS = 30 minutes; // Chainlink feed staleness
    uint256 private constant MAX_FEED_FAILURES = 50; // 50% feed failure threshold
    uint256 private constant UPKEEP_INTERVAL = 1 days; // Chainlink Automation interval
    uint256 private constant MAX_PAUSE_DURATION = 7 days; // Emergency pause limit
    uint256 private constant GOVERNANCE_UPDATE_DELAY = 2 days; // Governance timelock
    uint256 private constant UPGRADE_DELAY = 2 days; // Upgrade timelock
    uint256 private constant TIMELOCK_DELAY = 2 days; // Action timelock

    // Allocation struct
    struct Allocation {
        address protocol;
        uint256 amount;
        uint256 apy; // Basis points
        uint256 lastUpdated;
        bool isLeveraged;
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
    event FeeMonetizationRewardsClaimed(uint256 amount);
    event SonicPointsClaimed(address indexed user, uint256 points);
    event RWADelegatedToAI(address indexed aiYieldOptimizer, uint256 amount);

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
        uint256 feeShare = ((gasUsed - gasleft()) * tx.gasprice * feeMonetizationShare) / 100;
        totalFeeMonetizationRewards += feeShare;
    }

    /**
     * @notice Initializes the contract with Sonic-specific parameters and AIYieldOptimizer.
     * @param _stablecoin Sonic’s native USDC address.
     * @param _rwaYield RWA yield contract.
     * @param _defiYield DeFi yield contract.
     * @param _flyingTulip FlyingTulip contract.
     * @param _aavePool Aave V3 pool contract.
     * @param _sonicProtocol Sonic protocol compliance contract.
     * @param _sonicPointsToken Sonic Points token for airdrop.
     * @param _feeRecipient Fee recipient address.
     * @param _governance Governance address (multi-sig/DAO).
     * @param _aiYieldOptimizer AIYieldOptimizer contract for RWA allocations.
     */
    function initialize(
        address _stablecoin,
        address _rwaYield,
        address _defiYield,
        address _flyingTulip,
        address _aavePool,
        address _sonicProtocol,
        address _sonicPointsToken,
        address _feeRecipient,
        address _governance,
        address _aiYieldOptimizer
    ) external initializer {
        require(!initializedImplementation, "Implementation already initialized");
        initializedImplementation = true;

        require(_stablecoin != address(0), "Invalid stablecoin address");
        require(_rwaYield != address(0), "Invalid RWAYield address");
        require(_defiYield != address(0), "Invalid DeFiYield address");
        require(_flyingTulip != address(0), "Invalid FlyingTulip address");
        require(_aavePool != address(0), "Invalid AavePool address");
        require(_sonicProtocol != address(0), "Invalid SonicProtocol address");
        require(_sonicPointsToken != address(0), "Invalid SonicPointsToken address");
        require(_feeRecipient != address(0), "Invalid fee recipient");
        require(_governance != address(0), "Invalid governance");
        require(_aiYieldOptimizer != address(0), "Invalid AIYieldOptimizer address");

        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        stablecoin = IERC20(_stablecoin);
        sonicNativeUSDC = _stablecoin;
        rwaYield = IRWAYield(_rwaYield);
        defiYield = IDeFiYield(_defiYield);
        flyingTulip = IFlyingTulip(_flyingTulip);
        aavePool = IAaveV3Pool(_aavePool);
        sonicProtocol = ISonicProtocol(_sonicProtocol);
        sonicPointsToken = IERC20(_sonicPointsToken);
        aiYieldOptimizer = IAIYieldOptimizer(_aiYieldOptimizer);
        feeRecipient = _feeRecipient;
        governance = _governance;
        managementFee = 50; // 0.5%
        performanceFee = 1000; // 10%
        feeMonetizationShare = 90; // 90% for Sonic FeeM
        MIN_DEPOSIT = 10 ** IERC20Metadata(_stablecoin).decimals();
        allowLeverage = false;
        emergencyPaused = false;
        lastUpkeepTimestamp = block.timestamp;
    }

    /**
     * @notice Proposes a contract upgrade with a timelock.
     * @param newImplementation Address of the new implementation.
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
     * @notice Deposits funds and allocates them to protocols with Sonic points tracking.
     * @param amount Amount of stablecoin to deposit.
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
        sonicPointsEarned[msg.sender] += netAmount * 2; // 2x multiplier for activity points
        _allocateFunds(netAmount, 0, activeProtocols.length);

        emit Deposit(msg.sender, netAmount, fee);
    }

    /**
     * @notice Withdraws funds and distributes profits.
     * @param amount Amount to withdraw.
     */
    function withdraw(uint256 amount) external nonReentrant whenNotPaused whenNotEmergencyPaused sonicFeeMonetization {
        require(amount > 0, "Amount must be > 0");
        require(userBalances[msg.sender] >= amount, "Insufficient balance");

        uint256 profit = _calculateProfit(msg.sender, amount);
        uint256 performanceFeeAmount = (profit * performanceFee) / BASIS_POINTS;
        uint256 netProfit = profit - performanceFeeAmount;

        userBalances[msg.sender] -= amount;
        totalAllocated -= amount;
        sonicPointsEarned[msg.sender] += amount; // 1x points for withdrawals

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
     * @param amount Amount to withdraw.
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
     * @notice Rebalances funds across protocols, delegating RWA allocations to AIYieldOptimizer.
     */
    function rebalance() external onlyGovernance nonReentrant whenNotPaused whenNotEmergencyPaused sonicFeeMonetization {
        // Step 1: Withdraw from all protocols
        for (uint256 i = 0; i < activeProtocols.length; i++) {
            address protocol = activeProtocols[i];
            Allocation storage alloc = allocations[protocol];
            if (alloc.amount > 0) {
                uint256 withdrawn = _withdrawFromProtocol(protocol, alloc.amount);
                alloc.amount -= withdrawn;
            }
        }

        // Step 2: Clean up allocations
        _cleanAllocations();

        // Step 3: Fetch APYs for non-RWA protocols
        (address[] memory protocols, uint256[] memory apys) = _getAPYsFromChainlink();
        require(protocols.length <= MAX_PROTOCOLS, "Invalid protocol count");
        require(protocols.length == apys.length, "APY data mismatch");

        // Step 4: Calculate total balance, including RWA balance from AIYieldOptimizer
        uint256 totalBalance = stablecoin.balanceOf(address(this)) + aiYieldOptimizer.getTotalRWABalance();
        uint256 totalAPY = _totalAPY(apys);

        // Step 5: Allocate to non-RWA protocols
        uint256 nonRWAAmount = 0;
        for (uint256 i = 0; i < protocols.length; i++) {
            if (rwaYield.isRWA(protocols[i])) {
                continue; // Skip RWA protocols for now
            }
            if (!_isValidProtocol(protocols[i]) || !_validateAPY(apys[i], protocols[i])) {
                emit AllocationSkipped(protocols[i], "Invalid protocol or APY");
                continue;
            }
            uint256 allocAmount = (totalBalance * apys[i]) / totalAPY;
            if (allocAmount < MIN_ALLOCATION) {
                emit AllocationSkipped(protocols[i], "Amount below minimum");
                continue;
            }
            bool isLeveraged = allowLeverage && (protocols[i] == address(flyingTulip) || protocols[i] == address(aavePool) || isCompoundProtocol[protocols[i]]);
            allocations[protocols[i]] = Allocation(protocols[i], allocAmount, apys[i], block.timestamp, isLeveraged);
            lastKnownAPYs[protocols[i]] = apys[i];
            if (!isActiveProtocol[protocols[i]]) {
                activeProtocols.push(protocols[i]);
                isActiveProtocol[protocols[i]] = true;
            }
            _depositToProtocol(protocols[i], allocAmount, isLeveraged);
            nonRWAAmount += allocAmount;
            if (isLeveraged) {
                uint256 ltv;
                if (protocols[i] == address(flyingTulip)) {
                    ltv = flyingTulip.getLTV(protocols[i], allocAmount);
                } else if (protocols[i] == address(aavePool)) {
                    ltv = aavePool.getUserAccountData(address(this)).ltv;
                } else if (isCompoundProtocol[protocols[i]]) {
                    (, uint256 collateralFactor, ) = ICompound(protocols[i]).getAccountLiquidity(address(this));
                    ltv = (collateralFactor * BASIS_POINTS) / 1e18;
                }
                ltv = ltv > MAX_LTV ? MAX_LTV : ltv;
                uint256 borrowAmount = (allocAmount * ltv) / BASIS_POINTS;
                if (borrowAmount > 0 && borrowAmount <= MAX_BORROW_AMOUNT && _checkLiquidationRisk(protocols[i], allocAmount, borrowAmount)) {
                    if (protocols[i] == address(flyingTulip)) {
                        flyingTulip.borrowWithLTV(protocols[i], allocAmount, borrowAmount);
                    } else if (protocols[i] == address(aavePool)) {
                        _borrowFromAave(protocols[i], allocAmount, borrowAmount);
                    } else if (isCompoundProtocol[protocols[i]]) {
                        _borrowFromCompound(protocols[i], allocAmount, borrowAmount);
                    }
                    emit LTVBorrow(protocols[i], allocAmount, borrowAmount);
                } else {
                    emit AllocationSkipped(protocols[i], "Liquidation risk too high");
                }
            }
            emit Rebalance(protocols[i], allocAmount, apys[i], isLeveraged);
        }

        // Step 6: Delegate RWA allocation to AIYieldOptimizer
        uint256 rwaAmount = totalBalance > nonRWAAmount ? totalBalance - nonRWAAmount : 0;
        if (rwaAmount >= MIN_ALLOCATION) {
            address[] memory rwaProtocols = aiYieldOptimizer.getSupportedProtocols();
            uint256[] memory amounts = new uint256[](rwaProtocols.length);
            bool[] memory isLeveraged = new bool[](rwaProtocols.length);
            // AI model determines amounts and leverage off-chain, submitted via aiOracle
            stablecoin.safeApprove(address(aiYieldOptimizer), 0);
            stablecoin.safeApprove(address(aiYieldOptimizer), rwaAmount);
            stablecoin.safeTransfer(address(aiYieldOptimizer), rwaAmount);
            aiYieldOptimizer.rebalancePortfolio(rwaProtocols, amounts, isLeveraged);
            emit RWADelegatedToAI(address(aiYieldOptimizer), rwaAmount);
        }
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
        aavePool.borrow(address(stablecoin), borrowAmount, 2, AAVE_REFERRAL_CODE, address(this)); // Variable rate
    }

    /**
     * @notice Borrows from Compound with safety checks.
     */
    function _borrowFromCompound(address protocol, uint256 collateral, uint256 borrowAmount) internal {
        require(isCompoundProtocol[protocol], "Invalid protocol");
        (, uint256 collateralFactor, uint256 liquidity) = ICompound(protocol).getAccountLiquidity(address(this));
        require(collateralFactor >= MIN_COLLATERAL_FACTOR, "Collateral factor too low");
        require(borrowAmount <= liquidity, "Exceeds available liquidity");
        stablecoin.safeApprove(protocol, 0);
        stablecoin.safeApprove(protocol, borrowAmount);
        require(ICompound(protocol).borrow(borrowAmount) == 0, "Compound borrow failed");
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
            aavePool.repay(address(stablecoin), repayAmount, 2, address(this)); // Variable rate
        } else if (isCompoundProtocol[protocol]) {
            repayAmount = ICompound(protocol).borrowBalanceCurrent(address(this));
            _withdrawForRepayment(repayAmount);
            stablecoin.safeApprove(protocol, 0);
            stablecoin.safeApprove(protocol, repayAmount);
            require(ICompound(protocol).repayBorrow(repayAmount) == 0, "Compound repay failed");
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
            emit FeedHealthCheckFailed(validFeeds, totalFeeds);
        }
        return isHealthy;
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
        uint256 currentLTV;
        if (protocol == address(flyingTulip)) {
            currentLTV = flyingTulip.getLTV(protocol, alloc.amount);
        } else if (protocol == address(aavePool)) {
            currentLTV = aavePool.getUserAccountData(address(this)).ltv;
        } else if (isCompoundProtocol[protocol]) {
            (, uint256 collateralFactor, ) = ICompound(protocol).getAccountLiquidity(address(this));
            currentLTV = (collateralFactor * BASIS_POINTS) / 1e18;
        }
        if (currentLTV > maxLTV) {
            uint256 excessLTV = currentLTV - maxLTV;
            uint256 repayAmount = (alloc.amount * excessLTV) / BASIS_POINTS;
            uint256 balance = stablecoin.balanceOf(address(this));
            if (balance < repayAmount) {
                uint256 needed = repayAmount - balance;
                try this.withdrawForRepayment(needed) {
                    // Success
                } catch {
                    emit AllocationSkipped(protocol, "Failed to withdraw for repayment");
                    _pauseLeverage(protocol);
                    return;
                }
            }
            stablecoin.safeApprove(protocol, 0);
            stablecoin.safeApprove(protocol, repayAmount);
            if (protocol == address(flyingTulip)) {
                flyingTulip.repayBorrow(protocol, repayAmount);
            } else if (protocol == address(aavePool)) {
                aavePool.repay(address(stablecoin), repayAmount, 2, address(this)); // Variable rate
            } else if (isCompoundProtocol[protocol]) {
                require(ICompound(protocol).repayBorrow(repayAmount) == 0, "Compound repay failed");
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
                    lastKnownAPYs[protocol] = apy;
                    emit LastKnownAPYUpdated(protocol, apy);
                }
            }
        }
        emit ManualUpkeepTriggered(block.timestamp);
    }

    /**
     * @notice Claims Sonic Fee Monetization rewards for the developer.
     */
    function claimFeeMonetizationRewards() external onlyGovernance nonReentrant sonicFeeMonetization {
        uint256 rewards = totalFeeMonetizationRewards;
        require(rewards > 0, "No rewards available");
        totalFeeMonetizationRewards = 0;
        stablecoin.safeTransfer(governance, rewards);
        emit FeeMonetizationRewardsClaimed(rewards);
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
                            ? IERC20(ICompound(protocol).underlying()).balanceOf(protocol)
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
        require(newManagementFee <= 200 && newPerformanceFee <= 2000, "Fees too high"); // Max 2% and 20%
        bytes32 actionHash = keccak256(abi.encode("updateFees", newManagementFee, newPerformanceFee));
        timelockActions[actionHash] = TimelockAction(actionHash, block.timestamp + TIMELOCK_DELAY);
        emit TimelockActionProposed(actionHash, block.timestamp + TIMELOCK_DELAY);
    }

    /**
     * @notice Executes fee update after timelock.
     */
    function executeUpdateFees(uint256 newManagementFee, uint256 newPerformanceFee) external onlyGovernance sonicFeeMonetization {
        bytes32 actionHash = keccak256(abi.encode("updateFees", newManagementFee, newPerformanceFee));
        TimelockAction memory action = timelockActions[actionHash];
        require(action.timestamp > 0 && block.timestamp >= action.timestamp, "Timelock not elapsed");
        managementFee = newManagementFee;
        performanceFee = newPerformanceFee;
        delete timelockActions[actionHash];
        emit FeesUpdated(newManagementFee, newPerformanceFee);
        emit TimelockActionExecuted(actionHash);
    }

    /**
     * @notice Updates fee recipient address with timelock.
     */
    function proposeFeeRecipientUpdate(address newRecipient) external onlyGovernance sonicFeeMonetization {
        require(newRecipient != address(0), "Invalid address");
        bytes32 actionHash = keccak256(abi.encode("updateFeeRecipient", newRecipient));
        timelockActions[actionHash] = TimelockAction(actionHash, block.timestamp + TIMELOCK_DELAY);
        emit TimelockActionProposed(actionHash, block.timestamp + TIMELOCK_DELAY);
    }

    function executeFeeRecipientUpdate(address newRecipient) external onlyGovernance sonicFeeMonetization {
        bytes32 actionHash = keccak256(abi.encode("updateFeeRecipient", newRecipient));
        TimelockAction memory action = timelockActions[actionHash];
        require(action.timestamp > 0 && block.timestamp >= action.timestamp, "Timelock not elapsed");
        feeRecipient = newRecipient;
        delete timelockActions[actionHash];
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
        timelockActions[actionHash] = TimelockAction(actionHash, block.timestamp + TIMELOCK_DELAY);
        emit TimelockActionProposed(actionHash, block.timestamp + TIMELOCK_DELAY);
    }

    /**
     * @notice Executes fund recovery after timelock.
     */
    function executeRecoverFunds(address protocol, uint256 amount) external onlyGovernance nonReentrant sonicFeeMonetization {
        bytes32 actionHash = keccak256(abi.encode("recoverFunds", protocol, amount));
        TimelockAction memory action = timelockActions[actionHash];
        require(action.timestamp > 0 && block.timestamp >= action.timestamp, "Timelock not elapsed");
        uint256 withdrawn = _withdrawFromProtocol(protocol, amount);
        require(withdrawn > 0, "No funds recovered");
        allocations[protocol].amount -= withdrawn;
        _cleanAllocations();
        delete timelockActions[actionHash];
        emit FundsRecovered(protocol, withdrawn);
        emit TimelockActionExecuted(actionHash);
    }

    /**
     * @notice Proposes an emergency withdrawal for a user.
     */
    function proposeEmergencyWithdraw(address user, uint256 amount) external onlyGovernance sonicFeeMonetization {
        require(userBalances[user] >= amount, "Insufficient balance");
        bytes32 actionHash = keccak256(abi.encode("emergencyWithdraw", user, amount));
        timelockActions[actionHash] = TimelockAction(actionHash, block.timestamp + TIMELOCK_DELAY);
        emit TimelockActionProposed(actionHash, block.timestamp + TIMELOCK_DELAY);
    }

    /**
     * @notice Executes an emergency withdrawal after timelock.
     */
    function executeEmergencyWithdraw(address user, uint256 amount) external onlyGovernance sonicFeeMonetization {
        bytes32 actionHash = keccak256(abi.encode("emergencyWithdraw", user, amount));
        TimelockAction memory action = timelockActions[actionHash];
        require(action.timestamp > 0 && block.timestamp >= action.timestamp, "Timelock not elapsed");
        require(emergencyPaused, "Not emergency paused");
        require(userBalances[user] >= amount, "Insufficient balance");
        userBalances[user] -= amount;
        totalAllocated -= amount;
        stablecoin.safeTransfer(user, amount);
        delete timelockActions[actionHash];
        emit EmergencyTransfer(user, amount);
        emit TimelockActionExecuted(actionHash);
    }

    /**
     * @notice Proposes an emergency transfer of stuck funds.
     */
    function proposeEmergencyTransfer(address user, uint256 amount) external onlyGovernance sonicFeeMonetization {
        require(stablecoin.balanceOf(address(this)) >= amount, "Insufficient balance");
        bytes32 actionHash = keccak256(abi.encode("emergencyTransfer", user, amount));
        timelockActions[actionHash] = TimelockAction(actionHash, block.timestamp + TIMELOCK_DELAY);
        emit TimelockActionProposed(actionHash, block.timestamp + TIMELOCK_DELAY);
    }

    /**
     * @notice Executes an emergency transfer after timelock.
     */
    function executeEmergencyTransfer(address user, uint256 amount) external onlyGovernance sonicFeeMonetization {
        bytes32 actionHash = keccak256(abi.encode("emergencyTransfer", user, amount));
        TimelockAction memory action = timelockActions[actionHash];
        require(action.timestamp > 0 && block.timestamp >= action.timestamp, "Timelock not elapsed");
        require(emergencyPaused, "Not emergency paused");
        require(stablecoin.balanceOf(address(this)) >= amount, "Insufficient balance");
        stablecoin.safeTransfer(user, amount);
        delete timelockActions[actionHash];
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

        uint256 totalAPY = _totalAPY(apys);
        uint256 nonRWAAmount = 0;

        // Step 1: Allocate to non-RWA protocols
        for (uint256 i = startIndex; i < endIndex && i < protocols.length; i++) {
            if (rwaYield.isRWA(protocols[i])) {
                continue; // Skip RWA protocols for now
            }
            if (!_isValidProtocol(protocols[i]) || !_validateAPY(apys[i], protocols[i])) {
                emit AllocationSkipped(protocols[i], "Invalid protocol or APY");
                continue;
            }
            uint256 allocAmount = (amount * apys[i]) / totalAPY;
            if (allocAmount < MIN_ALLOCATION) {
                emit AllocationSkipped(protocols[i], "Amount below minimum");
                continue;
            }
            bool isLeveraged = allowLeverage && (protocols[i] == address(flyingTulip) || protocols[i] == address(aavePool) || isCompoundProtocol[protocols[i]]);
            allocations[protocols[i]] = Allocation(protocols[i], allocAmount, apys[i], block.timestamp, isLeveraged);
            lastKnownAPYs[protocols[i]] = apys[i];
            if (!isActiveProtocol[protocols[i]]) {
                activeProtocols.push(protocols[i]);
                isActiveProtocol[protocols[i]] = true;
            }
            _depositToProtocol(protocols[i], allocAmount, isLeveraged);
            nonRWAAmount += allocAmount;
            sonicPointsEarned[msg.sender] += allocAmount * 2; // 2x points for allocation
            if (isLeveraged) {
                uint256 ltv;
                if (protocols[i] == address(flyingTulip)) {
                    ltv = flyingTulip.getLTV(protocols[i], allocAmount);
                } else if (protocols[i] == address(aavePool)) {
                    ltv = aavePool.getUserAccountData(address(this)).ltv;
                } else if (isCompoundProtocol[protocols[i]]) {
                    (, uint256 collateralFactor, ) = ICompound(protocols[i]).getAccountLiquidity(address(this));
                    ltv = (collateralFactor * BASIS_POINTS) / 1e18;
                }
                ltv = ltv > MAX_LTV ? MAX_LTV : ltv;
                uint256 borrowAmount = (allocAmount * ltv) / BASIS_POINTS;
                if (borrowAmount > 0 && borrowAmount <= MAX_BORROW_AMOUNT && _checkLiquidationRisk(protocols[i], allocAmount, borrowAmount)) {
                    if (protocols[i] == address(flyingTulip)) {
                        flyingTulip.borrowWithLTV(protocols[i], allocAmount, borrowAmount);
                    } else if (protocols[i] == address(aavePool)) {
                        _borrowFromAave(protocols[i], allocAmount, borrowAmount);
                    } else if (isCompoundProtocol[protocols[i]]) {
                        _borrowFromCompound(protocols[i], allocAmount, borrowAmount);
                    }
                    emit LTVBorrow(protocols[i], allocAmount, borrowAmount);
                } else {
                    emit AllocationSkipped(protocols[i], "Liquidation risk too high");
                }
            }
            emit Rebalance(protocols[i], allocAmount, apys[i], isLeveraged);
        }

        // Step 2: Delegate RWA allocation to AIYieldOptimizer
        uint256 rwaAmount = amount > nonRWAAmount ? amount - nonRWAAmount : 0;
        if (rwaAmount >= MIN_ALLOCATION) {
            address[] memory rwaProtocols = aiYieldOptimizer.getSupportedProtocols();
            uint256[] memory amounts = new uint256[](rwaProtocols.length);
            bool[] memory isLeveraged = new bool[](rwaProtocols.length);
            // AI model determines amounts and leverage off-chain, submitted via aiOracle
            stablecoin.safeApprove(address(aiYieldOptimizer), 0);
            stablecoin.safeApprove(address(aiYieldOptimizer), rwaAmount);
            stablecoin.safeTransfer(address(aiYieldOptimizer), rwaAmount);
            aiYieldOptimizer.submitAIAllocation(rwaProtocols, amounts, isLeveraged);
            sonicPointsEarned[msg.sender] += rwaAmount * 2; // 2x points for RWA allocation
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
        for (uint256 i = startIndex; i < endIndex && totalWithdrawn < amount; i++) {
            address protocol = sortedProtocols[i];
            Allocation storage alloc = allocations[protocol];
            uint256 withdrawAmount = (amount * alloc.amount) / totalAllocated;
            if (withdrawAmount > 0) {
                uint256 availableLiquidity = getProtocolLiquidity(protocol);
                withdrawAmount = withdrawAmount > availableLiquidity ? availableLiquidity : withdrawAmount;
                uint256 withdrawn = _withdrawFromProtocol(protocol, withdrawAmount);
                alloc.amount -= withdrawn;
                totalWithdrawn += withdrawn;
                sonicPointsEarned[msg.sender] += withdrawn; // 1x points for deallocation
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
            try ICompound(protocol).mint(amount) returns (uint256 err) {
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
                            ? ICompound(protocol).redeemUnderlying(amount) == 0 ? amount : 0
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
        for (uint256 i = 0; i < sortedProtocols.length && totalWithdrawn < amount; i++) {
            address protocol = sortedProtocols[i];
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
        uint256 writeIndex = 0;
        for (uint256 i = 0; i < activeProtocols.length; i++) {
            address protocol = activeProtocols[i];
            if (allocations[protocol].amount == 0) {
                delete allocations[protocol];
                isActiveProtocol[protocol] = false;
            } else {
                if (i != writeIndex) {
                    activeProtocols[writeIndex] = protocol;
                }
                writeIndex++;
            }
        }
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
            (rwaYield.isRWA(protocol) || protocol == address(flyingTulip) || protocol == address(aavePool) || isCompoundProtocol[protocol] || _isDeFiProtocol(protocol)) &&
            checkProtocolHealth(protocol) &&
            sonicProtocol.isSonicCompliant(protocol);
    }

    /**
     * @notice Checks if a protocol is a valid DeFi protocol.
     */
    function _isDeFiProtocol(address protocol) internal view returns (bool) {
        return defiYield.isDeFiProtocol(protocol);
    }

    /**
     * @notice Validates APY data from Chainlink, RedStone, or Aave/Compound.
     */
    function _validateAPY(uint256 apy, address protocol) internal view returns (bool) {
        if (apy == 0 || apy > MAX_APY) return false;
        if (lastKnownAPYs[protocol] > 0) {
            uint256 delta = apy > lastKnownAPYs[protocol]
                ? apy - lastKnownAPYs[protocol]
                : lastKnownAPYs[protocol] - apy;
            return delta * 100 / lastKnownAPYs[protocol] <= 50; // Max 50% deviation
        }
        return true;
    }

    /**
     * @notice Checks protocol health, including Aave, Compound, and Sonic-specific checks.
     */
    function checkProtocolHealth(address protocol) internal view returns (bool) {
        if (protocol == address(flyingTulip)) {
            return flyingTulip.isProtocolHealthy(protocol);
        } else if (protocol == address(aavePool)) {
            (, , , , , uint256 healthFactor) = aavePool.getUserAccountData(address(this));
            return healthFactor >= MIN_HEALTH_FACTOR;
        } else if (isCompoundProtocol[protocol]) {
            (, uint256 collateralFactor, ) = ICompound(protocol).getAccountLiquidity(address(this));
            return collateralFactor >= MIN_COLLATERAL_FACTOR;
        }
        return true;
    }

    /**
     * @notice Checks liquidation risk for leveraged positions.
     */
    function _checkLiquidationRisk(address protocol, uint256 collateral, uint256 borrowAmount) internal view returns (bool) {
        if (protocol == address(flyingTulip)) {
            return flyingTulip.isProtocolHealthy(protocol) &&
                   flyingTulip.getLTV(protocol, collateral) <= MAX_LTV &&
                   getProtocolLiquidity(protocol) >= borrowAmount;
        } else if (protocol == address(aavePool)) {
            (, , uint256 availableBorrowsBase, , , uint256 healthFactor) = aavePool.getUserAccountData(address(this));
            return healthFactor >= MIN_HEALTH_FACTOR &&
                   borrowAmount <= availableBorrowsBase &&
                   getProtocolLiquidity(protocol) >= borrowAmount;
        } else if (isCompoundProtocol[protocol]) {
            (, uint256 collateralFactor, uint256 liquidity) = ICompound(protocol).getAccountLiquidity(address(this));
            return collateralFactor >= MIN_COLLATERAL_FACTOR &&
                   borrowAmount <= liquidity &&
                   getProtocolLiquidity(protocol) >= borrowAmount;
        }
        return true;
    }

    /**
     * @notice Sorts protocols by allocation size (descending) using insertion sort.
     */
    function _sortProtocolsByAllocation() internal view returns (address[] memory) {
        address[] memory sorted = new address[](activeProtocols.length);
        uint256[] memory amounts = new uint256[](activeProtocols.length);

        for (uint256 i = 0; i < activeProtocols.length; i++) {
            sorted[i] = activeProtocols[i];
            amounts[i] = allocations[activeProtocols[i]].amount;
        }

        for (uint256 i = 1; i < sorted.length; i++) {
            address keyProtocol = sorted[i];
            uint256 keyAmount = amounts[i];
            uint256 j = i;
            while (j > 0 && amounts[j - 1] < keyAmount) {
                sorted[j] = sorted[j - 1];
                amounts[j] = amounts[j - 1];
                j--;
            }
            sorted[j] = keyProtocol;
            amounts[j] = keyAmount;
        }

        return sorted;
    }

    /**
     * @notice Sorts protocols by available liquidity (descending) using insertion sort.
     */
    function _sortProtocolsByLiquidity() internal view returns (address[] memory) {
        address[] memory sorted = new address[](activeProtocols.length);
        uint256[] memory liquidities = new uint256[](activeProtocols.length);

        for (uint256 i = 0; i < activeProtocols.length; i++) {
            sorted[i] = activeProtocols[i];
            liquidities[i] = getProtocolLiquidity(activeProtocols[i]);
        }

        for (uint256 i = 1; i < sorted.length; i++) {
            address keyProtocol = sorted[i];
            uint256 keyLiquidity = liquidities[i];
            uint256 j = i;
            while (j > 0 && liquidities[j - 1] < keyLiquidity) {
                sorted[j] = sorted[j - 1];
                liquidities[j] = liquidities[j - 1];
                j--;
            }
            sorted[j] = keyProtocol;
            liquidities[j] = keyLiquidity;
        }

        return sorted;
    }

    /**
     * @notice Fetches APY data with Sonic RedStone oracle support.
     */
    function _getAPYsFromChainlink() internal returns (address[] memory protocols, uint256[] memory apys) {
        uint256 totalFeeds = 0;
        uint256 failedFeeds = 0;
        for (uint256 i = 0; i < activeProtocols.length; i++) {
            if (address(protocolAPYFeeds[activeProtocols[i]]) != address(0)) {
                totalFeeds++;
            }
        }

        address[] memory tempProtocols = new address[](activeProtocols.length);
        uint256[] memory tempAPYs = new uint256[](activeProtocols.length);
        uint256 index = 0;

        for (uint256 i = 0; i < activeProtocols.length; i++) {
            address protocol = activeProtocols[i];
            AggregatorV3Interface feed = protocolAPYFeeds[protocol];
            if (address(feed) != address(0)) {
                try feed.latestRoundData() returns (uint80, int256 answer, , uint256 updatedAt, uint80) {
                    if (answer > 0 && block.timestamp <= updatedAt + MAX_STALENESS && uint256(answer) <= MAX_APY) {
                        tempProtocols[index] = protocol;
                        tempAPYs[index] = uint256(answer);
                        index++;
                        continue;
                    } else {
                        failedFeeds++;
                    }
                } catch {
                    failedFeeds++;
                }
            }
            if (protocol == address(aavePool)) {
                uint256 aaveAPY = _getAaveAPY(address(stablecoin));
                if (aaveAPY > 0 && aaveAPY <= MAX_APY) {
                    tempProtocols[index] = protocol;
                    tempAPYs[index] = aaveAPY;
                    index++;
                    continue;
                }
            } else if (isCompoundProtocol[protocol]) {
                uint256 compoundAPY = _getCompoundAPY(protocol);
                if (compoundAPY > 0 && compoundAPY <= MAX_APY) {
                    tempProtocols[index] = protocol;
                    tempAPYs[index] = compoundAPY;
                    index++;
                    continue;
                }
            } else {
                uint256 sonicAPY = sonicProtocol.getSonicAPY(protocol);
                if (sonicAPY > 0 && sonicAPY <= MAX_APY) {
                    tempProtocols[index] = protocol;
                    tempAPYs[index] = sonicAPY;
                    index++;
                    continue;
                }
            }
            if (lastKnownAPYs[protocol] > 0) {
                tempProtocols[index] = protocol;
                tempAPYs[index] = lastKnownAPYs[protocol];
                index++;
            }
        }

        if (totalFeeds > 0 && (failedFeeds * 100) / totalFeeds > MAX_FEED_FAILURES) {
            _pause();
            emit CircuitBreakerTriggered(failedFeeds, totalFeeds);
            revert("Circuit breaker: Too many feed failures");
        }

        protocols = new address[](index);
        apys = new uint256[](index);
        for (uint256 i = 0; i < index; i++) {
            protocols[i] = tempProtocols[i];
            apys[i] = tempAPYs[i];
        }
    }

    /**
     * @notice Gets Aave's variable APY for the stablecoin.
     */
    function _getAaveAPY(address asset) internal view returns (uint256) {
        try aavePool.getReserveData(asset) returns (
            uint256,
            uint256,
            uint256 currentLiquidityRate,
            uint256,
            uint256,
            uint40,
            address,
            address,
            address,
            address,
            uint128,
            uint128,
            uint128
        ) {
            return (currentLiquidityRate * BASIS_POINTS) / 1e27;
        } catch {
            return 0;
        }
    }

    /**
     * @notice Gets Compound's supply APY for the cToken.
     */
    function _getCompoundAPY(address cToken) internal view returns (uint256) {
        try ICompound(cToken).supplyRatePerBlock() returns (uint256 ratePerBlock) {
            return (ratePerBlock * BLOCKS_PER_YEAR * BASIS_POINTS) / 1e18;
        } catch {
            return 0;
        }
    }

    /**
     * @notice Calculates total APY for allocation.
     */
    function _totalAPY(uint256[] memory apys) internal pure returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < apys.length; i++) {
            total += apys[i];
        }
        return total == 0 ? 1 : total;
    }

    /**
     * @notice Computes e^x using OpenZeppelin's Math library for precision.
     */
    function _exp(uint256 x) internal pure returns (uint256) {
        require(x <= MAX_EXP_INPUT, "Exponent too large");
        if (x < 1e16) return FIXED_POINT_SCALE + x; // Linear approximation for x < 0.01
        return Math.exp(x, FIXED_POINT_SCALE);
    }

    /**
     * @notice Calculates user profit with protocol-specific compounding.
     */
    function _calculateProfit(address user, uint256 amount) internal view returns (uint256) {
        uint256 userShare = totalAllocated == 0 ? 0 : (userBalances[user] * 1e18) / totalAllocated;
        uint256 totalProfit = 0;

        for (uint256 i = 0; i < activeProtocols.length; i++) {
            address protocol = activeProtocols[i];
            Allocation memory alloc = allocations[protocol];
            uint256 yield = protocol == address(flyingTulip)
                ? flyingTulip.getDynamicAPY(protocol)
                : protocol == address(aavePool)
                    ? _getAaveAPY(address(stablecoin))
                    : isCompoundProtocol[protocol]
                        ? _getCompoundAPY(protocol)
                        : sonicProtocol.getSonicAPY(protocol);
            uint256 timeElapsed = block.timestamp - alloc.lastUpdated;
            uint256 profit;
            if (protocol == address(aavePool) || isCompoundProtocol[protocol]) {
                profit = (alloc.amount * yield * timeElapsed) / (BASIS_POINTS * SECONDS_PER_YEAR);
            } else {
                uint256 rt = (yield * timeElapsed * FIXED_POINT_SCALE) / (BASIS_POINTS * SECONDS_PER_YEAR);
                uint256 expRt = _exp(rt);
                uint256 compounded = (alloc.amount * expRt) / FIXED_POINT_SCALE;
                profit = compounded > alloc.amount ? compounded - alloc.amount : 0;
            }
            totalProfit += profit;
        }

        uint256 userProfit = (totalProfit * userShare * amount) / (1e18 * userBalances[user]);
        return userProfit >= MIN_PROFIT ? userProfit : 0;
    }

    /**
     * @notice Estimates user profit.
     */
    function estimateProfit(address user) external view returns (uint256) {
        return _calculateProfit(user, userBalances[user]);
    }

    /**
     * @notice Gets total value locked (TVL).
     */
    function getTVL() external view returns (uint256) {
        return totalAllocated;
    }

    /**
     * @notice Gets active allocations.
     */
    function getAllocations() external view returns (Allocation[] memory) {
        Allocation[] memory result = new Allocation[](activeProtocols.length);
        for (uint256 i = 0; i < activeProtocols.length; i++) {
            result[i] = allocations[activeProtocols[i]];
        }
        return result;
    }
}
