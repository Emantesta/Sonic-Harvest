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
    function depositToDeFi(address protocol, uint256 amount) external;
    function withdrawFromDeFi(address protocol, uint256 amount) external returns (uint256);
    function isDeFiProtocol(address protocol) external view returns (bool);
    function getAvailableLiquidity(address protocol) external view returns (uint256);
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
    function earnPoints(address user, uint256 amount, bool isAllocation) external;
    function claimPoints(address user) external;
}

interface IGovernanceManager {
    function proposeAction(bytes32 actionHash) external;
    function executeAction(bytes32 actionHash) external;
    function updateGovernance(address newGovernance) external;
}

interface IUpkeepManager {
    function manualUpkeep(bool isRWA) external;
}

/**
 * @title YieldOptimizer
 * @notice A DeFi yield farming aggregator optimized for Sonic Blockchain, supporting Aave V3, Compound, FlyingTulip, and delegating RWA allocations to AIYieldOptimizer.
 * @dev Uses UUPS proxy, integrates with Sonic’s Fee Monetization, native USDC, RedStone oracles, Sonic Points, and modular contracts.
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
    address public feeRecipient;
    uint256 public managementFee;
    uint256 public performanceFee;
    uint256 public totalAllocated;
    uint256 public minRWALiquidityThreshold;
    bool public allowLeverage;
    bool public isPaused;
    mapping(address => uint256) public userBalances;
    mapping(address => Allocation) public allocations;
    mapping(address => bool) public blacklistedUsers;
    mapping(address => uint256) public lastKnownAPYs;

    // Constants
    uint256 public constant BASIS_POINTS = 10000;
    uint256 private constant SECONDS_PER_YEAR = 365 days;
    uint256 private constant MAX_APY = 10000; // 100%
    uint256 private constant FIXED_POINT_SCALE = 1e18;
    uint256 private constant MAX_EXP_INPUT = 10e18;
    uint256 private constant MIN_PROFIT = 1e6;
    uint256 private constant AAVE_REFERRAL_CODE = 0;
    uint256 private constant MIN_ALLOCATION = 1e16;
    uint256 public immutable MIN_DEPOSIT;

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

    // Events
    event Deposit(address indexed user, uint256 amount, uint256 fee);
    event Withdraw(address indexed user, uint256 amount, uint256 fee);
    event Rebalance(address indexed protocol, uint256 amount, uint256 apy, bool isLeveraged);
    event FeesCollected(uint256 managementFee, uint256 performanceFee);
    event FeeRecipientUpdated(address indexed newRecipient);
    event FeesUpdated(uint256 managementFee, uint256 performanceFee);
    event BlacklistUpdated(address indexed user, bool status);
    event OFACCheckFailed(address indexed user);
    event UserEmergencyWithdraw(address indexed user, uint256 amount);
    event AIAllocationOptimized(address indexed protocol, uint256 amount, uint256 apy, bool isLeveraged);
    event AIAllocationDetails(address[] protocols, uint256[] amounts, bool[] isLeveraged, string logicDescription);
    event RWADelegatedToAI(address indexed aiYieldOptimizer, uint256 amount);
    event PauseToggled(bool status);

    // Modifiers
    modifier onlyGovernance() {
        require(msg.sender == governanceManager.governance(), "Not governance");
        _;
    }

    modifier whenNotPaused() {
        require(!isPaused, "Paused");
        _;
    }

    /**
     * @notice Initializes the contract with Sonic-specific parameters and modular integrations.
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
        address _feeRecipient
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
        require(_feeRecipient != address(0), "Invalid fee recipient");

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
        feeRecipient = _feeRecipient;
        managementFee = 50; // 0.5%
        performanceFee = 1000; // 10%
        MIN_DEPOSIT = 10 ** IERC20Metadata(_stablecoin).decimals();
        allowLeverage = true;
        minRWALiquidityThreshold = 1e18;
    }

    /**
     * @notice Authorizes contract upgrades.
     */
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /**
     * @notice Deposits funds and allocates them to protocols with Sonic points tracking.
     */
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        require(amount >= MIN_DEPOSIT, "Deposit below minimum");
        require(!blacklistedUsers[msg.sender], "User blacklisted");
        require(flyingTulip.isOFACCompliant(msg.sender), "OFAC check failed");

        uint256 fee = (amount * managementFee) / BASIS_POINTS;
        uint256 netAmount = amount - fee;

        stablecoin.safeTransferFrom(msg.sender, address(this), amount);
        stablecoin.safeTransfer(feeRecipient, fee);

        userBalances[msg.sender] += netAmount;
        totalAllocated += netAmount;
        stakingManager.earnPoints(msg.sender, netAmount, true);

        _allocateFunds(netAmount);

        emit Deposit(msg.sender, netAmount, fee);
    }

    /**
     * @notice Withdraws funds and distributes profits.
     */
    function withdraw(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "Amount must be > 0");
        require(userBalances[msg.sender] >= amount, "Insufficient balance");

        uint256 profit = _calculateProfit(msg.sender, amount);
        uint256 performanceFeeAmount = (profit * performanceFee) / BASIS_POINTS;
        uint256 netProfit = profit - performanceFeeAmount;

        userBalances[msg.sender] -= amount;
        totalAllocated -= amount;
        stakingManager.earnPoints(msg.sender, amount, false);

        uint256 withdrawnAmount = _deallocateFunds(amount);
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
    function userEmergencyWithdraw(uint256 amount) external nonReentrant {
        require(isPaused, "Not paused");
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
    function rebalance() external onlyGovernance nonReentrant whenNotPaused {
        address[] memory protocols = registry.getActiveProtocols(false);
        uint256[] memory apys = new uint256[](protocols.length);

        // Withdraw from non-RWA protocols
        for (uint256 i = 0; i < protocols.length; i++) {
            Allocation storage alloc = allocations[protocols[i]];
            if (alloc.amount > 0) {
                uint256 withdrawn = _withdrawFromProtocol(protocols[i], alloc.amount);
                alloc.amount -= withdrawn;
            }
        }
        _cleanAllocations();

        // Fetch APYs and risk scores
        for (uint256 i = 0; i < protocols.length; i++) {
            apys[i] = riskManager.getRiskAdjustedAPY(protocols[i], sonicProtocol.getSonicAPY(protocols[i]));
        }

        uint256 totalBalance = stablecoin.balanceOf(address(this)) + aiYieldOptimizer.getTotalRWABalance();
        uint256 totalWeightedAPY = 0;
        uint256 nonRWAAmount = 0;
        uint256[] memory weights = new uint256[](protocols.length);

        // Calculate weights for non-RWA protocols
        for (uint256 i = 0; i < protocols.length; i++) {
            if (!registry.isValidProtocol(protocols[i]) || !_validateAPY(apys[i], protocols[i])) {
                emit AIAllocationOptimized(protocols[i], 0, apys[i], false);
                continue;
            }
            weights[i] = apys[i];
            totalWeightedAPY += apys[i];
        }

        // Allocate to non-RWA protocols
        for (uint256 i = 0; i < protocols.length; i++) {
            if (weights[i] == 0) continue;
            uint256 allocAmount = (totalBalance * weights[i]) / (totalWeightedAPY == 0 ? 1 : totalWeightedAPY);
            if (allocAmount < MIN_ALLOCATION) {
                emit AIAllocationOptimized(protocols[i], 0, apys[i], false);
                continue;
            }
            bool isLeveraged = allowLeverage && _assessLeverageViability(protocols[i], allocAmount);
            allocations[protocols[i]] = Allocation(protocols[i], allocAmount, apys[i], block.timestamp, isLeveraged);
            lastKnownAPYs[protocols[i]] = apys[i];
            _depositToProtocol(protocols[i], allocAmount, isLeveraged);
            nonRWAAmount += allocAmount;
            if (isLeveraged) {
                uint256 ltv = _getLTV(protocols[i], allocAmount);
                looperCore.applyLeverage(protocols[i], allocAmount, ltv, false);
            }
            emit AIAllocationOptimized(protocols[i], allocAmount, apys[i], isLeveraged);
            emit Rebalance(protocols[i], allocAmount, apys[i], isLeveraged);
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
               registry.isValidProtocol(protocol) &&
               sonicProtocol.isSonicCompliant(protocol);
    }

    /**
     * @notice Assesses leverage viability using RiskManager.
     */
    function _assessLeverageViability(address protocol, uint256 amount) internal view returns (bool) {
        uint256 ltv = _getLTV(protocol, amount);
        return riskManager.assessLeverageViability(protocol, amount, ltv, false);
    }

    /**
     * @notice Gets LTV for a protocol.
     */
    function _getLTV(address protocol, uint256 amount) internal view returns (uint256) {
        if (protocol == address(flyingTulip)) {
            return flyingTulip.getDynamicAPY(protocol); // Simplified, assumes APY as LTV proxy
        } else if (protocol == address(aavePool)) {
            return aavePool.getReserveData(address(stablecoin)).liquidityIndex; // Simplified
        } else if (registry.protocols(protocol).isCompound) {
            return 5000; // Default 50% LTV for Compound
        }
        return 0;
    }

    /**
     * @notice Toggles emergency pause.
     */
    function pause() external onlyGovernance {
        isPaused = true;
        emit PauseToggled(true);
    }

    /**
     * @notice Unpauses the contract.
     */
    function unpause() external onlyGovernance {
        isPaused = false;
        emit PauseToggled(false);
    }

    /**
     * @notice Updates user blacklist status.
     */
    function updateBlacklist(address user, bool status) external onlyGovernance {
        blacklistedUsers[user] = status;
        emit BlacklistUpdated(user, status);
    }

    /**
     * @notice Manual upkeep for non-RWA protocols.
     */
    function manualUpkeep() external onlyGovernance {
        upkeepManager.manualUpkeep(false);
    }

    /**
     * @notice Allocates funds to protocols, delegating RWA allocations to AIYieldOptimizer.
     */
    function _allocateFunds(uint256 amount) internal {
        address[] memory protocols = registry.getActiveProtocols(false);
        uint256[] memory apys = new uint256[](protocols.length);
        for (uint256 i = 0; i < protocols.length; i++) {
            apys[i] = riskManager.getRiskAdjustedAPY(protocols[i], sonicProtocol.getSonicAPY(protocols[i]));
        }

        uint256 totalWeightedAPY = 0;
        uint256 nonRWAAmount = 0;
        uint256[] memory weights = new uint256[](protocols.length);

        for (uint256 i = 0; i < protocols.length; i++) {
            if (!registry.isValidProtocol(protocols[i]) || !_validateAPY(apys[i], protocols[i])) continue;
            weights[i] = apys[i];
            totalWeightedAPY += apys[i];
        }

        for (uint256 i = 0; i < protocols.length; i++) {
            if (weights[i] == 0) continue;
            uint256 allocAmount = (amount * weights[i]) / (totalWeightedAPY == 0 ? 1 : totalWeightedAPY);
            if (allocAmount < MIN_ALLOCATION) continue;
            bool isLeveraged = allowLeverage && _assessLeverageViability(protocols[i], allocAmount);
            allocations[protocols[i]] = Allocation(protocols[i], allocAmount, apys[i], block.timestamp, isLeveraged);
            lastKnownAPYs[protocols[i]] = apys[i];
            _depositToProtocol(protocols[i], allocAmount, isLeveraged);
            nonRWAAmount += allocAmount;
            if (isLeveraged) {
                uint256 ltv = _getLTV(protocols[i], allocAmount);
                looperCore.applyLeverage(protocols[i], allocAmount, ltv, false);
            }
            stakingManager.earnPoints(msg.sender, allocAmount, true);
            emit AIAllocationOptimized(protocols[i], allocAmount, apys[i], isLeveraged);
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
            emit AIAllocationDetails(rwaProtocols, amounts, isLeveraged, logicDescription);
            stakingManager.earnPoints(msg.sender, rwaAmount, true);
            emit RWADelegatedToAI(address(aiYieldOptimizer), rwaAmount);
        }
    }

    /**
     * @notice Deallocates funds from protocols with Sonic points tracking.
     */
    function _deallocateFunds(uint256 amount) internal returns (uint256) {
        uint256 totalWithdrawn = 0;
        address[] memory protocols = registry.getActiveProtocols(false);
        address[] memory rwaProtocols = aiYieldOptimizer.getSupportedProtocols();

        // Withdraw from RWA protocols
        uint256 rwaBalance = aiYieldOptimizer.getTotalRWABalance();
        if (rwaBalance > 0) {
            uint256 rwaWithdrawAmount = (amount * rwaBalance) / (totalAllocated == 0 ? 1 : totalAllocated);
            for (uint256 i = 0; i < rwaProtocols.length && totalWithdrawn < amount; i++) {
                address protocol = rwaProtocols[i];
                uint256 availableLiquidity = rwaYield.getAvailableLiquidity(protocol);
                uint256 withdrawAmount = rwaWithdrawAmount > availableLiquidity ? availableLiquidity : rwaWithdrawAmount;
                try aiYieldOptimizer.withdrawForYieldOptimizer(protocol, withdrawAmount) returns (uint256 withdrawn) {
                    totalWithdrawn += withdrawn;
                    stakingManager.earnPoints(msg.sender, withdrawn, false);
                } catch {
                    emit AIAllocationOptimized(protocol, 0, 0, false);
                }
            }
        }

        // Withdraw from non-RWA protocols
        for (uint256 i = 0; i < protocols.length && totalWithdrawn < amount; i++) {
            address protocol = protocols[i];
            Allocation storage alloc = allocations[protocol];
            uint256 withdrawAmount = (amount * alloc.amount) / (totalAllocated == 0 ? 1 : totalAllocated);
            if (withdrawAmount > 0) {
                uint256 availableLiquidity = getProtocolLiquidity(protocol);
                withdrawAmount = withdrawAmount > availableLiquidity ? availableLiquidity : withdrawAmount;
                uint256 withdrawn = _withdrawFromProtocol(protocol, withdrawAmount);
                alloc.amount -= withdrawn;
                totalWithdrawn += withdrawn;
                stakingManager.earnPoints(msg.sender, withdrawn, false);
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
        if (protocol == address(flyingTulip)) {
            flyingTulip.depositToPool(protocol, amount, isLeveraged);
        } else if (protocol == address(aavePool)) {
            try aavePool.supply(address(stablecoin), amount, address(this), AAVE_REFERRAL_CODE) {
                emit AIAllocationOptimized(protocol, amount, lastKnownAPYs[protocol], isLeveraged);
            } catch {
                revert("Aave supply failed");
            }
        } else if (registry.protocols(protocol).isCompound) {
            try compound.mint(amount) returns (uint256 err) {
                require(err == 0, "Compound mint failed");
                emit AIAllocationOptimized(protocol, amount, lastKnownAPYs[protocol], isLeveraged);
            } catch {
                revert("Compound mint failed");
            }
        } else {
            defiYield.depositToDeFi(protocol, amount);
        }
    }

    /**
     * @notice Withdraws funds from a protocol.
     */
    function _withdrawFromProtocol(address protocol, uint256 amount) internal returns (uint256) {
        uint256 balanceBefore = stablecoin.balanceOf(address(this));
        uint256 withdrawn = 0;
        try
            protocol == address(flyingTulip)
                ? flyingTulip.withdrawFromPool(protocol, amount)
                : protocol == address(aavePool)
                    ? aavePool.withdraw(address(stablecoin), amount, address(this))
                    : registry.protocols(protocol).isCompound
                        ? compound.redeemUnderlying(amount) == 0 ? amount : 0
                        : defiYield.withdrawFromDeFi(protocol, amount)
        returns (uint256 amountWithdrawn) {
            withdrawn = amountWithdrawn;
        } catch {
            emit AIAllocationOptimized(protocol, 0, 0, false);
        }
        require(stablecoin.balanceOf(address(this)) >= balanceBefore + withdrawn, "Withdrawal balance mismatch");
        return withdrawn;
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
    }

    /**
     * @notice Validates a protocol for allocation.
     */
    function _isValidProtocol(address protocol) internal view returns (bool) {
        return registry.isValidProtocol(protocol) && sonicProtocol.isSonicCompliant(protocol);
    }

    /**
     * @notice Validates APY data for a protocol.
     */
    function _validateAPY(uint256 apy, address protocol) internal view returns (bool) {
        uint256 liquidity = getProtocolLiquidity(protocol);
        return apy > 0 && apy <= MAX_APY && liquidity > 0;
    }

    /**
     * @notice Gets the actual liquidity available in a protocol.
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
                        : registry.protocols(protocol).isCompound
                            ? IERC20(compound.underlying()).balanceOf(protocol)
                            : defiYield.getAvailableLiquidity(protocol)
        returns (uint256 available) {
            return available;
        } catch {
            return 0;
        }
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
        address[] memory protocols = registry.getActiveProtocols(false);

        for (uint256 i = 0; i < protocols.length; i++) {
            Allocation memory alloc = allocations[protocols[i]];
            if (alloc.amount == 0 || alloc.apy == 0) continue;
            uint256 timeElapsed = block.timestamp - alloc.lastUpdated;
            if (timeElapsed == 0) continue;

            uint256 apyScaled = (alloc.apy * FIXED_POINT_SCALE) / BASIS_POINTS;
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
    }

    /**
     * @notice Gets user balance with estimated profits.
     */
    function getUserBalance(address user) external view returns (uint256 balance, uint256 estimatedProfit) {
        balance = userBalances[user];
        estimatedProfit = _calculateProfit(user, balance);
    }

    /**
     * @notice Gets detailed allocation breakdown for transparency.
     */
    function getAllocationBreakdown() external view returns (AllocationBreakdown[] memory) {
        address[] memory protocols = registry.getActiveProtocols(false);
        AllocationBreakdown[] memory breakdown = new AllocationBreakdown[](protocols.length + 1);
        uint256 breakdownIndex = 0;

        for (uint256 i = 0; i < protocols.length; i++) {
            Allocation memory alloc = allocations[protocols[i]];
            if (alloc.amount == 0) continue;
            breakdown[breakdownIndex] = AllocationBreakdown({
                protocol: protocols[i],
                amount: alloc.amount,
                apy: alloc.apy,
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
    }

    /**
     * @notice Fallback function to prevent accidental ETH deposits.
     */
    receive() external payable {
        revert("ETH deposits not allowed");
    }
}
