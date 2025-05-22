// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

// Placeholder for Redstone oracle interface
interface IRedstoneOracle {
    function latestRoundData(address feed) external view returns (uint80, int256, uint256, uint256, uint80);
}

// Interface for StakingManager
interface IStakingManager {
    function depositRewards(uint256 amount, address token) external;
    function awardPoints(address user, uint256 totalAmount, bool isDeposit) external;
}

// Standardized DeFiYield interface
interface IDeFiYield {
    function depositToDeFi(address protocol, uint256 amount, bytes32 correlationId) external;
    function withdrawFromDeFi(address protocol, uint256 amount, bytes32 correlationId) external returns (uint256);
    function isDeFiProtocol(address protocol) external view returns (bool);
    function getAvailableLiquidity(address protocol) external view returns (uint256);
    function getTotalDeFiBalance() external view returns (uint256);
}

/**
 * @title DeFiYield
 * @dev Yield aggregator for Sonic DeFi protocols with a 10% performance fee.
 * @notice 10% of the performance fee is sent to StakingManager for rewards.
 */
contract DeFiYield is OwnableUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable, UUPSUpgradeable, IDeFiYield {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using SafeMathUpgradeable for uint256;

    // Immutable stablecoin (USDC)
    IERC20Upgradeable public immutable stablecoin;
    IStakingManager public stakingManager;
    address public feeRecipient; // Governance/treasury for performance fees
    uint256 public performanceFee; // In basis points (e.g., 1000 = 10%)
    uint256 public stakingRewardShare; // Share of perf fee to StakingManager (e.g., 1000 = 10%)
    uint256 private constant BASIS_POINTS = 10000;

    // Protocol and balance management
    mapping(address => bool) public supportedProtocols;
    mapping(address => uint256) public defiBalances;
    uint256 public totalDeFiBalance;

    // User profit tracking
    mapping(address => uint256) public userDeposits;
    mapping(address => uint256) public userProfits;
    uint256 public totalDeposits;

    // Oracle management
    struct OracleConfig {
        address chainlinkFeed;
        address redstoneFeed;
        bool isActive;
    }
    mapping(address => OracleConfig) public protocolOracles;
    address[] public oracleProtocols;

    // Default oracle values
    struct OracleDefaults {
        uint256 defaultAPY;
        uint256 defaultTVL;
        uint256 defaultRiskScore;
    }
    OracleDefaults public oracleDefaults;

    // AI-driven strategy parameters
    struct AIStrategy {
        uint256 riskTolerance;
        uint256 yieldPreference;
        uint256 lastUpdated;
    }
    mapping(address => AIStrategy) public userStrategies;
    uint256 public aiUpdateInterval;

    // Protocol scoring
    struct ProtocolScore {
        uint256 apy;
        uint256 tvl;
        uint256 riskScore;
        uint256 score;
    }
    mapping(address => ProtocolScore) public protocolScores;

    // Dynamic protocol handling
    struct ProtocolConfig {
        bytes4 depositSelector;
        bytes4 withdrawSelector;
        bool isActive;
    }
    mapping(address => ProtocolConfig) public protocolConfigs;

    // Events
    event DepositDeFi(address indexed protocol, uint256 amount, bytes32 indexed correlationId);
    event WithdrawDeFi(address indexed protocol, uint256 amount, uint256 profit, bytes32 indexed correlationId);
    event ProfitAllocated(address indexed user, uint256 profit, bytes32 indexed correlationId);
    event ProfitClaimed(address indexed user, uint256 amount);
    event PerformanceFeeCollected(address indexed feeRecipient, uint256 amount, bytes32 indexed correlationId);
    event StakingRewardSent(address indexed stakingManager, uint256 amount, bytes32 indexed correlationId);
    event ProtocolUpdated(address indexed protocol, bool isSupported);
    event ProtocolConfigUpdated(address indexed protocol, bytes4 depositSelector, bytes4 withdrawSelector);
    event StakingManagerUpdated(address indexed newStakingManager);
    event FeeRecipientUpdated(address indexed newFeeRecipient);
    event PerformanceFeeUpdated(uint256 newFee);
    event StakingRewardShareUpdated(uint256 newShare);
    event OracleUpdated(address indexed protocol, address chainlinkFeed, address redstoneFeed);
    event OracleFailure(address indexed protocol, string reason);
    event UserStrategyUpdated(address indexed user, uint256 riskTolerance, uint256 yieldPreference);
    event AIAllocation(address indexed protocol, uint256 amount, uint256 score, bytes32 indexed correlationId);
    event EmergencyWithdraw(address indexed protocol, uint256 amount, bytes32 indexed correlationId);

    // Constructor
    constructor(address _stablecoin) {
        require(_stablecoin != address(0), "Invalid stablecoin address");
        stablecoin = IERC20Upgradeable(_stablecoin);
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract.
     */
    function initialize(
        address[] memory _protocols,
        OracleConfig[] memory _oracleConfigs,
        address _stakingManager,
        address _feeRecipient,
        ProtocolConfig[] memory _protocolConfigs
    ) external initializer {
        require(_stakingManager != address(0), "Invalid StakingManager address");
        require(_feeRecipient != address(0), "Invalid feeRecipient address");
        require(
            _protocols.length == _oracleConfigs.length && _protocols.length == _protocolConfigs.length,
            "Array length mismatch"
        );
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        stakingManager = IStakingManager(_stakingManager);
        feeRecipient = _feeRecipient;
        performanceFee = 1000; // 10%
        stakingRewardShare = 1000; // 10% of performance fee
        aiUpdateInterval = 1 days;

        oracleDefaults = OracleDefaults({
            defaultAPY: 500, // 5% APY
            defaultTVL: 10_000_000, // 10M USD
            defaultRiskScore: 50 // Moderate risk
        });

        for (uint256 i = 0; i < _protocols.length; i++) {
            require(_protocols[i] != address(0), "Invalid protocol address");
            supportedProtocols[_protocols[i]] = true;
            protocolOracles[_protocols[i]] = OracleConfig({
                chainlinkFeed: _oracleConfigs[i].chainlinkFeed,
                redstoneFeed: _oracleConfigs[i].redstoneFeed,
                isActive: true
            });
            protocolConfigs[_protocols[i]] = ProtocolConfig({
                depositSelector: _protocolConfigs[i].depositSelector,
                withdrawSelector: _protocolConfigs[i].withdrawSelector,
                isActive: true
            });
            oracleProtocols.push(_protocols[i]);
            emit ProtocolConfigUpdated(_protocols[i], _protocolConfigs[i].depositSelector, _protocolConfigs[i].withdrawSelector);
        }
    }

    /**
     * @notice Deposits stablecoins into a DeFi protocol.
     */
    function depositToDeFi(address protocol, uint256 amount, bytes32 correlationId) external override nonReentrant whenNotPaused {
        require(msg.sender == owner(), "Only YieldOptimizer");
        require(supportedProtocols[protocol] && protocolConfigs[protocol].isActive, "Unsupported protocol");
        require(amount > 0, "Amount must be > 0");

        uint256 allowance = stablecoin.allowance(address(this), protocol);
        if (allowance < amount) {
            stablecoin.safeApprove(protocol, 0);
            stablecoin.safeApprove(protocol, type(uint256).max);
        }

        (bool success, ) = protocol.call(
            abi.encodeWithSelector(protocolConfigs[protocol].depositSelector, address(stablecoin), amount)
        );
        require(success, "Deposit failed");

        defiBalances[protocol] = defiBalances[protocol].add(amount);
        totalDeFiBalance = totalDeFiBalance.add(amount);
        userDeposits[msg.sender] = userDeposits[msg.sender].add(amount);
        totalDeposits = totalDeposits.add(amount);
        stakingManager.awardPoints(msg.sender, amount, true);

        emit DepositDeFi(protocol, amount, correlationId);
    }

    /**
     * @notice Withdraws stablecoins and allocates profits with performance fee.
     */
    function withdrawFromDeFi(address protocol, uint256 amount, bytes32 correlationId)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        require(msg.sender == owner(), "Only YieldOptimizer");
        require(supportedProtocols[protocol] && protocolConfigs[protocol].isActive, "Unsupported protocol");
        require(amount > 0 && amount <= defiBalances[protocol], "Invalid amount");

        uint256 initialBalance = stablecoin.balanceOf(address(this));
        uint256 withdrawn;

        (bool success, bytes memory data) = protocol.call(
            abi.encodeWithSelector(protocolConfigs[protocol].withdrawSelector, address(stablecoin), amount)
        );
        if (!success) {
            emit WithdrawDeFi(protocol, amount, 0, correlationId);
            return 0;
        }

        withdrawn = abi.decode(data, (uint256));

        uint256 profit = withdrawn > initialBalance ? withdrawn.sub(initialBalance) : 0;
        defiBalances[protocol] = defiBalances[protocol].sub(amount);
        totalDeFiBalance = totalDeFiBalance.sub(amount);
        userDeposits[msg.sender] = userDeposits[msg.sender].sub(amount);
        totalDeposits = totalDeposits.sub(amount);
        stakingManager.awardPoints(msg.sender, amount, false);

        if (profit > 0) {
            // Calculate performance fee
            uint256 perfFee = profit.mul(performanceFee).div(BASIS_POINTS);
            uint256 userProfit = profit.sub(perfFee);

            // Allocate user profit
            userProfits[msg.sender] = userProfits[msg.sender].add(userProfit);
            emit ProfitAllocated(msg.sender, userProfit, correlationId);

            // Handle performance fee
            if (perfFee > 0) {
                uint256 stakingShare = perfFee.mul(stakingRewardShare).div(BASIS_POINTS);
                uint256 recipientShare = perfFee.sub(stakingShare);

                // Send to feeRecipient
                if (recipientShare > 0) {
                    stablecoin.safeTransfer(feeRecipient, recipientShare);
                    emit PerformanceFeeCollected(feeRecipient, recipientShare, correlationId);
                }

                // Send to StakingManager
                if (stakingShare > 0) {
                    stablecoin.safeApprove(address(stakingManager), 0);
                    stablecoin.safeApprove(address(stakingManager), stakingShare);
                    stakingManager.depositRewards(stakingShare, address(stablecoin));
                    emit StakingRewardSent(address(stakingManager), stakingShare, correlationId);
                }
            }
        }

        if (withdrawn > 0) {
            stablecoin.safeTransfer(msg.sender, withdrawn);
        }

        if (defiBalances[protocol] == 0) {
            stablecoin.safeApprove(protocol, 0);
        }

        emit WithdrawDeFi(protocol, amount, profit, correlationId);
        return withdrawn;
    }

    /**
     * @notice Allows users to claim their allocated profits.
     */
    function claimProfits() external nonReentrant whenNotPaused {
        uint256 profit = userProfits[msg.sender];
        require(profit > 0, "No profits to claim");

        userProfits[msg.sender] = 0;
        stablecoin.safeTransfer(msg.sender, profit);
        emit ProfitClaimed(msg.sender, profit);
    }

    /**
     * @notice Updates performance fee.
     */
    function updatePerformanceFee(uint256 newFee) external onlyOwner {
        require(newFee <= 2000, "Fee too high"); // Max 20%
        performanceFee = newFee;
        emit PerformanceFeeUpdated(newFee);
    }

    /**
     * @notice Updates staking reward share.
     */
    function updateStakingRewardShare(uint256 newShare) external onlyOwner {
        require(newShare <= 5000, "Share too high"); // Max 50%
        stakingRewardShare = newShare;
        emit StakingRewardShareUpdated(newShare);
    }

    /**
     * @notice Updates fee recipient with validation.
     */
    function updateFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "Invalid recipient");
        // Ensure recipient is EOA or contract capable of receiving tokens
        require(newRecipient.code.length == 0 || newRecipient.isContract(), "Invalid recipient contract");
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(newRecipient);
    }

    /**
     * @notice Updates staking manager.
     */
    function updateStakingManager(address newStakingManager) external onlyOwner {
        require(newStakingManager != address(0), "Invalid StakingManager address");
        stakingManager = IStakingManager(newStakingManager);
        emit StakingManagerUpdated(newStakingManager);
    }

    /**
     * @notice Pauses the contract.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpauses the contract.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Checks if a protocol is supported.
     */
    function isDeFiProtocol(address protocol) external view override returns (bool) {
        return supportedProtocols[protocol];
    }

    /**
     * @notice Gets available liquidity for a protocol (placeholder).
     */
    function getAvailableLiquidity(address protocol) external view override returns (uint256) {
        // Placeholder: Implement actual liquidity check based on protocol
        return defiBalances[protocol];
    }

    /**
     * @notice Gets total DeFi balance.
     */
    function getTotalDeFiBalance() external view override returns (uint256) {
        return totalDeFiBalance;
    }

    /**
     * @notice Updates protocol support.
     */
    function updateProtocol(address protocol, bool isSupported) external onlyOwner {
        require(protocol != address(0), "Invalid protocol address");
        supportedProtocols[protocol] = isSupported;
        emit ProtocolUpdated(protocol, isSupported);
    }

    /**
     * @notice Updates protocol configuration.
     */
    function updateProtocolConfig(address protocol, bytes4 depositSelector, bytes4 withdrawSelector) external onlyOwner {
        require(protocol != address(0), "Invalid protocol address");
        protocolConfigs[protocol] = ProtocolConfig({
            depositSelector: depositSelector,
            withdrawSelector: withdrawSelector,
            isActive: true
        });
        emit ProtocolConfigUpdated(protocol, depositSelector, withdrawSelector);
    }

    /**
     * @notice Updates oracle configuration.
     */
    function updateOracle(address protocol, address chainlinkFeed, address redstoneFeed) external onlyOwner {
        require(protocol != address(0), "Invalid protocol address");
        protocolOracles[protocol] = OracleConfig({
            chainlinkFeed: chainlinkFeed,
            redstoneFeed: redstoneFeed,
            isActive: true
        });
        emit OracleUpdated(protocol, chainlinkFeed, redstoneFeed);
    }

    /**
     * @notice Updates user AI strategy.
     */
    function updateUserStrategy(uint256 riskTolerance, uint256 yieldPreference) external {
        require(riskTolerance <= 100 && yieldPreference <= 100, "Invalid parameters");
        userStrategies[msg.sender] = AIStrategy({
            riskTolerance: riskTolerance,
            yieldPreference: yieldPreference,
            lastUpdated: block.timestamp
        });
        emit UserStrategyUpdated(msg.sender, riskTolerance, yieldPreference);
    }

    /**
     * @notice Emergency withdrawal from a protocol.
     */
    function emergencyWithdraw(address protocol, uint256 amount, bytes32 correlationId) external onlyOwner {
        require(supportedProtocols[protocol], "Unsupported protocol");
        require(amount > 0 && amount <= defiBalances[protocol], "Invalid amount");

        (bool success, bytes memory data) = protocol.call(
            abi.encodeWithSelector(protocolConfigs[protocol].withdrawSelector, address(stablecoin), amount)
        );
        require(success, "Emergency withdraw failed");

        uint256 withdrawn = abi.decode(data, (uint256));
        defiBalances[protocol] = defiBalances[protocol].sub(amount);
        totalDeFiBalance = totalDeFiBalance.sub(amount);

        if (withdrawn > 0) {
            stablecoin.safeTransfer(owner(), withdrawn);
        }

        emit EmergencyWithdraw(protocol, amount, correlationId);
    }

    /**
     * @notice Authorizes upgrades.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
