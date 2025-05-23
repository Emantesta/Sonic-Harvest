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
 * @dev Yield aggregator for Sonic DeFi protocols with a performance fee.
 * @notice 10% of the performance fee is sent to StakingManager for rewards.
 *         Integrates with Chainlink and Redstone oracles for APY, TVL, and risk data.
 *         Includes pagination for protocol scores and UI-friendly functions for AI strategies and dashboards.
 */
contract DeFiYield is OwnableUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable, UUPSUpgradeable, IDeFiYield {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using SafeMathUpgradeable for uint256;

    // Immutable stablecoin (e.g., USDC)
    IERC20Upgradeable public immutable stablecoin;
    IStakingManager public stakingManager;
    address public feeRecipient; // Governance/treasury for performance fees
    uint256 public performanceFee; // In basis points (e.g., 1000 = 10%)
    uint256 public stakingRewardShare; // Share of perf fee to StakingManager (e.g., 1000 = 10%)
    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant MAX_FEE_BPS = 2000; // Maximum fee cap (20%)
    uint256 private constant ORACLE_STALENESS_THRESHOLD = 1 hours; // Maximum age of oracle data
    uint256 private constant MAX_PROTOCOLS_PER_PAGE = 10; // Maximum protocols to process per pagination call

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

    // Circuit breaker for emergency situations
    bool public circuitBreakerActive;

    // Events
    event DepositDeFi(address indexed protocol, uint256 amount, bytes32 indexed correlationId);
    event WithdrawDeFi(address indexed protocol, uint256 amount, uint256 profit, bytes32 indexed correlationId);
    event ProfitAllocated(address indexed user, uint256 profit, bytes32 indexed correlationId);
    event ProfitClaimed(address indexed user, uint256 amount);
    event PerformanceFeeCollected(address indexed feeRecipient, uint256 amount, bytes32 indexed correlationId);
    event StakingRewardSent(address indexed stakingManager, uint256 amount, bytes32 indexed correlationId);
    event ProtocolUpdated(address indexed protocol, bool isSupported);
    event ProtocolDeactivated(address indexed protocol);
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
    event AIUpdateIntervalUpdated(uint256 newInterval);
    event CircuitBreakerToggled(bool active);

    // Modifiers
    modifier whenCircuitBreakerInactive() {
        require(!circuitBreakerActive, "Circuit breaker active");
        _;
    }

    // Constructor
    constructor(address _stablecoin) {
        require(_stablecoin != address(0), "Invalid stablecoin address");
        stablecoin = IERC20Upgradeable(_stablecoin);
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract with external dependencies and configurations.
     * @param _protocols Array of supported protocol addresses.
     * @param _oracleConfigs Array of oracle configurations for each protocol.
     * @param _stakingManager Address of the StakingManager contract.
     * @param _feeRecipient Address to receive performance fees.
     * @param _protocolConfigs Array of protocol configurations (selectors).
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
        circuitBreakerActive = false;

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
            emit ProtocolUpdated(_protocols[i], true);
            emit ProtocolConfigUpdated(_protocols[i], _protocolConfigs[i].depositSelector, _protocolConfigs[i].withdrawSelector);
        }
    }

    /**
     * @notice Deposits stablecoins into a DeFi protocol.
     * @param protocol Address of the DeFi protocol.
     * @param amount Amount of stablecoin to deposit.
     * @param correlationId Unique identifier for tracking the transaction.
     * @dev Only callable by the owner (e.g., YieldOptimizer).
     */
    function depositToDeFi(address protocol, uint256 amount, bytes32 correlationId) 
        external 
        override 
        nonReentrant 
        whenNotPaused 
        whenCircuitBreakerInactive 
    {
        require(msg.sender == owner(), "Only YieldOptimizer");
        require(supportedProtocols[protocol] && protocolConfigs[protocol].isActive, "Unsupported or inactive protocol");
        require(amount > 0, "Amount must be > 0");

        if (correlationId == bytes32(0)) {
            correlationId = keccak256(abi.encodePacked(msg.sender, block.timestamp, amount));
        }

        if (stablecoin.allowance(address(this), protocol) < amount) {
            stablecoin.safeApprove(protocol, 0);
            stablecoin.safeApprove(protocol, type(uint256).max);
        }

        (bool success, ) = protocol.call(
            abi.encodeWithSelector(protocolConfigs[protocol].depositSelector, address(stablecoin), amount)
        );
        require(success, "Deposit to protocol failed");

        defiBalances[protocol] = defiBalances[protocol].add(amount);
        totalDeFiBalance = totalDeFiBalance.add(amount);
        userDeposits[msg.sender] = userDeposits[msg.sender].add(amount);
        totalDeposits = totalDeposits.add(amount);

        stakingManager.awardPoints(msg.sender, amount, true);

        emit DepositDeFi(protocol, amount, correlationId);
    }

    /**
     * @notice Withdraws stablecoins from a DeFi protocol and allocates profits with a performance fee.
     * @param protocol Address of the DeFi protocol.
     * @param amount Amount of stablecoin to withdraw.
     * @param correlationId Unique identifier for tracking the transaction.
     * @return Amount withdrawn from the protocol.
     */
    function withdrawFromDeFi(address protocol, uint256 amount, bytes32 correlationId)
        external
        override
        nonReentrant
        whenNotPaused
        whenCircuitBreakerInactive
        returns (uint256)
    {
        require(msg.sender == owner(), "Only YieldOptimizer");
        require(supportedProtocols[protocol] && protocolConfigs[protocol].isActive, "Unsupported or inactive protocol");
        require(amount > 0 && amount <= defiBalances[protocol], "Invalid amount");

        if (correlationId == bytes32(0)) {
            correlationId = keccak256(abi.encodePacked(msg.sender, block.timestamp, amount));
        }

        uint256 initialBalance = stablecoin.balanceOf(address(this));
        uint256 withdrawn;

        try protocol.call(
            abi.encodeWithSelector(protocolConfigs[protocol].withdrawSelector, address(stablecoin), amount)
        ) returns (bool success, bytes memory data) {
            require(success, "Withdrawal from protocol failed");
            withdrawn = abi.decode(data, (uint256));
        } catch {
            emit WithdrawDeFi(protocol, amount, 0, correlationId);
            return 0;
        }

        uint256 profit = withdrawn > initialBalance ? withdrawn.sub(initialBalance) : 0;

        defiBalances[protocol] = defiBalances[protocol].sub(amount);
        totalDeFiBalance = totalDeFiBalance.sub(amount);
        userDeposits[msg.sender] = userDeposits[msg.sender].sub(amount);
        totalDeposits = totalDeposits.sub(amount);

        stakingManager.awardPoints(msg.sender, amount, false);

        if (profit > 0) {
            uint256 perfFee = profit.mul(performanceFee).div(BASIS_POINTS);
            if (perfFee > profit.mul(MAX_FEE_BPS).div(BASIS_POINTS)) {
                perfFee = profit.mul(MAX_FEE_BPS).div(BASIS_POINTS);
            }
            uint256 userProfit = profit.sub(perfFee);

            userProfits[msg.sender] = userProfits[msg.sender].add(userProfit);
            emit ProfitAllocated(msg.sender, userProfit, correlationId);

            if (perfFee > 0) {
                uint256 stakingShare = perfFee.mul(stakingRewardShare).div(BASIS_POINTS);
                uint256 recipientShare = perfFee.sub(stakingShare);

                if (recipientShare > 0) {
                    stablecoin.safeTransfer(feeRecipient, recipientShare);
                    emit PerformanceFeeCollected(feeRecipient, recipientShare, correlationId);
                }

                if (stakingShare > 0) {
                    stablecoin.safeApprove(address(stakingManager), 0);
                    stablecoin.safeApprove(address(stakingManager), stakingShare);
                    try stakingManager.depositRewards(stakingShare, address(stablecoin)) {
                        emit StakingRewardSent(address(stakingManager), stakingShare, correlationId);
                    } catch {
                        stablecoin.safeTransfer(feeRecipient, stakingShare);
                        emit PerformanceFeeCollected(feeRecipient, stakingShare, correlationId);
                    }
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
    function claimProfits() 
        external 
        nonReentrant 
        whenNotPaused 
        whenCircuitBreakerInactive 
    {
        uint256 profit = userProfits[msg.sender];
        require(profit > 0, "No profits to claim");

        userProfits[msg.sender] = 0;
        stablecoin.safeTransfer(msg.sender, profit);
        emit ProfitClaimed(msg.sender, profit);
    }

    /**
     * @notice Estimates the performance fee for a given profit amount.
     * @param profit Profit amount to calculate the fee for.
     * @return fee The estimated performance fee.
     * @return stakingShare The share of the fee sent to StakingManager.
     */
    function estimatePerformanceFee(uint256 profit) 
        public 
        view 
        returns (uint256 fee, uint256 stakingShare) 
    {
        fee = profit.mul(performanceFee).div(BASIS_POINTS);
        if (fee > profit.mul(MAX_FEE_BPS).div(BASIS_POINTS)) {
            fee = profit.mul(MAX_FEE_BPS).div(BASIS_POINTS);
        }
        stakingShare = fee.mul(stakingRewardShare).div(BASIS_POINTS);
        return (fee, stakingShare);
    }

    /**
     * @notice Updates the performance fee.
     * @param newFee New performance fee in basis points (max 20%).
     */
    function updatePerformanceFee(uint256 newFee) 
        external 
        onlyOwner 
    {
        require(newFee <= MAX_FEE_BPS, "Fee too high");
        performanceFee = newFee;
        emit PerformanceFeeUpdated(newFee);
    }

    /**
     * @notice Updates the staking reward share.
     * @param newShare New staking reward share in basis points (max 50%).
     */
    function updateStakingRewardShare(uint256 newShare) 
        external 
        onlyOwner 
    {
        require(newShare <= 5000, "Share too high");
        stakingRewardShare = newShare;
        emit StakingRewardShareUpdated(newShare);
    }

    /**
     * @notice Updates the fee recipient with validation.
     * @param newRecipient New address to receive performance fees.
     */
    function updateFeeRecipient(address newRecipient) 
        external 
        onlyOwner 
    {
        require(newRecipient != address(0), "Invalid recipient");
        require(newRecipient.code.length == 0 || newRecipient.isContract(), "Invalid recipient contract");
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(newRecipient);
    }

    /**
     * @notice Updates the staking manager.
     * @param newStakingManager New StakingManager address.
     */
    function updateStakingManager(address newStakingManager) 
        external 
        onlyOwner 
    {
        require(newStakingManager != address(0), "Invalid StakingManager address");
        stakingManager = IStakingManager(newStakingManager);
        emit StakingManagerUpdated(newStakingManager);
    }

    /**
     * @notice Updates the AI update interval.
     * @param newInterval New interval in seconds (minimum 1 hour, maximum 30 days).
     */
    function updateAIUpdateInterval(uint256 newInterval) 
        external 
        onlyOwner 
    {
        require(newInterval >= 1 hours && newInterval <= 30 days, "Invalid interval");
        aiUpdateInterval = newInterval;
        emit AIUpdateIntervalUpdated(newInterval);
    }

    /**
     * @notice Pauses the contract.
     */
    function pause() 
        external 
        onlyOwner 
    {
        _pause();
    }

    /**
     * @notice Unpauses the contract.
     */
    function unpause() 
        external 
        onlyOwner 
    {
        _unpause();
    }

    /**
     * @notice Toggles the circuit breaker.
     * @param active True to activate, false to deactivate.
     */
    function toggleCircuitBreaker(bool active) 
        external 
        onlyOwner 
    {
        circuitBreakerActive = active;
        emit CircuitBreakerToggled(active);
    }

    /**
     * @notice Checks if a protocol is supported.
     * @param protocol Protocol address.
     * @return True if the protocol is supported.
     */
    function isDeFiProtocol(address protocol) 
        external 
        view 
        override 
        returns (bool) 
    {
        return supportedProtocols[protocol] && protocolConfigs[protocol].isActive;
    }

    /**
     * @notice Gets available liquidity for a protocol.
     * @param protocol Protocol address.
     * @return Available liquidity in the protocol.
     */
    function getAvailableLiquidity(address protocol) 
        external 
        view 
        override 
        returns (uint256) 
    {
        if (!supportedProtocols[protocol] || !protocolConfigs[protocol].isActive) {
            return 0;
        }

        try this._fetchProtocolLiquidity(protocol) returns (uint256 liquidity) {
            return liquidity;
        } catch {
            return defiBalances[protocol];
        }
    }

    /**
     * @notice Internal helper to fetch protocol liquidity dynamically.
     * @param protocol Protocol address.
     * @return Liquidity amount.
     */
    function _fetchProtocolLiquidity(address protocol) 
        external 
        view 
        returns (uint256) 
    {
        return IERC20Upgradeable(stablecoin).balanceOf(protocol);
    }

    /**
     * @notice Gets the total DeFi balance across all protocols.
     * @return Total DeFi balance.
     */
    function getTotalDeFiBalance() 
        external 
        view 
        override 
        returns (uint256) 
    {
        return totalDeFiBalance;
    }

    /**
     * @notice Updates protocol support.
     * @param protocol Protocol address.
     * @param isSupported True to support, false to remove support.
     */
    function updateProtocol(address protocol, bool isSupported) 
        external 
        onlyOwner 
    {
        require(protocol != address(0), "Invalid protocol address");
        supportedProtocols[protocol] = isSupported;
        if (!isSupported) {
            protocolConfigs[protocol].isActive = false;
            emit ProtocolDeactivated(protocol);
        }
        emit ProtocolUpdated(protocol, isSupported);
    }

    /**
     * @notice Deactivates a protocol without removing support.
     * @param protocol Protocol address.
     */
    function deactivateProtocol(address protocol) 
        external 
        onlyOwner 
    {
        require(supportedProtocols[protocol], "Unsupported protocol");
        protocolConfigs[protocol].isActive = false;
        emit ProtocolDeactivated(protocol);
    }

    /**
     * @notice Updates protocol configuration with selector validation.
     * @param protocol Protocol address.
     * @param depositSelector Deposit function selector.
     * @param withdrawSelector Withdraw function selector.
     */
    function updateProtocolConfig(address protocol, bytes4 depositSelector, bytes4 withdrawSelector) 
        external 
        onlyOwner 
    {
        require(protocol != address(0), "Invalid protocol address");
        require(depositSelector != bytes4(0) && withdrawSelector != bytes4(0), "Invalid selectors");
        require(protocol.code.length > 0, "Protocol must be a contract");

        protocolConfigs[protocol] = ProtocolConfig({
            depositSelector: depositSelector,
            withdrawSelector: withdrawSelector,
            isActive: true
        });
        emit ProtocolConfigUpdated(protocol, depositSelector, withdrawSelector);
    }

    /**
     * @notice Updates oracle configuration for a protocol.
     * @param protocol Protocol address.
     * @param chainlinkFeed Chainlink oracle feed address.
     * @param redstoneFeed Redstone oracle feed address.
     */
    function updateOracle(address protocol, address chainlinkFeed, address redstoneFeed) 
        external 
        onlyOwner 
    {
        require(protocol != address(0), "Invalid protocol address");
        protocolOracles[protocol] = OracleConfig({
            chainlinkFeed: chainlinkFeed,
            redstoneFeed: redstoneFeed,
            isActive: true
        });
        bool found = false;
        for (uint256 i = 0; i < oracleProtocols.length; i++) {
            if (oracleProtocols[i] == protocol) {
                found = true;
                break;
            }
        }
        if (!found) {
            oracleProtocols.push(protocol);
        }
        emit OracleUpdated(protocol, chainlinkFeed, redstoneFeed);
    }

    /**
     * @notice Sets user AI strategy for allocation preferences (UI-friendly).
     * @param riskTolerance Risk tolerance (0-100).
     * @param yieldPreference Yield preference (0-100).
     * @dev This function is designed to be called via a user interface.
     */
    function setUserStrategy(uint256 riskTolerance, uint256 yieldPreference) 
        external 
    {
        require(riskTolerance <= 100 && yieldPreference <= 100, "Invalid parameters");
        require(block.timestamp >= userStrategies[msg.sender].lastUpdated + aiUpdateInterval, "Update interval not elapsed");
        userStrategies[msg.sender] = AIStrategy({
            riskTolerance: riskTolerance,
            yieldPreference: yieldPreference,
            lastUpdated: block.timestamp
        });
        emit UserStrategyUpdated(msg.sender, riskTolerance, yieldPreference);
    }

    /**
     * @notice Performs an emergency withdrawal from a protocol.
     * @param protocol Protocol address.
     * @param amount Amount to withdraw.
     * @param correlationId Unique identifier for tracking.
     */
    function emergencyWithdraw(address protocol, uint256 amount, bytes32 correlationId) 
        external 
        onlyOwner 
    {
        require(supportedProtocols[protocol], "Unsupported protocol");
        require(amount > 0 && amount <= defiBalances[protocol], "Invalid amount");

        if (correlationId == bytes32(0)) {
            correlationId = keccak256(abi.encodePacked(msg.sender, block.timestamp, amount));
        }

        try protocol.call(
            abi.encodeWithSelector(protocolConfigs[protocol].withdrawSelector, address(stablecoin), amount)
        ) returns (bool success, bytes memory data) {
            require(success, "Emergency withdraw failed");
            uint256 withdrawn = abi.decode(data, (uint256));
            defiBalances[protocol] = defiBalances[protocol].sub(amount);
            totalDeFiBalance = totalDeFiBalance.sub(amount);

            if (withdrawn > 0) {
                stablecoin.safeTransfer(owner(), withdrawn);
            }

            emit EmergencyWithdraw(protocol, amount, correlationId);
        } catch {
            revert("Emergency withdraw failed");
        }
    }

    /**
     * @notice Fetches protocol scores for a single protocol.
     * @param protocol Protocol address.
     * @return apy Annual Percentage Yield.
     * @return tvl Total Value Locked.
     * @return riskScore Risk score (0-100).
     * @return score Combined score based on user strategy.
     */
    function protocolScores(address protocol) 
        external 
        view 
        returns (uint256 apy, uint256 tvl, uint256 riskScore, uint256 score) 
    {
        if (!supportedProtocols[protocol] || !protocolConfigs[protocol].isActive) {
            return (0, 0, 0, 0);
        }

        return _computeProtocolScore(protocol, msg.sender);
    }

    /**
     * @notice Fetches paginated protocol scores for a dashboard UI.
     * @param start Starting index for pagination.
     * @param limit Number of protocols to fetch (max 10 per call).
     * @return scores Array of protocol scores with additional metadata.
     * @return totalProtocols Total number of protocols available.
     * @dev Designed for UI dashboards to display protocol performance.
     */
    function getProtocolScoresDashboard(uint256 start, uint256 limit) 
        external 
        view 
        returns (
            ProtocolScoreWithMetadata[] memory scores,
            uint256 totalProtocols
        ) 
    {
        totalProtocols = oracleProtocols.length;
        require(start < totalProtocols, "Invalid start index");

        // Limit the number of protocols processed per call
        if (limit > MAX_PROTOCOLS_PER_PAGE) {
            limit = MAX_PROTOCOLS_PER_PAGE;
        }
        uint256 end = start.add(limit) > totalProtocols ? totalProtocols : start.add(limit);
        uint256 resultCount = end.sub(start);

        ProtocolScoreWithMetadata[] memory result = new ProtocolScoreWithMetadata[](resultCount);

        for (uint256 i = start; i < end; i++) {
            address protocol = oracleProtocols[i];
            if (!supportedProtocols[protocol] || !protocolConfigs[protocol].isActive) {
                result[i - start] = ProtocolScoreWithMetadata({
                    protocol: protocol,
                    apy: 0,
                    tvl: 0,
                    riskScore: 0,
                    score: 0,
                    isActive: false
                });
                continue;
            }

            (uint256 apy, uint256 tvl, uint256 riskScore, uint256 score) = _computeProtocolScore(protocol, msg.sender);
            result[i - start] = ProtocolScoreWithMetadata({
                protocol: protocol,
                apy: apy,
                tvl: tvl,
                riskScore: riskScore,
                score: score,
                isActive: true
            });
        }

        return (result, totalProtocols);
    }

    /**
     * @notice Internal helper to compute protocol scores.
     * @param protocol Protocol address.
     * @param user User address for strategy.
     * @return apy, tvl, riskScore, score Computed values.
     */
    function _computeProtocolScore(address protocol, address user) 
        internal 
        view 
        returns (uint256 apy, uint256 tvl, uint256 riskScore, uint256 score) 
    {
        OracleConfig memory oracle = protocolOracles[protocol];
        AIStrategy memory strategy = userStrategies[user];

        apy = oracleDefaults.defaultAPY;
        tvl = oracleDefaults.defaultTVL;
        riskScore = oracleDefaults.defaultRiskScore;

        if (oracle.chainlinkFeed != address(0) && oracle.isActive) {
            try AggregatorV3Interface(oracle.chainlinkFeed).latestRoundData() returns (
                uint80,
                int256 price,
                uint256,
                uint256 updatedAt,
                uint80
            ) {
                if (block.timestamp.sub(updatedAt) <= ORACLE_STALENESS_THRESHOLD && price > 0) {
                    apy = uint256(price);
                } else {
                    emit OracleFailure(protocol, "Chainlink data stale or invalid");
                }
            } catch {
                emit OracleFailure(protocol, "Chainlink oracle failed");
            }
        }

        if (oracle.redstoneFeed != address(0) && oracle.isActive && apy == oracleDefaults.defaultAPY) {
            try IRedstoneOracle(oracle.redstoneFeed).latestRoundData(oracle.redstoneFeed) returns (
                uint80,
                int256 price,
                uint256,
                uint256 updatedAt,
                uint80
            ) {
                if (block.timestamp.sub(updatedAt) <= ORACLE_STALENESS_THRESHOLD && price > 0) {
                    apy = uint256(price);
                } else {
                    emit OracleFailure(protocol, "Redstone data stale or invalid");
                }
            } catch {
                emit OracleFailure(protocol, "Redstone oracle failed");
            }
        }

        tvl = oracleDefaults.defaultTVL;
        riskScore = oracleDefaults.defaultRiskScore;

        uint256 riskFactor = 100 - strategy.riskTolerance;
        uint256 yieldFactor = strategy.yieldPreference;
        score = (apy * yieldFactor * (100 - riskScore * riskFactor / 100)) / 100;
    }

    /**
     * @notice Authorizes contract upgrades.
     * @param newImplementation Address of the new implementation contract.
     */
    function _authorizeUpgrade(address newImplementation) 
        internal 
        override 
        onlyOwner 
    {}

    // Struct for dashboard scores
    struct ProtocolScoreWithMetadata {
        address protocol;
        uint256 apy;
        uint256 tvl;
        uint256 riskScore;
        uint256 score;
        bool isActive;
    }
}
