// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

interface ISonicProtocol {
    function depositFeeMonetizationRewards(address recipient, uint256 amount) external returns (bool);
    function depositGasFees(address recipient, uint256 amount) external returns (bool);
}

interface IPointsTierManager {
    function assignTier(address user, uint256 totalAmount, bool hasLockup, uint256 maxLockupDays) external;
    function getUserMultiplier(address user) external view returns (uint256);
}

interface ISwapRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

/**
 * @title StakingManager
 * @notice Manages Sonic Points and reward distribution with USDC to $S conversion.
 */
contract StakingManager is UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    IERC20 public sonicSToken;
    IERC20 public usdcToken;
    ISonicProtocol public sonicProtocol;
    IPointsTierManager public pointsTierManager;
    ISwapRouter public swapRouter;
    AggregatorV3Interface public priceFeed;
    address public governance;
    address public yieldOptimizer;
    uint256 public totalFeeMonetizationRewards;
    uint256 public totalPoints;
    mapping(address => uint256) public userPoints;
    mapping(address => uint256) public claimableRewards;
    uint256 public constant POINTS_TO_TOKEN_RATE = 1e16; // 1 point = 0.01 $S
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public maxSlippage; // Configurable slippage (e.g., 500 = 5%)
    uint256 public fallbackRate; // Fallback USDC/$S rate (e.g., 1e12 for 1:1)
    uint256 public lastValidPrice; // Last valid Chainlink price
    uint256 public maxBatchSize; // Max deposits per batch processing

    // Batch deposit tracking
    struct BatchDeposit {
        uint256 amount;
        string source;
    }
    BatchDeposit[] public pendingDeposits;

    // Events
    event PointsAwarded(address indexed user, uint256 totalAmount, uint256 points, bool isDeposit);
    event RewardsDeposited(address indexed sender, uint256 amount, string source);
    event GasFeesDeposited(address indexed sender, uint256 amount);
    event SonicGemsDeposited(address indexed sender, uint256 amount);
    event RewardsClaimed(address indexed recipient, uint256 amount);
    event PointsClaimed(address indexed user, uint256 points, uint256 tokens);
    event TokenConverted(address indexed tokenIn, uint256 amountIn, uint256 amountOut, bool usedFallback);
    event BatchDepositsProcessed(uint256 totalAmount, uint256 batchSize);
    event PointsTierManagerUpdated(address indexed newPointsTierManager);
    event YieldOptimizerUpdated(address indexed newYieldOptimizer);
    event GovernanceUpdated(address indexed newGovernance);
    event SwapRouterUpdated(address indexed newSwapRouter);
    event PriceFeedUpdated(address indexed newPriceFeed);
    event MaxSlippageUpdated(uint256 newSlippage);
    event FallbackRateUpdated(uint256 newRate);
    event MaxBatchSizeUpdated(uint256 newSize);

    // Modifiers
    modifier onlyGovernance() {
        require(msg.sender == governance, "Not governance");
        _;
    }

    modifier onlyYieldOptimizer() {
        require(msg.sender == yieldOptimizer, "Only YieldOptimizer");
        _;
    }

    /**
     * @notice Initializes the contract.
     */
    function initialize(
        address _sonicSToken,
        address _usdcToken,
        address _sonicProtocol,
        address _pointsTierManager,
        address _yieldOptimizer,
        address _governance,
        address _swapRouter,
        address _priceFeed
    ) external initializer {
        require(_sonicSToken != address(0), "Invalid sonicSToken address");
        require(_usdcToken != address(0), "Invalid usdcToken address");
        require(_sonicProtocol != address(0), "Invalid sonicProtocol address");
        require(_pointsTierManager != address(0), "Invalid pointsTierManager address");
        require(_yieldOptimizer != address(0), "Invalid yieldOptimizer address");
        require(_governance != address(0), "Invalid governance address");
        require(_swapRouter != address(0), "Invalid swapRouter address");
        require(_priceFeed != address(0), "Invalid priceFeed address");

        __Ownable_init(msg.sender);
        __Pausable_init();
        __UUPSUpgradeable_init();
        sonicSToken = IERC20(_sonicSToken);
        usdcToken = IERC20(_usdcToken);
        sonicProtocol = ISonicProtocol(_sonicProtocol);
        pointsTierManager = IPointsTierManager(_pointsTierManager);
        yieldOptimizer = _yieldOptimizer;
        governance = _governance;
        swapRouter = ISwapRouter(_swapRouter);
        priceFeed = AggregatorV3Interface(_priceFeed);
        maxSlippage = 500; // 5%
        fallbackRate = 1e12; // 1 USDC = 1 $S (6 decimals to 18 decimals)
        lastValidPrice = 1e8; // Default 1:1 price (8 decimals)
        maxBatchSize = 100; // Max 100 deposits per batch
    }

    /**
     * @notice Deposits rewards, converting USDC to $S if needed.
     */
    function depositRewards(uint256 amount, address token) external whenNotPaused {
        require(amount > 0, "Invalid amount");
        uint256 sAmount;

        if (token == address(sonicSToken)) {
            sonicSToken.safeTransferFrom(msg.sender, address(this), amount);
            sAmount = amount;
        } else if (token == address(usdcToken)) {
            usdcToken.safeTransferFrom(msg.sender, address(this), amount);
            sAmount = _convertUsdcToS(amount);
        } else {
            revert("Unsupported token");
        }

        pendingDeposits.push(BatchDeposit({amount: sAmount, source: "ProtocolFee"}));
        emit RewardsDeposited(msg.sender, sAmount, "ProtocolFee");
    }

    /**
     * @notice Deposits gas fees in $S.
     */
    function depositGasFees(uint256 amount) external whenNotPaused {
        require(amount > 0, "Invalid amount");
        sonicSToken.safeTransferFrom(msg.sender, address(this), amount);
        pendingDeposits.push(BatchDeposit({amount: amount, source: "GasFees"}));
        emit GasFeesDeposited(msg.sender, amount);
    }

    /**
     * @notice Deposits Sonic Gems in $S.
     */
    function depositSonicGems(uint256 amount) external onlyOwner whenNotPaused {
        require(amount > 0, "Invalid amount");
        sonicSToken.safeTransferFrom(msg.sender, address(this), amount);
        pendingDeposits.push(BatchDeposit({amount: amount, source: "SonicGems"}));
        emit SonicGemsDeposited(msg.sender, amount);
    }

    /**
     * @notice Processes batched reward deposits with gas limits.
     */
    function processBatchDeposits() external onlyOwner {
        uint256 depositCount = pendingDeposits.length;
        require(depositCount > 0, "No pending deposits");

        uint256 totalAmount;
        uint256 processedCount;
        uint256 gasUsed = gasleft();

        // Process in chunks to respect maxBatchSize
        for (uint256 i = 0; i < depositCount && processedCount < maxBatchSize; i++) {
            totalAmount += pendingDeposits[i].amount;
            processedCount++;
            // Check gas limit (arbitrary threshold, e.g., 50,000 gas remaining)
            if (gasleft() < 50_000) {
                break;
            }
        }

        if (totalAmount > 0 && totalPoints > 0) {
            bool success = sonicProtocol.depositFeeMonetizationRewards(address(this), totalAmount);
            require(success, "Sonic batch deposit failed");
        }

        totalFeeMonetizationRewards += totalAmount;

        // Remove processed deposits
        for (uint256 i = 0; i < processedCount; i++) {
            pendingDeposits[i] = pendingDeposits[pendingDeposits.length - 1];
            pendingDeposits.pop();
        }

        emit BatchDepositsProcessed(totalAmount, processedCount);
    }

    /**
     * @notice Converts USDC to $S with slippage protection and fallback.
     */
    function _convertUsdcToS(uint256 usdcAmount) internal returns (uint256) {
        require(usdcAmount > 0, "Invalid amount");
        bool usedFallback = false;
        uint256 sAmount;

        // Try Chainlink price feed
        try priceFeed.latestRoundData() returns (uint80, int256 price, uint256, uint256, uint80) {
            if (price <= 0) {
                // Fallback if price is invalid
                sAmount = usdcAmount.mul(fallbackRate).div(1e6);
                usedFallback = true;
            } else {
                lastValidPrice = uint256(price);
                // Calculate expected $S (price in 8 decimals, USDC in 6, $S in 18)
                uint256 expectedS = usdcAmount.mul(lastValidPrice).mul(1e10).div(1e8);
                uint256 amountOutMin = expectedS.mul(BASIS_POINTS - maxSlippage).div(BASIS_POINTS);

                // Perform swap
                address[] memory path = new address[](2);
                path[0] = address(usdcToken);
                path[1] = address(sonicSToken);
                usdcToken.safeApprove(address(swapRouter), usdcAmount);

                try swapRouter.swapExactTokensForTokens(
                    usdcAmount,
                    amountOutMin,
                    path,
                    address(this),
                    block.timestamp + 300
                ) returns (uint256[] memory amounts) {
                    sAmount = amounts[1];
                } catch {
                    // Fallback if swap fails
                    sAmount = usdcAmount.mul(fallbackRate).div(1e6);
                    usedFallback = true;
                }
            }
        } catch {
            // Fallback if oracle fails
            sAmount = usdcAmount.mul(fallbackRate).div(1e6);
            usedFallback = true;
        }

        emit TokenConverted(address(usdcToken), usdcAmount, sAmount, usedFallback);
        return sAmount;
    }

    /**
     * @notice Claims accumulated rewards.
     */
    function claimRewards(address recipient) external whenNotPaused {
        require(recipient != address(0), "Invalid recipient");
        uint256 amount;

        if (recipient == governance) {
            require(msg.sender == governance, "Not governance");
            amount = totalFeeMonetizationRewards;
            totalFeeMonetizationRewards = 0;
        } else {
            amount = claimableRewards[recipient];
            claimableRewards[recipient] = 0;
        }

        require(amount > 0, "No rewards to claim");
        sonicSToken.safeTransfer(recipient, amount);
        emit RewardsClaimed(recipient, amount);
    }

    /**
     * @notice Awards Sonic Points and distributes rewards.
     */
    function awardPoints(address user, uint256 totalAmount, bool isDeposit) external onlyYieldOptimizer whenNotPaused {
        require(user != address(0), "Invalid user");
        require(totalAmount >= 1 * 1e6, "Amount below minimum");

        pointsTierManager.assignTier(user, totalAmount, false, 0);
        uint256 multiplier = pointsTierManager.getUserMultiplier(user);
        uint256 points = (totalAmount * multiplier) / 100;

        if (isDeposit) {
            userPoints[user] += points;
            totalPoints += points;

            if (totalFeeMonetizationRewards > 0 && totalPoints > 0) {
                uint256 rewardShare = (totalFeeMonetizationRewards * points) / totalPoints;
                claimableRewards[user] += rewardShare;
                totalFeeMonetizationRewards -= rewardShare;
            }
        } else {
            uint256 pointsToDeduct = points > userPoints[user] ? userPoints[user] : points;
            userPoints[user] -= pointsToDeduct;
            totalPoints -= pointsToDeduct;

            if (claimableRewards[user] > 0 && userPoints[user] > 0) {
                uint256 rewardReduction = (claimableRewards[user] * pointsToDeduct) / userPoints[user];
                claimableRewards[user] -= rewardReduction;
                totalFeeMonetizationRewards += rewardReduction;
            } else {
                totalFeeMonetizationRewards += claimableRewards[user];
                claimableRewards[user] = 0;
            }
        }

        emit PointsAwarded(user, totalAmount, points, isDeposit);
    }

    /**
     * @notice Claims Sonic Points and converts to $S tokens.
     */
    function claimPoints() external whenNotPaused {
        uint256 points = userPoints[msg.sender];
        require(points > 0, "No points to claim");
        uint256 tokens = (points * POINTS_TO_TOKEN_RATE) / 1e18;
        require(tokens <= sonicSToken.balanceOf(address(this)), "Insufficient tokens");

        uint256 upfront = tokens / 4;
        uint256 burnAmount = block.timestamp < airdropStart + 30 days ? tokens / 10 : 0;
        sonicSToken.safeTransfer(msg.sender, upfront - burnAmount);
        if (burnAmount > 0) sonicSToken.safeTransfer(address(0), burnAmount);

        userPoints[msg.sender] = 0;
        totalPoints -= points;
        totalFeeMonetizationRewards += claimableRewards[msg.sender];
        claimableRewards[msg.sender] = 0;
        emit PointsClaimed(msg.sender, points, upfront - burnAmount);
    }

    /**
     * @notice Updates swap router.
     */
    function updateSwapRouter(address newSwapRouter) external onlyOwner {
        require(newSwapRouter != address(0), "Invalid swapRouter");
        swapRouter = ISwapRouter(newSwapRouter);
        emit SwapRouterUpdated(newSwapRouter);
    }

    /**
     * @notice Updates price feed.
     */
    function updatePriceFeed(address newPriceFeed) external onlyOwner {
        require(newPriceFeed != address(0), "Invalid priceFeed");
        priceFeed = AggregatorV3Interface(newPriceFeed);
        emit PriceFeedUpdated(newPriceFeed);
    }

    /**
     * @notice Updates max slippage.
     */
    function updateMaxSlippage(uint256 newSlippage) external onlyGovernance {
        require(newSlippage <= 1000, "Slippage too high"); // Max 10%
        maxSlippage = newSlippage;
        emit MaxSlippageUpdated(newSlippage);
    }

    /**
     * @notice Updates fallback rate.
     */
    function updateFallbackRate(uint256 newRate) external onlyGovernance {
        require(newRate > 0, "Invalid rate");
        fallbackRate = newRate;
        emit FallbackRateUpdated(newRate);
    }

    /**
     * @notice Updates max batch size.
     */
    function updateMaxBatchSize(uint256 newSize) external onlyOwner {
        require(newSize > 0, "Invalid size");
        maxBatchSize = newSize;
        emit MaxBatchSizeUpdated(newSize);
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
     * @notice Authorizes upgrades.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
