// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// OpenZeppelin imports
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Chainlink import
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

// Interfaces
interface IAaveV3Pool {
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf) external;
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf) external returns (uint256);
}

interface ICompound {
    function getAccountLiquidity(address account) external view returns (uint256, uint256, uint256);
    function borrow(uint256 borrowAmount) external returns (uint256);
    function repayBorrow(uint256 repayAmount) external returns (uint256);
}

interface IFlyingTulip {
    function depositToPool(address pool, uint256 amount, bool useLeverage) external returns (uint256);
    function withdrawFromPool(address pool, uint256 amount) external returns (uint256);
    function getLTV(address pool, uint256 collateral) external view returns (uint256);
    function borrowWithLTV(address pool, uint256 collateral, uint256 borrowAmount) external;
    function repayBorrow(address pool, uint256 amount) external;
    function isProtocolHealthy(address pool) external view returns (bool);
}

interface IRiskManager {
    function assessLeverageViability(address protocol, uint256 amount, uint256 ltv, bool isRWA) external view returns (bool);
}

interface IRegistry {
    function getProtocolAPYFeed(address protocol) external view returns (address);
}

interface IRWAYield {
    function getAvailableLiquidity(address protocol) external view returns (uint256);
}

/**
 * @title LooperCore
 * @notice Manages leverage operations for YieldOptimizer and AIYieldOptimizer with explicit circuit breakers.
 * @dev Uses UUPS proxy, integrates with Sonic Blockchain, and includes circuit breakers for price volatility, oracle staleness, liquidity, total borrow, protocol-specific volatility, and cross-protocol exposure.
 */
contract LooperCore is UUPSUpgradeable, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    // State variables
    IERC20 public stablecoin;
    IAaveV3Pool public aavePool;
    ICompound public compound;
    IFlyingTulip public flyingTulip;
    IRiskManager public riskManager;
    IRegistry public registry;
    IRWAYield public rwaYield;
    address public governance;
    AggregatorV3Interface public priceFeed;
    bool public isPaused;
    uint256 public totalBorrowed;
    uint256 public lastPrice;
    uint256 public lastPriceTimestamp;
    mapping(address => uint256) public protocolBorrows; // Borrowed amount per protocol
    mapping(address => APYHistory) public protocolAPYHistory; // APY history for volatility checks
    uint256 public activeProtocolCount; // Number of protocols with active leverage

    // Struct for APY history
    struct APYHistory {
        uint256 lastAPY;
        uint256 lastTimestamp;
    }

    // Constants
    uint256 public constant MAX_LTV = 8000; // 80% LTV cap
    uint256 public constant MIN_HEALTH_FACTOR = 1.5e18; // Aave health factor threshold
    uint256 public constant MIN_COLLATERAL_FACTOR = 1.5e18; // Compound collateral factor threshold
    uint256 public constant AAVE_REFERRAL_CODE = 0;
    uint256 public MAX_PRICE_VOLATILITY = 500; // 5% in basis points
    uint256 public MAX_ORACLE_STALENESS = 30 minutes;
    uint256 public MIN_LIQUIDITY_THRESHOLD = 1e18; // 1 stablecoin unit
    uint256 public MAX_TOTAL_BORROW = 1e24; // 1M stablecoin units
    uint256 public MAX_PROTOCOL_VOLATILITY = 1000; // 10% in basis points
    uint256 public PROTOCOL_VOLATILITY_WINDOW = 1 hours; // Time window for volatility
    uint256 public MAX_PROTOCOL_BORROW_PERCENTAGE = 3000; // 30% of total borrow limit
    uint256 public MAX_ACTIVE_PROTOCOLS = 5; // Max protocols with active leverage
    uint256 public constant BASIS_POINTS = 10000;

    // Events
    event LeverageApplied(address indexed protocol, uint256 collateral, uint256 borrowAmount);
    event LeverageUnwound(address indexed protocol, uint256 repayAmount);
    event Paused(address indexed governance);
    event Unpaused(address indexed governance);
    event PriceFeedUpdated(address indexed newFeed);
    event MaxPriceVolatilityUpdated(uint256 newVolatility);
    event MaxOracleStalenessUpdated(uint256 newStaleness);
    event MinLiquidityThresholdUpdated(uint256 newThreshold);
    event MaxTotalBorrowUpdated(uint256 newMaxBorrow);
    event MaxProtocolVolatilityUpdated(uint256 newVolatility);
    event ProtocolVolatilityWindowUpdated(uint256 newWindow);
    event MaxProtocolBorrowPercentageUpdated(uint256 newPercentage);
    event MaxActiveProtocolsUpdated(uint256 newMax);
    event CircuitBreakerTriggered(string reason);

    // Modifiers
    modifier onlyGovernance() {
        require(msg.sender == governance, "Not governance");
        _;
    }

    modifier whenNotPaused() {
        require(!isPaused, "Contract paused");
        _;
    }

    /**
     * @notice Initializes the contract with Sonic-specific parameters and modular integrations.
     */
    function initialize(
        address _stablecoin,
        address _aavePool,
        address _compound,
        address _flyingTulip,
        address _riskManager,
        address _registry,
        address _rwaYield,
        address _governance,
        address _priceFeed
    ) external initializer {
        require(_stablecoin != address(0), "Invalid stablecoin address");
        require(_aavePool != address(0), "Invalid AavePool address");
        require(_compound != address(0), "Invalid Compound address");
        require(_flyingTulip != address(0), "Invalid FlyingTulip address");
        require(_riskManager != address(0), "Invalid RiskManager address");
        require(_registry != address(0), "Invalid Registry address");
        require(_rwaYield != address(0), "Invalid RWAYield address");
        require(_governance != address(0), "Invalid governance address");
        require(_priceFeed != address(0), "Invalid price feed address");

        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();

        stablecoin = IERC20(_stablecoin);
        aavePool = IAaveV3Pool(_aavePool);
        compound = ICompound(_compound);
        flyingTulip = IFlyingTulip(_flyingTulip);
        riskManager = IRiskManager(_riskManager);
        registry = IRegistry(_registry);
        rwaYield = IRWAYield(_rwaYield);
        governance = _governance;
        priceFeed = AggregatorV3Interface(_priceFeed);
    }

    /**
     * @notice Authorizes contract upgrades.
     */
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /**
     * @notice Applies leverage to a protocol with circuit breaker checks.
     */
    function applyLeverage(address protocol, uint256 amount, uint256 ltv, bool isRWA) external onlyGovernance whenNotPaused {
        // Circuit Breaker: RiskManager validation
        require(riskManager.assessLeverageViability(protocol, amount, ltv, isRWA), "Leverage not viable");
        emit CircuitBreakerTriggered("RiskManager validation passed");

        // Circuit Breaker: Price volatility
        require(checkPriceVolatility(), "High price volatility");
        emit CircuitBreakerTriggered("Price volatility check passed");

        // Circuit Breaker: Protocol-specific volatility
        require(checkProtocolVolatility(protocol), "High protocol volatility");
        emit CircuitBreakerTriggered("Protocol volatility check passed");

        // Circuit Breaker: Oracle staleness
        require(checkOracleFreshness(protocol), "Stale oracle data");
        emit CircuitBreakerTriggered("Oracle staleness check passed");

        // Circuit Breaker: Liquidity threshold
        require(checkLiquidity(protocol, isRWA), "Insufficient liquidity");
        emit CircuitBreakerTriggered("Liquidity threshold check passed");

        // Calculate borrow amount
        uint256 borrowAmount = (amount * ltv) / BASIS_POINTS;
        require(borrowAmount > 0, "Invalid borrow amount");

        // Circuit Breaker: Total borrow limit
        require(totalBorrowed + borrowAmount <= MAX_TOTAL_BORROW, "Total borrow limit exceeded");
        emit CircuitBreakerTriggered("Total borrow limit check passed");

        // Circuit Breaker: Protocol-specific borrow limit
        uint256 maxProtocolBorrow = (MAX_TOTAL_BORROW * MAX_PROTOCOL_BORROW_PERCENTAGE) / BASIS_POINTS;
        require(protocolBorrows[protocol] + borrowAmount <= maxProtocolBorrow, "Protocol borrow limit exceeded");
        emit CircuitBreakerTriggered("Protocol borrow limit check passed");

        // Circuit Breaker: Active protocols limit
        bool isNewProtocol = protocolBorrows[protocol] == 0;
        if (isNewProtocol) {
            require(activeProtocolCount < MAX_ACTIVE_PROTOCOLS, "Max active protocols exceeded");
            activeProtocolCount++;
        }
        emit CircuitBreakerTriggered("Active protocols limit check passed");

        // Circuit Breaker: Liquidation risk
        require(checkLiquidationRisk(protocol, amount, borrowAmount, isRWA), "High liquidation risk");
        emit CircuitBreakerTriggered("Liquidation risk check passed");

        // Execute leverage
        if (isRWA) {
            stablecoin.safeApprove(address(flyingTulip), 0);
            stablecoin.safeApprove(address(flyingTulip), borrowAmount);
            flyingTulip.borrowWithLTV(protocol, amount, borrowAmount);
        } else if (protocol == address(aavePool)) {
            (, , uint256 availableBorrowsBase, , , uint256 healthFactor) = aavePool.getUserAccountData(address(this));
            require(healthFactor >= MIN_HEALTH_FACTOR && borrowAmount <= availableBorrowsBase, "Aave borrow invalid");
            stablecoin.safeApprove(protocol, 0);
            stablecoin.safeApprove(protocol, borrowAmount);
            aavePool.borrow(address(stablecoin), borrowAmount, 2, AAVE_REFERRAL_CODE, address(this));
        } else if (protocol == address(compound)) {
            (, uint256 collateralFactor, uint256 liquidity) = compound.getAccountLiquidity(address(this));
            require(collateralFactor >= MIN_COLLATERAL_FACTOR && borrowAmount <= liquidity, "Compound borrow invalid");
            stablecoin.safeApprove(protocol, 0);
            stablecoin.safeApprove(protocol, borrowAmount);
            require(compound.borrow(borrowAmount) == 0, "Compound borrow failed");
        } else {
            revert("Unsupported protocol");
        }

        totalBorrowed += borrowAmount;
        protocolBorrows[protocol] += borrowAmount;
        emit LeverageApplied(protocol, amount, borrowAmount);
    }

    /**
     * @notice Unwinds leverage by repaying borrowed amounts.
     */
    function unwindLeverage(address protocol, uint256 repayAmount, bool isRWA) external onlyGovernance whenNotPaused {
        require(repayAmount <= protocolBorrows[protocol], "Repay amount exceeds borrowed");

        stablecoin.safeApprove(protocol, 0);
        stablecoin.safeApprove(protocol, repayAmount);
        if (isRWA) {
            stablecoin.safeApprove(address(flyingTulip), 0);
            stablecoin.safeApprove(address(flyingTulip), repayAmount);
            flyingTulip.repayBorrow(protocol, repayAmount);
        } else if (protocol == address(aavePool)) {
            aavePool.repay(address(stablecoin), repayAmount, 2, address(this));
        } else if (protocol == address(compound)) {
            require(compound.repayBorrow(repayAmount) == 0, "Compound repay failed");
        } else {
            revert("Unsupported protocol");
        }

        totalBorrowed = totalBorrowed > repayAmount ? totalBorrowed - repayAmount : 0;
        protocolBorrows[protocol] = protocolBorrows[protocol] > repayAmount ? protocolBorrows[protocol] - repayAmount : 0;
        if (protocolBorrows[protocol] == 0) {
            activeProtocolCount = activeProtocolCount > 0 ? activeProtocolCount - 1 : 0;
        }
        emit LeverageUnwound(protocol, repayAmount);
    }

    /**
     * @notice Checks liquidation risk for a protocol.
     */
    function checkLiquidationRisk(address protocol, uint256 collateral, uint256 borrowAmount, bool isRWA) public view returns (bool) {
        if (isRWA) {
            return flyingTulip.isProtocolHealthy(protocol) &&
                   flyingTulip.getLTV(protocol, collateral) <= MAX_LTV &&
                   rwaYield.getAvailableLiquidity(protocol) >= borrowAmount;
        } else if (protocol == address(aavePool)) {
            (, , , , , uint256 healthFactor) = aavePool.getUserAccountData(address(this));
            return healthFactor >= MIN_HEALTH_FACTOR;
        } else if (protocol == address(compound)) {
            (, uint256 collateralFactor, uint256 liquidity) = compound.getAccountLiquidity(address(this));
            return collateralFactor >= MIN_COLLATERAL_FACTOR && liquidity >= borrowAmount;
        }
        return false;
    }

    /**
     * @notice Checks stablecoin price volatility using Chainlink/RedStone feed.
     */
    function checkPriceVolatility() internal returns (bool) {
        (, int256 price, , uint256 updatedAt, ) = priceFeed.latestRoundData();
        require(updatedAt >= block.timestamp - MAX_ORACLE_STALENESS, "Stale price feed");
        if (lastPrice != 0 && lastPriceTimestamp != 0) {
            uint256 priceChange = lastPrice > uint256(price) ? lastPrice - uint256(price) : uint256(price) - lastPrice;
            uint256 volatility = (priceChange * BASIS_POINTS) / lastPrice;
            if (volatility > MAX_PRICE_VOLATILITY) {
                emit CircuitBreakerTriggered("Price volatility exceeded");
                return false;
            }
        }
        lastPrice = uint256(price);
        lastPriceTimestamp = block.timestamp;
        return true;
    }

    /**
     * @notice Checks protocol-specific APY volatility.
     */
    function checkProtocolVolatility(address protocol) internal returns (bool) {
        address feed = registry.getProtocolAPYFeed(protocol);
        if (feed == address(0)) {
            return true; // No feed configured, skip check
        }
        (, int256 apy, , uint256 updatedAt, ) = AggregatorV3Interface(feed).latestRoundData();
        require(updatedAt >= block.timestamp - MAX_ORACLE_STALENESS, "Stale APY feed");
        APYHistory storage history = protocolAPYHistory[protocol];
        if (history.lastAPY != 0 && history.lastTimestamp != 0 && block.timestamp <= history.lastTimestamp + PROTOCOL_VOLATILITY_WINDOW) {
            uint256 apyChange = history.lastAPY > uint256(apy) ? history.lastAPY - uint256(apy) : uint256(apy) - history.lastAPY;
            uint256 volatility = (apyChange * BASIS_POINTS) / history.lastAPY;
            if (volatility > MAX_PROTOCOL_VOLATILITY) {
                emit CircuitBreakerTriggered("Protocol APY volatility exceeded");
                return false;
            }
        }
        history.lastAPY = uint256(apy);
        history.lastTimestamp = block.timestamp;
        return true;
    }

    /**
     * @notice Checks oracle data freshness for a protocol.
     */
    function checkOracleFreshness(address protocol) internal view returns (bool) {
        address feed = registry.getProtocolAPYFeed(protocol);
        if (feed == address(0)) {
            return true; // No feed configured, skip check
        }
        (, , , uint256 updatedAt, ) = AggregatorV3Interface(feed).latestRoundData();
        return block.timestamp <= updatedAt + MAX_ORACLE_STALENESS;
    }

    /**
     * @notice Checks protocol liquidity against minimum threshold.
     */
    function checkLiquidity(address protocol, bool isRWA) internal view returns (bool) {
        uint256 liquidity = isRWA ? rwaYield.getAvailableLiquidity(protocol) : stablecoin.balanceOf(protocol);
        return liquidity >= MIN_LIQUIDITY_THRESHOLD;
    }

    /**
     * @notice Toggles emergency pause for circuit breaker.
     */
    function pause() external onlyGovernance {
        isPaused = true;
        emit Paused(msg.sender);
        emit CircuitBreakerTriggered("Emergency pause activated");
    }

    /**
     * @notice Unpauses the contract.
     */
    function unpause() external onlyGovernance {
        isPaused = false;
        emit Unpaused(msg.sender);
    }

    /**
     * @notice Updates price feed address.
     */
    function setPriceFeed(address _priceFeed) external onlyGovernance {
        require(_priceFeed != address(0), "Invalid price feed");
        priceFeed = AggregatorV3Interface(_priceFeed);
        emit PriceFeedUpdated(_priceFeed);
    }

    /**
     * @notice Updates maximum price volatility threshold.
     */
    function setMaxPriceVolatility(uint256 _volatility) external onlyGovernance {
        require(_volatility <= 1000, "Volatility too high"); // Max 10%
        MAX_PRICE_VOLATILITY = _volatility;
        emit MaxPriceVolatilityUpdated(_volatility);
    }

    /**
     * @notice Updates maximum oracle staleness period.
     */
    function setMaxOracleStaleness(uint256 _staleness) external onlyGovernance {
        require(_staleness >= 5 minutes && _staleness <= 1 hours, "Invalid staleness");
        MAX_ORACLE_STALENESS = _staleness;
        emit MaxOracleStalenessUpdated(_staleness);
    }

    /**
     * @notice Updates minimum liquidity threshold.
     */
    function setMinLiquidityThreshold(uint256 _threshold) external onlyGovernance {
        require(_threshold > 0, "Invalid threshold");
        MIN_LIQUIDITY_THRESHOLD = _threshold;
        emit MinLiquidityThresholdUpdated(_threshold);
    }

    /**
     * @notice Updates maximum total borrow limit.
     */
    function setMaxTotalBorrow(uint256 _max) external onlyGovernance {
        require(_max > 0, "Invalid max borrow");
        MAX_TOTAL_BORROW = _max;
        emit MaxTotalBorrowUpdated(_max);
    }

    /**
     * @notice Updates maximum protocol-specific volatility threshold.
     */
    function setMaxProtocolVolatility(uint256 _volatility) external onlyGovernance {
        require(_volatility <= 2000, "Volatility too high"); // Max 20%
        MAX_PROTOCOL_VOLATILITY = _volatility;
        emit MaxProtocolVolatilityUpdated(_volatility);
    }

    /**
     * @notice Updates protocol volatility time window.
     */
    function setProtocolVolatilityWindow(uint256 _window) external onlyGovernance {
        require(_window >= 15 minutes && _window <= 24 hours, "Invalid window");
        PROTOCOL_VOLATILITY_WINDOW = _window;
        emit ProtocolVolatilityWindowUpdated(_window);
    }

    /**
     * @notice Updates maximum protocol borrow percentage.
     */
    function setMaxProtocolBorrowPercentage(uint256 _percentage) external onlyGovernance {
        require(_percentage <= 5000, "Percentage too high"); // Max 50%
        MAX_PROTOCOL_BORROW_PERCENTAGE = _percentage;
        emit MaxProtocolBorrowPercentageUpdated(_percentage);
    }

    /**
     * @notice Updates maximum active protocols.
     */
    function setMaxActiveProtocols(uint256 _max) external onlyGovernance {
        require(_max >= 1 && _max <= 10, "Invalid max protocols");
        MAX_ACTIVE_PROTOCOLS = _max;
        emit MaxActiveProtocolsUpdated(_max);
    }

    /**
     * @notice Fallback function to prevent accidental ETH deposits.
     */
    receive() external payable {
        revert("ETH deposits not allowed");
    }
}
