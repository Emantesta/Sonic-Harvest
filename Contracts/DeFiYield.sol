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

// Expanded protocol interfaces
interface ISonicNativeVault {
    function deposit(address asset, uint256 amount) external returns (uint256);
    function withdraw(address asset, uint256 amount) external returns (uint256);
}

interface ISonicLiquidityPool {
    function stake(address asset, uint256 amount) external returns (uint256);
    function unstake(address asset, uint256 amount) external returns (uint256);
}

interface ISiloFinance {
    function deposit(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount) external returns (uint256);
}

interface IBeets {
    function depositToPool(address asset, uint256 amount) external;
    function withdrawFromPool(address asset, uint256 amount) external returns (uint256);
}

interface IRingsProtocol {
    function stake(address asset, uint256 amount) external;
    function unstake(address asset, uint256 amount) external returns (uint256);
}

interface IAave {
    function supply(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount) external returns (uint256);
}

interface IEggsFinance {
    function mintEggs(uint256 amount) external;
    function redeemEggs(uint256 amount) external returns (uint256);
}

interface ICompound {
    function mint(address asset, uint256 amount) external;
    function redeem(address asset, uint256 amount) external returns (uint256);
}

interface IBalancer {
    function joinPool(address pool, uint256 amount) external;
    function exitPool(address pool, uint256 amount) external returns (uint256);
}

interface ICurve {
    function add_liquidity(address pool, uint256 amount) external;
    function remove_liquidity(address pool, uint256 amount) external returns (uint256);
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
    mapping(address => OracleConfig) public protocolOracles; // Protocol -> OracleConfig
    address[] public oracleProtocols;

    // AI-driven strategy parameters
    struct AIStrategy {
        uint256 riskTolerance; // 0 (conservative) to 100 (aggressive)
        uint256 yieldPreference; // 0 (stable) to 100 (high-yield)
        uint256 lastUpdated;
    }
    mapping(address => AIStrategy) public userStrategies; // User -> AIStrategy
    uint256 public aiUpdateInterval; // Interval for AI model updates (e.g., 1 day)

    // Protocol scoring for AI
    struct ProtocolScore {
        uint256 apy; // Annualized yield (% * 100)
        uint256 tvl; // Total value locked (USD)
        uint256 riskScore; // Risk score (0–100)
        uint256 score; // Computed score for allocation
    }
    mapping(address => ProtocolScore) public protocolScores;

    // Events
    event DepositDeFi(address indexed protocol, uint256 amount);
    event WithdrawDeFi(address indexed protocol, uint256 amount, uint256 profit);
    event ProtocolUpdated(address indexed protocol, bool isSupported);
    event StakingManagerUpdated(address indexed newStakingManager);
    event OracleUpdated(address indexed protocol, address chainlinkFeed, address redstoneFeed);
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
     * @param _oracleConfigs Array of oracle configurations (chainlink, redstone feeds)
     * @param _stakingManager StakingManager address
     */
    function initialize(
        address[] memory _protocols,
        OracleConfig[] memory _oracleConfigs,
        address _stakingManager
    ) external initializer {
        require(_stakingManager != address(0), "Invalid StakingManager address");
        require(_protocols.length == _oracleConfigs.length, "Protocol-oracle mismatch");
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        stakingManager = IStakingManager(_stakingManager);
        aiUpdateInterval = 1 days;

        for (uint256 i = 0; i < _protocols.length; i++) {
            require(_protocols[i] != address(0), "Invalid protocol address");
            supportedProtocols[_protocols[i]] = true;
            protocolOracles[_protocols[i]] = OracleConfig({
                chainlinkFeed: _oracleConfigs[i].chainlinkFeed,
                redstoneFeed: _oracleConfigs[i].redstoneFeed,
                isActive: true
            });
            oracleProtocols.push(_protocols[i]);
        }
    }

    /**
     * @notice Deposits stablecoins into a DeFi protocol with AI-driven allocation.
     * @param protocol Protocol address
     * @param amount Amount to deposit (6 decimals)
     */
    function depositToDeFi(address protocol, uint256 amount) external nonReentrant {
        require(msg.sender == owner(), "Only YieldOptimizer");
        require(supportedProtocols[protocol], "Unsupported protocol");
        require(amount > 0, "Amount must be > 0");

        // Optimized approval
        uint256 allowance = stablecoin.allowance(address(this), protocol);
        if (allowance < amount) {
            stablecoin.safeApprove(protocol, 0);
            stablecoin.safeApprove(protocol, type(uint256).max);
        }

        // Protocol-specific deposit
        if (protocol == address(0xSiloFinance)) {
            ISiloFinance(protocol).deposit(address(stablecoin), amount);
        } else if (protocol == address(0xBeets)) {
            IBeets(protocol).depositToPool(address(stablecoin), amount);
        } else if (protocol == address(0xRingsProtocol)) {
            IRingsProtocol(protocol).stake(address(stablecoin), amount);
        } else if (protocol == address(0xAave)) {
            IAave(protocol).supply(address(stablecoin), amount);
        } else if (protocol == address(0xEggsFinance)) {
            IEggsFinance(protocol).mintEggs(amount);
        } else if (protocol == address(0xSonicNativeVault)) {
            ISonicNativeVault(protocol).deposit(address(stablecoin), amount);
        } else if (protocol == address(0xSonicLiquidityPool)) {
            ISonicLiquidityPool(protocol).stake(address(stablecoin), amount);
        } else if (protocol == address(0xCompound)) {
            ICompound(protocol).mint(address(stablecoin), amount);
        } else if (protocol == address(0xBalancer)) {
            IBalancer(protocol).joinPool(address(stablecoin), amount);
        } else if (protocol == address(0xCurve)) {
            ICurve(protocol).add_liquidity(address(stablecoin), amount);
        } else {
            revert("Unknown protocol");
        }

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
    function withdrawFromDeFi(address protocol, uint256 amount)
        external
        nonReentrant
        returns (uint256)
    {
        require(msg.sender == owner(), "Only YieldOptimizer");
        require(supportedProtocols[protocol], "Unsupported protocol");
        require(amount > 0 && amount <= defiBalances[protocol], "Invalid amount");

        uint256 initialBalance = stablecoin.balanceOf(address(this));
        uint256 withdrawn;

        try
            protocol == address(0xSiloFinance)
                ? ISiloFinance(protocol).withdraw(address(stablecoin), amount)
                : protocol == address(0xBeets)
                    ? IBeets(protocol).withdrawFromPool(address(stablecoin), amount)
                    : protocol == address(0xRingsProtocol)
                        ? IRingsProtocol(protocol).unstake(address(stablecoin), amount)
                        : protocol == address(0xAave)
                            ? IAave(protocol).withdraw(address(stablecoin), amount)
                            : protocol == address(0xEggsFinance)
                                ? IEggsFinance(protocol).redeemEggs(amount)
                                : protocol == address(0xSonicNativeVault)
                                    ? ISonicNativeVault(protocol).withdraw(address(stablecoin), amount)
                                    : protocol == address(0xSonicLiquidityPool)
                                        ? ISonicLiquidityPool(protocol).unstake(address(stablecoin), amount)
                                        : protocol == address(0xCompound)
                                            ? ICompound(protocol).redeem(address(stablecoin), amount)
                                            : protocol == address(0xBalancer)
                                                ? IBalancer(protocol).exitPool(address(stablecoin), amount)
                                                : ICurve(protocol).remove_liquidity(address(stablecoin), amount)
        returns (uint256 amountWithdrawn) {
            withdrawn = amountWithdrawn;
        } catch {
            emit WithdrawDeFi(protocol, amount, 0);
            return 0;
        }

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
     * @param amounts Amounts to allocate per protocol
     */
()][https://www.youtube.com/watch?v=3o8hH-aWDIU&t=186s)
    */
    function executeAIAllocation(address[] memory protocols, uint256[] memory amounts)
        external
        nonReentrant
        onlyOwner
    {
        require(protocols.length == amounts.length, "Array length mismatch");
        require(block.timestamp >= userStrategies[msg.sender].lastUpdated + aiUpdateInterval, "AI update interval not elapsed");

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
        uint256 tvlWeight = 50; // Fixed weight for TVL

        return (score.apy.mul(apyWeight)).add(score.tvl.mul(tvlWeight)).sub(score.riskScore.mul(riskWeight)).div(100);
    }

    /**
     * @notice Updates protocol scores using oracle data.
     */
    function _updateProtocolScores() internal {
        for (uint256 i = 0; i < oracleProtocols.length; i++) {
            address protocol = oracleProtocols[i];
            if (supportedProtocols[protocol] && protocolOracles[protocol].isActive) {
                (uint256 apy, uint256 tvl, uint256 risk) = _getOracleData(protocol);
                protocolScores[protocol] = ProtocolScore({
                    apy: apy,
                    tvl: tvl,
                    riskScore: risk,
                    score: 0
                });
            }
        }
    }

    /**
     * @notice Fetches data from Chainlink and Redstone oracles with fallback.
     * @param protocol Protocol address
     * @return apy, tvl, riskScore Oracle data
     */
    function _getOracleData(address protocol)
        internal
        view
        returns (uint256 apy, uint256 tvl, uint256 riskScore)
    {
        OracleConfig memory config = protocolOracles[protocol];
        bool chainlinkSuccess = false;

        // Try Chainlink
        if (config.chainlinkFeed != address(0)) {
            try AggregatorV3Interface(config.chainlinkFeed).latestRoundData() returns (
                uint80,
                int256 answer,
                uint256,
                uint256,
                uint80
            ) {
                apy = uint256(answer);
                chainlinkSuccess = true;
            } catch {}
        }

        // Fallback to Redstone
        if (!chainlinkSuccess && config.redstoneFeed != address(0)) {
            try IRedstoneOracle(config.redstoneFeed).latestRoundData(config.redstoneFeed) returns (
                uint80,
                int256 answer,
                uint256,
                uint256,
                uint80
            ) {
                apy = uint256(answer);
            } catch {}
        }

        // Placeholder for TVL and risk (extend with additional feeds)
        tvl = 100_000_000; // Mock TVL (USD)
        riskScore = 20; // Mock risk score
    }

    /**
     * @notice Checks if it's optimal to deposit rewards based on staking cycle.
     * @return isOptimal True if within optimal deposit window
     */
    function _isOptimalDepositTime() internal view returns (bool) {
        (uint256 start, uint256 end,) = stakingManager.getStakingCycle();
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
     * @notice Updates protocol support and oracle configuration.
     * @param protocol Protocol address
     * @param isSupported True to enable, false to disable
     * @param chainlinkFeed Chainlink feed address
     * @param redstoneFeed Redstone feed address
     */
    function updateProtocol(
        address protocol,
        bool isSupported,
        address chainlinkFeed,
        address redstoneFeed
    ) external onlyOwner {
        require(protocol != address(0), "Invalid protocol address");
        supportedProtocols[protocol] = isSupported;
        if (isSupported) {
            protocolOracles[protocol] = OracleConfig({
                chainlinkFeed: chainlinkFeed,
                redstoneFeed: redstoneFeed,
                isActive: true
            });
            oracleProtocols.push(protocol);
        } else {
            stablecoin.safeApprove(protocol, 0);
            protocolOracles[protocol].isActive = false;
        }
        emit ProtocolUpdated(protocol, isSupported);
        emit OracleUpdated(protocol, chainlinkFeed, redstoneFeed);
    }

    /**
     * @notice Emergency withdraw from all protocols.
     */
    function emergencyWithdrawAll() external nonReentrant onlyOwner {
        for (uint256 i = 0; i < oracleProtocols.length; i++) {
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
            fromProtocols.length == toProtocols.length &&
            fromProtocols.length == amounts.length,
            "Array length mismatch"
        );
        for (uint256 i = 0; i < fromProtocols.length; i++) {
            uint256 withdrawn = withdrawFromDeFi(fromProtocols[i], amounts[i]);
            if (withdrawn > 0) {
                depositToDeFi(toProtocols[i], withdrawn);
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
