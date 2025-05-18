// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

// Placeholder for Redstone oracle interface (adjust based on actual implementation)
interface IRedstoneOracle {
    function latestRoundData(address feed) external view returns (uint80, int256, uint256, uint256, uint80);
}

// Interface for StakingManager with cycle timing
interface IStakingManager {
    function depositRewards(uint256 amount) external;
    function getStakingCycle() external view returns (uint256 start, uint256 end, uint256 duration);
}

/**
 * @title DeFiYield
 * @dev Advanced yield aggregator with AI-driven strategies, multi-oracle integration, and user customization.
 * @notice Upgradable contract for Sonic DeFi protocols, optimized for yield and profit distribution.
 */
contract DeFiYield is OwnableUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {
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
        address chainlinkFeed; // Chainlink data feed
        address redstoneFeed; // Redstone data feed
        bool isActive;
    }
    mapping(address => OracleConfig) public protocolOracles;
    address[] public oracleProtocols;

    // Default oracle values for fallback
    struct OracleDefaults {
        uint256 defaultAPY; // e.g., 5% (500)
        uint256 defaultTVL; // e.g., 10M USD
        uint256 defaultRiskScore; // e.g., 50
    }
    OracleDefaults public oracleDefaults;

    // AI-driven strategy parameters
    struct AIStrategy {
        uint256 riskTolerance; // 0 (conservative) to 100 (aggressive)
        uint256 yieldPreference; // 0 (stable) to 100 (high-yield)
        uint256 lastUpdated;
    }
    mapping(address => AIStrategy) public userStrategies;
    uint256 public aiUpdateInterval;

    // Protocol scoring for AI
    struct ProtocolScore {
        uint256 apy; // Annualized yield (% * 100)
        uint256 tvl; // Total value locked (USD)
        uint256 riskScore; // Risk score (0–100)
        uint256 score; // Computed score for allocation
    }
    mapping(address => ProtocolScore) public protocolScores;

    // Dynamic protocol handling
    struct ProtocolConfig {
        bytes4 depositSelector; // e.g., keccak256("deposit(address,uint256)")
        bytes4 withdrawSelector; // e.g., keccak256("withdraw(address,uint256)")
        bool isActive;
    }
    mapping(address => ProtocolConfig) public protocolConfigs;

    // Events
    event DepositDeFi(address indexed protocol, uint256 amount);
    event WithdrawDeFi(address indexed protocol, uint256 amount, uint256 profit);
    event ProtocolUpdated(address indexed protocol, bool isSupported);
    event ProtocolConfigUpdated(address indexed protocol, bytes4 depositSelector, bytes4 withdrawSelector);
    event StakingManagerUpdated(address indexed newStakingManager);
    event OracleUpdated(address indexed protocol, address chainlinkFeed, address redstoneFeed);
    event OracleFailure(address indexed protocol, string reason);
    event UserStrategyUpdated(address indexed user, uint256 riskTolerance, uint256 yieldPreference);
    event AIAllocation(address indexed protocol, uint256 amount, uint256 score);
    event EmergencyWithdraw(address indexed protocol, uint256 amount);

    // Constructor
    constructor(address _stablecoin) {
        require(_stablecoin != address(0), "Invalid stablecoin address");
        stablecoin = IERC20Upgradeable(_stablecoin);
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract with protocols, oracles, and StakingManager.
     * @param _protocols Array of supported protocol addresses
     * @param _oracleConfigs Array of oracle configurations
     * @param _stakingManager StakingManager address
     * @param _protocolConfigs Array of protocol function selectors
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

        // Set default oracle values
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
     * @notice Deposits stablecoins into a DeFi protocol using dynamic function calls.
     * @param protocol Protocol address
     * @param amount Amount to deposit (6 decimals)
     */
    function depositToDeFi(address protocol, uint256 amount) external nonReentrant {
        require(msg.sender == owner(), "Only YieldOptimizer");
        require(supportedProtocols[protocol] && protocolConfigs[protocol].isActive, "Unsupported protocol");
        require(amount > 0, "Amount must be > 0");

        // Optimized approval
        uint256 allowance = stablecoin.allowance(address(this), protocol);
        if (allowance < amount) {
            stablecoin.safeApprove(protocol, 0);
            stablecoin.safeApprove(protocol, type(uint256).max);
        }

        // Dynamic deposit call
        (bool success, ) = protocol.call(
            abi.encodeWithSelector(protocolConfigs[protocol].depositSelector, address(stablecoin), amount)
        );
        require(success, "Deposit failed");

        defiBalances[protocol] = defiBalances[protocol].add(amount);
        totalDeFiBalance = totalDeFiBalance.add(amount);
        emit DepositDeFi(protocol, amount);
    }

    /**
     * @notice Withdraws stablecoins and profits, distributing to StakingManager.
     * @param protocol Protocol address
     * @param amount Amount to withdraw (6 decimals)
     * @return withdrawn Amount withdrawn
     */
    function withdrawFromDeFi(address protocol, uint256 amount) external nonReentrant returns (uint256) {
        require(msg.sender == owner(), "Only YieldOptimizer");
        require(supportedProtocols[protocol] && protocolConfigs[protocol].isActive, "Unsupported protocol");
        require(amount > 0 && amount <= defiBalances[protocol], "Invalid amount");

        uint256 initialBalance = stablecoin.balanceOf(address(this));
        uint256 withdrawn;

        // Dynamic withdraw call
        (bool success, bytes memory data) = protocol.call(
            abi.encodeWithSelector(protocolConfigs[protocol].withdrawSelector, address(stablecoin), amount)
        );
        if (!success) {
            emit WithdrawDeFi(protocol, amount, 0);
            return 0;
        }

        // Decode returned amount
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

        // Revoke approval if no balance
        if (defiBalances[protocol] == 0) {
            stablecoin.safeApprove(protocol, 0);
        }

        emit WithdrawDeFi(protocol, amount, profit);
        return withdrawn;
    }

    /**
     * @notice Executes AI-driven reallocation across protocols.
     * @param protocols Protocols to allocate to
     * @param amounts Amounts to allocate
     */
    function executeAIAllocation(address[] memory protocols, uint256[] memory amounts)
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
                depositToDeFi(protocols[i], amounts[i]);
                emit AIAllocation(protocols[i], amounts[i], score);
            }
        }
        userStrategies[msg.sender].lastUpdated = block.timestamp;
    }

    /**
     * @notice Computes protocol score based on AI parameters and user strategy.
     * @param protocol Protocol address
     * @param strategy User AI strategy
     * @return score Computed score
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
    }

    /**
     * @notice Updates protocol scores using oracle data.
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
    }

    /**
     * @notice Fetches data from Chainlink and Redstone oracles with enhanced fallbacks.
     * @param protocol Protocol address
     * @return apy, tvl, riskScore Oracle data
     */
    function _getOracleData(address protocol)
        internal
        view
        returns (uint256 apy, uint256 tvl, uint256 riskScore)
    {
        OracleConfig memory config = protocolOracles[protocol];
        bool success = false;

        // Try Chainlink for APY
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

        // Fallback to Redstone for APY
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

        // Final fallback to default APY
        if (!success) {
            apy = oracleDefaults.defaultAPY;
            emit OracleFailure(protocol, "All APY oracles failed, using default");
        }

        // TVL (placeholder for real feed)
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

        // Risk score (placeholder for real feed)
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
    }

    /**
     * @notice Checks if it's optimal to deposit rewards based on staking cycle.
     * @return isOptimal True if within optimal deposit window
     */
    function _isOptimalDepositTime() internal view returns (bool) {
        (uint256 start, uint256 end, ) = stakingManager.getStakingCycle();
        uint256 currentTime = block.timestamp;
        uint256 optimalWindow = end.sub(start).div(4); // First 25% of cycle
        return currentTime >= start && currentTime <= start.add(optimalWindow);
    }

    /**
     * @notice Updates user AI strategy parameters.
     * @param riskTolerance 0 (conservative) to 100 (aggressive)
     * @param yieldPreference 0 (stable) to 100 (high-yield)
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
     * @notice Updates protocol support, oracle, and function selectors.
     * @param protocol Protocol address
     * @param isSupported True to enable, false to disable
     * @param depositSelector Deposit function selector
     * @param withdrawSelector Withdraw function selector
     * @param chainlinkFeed Chainlink feed address
     * @param redstoneFeed Redstone feed address
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
            stablecoin.safeApprove(protocol, 0);
        }
        emit ProtocolUpdated(protocol, isSupported);
        emit ProtocolConfigUpdated(protocol, depositSelector, withdrawSelector);
        emit OracleUpdated(protocol, chainlinkFeed, redstoneFeed);
    }

    /**
     * @notice Updates oracle default values.
     * @param defaultAPY Default APY (e.g., 500 for 5%)
     * @param defaultTVL Default TVL (e.g., 10M USD)
     * @param defaultRiskScore Default risk score (e.g., 50)
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
    }

    /**
     * @notice Emergency withdraw from protocols in batches.
     * @param start Starting index
     * @param limit Number of protocols to process
     */
    function emergencyWithdrawAll(uint256 start, uint256 limit) external nonReentrant onlyOwner {
        require(start < oracleProtocols.length, "Invalid start index");
        uint256 end = start.add(limit) > oracleProtocols.length ? oracleProtocols.length : start.add(limit);

        for (uint256 i = start; i < end; i++) {
            address protocol = oracleProtocols[i];
            if (supportedProtocols[protocol] && defiBalances[protocol] > 0) {
                uint256 amount = withdrawFromDeFi(protocol, defiBalances[protocol]);
                emit EmergencyWithdraw(protocol, amount);
            }
        }
    }

    /**
     * @notice Batch reallocation across protocols.
     * @param fromProtocols Source protocols
     * @param toProtocols Destination protocols
     * @param amounts Amounts to reallocate
     */
    function batchReallocate(
        address[] memory fromProtocols,
        address[] memory toProtocols,
        uint256[] memory amounts
    ) external nonReentrant onlyOwner {
        require(
            fromProtocols.length == toProtocols.length && fromProtocols.length == amounts.length,
            "Array length mismatch"
        );

        // Batch update approvals for toProtocols
        _batchUpdateApprovals(toProtocols, amounts);

        for (uint256 i = 0; i < fromProtocols.length; i++) {
            uint256 withdrawn = withdrawFromDeFi(fromProtocols[i], amounts[i]);
            if (withdrawn > 0) {
                depositToDeFi(toProtocols[i], withdrawn);
            }
        }
    }

    /**
     * @notice Batch updates approvals for protocols.
     * @param protocols Protocols to approve
     * @param amounts Amounts for approval checks
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
    }

    /**
     * @notice Updates StakingManager address.
     * @param _stakingManager New StakingManager address
     */
    function setStakingManager(address _stakingManager) external onlyOwner {
        require(_stakingManager != address(0), "Invalid StakingManager address");
        stakingManager = IStakingManager(_stakingManager);
        emit StakingManagerUpdated(_stakingManager);
    }

    /**
     * @notice Returns total balance across protocols.
     * @return Total DeFi balance (6 decimals)
     */
    function getTotalDeFiBalance() external view returns (uint256) {
        return totalDeFiBalance;
    }

    /**
     * @notice Authorizes contract upgrades.
     * @param newImplementation New implementation address
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
