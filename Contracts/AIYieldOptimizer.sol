// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// OpenZeppelin imports
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

// Chainlink imports
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";

// Interfaces
interface IRWAYield {
    function depositToRWA(address protocol, uint256 amount) external;
    function withdrawFromRWA(address protocol, uint256 amount) external returns (uint256);
    function isRWA(address protocol) external view returns (bool);
    function getRWAYield(address protocol) external returns (uint256);
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
    function borrowWithLTV(address pool, uint256 collateral, uint256 borrowAmount) external;
    function repayBorrow(address pool, uint256 amount) external;
    function isProtocolHealthy(address pool) external view returns (bool);
}

/**
 * @title AIYieldOptimizer
 * @dev A delegated contract for AI-driven RWA yield optimization within YieldOptimizer.sol,
 *      integrated with Sonic Blockchain features, governance, leverage, Chainlink Automation,
 *      and advanced AI-driven allocation strategies with dynamic risk assessment.
 */
contract AIYieldOptimizer is ReentrancyGuard, AutomationCompatibleInterface {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // State variables
    IERC20 public immutable stablecoin; // Sonic’s native USDC
    IERC20 public immutable sonicPointsToken; // Sonic Points for airdrop
    IRWAYield public immutable rwaYield; // RWAYield contract
    ISonicProtocol public immutable sonicProtocol; // Sonic compliance and APY
    IFlyingTulip public immutable flyingTulip; // FlyingTulip for leverage
    address public governance; // Multi-sig or DAO
    address public feeRecipient; // Receives Fee Monetization rewards
    address public aiOracle; // Address for AI allocation recommendations
    uint256 public feeMonetizationShare; // Sonic FeeM share (default 90%)
    uint256 public totalFeeMonetizationRewards; // Accumulated FeeM rewards
    mapping(address => uint256) public sonicPointsEarned; // User airdrop points
    mapping(address => uint256) public rwaBalances; // Balances in each RWA protocol
    uint256 public totalRWABalance; // Total stablecoins allocated to RWAs
    address[] public supportedProtocols; // List of supported RWA protocols
    mapping(address => bool) public isSupportedProtocol; // Track supported protocols
    mapping(address => AggregatorV3Interface) public protocolAPYFeeds; // Chainlink/RedStone feeds
    mapping(address => Allocation) public allocations; // Protocol allocations
    bool public allowLeverage; // Toggle for leverage support
    uint256 public lastUpkeepTimestamp; // Last Chainlink upkeep
    uint256 public volatilityTolerance; // Basis points (e.g., 1000 = 10% max volatility)
    mapping(address => uint256) public protocolVolatility; // Protocol-specific volatility score

    // Governance timelock actions
    struct TimelockAction {
        bytes32 actionHash;
        uint256 timestamp;
    }
    mapping(bytes32 => TimelockAction) public timelockActions;

    // Constants
    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant UPKEEP_INTERVAL = 1 days; // Chainlink Automation interval
    uint256 private constant TIMELOCK_DELAY = 2 days; // Timelock for critical actions
    uint256 private constant MAX_PROTOCOLS = 10; // Max supported protocols
    uint256 private constant MAX_LTV = 8000; // 80% LTV cap
    uint256 private constant MAX_BORROW_AMOUNT = 1e24; // 1M stablecoin units
    uint256 private constant MAX_STALENESS = 30 minutes; // Chainlink feed staleness
    uint256 private constant MAX_APY = 10000; // 100% max APY

    // Allocation struct
    struct Allocation {
        address protocol;
        uint256 amount;
        uint256 apy; // Basis points
        uint256 lastUpdated;
        bool isLeveraged;
    }

    // Events
    event DepositRWA(address indexed protocol, uint256 amount, bool isLeveraged);
    event WithdrawRWA(address indexed protocol, uint256 amount, uint256 profit);
    event RWAYieldUpdated(address indexed protocol, uint256 apy);
    event AIAllocationUpdated(address indexed protocol, uint256 amount);
    event ProtocolAdded(address indexed protocol);
    event ProtocolRemoved(address indexed protocol);
    event AIOracleUpdated(address indexed newOracle);
    event GovernanceUpdated(address indexed newGovernance);
    event FeeRecipientUpdated(address indexed newRecipient);
    event LeverageToggled(bool status);
    event LTVBorrow(address indexed protocol, uint256 collateral, uint256 borrowAmount);
    event LTVRepaid(address indexed protocol, uint256 amount);
    event SonicPointsClaimed(address indexed user, uint256 points);
    event FeeMonetizationRewardsClaimed(uint256 amount);
    event TimelockActionProposed(bytes32 indexed actionHash, uint256 timestamp);
    event TimelockActionExecuted(bytes32 indexed actionHash);
    event ManualUpkeepTriggered(uint256 timestamp);
    event AIVolatilityAssessmentUpdated(address indexed protocol, uint256 volatilityScore);
    event AIRecommendedAllocation(address indexed protocol, uint256 amount, bool isLeveraged);

    // Modifiers
    modifier onlyGovernance() {
        require(msg.sender == governance, "Not governance");
        _;
    }

    modifier onlyAIOracle() {
        require(msg.sender == aiOracle, "Not AI Oracle");
        _;
    }

    modifier sonicFeeMonetization() {
        uint256 gasUsed = gasleft();
        _;
        uint256 feeShare = ((gasUsed - gasleft()) * tx.gasprice * feeMonetizationShare) / 100;
        totalFeeMonetizationRewards += feeShare;
    }

    /**
     * @dev Constructor initializes contract with dependencies
     * @param _stablecoin Sonic’s native USDC address
     * @param _sonicPointsToken Sonic Points token address
     * @param _rwaYield RWAYield contract address
     * @param _sonicProtocol Sonic protocol compliance contract
     * @param _flyingTulip FlyingTulip contract for leverage
     * @param _governance Governance address (multi-sig/DAO)
     * @param _feeRecipient Fee recipient address
     * @param _aiOracle Initial AI Oracle address
     */
    constructor(
        address _stablecoin,
        address _sonicPointsToken,
        address _rwaYield,
        address _sonicProtocol,
        address _flyingTulip,
        address _governance,
        address _feeRecipient,
        address _aiOracle
    ) {
        require(_stablecoin != address(0), "Invalid stablecoin address");
        require(_sonicPointsToken != address(0), "Invalid SonicPointsToken address");
        require(_rwaYield != address(0), "Invalid RWAYield address");
        require(_sonicProtocol != address(0), "Invalid SonicProtocol address");
        require(_flyingTulip != address(0), "Invalid FlyingTulip address");
        require(_governance != address(0), "Invalid governance address");
        require(_feeRecipient != address(0), "Invalid fee recipient");
        require(_aiOracle != address(0), "Invalid AI Oracle address");

        stablecoin = IERC20(_stablecoin);
        sonicPointsToken = IERC20(_sonicPointsToken);
        rwaYield = IRWAYield(_rwaYield);
        sonicProtocol = ISonicProtocol(_sonicProtocol);
        flyingTulip = IFlyingTulip(_flyingTulip);
        governance = _governance;
        feeRecipient = _feeRecipient;
        aiOracle = _aiOracle;
        feeMonetizationShare = 90; // 90% for Sonic FeeM
        allowLeverage = false;
        lastUpkeepTimestamp = block.timestamp;
        volatilityTolerance = 1000; // 10% default volatility tolerance
    }

    /**
     * @dev Sets volatility tolerance for AI-driven allocations
     * @param _volatilityTolerance Volatility tolerance in basis points (max 20%)
     */
    function setVolatilityTolerance(uint256 _volatilityTolerance) external onlyGovernance sonicFeeMonetization {
        require(_volatilityTolerance <= 2000, "Volatility tolerance too high"); // Max 20%
        volatilityTolerance = _volatilityTolerance;
    }

    /**
     * @dev Updates protocol volatility score based on AI assessment
     * @param protocol RWA protocol address
     * @param volatilityScore Volatility score in basis points
     */
    function updateProtocolVolatility(address protocol, uint256 volatilityScore) external onlyGovernance sonicFeeMonetization {
        require(isSupportedProtocol[protocol], "Unsupported protocol");
        require(volatilityScore <= 10000, "Invalid volatility score");
        protocolVolatility[protocol] = volatilityScore;
        emit AIVolatilityAssessmentUpdated(protocol, volatilityScore);
    }

    /**
     * @dev Proposes adding a new RWA protocol with timelock
     * @param protocol Address of the RWA protocol
     * @param apyFeed Chainlink/RedStone APY feed address
     */
    function proposeAddProtocol(address protocol, address apyFeed) external onlyGovernance sonicFeeMonetization {
        require(protocol != address(0), "Invalid protocol address");
        require(apyFeed != address(0), "Invalid APY feed address");
        require(!isSupportedProtocol[protocol], "Protocol already supported");
        require(rwaYield.isRWA(protocol), "Not an RWA protocol");
        require(sonicProtocol.isSonicCompliant(protocol), "Protocol not Sonic compliant");
        require(supportedProtocols.length < MAX_PROTOCOLS, "Max protocols reached");

        bytes32 actionHash = keccak256(abi.encode("addProtocol", protocol, apyFeed));
        timelockActions[actionHash] = TimelockAction(actionHash, block.timestamp + TIMELOCK_DELAY);
        emit TimelockActionProposed(actionHash, block.timestamp + TIMELOCK_DELAY);
    }

    /**
     * @dev Executes adding a new RWA protocol after timelock
     * @param protocol Address of the RWA protocol
     * @param apyFeed Chainlink/RedStone APY feed address
     */
    function executeAddProtocol(address protocol, address apyFeed) external onlyGovernance nonReentrant sonicFeeMonetization {
        bytes32 actionHash = keccak256(abi.encode("addProtocol", protocol, apyFeed));
        TimelockAction memory action = timelockActions[actionHash];
        require(action.timestamp > 0 && block.timestamp >= action.timestamp, "Timelock not elapsed");

        supportedProtocols.push(protocol);
        isSupportedProtocol[protocol] = true;
        protocolAPYFeeds[protocol] = AggregatorV3Interface(apyFeed);
        protocolVolatility[protocol] = 5000; // Default 50% volatility score
        delete timelockActions[actionHash];

        emit ProtocolAdded(protocol);
        emit TimelockActionExecuted(actionHash);
    }

    /**
     * @dev Proposes removing an RWA protocol with timelock
     * @param protocol Address of the RWA protocol
     */
    function proposeRemoveProtocol(address protocol) external onlyGovernance sonicFeeMonetization {
        require(isSupportedProtocol[protocol], "Protocol not supported");
        require(rwaBalances[protocol] == 0, "Withdraw funds first");

        bytes32 actionHash = keccak256(abi.encode("removeProtocol", protocol));
        timelockActions[actionHash] = TimelockAction(actionHash, block.timestamp + TIMELOCK_DELAY);
        emit TimelockActionProposed(actionHash, block.timestamp + TIMELOCK_DELAY);
    }

    /**
     * @dev Executes removing an RWA protocol after timelock
     * @param protocol Address of the RWA protocol
     */
    function executeRemoveProtocol(address protocol) external onlyGovernance nonReentrant sonicFeeMonetization {
        bytes32 actionHash = keccak256(abi.encode("removeProtocol", protocol));
        TimelockAction memory action = timelockActions[actionHash];
        require(action.timestamp > 0 && block.timestamp >= action.timestamp, "Timelock not elapsed");

        isSupportedProtocol[protocol] = false;
        delete protocolAPYFeeds[protocol];
        delete protocolVolatility[protocol];
        delete allocations[protocol];

        for (uint256 i = 0; i < supportedProtocols.length; i++) {
            if (supportedProtocols[i] == protocol) {
                supportedProtocols[i] = supportedProtocols[supportedProtocols.length - 1];
                supportedProtocols.pop();
                break;
            }
        }

        delete timelockActions[actionHash];
        emit ProtocolRemoved(protocol);
        emit TimelockActionExecuted(actionHash);
    }

    /**
     * @dev Proposes updating the AI Oracle address with timelock
     * @param newOracle New AI Oracle address
     */
    function proposeUpdateAIOracle(address newOracle) external onlyGovernance sonicFeeMonetization {
        require(newOracle != address(0), "Invalid AI Oracle address");

        bytes32 actionHash = keccak256(abi.encode("updateAIOracle", newOracle));
        timelockActions[actionHash] = TimelockAction(actionHash, block.timestamp + TIMELOCK_DELAY);
        emit TimelockActionProposed(actionHash, block.timestamp + TIMELOCK_DELAY);
    }

    /**
     * @dev Executes updating the AI Oracle address after timelock
     * @param newOracle New AI Oracle address
     */
    function executeUpdateAIOracle(address newOracle) external onlyGovernance nonReentrant sonicFeeMonetization {
        bytes32 actionHash = keccak256(abi.encode("updateAIOracle", newOracle));
        TimelockAction memory action = timelockActions[actionHash];
        require(action.timestamp > 0 && block.timestamp >= action.timestamp, "Timelock not elapsed");

        aiOracle = newOracle;
        delete timelockActions[actionHash];

        emit AIOracleUpdated(newOracle);
        emit TimelockActionExecuted(actionHash);
    }

    /**
     * @dev Proposes updating the governance address with timelock
     * @param newGovernance New governance address
     */
    function proposeUpdateGovernance(address newGovernance) external onlyGovernance sonicFeeMonetization {
        require(newGovernance != address(0), "Invalid governance address");

        bytes32 actionHash = keccak256(abi.encode("updateGovernance", newGovernance));
        timelockActions[actionHash] = TimelockAction(actionHash, block.timestamp + TIMELOCK_DELAY);
        emit TimelockActionProposed(actionHash, block.timestamp + TIMELOCK_DELAY);
    }

    /**
     * @dev Executes updating the governance address after timelock
     * @param newGovernance New governance address
     */
    function executeUpdateGovernance(address newGovernance) external onlyGovernance nonReentrant sonicFeeMonetization {
        bytes32 actionHash = keccak256(abi.encode("updateGovernance", newGovernance));
        TimelockAction memory action = timelockActions[actionHash];
        require(action.timestamp > 0 && block.timestamp >= action.timestamp, "Timelock not elapsed");

        governance = newGovernance;
        delete timelockActions[actionHash];

        emit GovernanceUpdated(newGovernance);
        emit TimelockActionExecuted(actionHash);
    }

    /**
     * @dev Proposes updating the fee recipient address with timelock
     * @param newRecipient New fee recipient address
     */
    function proposeUpdateFeeRecipient(address newRecipient) external onlyGovernance sonicFeeMonetization {
        require(newRecipient != address(0), "Invalid fee recipient");

        bytes32 actionHash = keccak256(abi.encode("updateFeeRecipient", newRecipient));
        timelockActions[actionHash] = TimelockAction(actionHash, block.timestamp + TIMELOCK_DELAY);
        emit TimelockActionProposed(actionHash, block.timestamp + TIMELOCK_DELAY);
    }

    /**
     * @dev Executes updating the fee recipient address after timelock
     * @param newRecipient New fee recipient address
     */
    function executeUpdateFeeRecipient(address newRecipient) external onlyGovernance nonReentrant sonicFeeMonetization {
        bytes32 actionHash = keccak256(abi.encode("updateFeeRecipient", newRecipient));
        TimelockAction memory action = timelockActions[actionHash];
        require(action.timestamp > 0 && block.timestamp >= action.timestamp, "Timelock not elapsed");

        feeRecipient = newRecipient;
        delete timelockActions[actionHash];

        emit FeeRecipientUpdated(newRecipient);
        emit TimelockActionExecuted(actionHash);
    }

    /**
     * @dev AI Oracle submits allocation recommendations
     * @param protocols Array of RWA protocols
     * @param amounts Array of amounts to allocate
     * @param isLeveraged Array indicating if leverage is used
     */
    function submitAIAllocation(
        address[] calldata protocols,
        uint256[] calldata amounts,
        bool[] calldata isLeveraged
    ) external onlyAIOracle nonReentrant sonicFeeMonetization {
        require(protocols.length == amounts.length && protocols.length == isLeveraged.length, "Mismatched arrays");
        require(protocols.length <= supportedProtocols.length, "Too many protocols");

        uint256 totalAmount;
        for (uint256 i = 0; i < protocols.length; i++) {
            require(isSupportedProtocol[protocols[i]], "Unsupported protocol");
            require(sonicProtocol.isSonicCompliant(protocols[i]), "Protocol not Sonic compliant");
            require(flyingTulip.isProtocolHealthy(protocols[i]), "Protocol not healthy");
            require(protocolVolatility[protocols[i]] <= volatilityTolerance, "Protocol too volatile");
            totalAmount = totalAmount.add(amounts[i]);
        }
        require(totalAmount <= stablecoin.balanceOf(address(this)), "Insufficient balance");

        // Execute allocations
        for (uint256 i = 0; i < protocols.length; i++) {
            if (amounts[i] > 0) {
                _depositToRWA(protocols[i], amounts[i], isLeveraged[i] && allowLeverage);
                allocations[protocols[i]] = Allocation(
                    protocols[i],
                    amounts[i],
                    rwaYield.getRWAYield(protocols[i]),
                    block.timestamp,
                    isLeveraged[i] && allowLeverage
                );
                sonicPointsEarned[msg.sender] += amounts[i] * 2; // 2x points for allocation
                emit AIAllocationUpdated(protocols[i], amounts[i]);
                emit AIRecommendedAllocation(protocols[i], amounts[i], isLeveraged[i] && allowLeverage);
            }
        }
    }

    /**
     * @dev Internal function to deposit to RWA protocol with optional leverage
     * @param protocol RWA protocol address
     * @param amount Amount to deposit
     * @param isLeveraged Whether to use leverage
     */
    function _depositToRWA(address protocol, uint256 amount, bool isLeveraged) internal {
        stablecoin.safeApprove(protocol, 0);
        stablecoin.safeApprove(protocol, amount);
        rwaYield.depositToRWA(protocol, amount);
        rwaBalances[protocol] = rwaBalances[protocol].add(amount);
        totalRWABalance = totalRWABalance.add(amount);

        if (isLeveraged && _assessLeverageViability(protocol, amount)) {
            uint256 ltv = flyingTulip.getLTV(protocol, amount);
            ltv = ltv > MAX_LTV ? MAX_LTV : ltv;
            uint256 borrowAmount = (amount * ltv) / BASIS_POINTS;
            if (borrowAmount > 0 && borrowAmount <= MAX_BORROW_AMOUNT && _checkLiquidationRisk(protocol, amount, borrowAmount)) {
                stablecoin.safeApprove(address(flyingTulip), 0);
                stablecoin.safeApprove(address(flyingTulip), borrowAmount);
                flyingTulip.borrowWithLTV(protocol, amount, borrowAmount);
                emit LTVBorrow(protocol, amount, borrowAmount);
            } else {
                isLeveraged = false; // Disable leverage if risk check fails
            }
        } else {
            isLeveraged = false; // Disable leverage if viability check fails
        }

        emit DepositRWA(protocol, amount, isLeveraged);
    }

    /**
     * @dev Withdraws from RWA protocol with leverage repayment
     * @param protocol RWA protocol address
     * @param amount Amount to withdraw
     * @return Total withdrawn amount (principal + profit)
     */
    function withdrawFromRWA(address protocol, uint256 amount)
        external
        onlyGovernance
        nonReentrant
        sonicFeeMonetization
        returns (uint256)
    {
        require(isSupportedProtocol[protocol], "Unsupported protocol");
        require(amount > 0 && amount <= rwaBalances[protocol], "Invalid amount");

        Allocation storage alloc = allocations[protocol];
        uint256 repayAmount;
        if (alloc.isLeveraged) {
            repayAmount = (amount * flyingTulip.getLTV(protocol, amount)) / BASIS_POINTS;
            if (stablecoin.balanceOf(address(this)) < repayAmount) {
                _withdrawForRepayment(repayAmount);
            }
            stablecoin.safeApprove(address(flyingTulip), 0);
            stablecoin.safeApprove(address(flyingTulip), repayAmount);
            flyingTulip.repayBorrow(protocol, repayAmount);
            emit LTVRepaid(protocol, repayAmount);
            alloc.isLeveraged = false;
        }

        uint256 withdrawn = rwaYield.withdrawFromRWA(protocol, amount);
        uint256 profit = withdrawn > amount ? withdrawn.sub(amount) : 0;

        rwaBalances[protocol] = rwaBalances[protocol].sub(amount);
        totalRWABalance = totalRWABalance.sub(amount);
        alloc.amount = alloc.amount.sub(amount);
        if (alloc.amount == 0) {
            delete allocations[protocol];
        }

        sonicPointsEarned[msg.sender] += amount; // 1x points for withdrawal
        emit WithdrawRWA(protocol, amount, profit);
        return withdrawn;
    }

    /**
     * @dev Rebalances portfolio based on AI recommendations
     * @param protocols Array of RWA protocols
     * @param amounts Array of amounts to allocate
     * @param isLeveraged Array indicating if leverage is used
     */
    function rebalancePortfolio(
        address[] calldata protocols,
        uint256[] calldata amounts,
        bool[] calldata isLeveraged
    ) external onlyAIOracle nonReentrant sonicFeeMonetization {
        require(protocols.length == amounts.length && protocols.length == isLeveraged.length, "Mismatched arrays");

        // Withdraw from all protocols
        for (uint256 i = 0; i < supportedProtocols.length; i++) {
            address protocol = supportedProtocols[i];
            if (rwaBalances[protocol] > 0) {
                withdrawFromRWA(protocol, rwaBalances[protocol]);
            }
        }

        // Reallocate based on AI recommendations
        for (uint256 i = 0; i < protocols.length; i++) {
            if (amounts[i] > 0) {
                _depositToRWA(protocols[i], amounts[i], isLeveraged[i] && allowLeverage);
                allocations[protocols[i]] = Allocation(
                    protocols[i],
                    amounts[i],
                    rwaYield.getRWAYield(protocols[i]),
                    block.timestamp,
                    isLeveraged[i] && allowLeverage
                );
                sonicPointsEarned[msg.sender] += amounts[i] * 2; // 2x points for reallocation
                emit AIAllocationUpdated(protocols[i], amounts[i]);
                emit AIRecommendedAllocation(protocols[i], amounts[i], isLeveraged[i] && allowLeverage);
            }
        }
    }

    /**
     * @dev Toggles leverage support
     * @param status Whether to allow leverage
     */
    function toggleLeverage(bool status) external onlyGovernance sonicFeeMonetization {
        allowLeverage = status;
        emit LeverageToggled(status);
    }

    /**
     * @dev Claims Sonic Fee Monetization rewards
     */
    function claimFeeMonetizationRewards() external onlyGovernance nonReentrant sonicFeeMonetization {
        uint256 rewards = totalFeeMonetizationRewards;
        require(rewards > 0, "No rewards available");
        totalFeeMonetizationRewards = 0;
        stablecoin.safeTransfer(feeRecipient, rewards);
        emit FeeMonetizationRewardsClaimed(rewards);
    }

    /**
     * @dev Claims Sonic Points for airdrop eligibility
     * @param user User address
     */
    function claimSonicPoints(address user) external nonReentrant sonicFeeMonetization {
        uint256 points = sonicPointsEarned[user];
        require(points > 0, "No points earned");
        sonicPointsEarned[user] = 0;
        sonicPointsToken.safeTransfer(user, points);
        emit SonicPointsClaimed(user, points);
    }

    /**
     * @dev Retrieves APY for all supported protocols
     * @return protocols Array of protocols
     * @return apys Array of APYs in basis points
     */
    function getAllYields() public returns (address[] memory, uint256[] memory) {
        uint256[] memory apys = new uint256[](supportedProtocols.length);
        for (uint256 i = 0; i < supportedProtocols.length; i++) {
            address protocol = supportedProtocols[i];
            AggregatorV3Interface feed = protocolAPYFeeds[protocol];
            if (address(feed) != address(0)) {
                try feed.latestRoundData() returns (uint80, int256 answer, , uint256 updatedAt, uint80) {
                    if (answer > 0 && block.timestamp <= updatedAt + MAX_STALENESS && uint256(answer) <= MAX_APY) {
                        apys[i] = uint256(answer);
                    } else {
                        apys[i] = sonicProtocol.getSonicAPY(protocol);
                    }
                } catch {
                    apys[i] = sonicProtocol.getSonicAPY(protocol);
                }
            } else {
                apys[i] = sonicProtocol.getSonicAPY(protocol);
            }
            emit RWAYieldUpdated(protocol, apys[i]);
        }
        return (supportedProtocols, apys);
    }

    /**
     * @dev Withdraws funds to cover repayment needs
     * @param amount Amount to withdraw
     */
    function _withdrawForRepayment(uint256 amount) internal nonReentrant {
        uint256 totalWithdrawn;
        for (uint256 i = 0; i < supportedProtocols.length && totalWithdrawn < amount; i++) {
            address protocol = supportedProtocols[i];
            if (rwaBalances[protocol] > 0) {
                uint256 withdrawAmount = amount.sub(totalWithdrawn);
                withdrawAmount = withdrawAmount > rwaBalances[protocol] ? rwaBalances[protocol] : withdrawAmount;
                uint256 withdrawn = withdrawFromRWA(protocol, withdrawAmount);
                totalWithdrawn = totalWithdrawn.add(withdrawn);
            }
        }
        require(totalWithdrawn >= amount, "Insufficient funds withdrawn");
    }

    /**
     * @dev Checks liquidation risk for leveraged positions
     * @param protocol Protocol address
     * @param collateral Collateral amount
     * @param borrowAmount Borrow amount
     * @return True if safe
     */
    function _checkLiquidationRisk(address protocol, uint256 collateral, uint256 borrowAmount) internal view returns (bool) {
        return flyingTulip.isProtocolHealthy(protocol) &&
               flyingTulip.getLTV(protocol, collateral) <= MAX_LTV &&
               rwaYield.getAvailableLiquidity(protocol) >= borrowAmount;
    }

    /**
     * @dev Assesses leverage viability for RWA protocols
     * @param protocol RWA protocol address
     * @param amount Amount to deposit
     * @return True if leverage is viable
     */
    function _assessLeverageViability(address protocol, uint256 amount) internal view returns (bool) {
        uint256 ltv = flyingTulip.getLTV(protocol, amount);
        uint256 volatility = protocolVolatility[protocol] > 0 ? protocolVolatility[protocol] : 5000; // Default 50%
        return volatility < 7000 && // Max 70% volatility
               ltv <= MAX_LTV &&
               _checkLiquidationRisk(protocol, amount, (amount * ltv) / BASIS_POINTS);
    }

    /**
     * @dev AI-driven allocation recommendations with volatility adjustment
     * @param totalAmount Total amount to allocate
     * @return protocols Array of recommended protocols
     * @return amounts Array of recommended amounts
     * @return isLeveraged Array indicating leverage use
     */
    function getRecommendedAllocations(uint256 totalAmount)
        external
        returns (address[] memory protocols, uint256[] memory amounts, bool[] memory isLeveraged)
    {
        (address[] memory allProtocols, uint256[] memory apys) = getAllYields();
        protocols = new address[](allProtocols.length);
        amounts = new uint256[](allProtocols.length);
        isLeveraged = new bool[](allProtocols.length);
        uint256 totalWeightedAPY;

        // Calculate volatility-adjusted weights
        uint256[] memory weights = new uint256[](allProtocols.length);
        for (uint256 i = 0; i < allProtocols.length; i++) {
            uint256 volatility = protocolVolatility[allProtocols[i]] > 0 ? protocolVolatility[allProtocols[i]] : 5000; // Default 50%
            if (volatility > volatilityTolerance) {
                continue;
            }
            uint256 adjustedAPY = (apys[i] * (10000 - volatility)) / 10000;
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
            if (amount < 1e16) { // Minimum allocation threshold (0.01 stablecoin units)
                continue;
            }
            protocols[index] = allProtocols[i];
            amounts[index] = amount;
            isLeveraged[index] = allowLeverage && _assessLeverageViability(allProtocols[i], amount);
            allocated += amount;
            if (msg.sender == aiOracle) {
                emit AIRecommendedAllocation(allProtocols[i], amount, isLeveraged[index]);
            }
            index++;
        }

        // Resize arrays to remove unused slots
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
     * @dev Returns active allocations
     * @return Array of Allocation structs
     */
    function getAllocations() external view returns (Allocation[] memory) {
        Allocation[] memory result = new Allocation[](supportedProtocols.length);
        for (uint256 i = 0; i < supportedProtocols.length; i++) {
            result[i] = allocations[supportedProtocols[i]];
        }
        return result;
    }

    /**
     * @dev Checks if upkeep is needed for Chainlink Automation
     * @param checkData Additional data (unused)
     * @return upkeepNeeded Whether upkeep is needed
     * @return performData Data to pass to performUpkeep
     */
    function checkUpkeep(bytes calldata checkData)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        upkeepNeeded = block.timestamp >= lastUpkeepTimestamp + UPKEEP_INTERVAL;
        performData = checkData;
        return (upkeepNeeded, performData);
    }

    /**
     * @dev Performs upkeep to update APYs
     * @param performData Additional data (unused)
     */
    function performUpkeep(bytes calldata performData) external override sonicFeeMonetization {
        require(block.timestamp >= lastUpkeepTimestamp + UPKEEP_INTERVAL, "Upkeep not yet due");
        lastUpkeepTimestamp = block.timestamp;
        getAllYields(); // Update APYs
        emit ManualUpkeepTriggered(block.timestamp);
    }

    /**
     * @dev Manual upkeep triggered by governance
     */
    function manualUpkeep() external onlyGovernance sonicFeeMonetization {
        lastUpkeepTimestamp = block.timestamp;
        getAllYields();
        emit ManualUpkeepTriggered(block.timestamp);
    }

    /**
     * @dev Returns total RWA balance
     * @return Total stablecoins in RWA
     */
    function getTotalRWABalance() external view returns (uint256) {
        return totalRWABalance;
    }

    /**
     * @dev Returns supported protocols
     * @return Array of supported protocol addresses
     */
    function getSupportedProtocols() external view returns (address[] memory) {
        return supportedProtocols;
    }
}
