// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

// Placeholder for Redstone oracle interface
interface IRedstoneOracle {
    function latestRoundData(address feed) external view returns (uint80, int256, uint256, uint256, uint80);
}

// Interface for StakingManager
interface IStakingManager {
    function depositRewards(uint256 amount) external;
    function getStakingCycle() external view returns (uint256 start, uint256 end, uint256 duration);
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
 * @dev Yield aggregator for Sonic DeFi protocols with AI-driven strategies and multi-oracle integration.
 * @notice Upgradable contract optimized for yield and profit distribution.
 */
contract DeFiYield is OwnableUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable, IDeFiYield {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using SafeMathUpgradeable for uint256;

    // Immutable stablecoin (USDC)
    IERC20Upgradeable public immutable stablecoin;
    IStakingManager public stakingManager;

    // Protocol and balance management
    mapping(address => bool) public supportedProtocols;
    mapping(address => uint256) public defiBalances;
    uint256 public totalDeFiBalance;

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
    event ProtocolUpdated(address indexed protocol, bool isSupported);
    event ProtocolConfigUpdated(address indexed protocol, bytes4 depositSelector, bytes4 withdrawSelector);
    event StakingManagerUpdated(address indexed newStakingManager);
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
     * @param _protocols Protocol addresses
     * @param _oracleConfigs Oracle configurations
     * @param _stakingManager StakingManager address
     * @param _protocolConfigs Protocol function selectors
     */
    function initialize(
        address[] memory _protocols,
        OracleConfig[] memory _oracleConfigs,
        address _stakingManager,
        ProtocolConfig[] memory _protocolConfigs
    ) external initializer {
        require(_stakingManager != address(0), "Invalid StakingManager address");
        require(
            _protocols.length == _oracleConfigs.length && _protocols.length == _protocolConfigs.length,
            "Array length mismatch"
        );
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        stakingManager = IStakingManager(_stakingManager);
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
     * @param protocol Protocol address
     * @param amount Amount to deposit (6 decimals)
     * @param correlationId Unique ID for event tracing
     */
    function depositToDeFi(address protocol, uint256 amount, bytes32 correlationId) external override nonReentrant {
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
        emit DepositDeFi(protocol, amount, correlationId);

        // Testing Note: Test edge cases like failed protocol calls, insufficient allowance, or invalid selectors.
    }

    /**
     * @notice Withdraws stablecoins and profits.
     * @param protocol Protocol address
     * @param amount Amount to withdraw (6 decimals)
     * @param correlationId Unique ID for event tracing
     * @return withdrawn Amount withdrawn
     */
    function withdrawFromDeFi(address protocol, uint256 amount, bytes32 correlationId)
        external
        override
        nonReentrant
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

        if (withdrawn > 0) {
            stablecoin.safeTransfer(msg.sender, withdrawn);
            if (profit > 0 && _isOptimalDepositTime()) {
                stablecoin.safeApprove(address(stakingManager), 0);
                stablecoin.safeApprove(address(stakingManager), profit);
                stakingManager.depositRewards(profit);
            }
        }

        if (defiBalances[protocol] == 0) {
            stablecoin.safeApprove(protocol, 0);
        }

        emit WithdrawDeFi(protocol, amount, profit, correlationId);
        return withdrawn;

        // Testing Note: Test failed withdrawals, partial withdrawals, StakingManager reverts, and profit calculation accuracy.
    }

    /**
     * @notice Checks if a protocol is supported.
     * @param protocol Protocol address
     * @return True if supported
     */
    function isDeFiProtocol(address protocol) external view override returns (bool) {
        return supportedProtocols[protocol] && protocolConfigs[protocol].isActive;

        // Testing Note: Test with inactive or unsupported protocols.
    }

    /**
     * @notice Gets available liquidity for a protocol.
     * @param protocol Protocol address
     * @return Available liquidity (6 decimals)
     */
    function getAvailableLiquidity(address protocol) external view override returns (uint256) {
        require(supportedProtocols[protocol], "Unsupported protocol");
        return protocolScores[protocol].tvl > 0 ? protocolScores[protocol].tvl : oracleDefaults.defaultTVL;

        // Testing Note: Test with real protocol liquidity feeds and edge cases like zero TVL or oracle failures.
    }

    /**
     * @notice Gets total DeFi balance.
     * @return Total balance across all protocols
     */
    function getTotalDeFiBalance() external view override returns (uint256) {
        return totalDeFiBalance;

        // Testing Note: Test with zero balances or after deposits/withdrawals.
    }

    /**
     * @notice Gets protocol scores.
     * @param protocol Protocol address
     * @return apy, tvl, riskScore, score
     */
    function protocolScores(address protocol) external view returns (uint256, uint256, uint256, uint256) {
        ProtocolScore memory score = protocolScores[protocol];
        return (score.apy, score.tvl, score.riskScore, score.score);

        // Testing Note: Test with protocols lacking oracle data or zero scores.
    }

    /**
     * @notice Executes AI-driven reallocation.
     * @param protocols Protocols to allocate to
     * @param amounts Amounts to allocate
     * @param correlationId Unique ID for event tracing
     */
    function executeAIAllocation(address[] memory protocols, uint256[] memory amounts, bytes32 correlationId)
        external
        nonReentrant
        onlyOwner
    {
        require(protocols.length == amounts.length, "Array length mismatch");
        require(
            block.timestamp >= userStrategies[msg.sender].lastUpdated + aiUpdateInterval,
            "AI update interval not elapsed"
        );

        _updateProtocolScores();
        AIStrategy memory strategy = userStrategies[msg.sender];

        for (uint256 i = 0; i < protocols.length; i++) {
            require(supportedProtocols[protocols[i]], "Unsupported protocol");
            uint256 score = _computeProtocolScore(protocols[i], strategy);
            if (score > 0 && amounts[i] > 0) {
                depositToDeFi(protocols[i], amounts[i], correlationId);
                emit AIAllocation(protocols[i], amounts[i], score, correlationId);
            }
        }
        userStrategies[msg.sender].lastUpdated = block.timestamp;

        // Testing Note: Test AI allocation with invalid protocols, zero amounts, or outdated strategies.
    }

    /**
     * @notice Computes protocol score.
     */
    function _computeProtocolScore(address protocol, AIStrategy memory strategy)
        internal
        view
        returns (uint256)
    {
        ProtocolScore memory score = protocolScores[protocol];
        uint256 apyWeight = strategy.yieldPreference.mul(100).div(100);
        uint256 riskWeight = (100 - strategy.riskTolerance).mul(100).div(100);
        uint256 tvlWeight = 50;

        return
            (score.apy.mul(apyWeight)).add(score.tvl.mul(tvlWeight)).sub(score.riskScore.mul(riskWeight)).div(100);

        // Testing Note: Test with extreme risk/yield preferences and zero scores.
    }

    /**
     * @notice Updates protocol scores.
     */
    function _updateProtocolScores() internal {
        uint256 length = oracleProtocols.length;
        for (uint256 i = 0; i < length; i++) {
            address protocol = oracleProtocols[i];
            if (supportedProtocols[protocol] && protocolOracles[protocol].isActive) {
                (uint256 apy, uint256 tvl, uint256 risk) = _getOracleData(protocol);
                protocolScores[protocol].apy = apy;
                protocolScores[protocol].tvl = tvl;
                protocolScores[protocol].riskScore = risk;
                protocolScores[protocol].score = 0;
            }
        }

        // Testing Note: Test oracle failures and default value fallbacks.
    }

    /**
     * @notice Fetches oracle data with fallbacks.
     */
    function _getOracleData(address protocol)
        internal
        view
        returns (uint256 apy, uint256 tvl, uint256 riskScore)
    {
        OracleConfig memory config = protocolOracles[protocol];
        bool success;

        // APY
        if (config.chainlinkFeed != address(0)) {
            try AggregatorV3Interface(config.chainlinkFeed).latestRoundData() returns (
                uint80,
                int256 answer,
                uint256,
                uint256,
                uint80
            ) {
                apy = uint256(answer);
                success = true;
            } catch {
                emit OracleFailure(protocol, "Chainlink APY fetch failed");
            }
        }

        if (!success && config.redstoneFeed != address(0)) {
            try IRedstoneOracle(config.redstoneFeed).latestRoundData(config.redstoneFeed) returns (
                uint80,
                int256 answer,
                uint256,
                uint256,
                uint80
            ) {
                apy = uint256(answer);
                success = true;
            } catch {
                emit OracleFailure(protocol, "Redstone APY fetch failed");
            }
        }

        if (!success) {
            apy = oracleDefaults.defaultAPY;
            emit OracleFailure(protocol, "All APY oracles failed, using default");
        }

        // TVL
        success = false;
        if (config.chainlinkFeed != address(0)) {
            try AggregatorV3Interface(config.chainlinkFeed).latestRoundData() returns (
                uint80,
                int256 answer,
                uint256,
                uint256,
                uint80
            ) {
                tvl = uint256(answer);
                success = true;
            } catch {
                emit OracleFailure(protocol, "Chainlink TVL fetch failed");
            }
        }

        if (!success) {
            tvl = oracleDefaults.defaultTVL;
            emit OracleFailure(protocol, "TVL fetch failed, using default");
        }

        // Risk Score
        success = false;
        if (config.redstoneFeed != address(0)) {
            try IRedstoneOracle(config.redstoneFeed).latestRoundData(config.redstoneFeed) returns (
                uint80,
                int256 answer,
                uint256,
                uint256,
                uint80
            ) {
                riskScore = uint256(answer);
                success = true;
            } catch {
                emit OracleFailure(protocol, "Redstone risk fetch failed");
            }
        }

        if (!success) {
            riskScore = oracleDefaults.defaultRiskScore;
            emit OracleFailure(protocol, "Risk fetch failed, using default");
        }

        // Testing Note: Test Chainlink/Redstone failures and fallback to defaults.
    }

    /**
     * @notice Checks optimal deposit time for staking rewards.
     */
    function _isOptimalDepositTime() internal view returns (bool) {
        (uint256 start, uint256 end, ) = stakingManager.getStakingCycle();
        uint256 currentTime = block.timestamp;
        uint256 optimalWindow = end.sub(start).div(4);
        return currentTime >= start && currentTime <= start.add(optimalWindow);

        // Testing Note: Test with different staking cycle configurations.
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

        // Testing Note: Test with invalid parameters and frequent updates.
    }

    /**
     * @notice Updates protocol support and configuration.
     */
    function updateProtocol(
        address protocol,
        bool isSupported,
        bytes4 depositSelector,
        bytes4 withdrawSelector,
        address chainlinkFeed,
        address redstoneFeed
    ) external onlyOwner {
        require(protocol != address(0), "Invalid protocol address");
        supportedProtocols[protocol] = isSupported;
        if (isSupported) {
            protocolConfigs[protocol] = ProtocolConfig({
                depositSelector: depositSelector,
                withdrawSelector: withdrawSelector,
                isActive: true
            });
            protocolOracles[protocol] = OracleConfig({
                chainlinkFeed: chainlinkFeed,
                redstoneFeed: redstoneFeed,
                isActive: true
            });
            bool exists = false;
            for (uint256 i = 0; i < oracleProtocols.length; i++) {
                if (oracleProtocols[i] == protocol) {
                    exists = true;
                    break;
                }
            }
            if (!exists) {
                oracleProtocols.push(protocol);
            }
        } else {
            protocolConfigs[protocol].isActive = false;
            protocolOracles[protocol].isActive = false;
            if (defiBalances[protocol] == 0) {
                stablecoin.safeApprove(protocol, 0);
            }
        }
        emit ProtocolUpdated(protocol, isSupported);
        emit ProtocolConfigUpdated(protocol, depositSelector, withdrawSelector);
        emit OracleUpdated(protocol, chainlinkFeed, redstoneFeed);

        // Testing Note: Test protocol addition/removal, duplicate protocols, and approval cleanup.
    }

    /**
     * @notice Updates oracle defaults.
     */
    function updateOracleDefaults(uint256 defaultAPY, uint256 defaultTVL, uint256 defaultRiskScore)
        external
        onlyOwner
    {
        oracleDefaults = OracleDefaults({
            defaultAPY: defaultAPY,
            defaultTVL: defaultTVL,
            defaultRiskScore: defaultRiskScore
        });

        // Testing Note: Test impact of default value changes on AI scoring.
    }

    /**
     * @notice Emergency withdraw in batches.
     */
    function emergencyWithdrawAll(uint256 start, uint256 limit, bytes32 correlationId)
        external
        nonReentrant
        onlyOwner
    {
        require(start < oracleProtocols.length, "Invalid start index");
        uint256 end = start.add(limit) > oracleProtocols.length ? oracleProtocols.length : start.add(limit);

        for (uint256 i = start; i < end; i++) {
            address protocol = oracleProtocols[i];
            if (supportedProtocols[protocol] && defiBalances[protocol] > 0) {
                uint256 amount = withdrawFromDeFi(protocol, defiBalances[protocol], correlationId);
                emit EmergencyWithdraw(protocol, amount, correlationId);
            }
        }

        // Testing Note: Test pagination, partial withdrawals, and gas limits with large protocol sets.
    }

    /**
     * @notice Batch reallocation.
     */
    function batchReallocate(
        address[] memory fromProtocols,
        address[] memory toProtocols,
        uint256[] memory amounts,
        bytes32 correlationId
    ) external nonReentrant onlyOwner {
        require(
            fromProtocols.length == toProtocols.length && fromProtocols.length == amounts.length,
            "Array length mismatch"
        );

        _batchUpdateApprovals(toProtocols, amounts);

        for (uint256 i = 0; i < fromProtocols.length; i++) {
            uint256 withdrawn = withdrawFromDeFi(fromProtocols[i], amounts[i], correlationId);
            if (withdrawn > 0) {
                depositToDeFi(toProtocols[i], withdrawn, correlationId);
            }
        }

        // Testing Note: Test reallocation with failed withdrawals or deposits, and verify balance updates.
    }

    /**
     * @notice Batch updates approvals.
     */
    function _batchUpdateApprovals(address[] memory protocols, uint256[] memory amounts) internal {
        for (uint256 i = 0; i < protocols.length; i++) {
            if (amounts[i] > 0 && supportedProtocols[protocols[i]]) {
                uint256 allowance = stablecoin.allowance(address(this), protocols[i]);
                if (allowance < amounts[i]) {
                    stablecoin.safeApprove(protocols[i], 0);
                    stablecoin.safeApprove(protocols[i], type(uint256).max);
                }
            }
        }

        // Testing Note: Test approval updates with large protocol sets and insufficient balances.
    }

    /**
     * @notice Updates StakingManager.
     */
    function setStakingManager(address _stakingManager) external onlyOwner {
        require(_stakingManager != address(0), "Invalid StakingManager address");
        stablecoin.safeApprove(address(stakingManager), 0);
        stakingManager = IStakingManager(_stakingManager);
        emit StakingManagerUpdated(_stakingManager);

        // Testing Note: Test StakingManager updates and reward deposit failures.
    }

    /**
     * @notice Prevents accidental ETH deposits.
     */
    receive() external payable {
        revert("ETH deposits not allowed");

        // Testing Note: Test fallback function with ETH transfers.
    }

    /**
     * @notice Authorizes upgrades.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
