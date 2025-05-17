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

/**
 * @title AIYieldOptimizer
 * @notice A delegated contract for AI-driven RWA yield optimization within YieldOptimizer.sol,
 *         integrated with Sonic Blockchain, modular contracts, and advanced AI-driven allocation strategies.
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
    address public aiOracle; // Address for AI allocation recommendations
    address public feeRecipient; // Receives management and performance fees
    uint256 public managementFee; // Management fee in basis points
    uint256 public performanceFee; // Performance fee in basis points
    uint256 public totalRWABalance; // Total stablecoins allocated to RWAs
    mapping(address => uint256) public rwaBalances; // Balances in each RWA protocol
    mapping(address => Allocation) public allocations; // Protocol allocations
    bool public allowLeverage; // Toggle for leverage support
    uint256 public minRWALiquidityThreshold; // Minimum liquidity threshold for RWA protocols
    bool public isPaused; // Emergency pause state

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

    // Events
    event DepositRWA(address indexed protocol, uint256 amount, uint256 fee, bool isLeveraged);
    event WithdrawRWA(address indexed protocol, uint256 amount, uint256 profit, uint256 fee);
    event AIAllocationUpdated(address indexed protocol, uint256 amount, bool isLeveraged);
    event AIOracleUpdated(address indexed newOracle);
    event FeeRecipientUpdated(address indexed newRecipient);
    event FeesUpdated(uint256 managementFee, uint256 performanceFee);
    event LeverageToggled(bool status);
    event PauseToggled(bool status);
    event AIRecommendedAllocation(address indexed protocol, uint256 amount, bool isLeveraged);
    event AllocationLogicUpdated(string logicDescription);
    event ManualUpkeepTriggered(uint256 timestamp);

    // Modifiers
    modifier onlyGovernance() {
        require(msg.sender == governanceManager.governance(), "Not governance");
        _;
    }

    modifier onlyAIOracle() {
        require(msg.sender == aiOracle, "Not AI Oracle");
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
    }

    /**
     * @notice Authorizes contract upgrades.
     */
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /**
     * @notice AI Oracle submits allocation recommendations from YieldOptimizer.sol.
     */
    function submitAIAllocation(
        address[] calldata protocols,
        uint256[] calldata amounts,
        bool[] calldata isLeveraged
    ) external nonReentrant whenNotPaused {
        require(msg.sender == address(this) || msg.sender == aiOracle, "Not authorized"); // Allow self-call from YieldOptimizer
        require(protocols.length == amounts.length && protocols.length == isLeveraged.length, "Mismatched arrays");
        require(protocols.length <= MAX_PROTOCOLS, "Too many protocols");

        uint256 totalAmount;
        for (uint256 i = 0; i < protocols.length; i++) {
            require(_isValidProtocol(protocols[i]), "Unsupported protocol");
            require(flyingTulip.isProtocolHealthy(protocols[i]), "Protocol not healthy");
            totalAmount += amounts[i];
        }
        require(totalAmount <= stablecoin.balanceOf(address(this)), "Insufficient balance");

        // Execute allocations
        for (uint256 i = 0; i < protocols.length; i++) {
            if (amounts[i] >= MIN_ALLOCATION) {
                uint256 fee = (amounts[i] * managementFee) / BASIS_POINTS;
                uint256 netAmount = amounts[i] - fee;
                _depositToRWA(protocols[i], netAmount, isLeveraged[i] && allowLeverage);
                allocations[protocols[i]] = Allocation(
                    protocols[i],
                    netAmount,
                    rwaYield.getRWAYield(protocols[i]),
                    block.timestamp,
                    isLeveraged[i] && allowLeverage
                );
                stablecoin.safeTransfer(feeRecipient, fee);
                stakingManager.earnPoints(msg.sender, netAmount, true);
                emit AIAllocationUpdated(protocols[i], netAmount, isLeveraged[i] && allowLeverage);
                emit DepositRWA(protocols[i], netAmount, fee, isLeveraged[i] && allowLeverage);
            }
        }
    }

    /**
     * @notice Rebalances portfolio based on AI recommendations.
     */
    function rebalancePortfolio(
        address[] calldata protocols,
        uint256[] calldata amounts,
        bool[] calldata isLeveraged
    ) external onlyAIOracle nonReentrant whenNotPaused {
        require(protocols.length == amounts.length && protocols.length == isLeveraged.length, "Mismatched arrays");

        // Withdraw from all protocols
        address[] memory activeProtocols = registry.getActiveProtocols(true);
        for (uint256 i = 0; i < activeProtocols.length; i++) {
            address protocol = activeProtocols[i];
            if (rwaBalances[protocol] > 0) {
                _withdrawFromRWA(protocol, rwaBalances[protocol], false);
            }
        }

        // Reallocate based on AI recommendations
        uint256 totalAmount;
        for (uint256 i = 0; i < protocols.length; i++) {
            totalAmount += amounts[i];
        }
        require(totalAmount <= stablecoin.balanceOf(address(this)), "Insufficient balance");

        for (uint256 i = 0; i < protocols.length; i++) {
            if (amounts[i] >= MIN_ALLOCATION) {
                uint256 fee = (amounts[i] * managementFee) / BASIS_POINTS;
                uint256 netAmount = amounts[i] - fee;
                _depositToRWA(protocols[i], netAmount, isLeveraged[i] && allowLeverage);
                allocations[protocols[i]] = Allocation(
                    protocols[i],
                    netAmount,
                    rwaYield.getRWAYield(protocols[i]),
                    block.timestamp,
                    isLeveraged[i] && allowLeverage
                );
                stablecoin.safeTransfer(feeRecipient, fee);
                stakingManager.earnPoints(msg.sender, netAmount, true);
                emit AIAllocationUpdated(protocols[i], netAmount, isLeveraged[i] && allowLeverage);
                emit DepositRWA(protocols[i], netAmount, fee, isLeveraged[i] && allowLeverage);
            }
        }
    }

    /**
     * @notice Withdraws from RWA protocol for YieldOptimizer.sol.
     */
    function withdrawForYieldOptimizer(address protocol, uint256 amount)
        external
        nonReentrant
        returns (uint256)
    {
        require(msg.sender == address(this), "Only YieldOptimizer"); // Internal call
        return _withdrawFromRWA(protocol, amount, true);
    }

    /**
     * @notice Internal function to deposit to RWA protocol with optional leverage.
     */
    function _depositToRWA(address protocol, uint256 amount, bool isLeveraged) internal {
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
    }

    /**
     * @notice Internal function to withdraw from RWA protocol with leverage repayment.
     */
    function _withdrawFromRWA(address protocol, uint256 amount, bool isForYieldOptimizer) internal returns (uint256) {
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

        emit WithdrawRWA(protocol, amount, profit, performanceFeeAmount);
        return netWithdrawn;
    }

    /**
     * @notice Toggles leverage support.
     */
    function toggleLeverage(bool status) external onlyGovernance {
        allowLeverage = status;
        emit LeverageToggled(status);
    }

    /**
     * @notice Updates AI Oracle address.
     */
    function updateAIOracle(address newOracle) external onlyGovernance {
        require(newOracle != address(0), "Invalid AI Oracle address");
        aiOracle = newOracle;
        emit AIOracleUpdated(newOracle);
    }

    /**
     * @notice Updates fee recipient address.
     */
    function updateFeeRecipient(address newRecipient) external onlyGovernance {
        require(newRecipient != address(0), "Invalid fee recipient");
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(newRecipient);
    }

    /**
     * @notice Updates management and performance fees.
     */
    function updateFees(uint256 newManagementFee, uint256 newPerformanceFee) external onlyGovernance {
        require(newManagementFee <= 200, "Management fee too high"); // Max 2%
        require(newPerformanceFee <= 2000, "Performance fee too high"); // Max 20%
        managementFee = newManagementFee;
        performanceFee = newPerformanceFee;
        emit FeesUpdated(newManagementFee, newPerformanceFee);
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
     * @notice Manual upkeep for RWA protocols.
     */
    function manualUpkeep() external onlyGovernance {
        upkeepManager.manualUpkeep(true);
        emit ManualUpkeepTriggered(block.timestamp);
    }

    /**
     * @notice AI-driven allocation recommendations with risk adjustment.
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

        // Fetch risk-adjusted APYs
        for (uint256 i = 0; i < allProtocols.length; i++) {
            apys[i] = riskManager.getRiskAdjustedAPY(allProtocols[i], sonicProtocol.getSonicAPY(allProtocols[i]));
        }

        // Calculate risk-adjusted weights
        uint256[] memory weights = new uint256[](allProtocols.length);
        for (uint256 i = 0; i < allProtocols.length; i++) {
            if (!_isValidProtocol(allProtocols[i]) || !_validateAPY(apys[i], allProtocols[i])) {
                continue;
            }
            uint256 riskScore = registry.getProtocolRiskScore(allProtocols[i]);
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
    }

    /**
     * @notice Provides a description of the allocation logic.
     */
    function getAllocationLogic(uint256 totalAmount) external view returns (string memory) {
        (address[] memory protocols, uint256[] memory amounts, bool[] memory isLeveraged) = getRecommendedAllocations(totalAmount);
        string memory logic = "AI-driven allocation based on risk-adjusted APYs and protocol health. Allocations: ";
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
        }
        return logic;
    }

    /**
     * @notice Retrieves APY for all supported protocols.
     */
    function getAllYields() public view returns (address[] memory, uint256[] memory) {
        address[] memory protocols = registry.getActiveProtocols(true);
        uint256[] memory apys = new uint256[](protocols.length);
        for (uint256 i = 0; i < protocols.length; i++) {
            address protocol = protocols[i];
            apys[i] = riskManager.getRiskAdjustedAPY(protocol, sonicProtocol.getSonicAPY(protocol));
        }
        return (protocols, apys);
    }

    /**
     * @notice Validates a protocol for allocation.
     */
    function _isValidProtocol(address protocol) internal view returns (bool) {
        return registry.isValidProtocol(protocol) &&
               rwaYield.isRWA(protocol) &&
               sonicProtocol.isSonicCompliant(protocol) &&
               rwaYield.getAvailableLiquidity(protocol) >= minRWALiquidityThreshold;
    }

    /**
     * @notice Validates APY data for a protocol.
     */
    function _validateAPY(uint256 apy, address protocol) internal view returns (bool) {
        uint256 liquidity = rwaYield.getAvailableLiquidity(protocol);
        return apy > 0 && apy <= MAX_APY && liquidity >= minRWALiquidityThreshold;
    }

    /**
     * @notice Assesses leverage viability for RWA protocols.
     */
    function _assessLeverageViability(address protocol, uint256 amount) internal view returns (bool) {
        uint256 ltv = flyingTulip.getLTV(protocol, amount);
        return ltv <= MAX_LTV &&
               riskManager.assessLeverageViability(protocol, amount, ltv, true) &&
               looperCore.checkLiquidationRisk(protocol, amount, (amount * ltv) / BASIS_POINTS, true);
    }

    /**
     * @notice Returns total RWA balance.
     */
    function getTotalRWABalance() external view returns (uint256) {
        return totalRWABalance;
    }

    /**
     * @notice Returns supported protocols.
     */
    function getSupportedProtocols() external view returns (address[] memory) {
        return registry.getActiveProtocols(true);
    }

    /**
     * @notice Returns active allocations.
     */
    function getAllocations() external view returns (Allocation[] memory) {
        address[] memory protocols = registry.getActiveProtocols(true);
        Allocation[] memory result = new Allocation[](protocols.length);
        for (uint256 i = 0; i < protocols.length; i++) {
            result[i] = allocations[protocols[i]];
        }
        return result;
    }

    /**
     * @notice Helper function to convert address to string.
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
    }
}
