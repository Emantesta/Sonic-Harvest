// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ISonicProtocol {
    function depositFeeMonetizationRewards(address recipient, uint256 amount) external returns (bool);
}

interface IPointsTierManager {
    function assignTier(address user, uint256 amount, bool useLockup, uint256 lockupDays) external;
    function getUserMultiplier(address user) external view returns (uint256);
}

/**
 * @title StakingManager
 * @notice Manages Sonic Points and fee monetization rewards, integrating with PointsTierManager for tiered multipliers.
 * @dev Uses UUPS proxy, supports Sonic’s fee monetization, and awards points with user-specific multipliers.
 */
contract StakingManager is UUPSUpgradeable, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    IERC20 public sonicSToken; // Token for fee monetization rewards
    ISonicProtocol public sonicProtocol; // Sonic Protocol for reward deposits
    IPointsTierManager public pointsTierManager; // Manages staking tiers and multipliers
    address public governance; // Governance address for reward claims
    address public yieldOptimizer; // YieldOptimizer for point awards
    uint256 public totalFeeMonetizationRewards; // Total rewards accumulated
    mapping(address => uint256) public userPoints; // User Sonic Points balance

    // Events
    event PointsAwarded(address indexed user, uint256 points, bool isDeposit, uint256 multiplier);
    event RewardsDeposited(address indexed sender, uint256 amount);
    event RewardsClaimed(address indexed recipient, uint256 amount);
    event PointsTierManagerUpdated(address indexed newPointsTierManager);
    event YieldOptimizerUpdated(address indexed newYieldOptimizer);

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
     * @notice Initializes the contract with Sonic-specific parameters and PointsTierManager.
     * @param _sonicSToken Address of the reward token
     * @param _sonicProtocol Address of the Sonic Protocol
     * @param _pointsTierManager Address of the PointsTierManager
     * @param _yieldOptimizer Address of the YieldOptimizer
     * @param _governance Governance address
     */
    function initialize(
        address _sonicSToken,
        address _sonicProtocol,
        address _pointsTierManager,
        address _yieldOptimizer,
        address _governance
    ) external initializer {
        require(_sonicSToken != address(0), "Invalid sonicSToken address");
        require(_sonicProtocol != address(0), "Invalid sonicProtocol address");
        require(_pointsTierManager != address(0), "Invalid pointsTierManager address");
        require(_yieldOptimizer != address(0), "Invalid yieldOptimizer address");
        require(_governance != address(0), "Invalid governance address");

        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        sonicSToken = IERC20(_sonicSToken);
        sonicProtocol = ISonicProtocol(_sonicProtocol);
        pointsTierManager = IPointsTierManager(_pointsTierManager);
        yieldOptimizer = _yieldOptimizer;
        governance = _governance;
    }

    /**
     * @notice Deposits fee monetization rewards.
     * @param amount Amount of sonicSToken to deposit
     */
    function depositRewards(uint256 amount) external {
        require(amount > 0, "Invalid amount");
        sonicSToken.safeTransferFrom(msg.sender, address(this), amount);
        totalFeeMonetizationRewards += amount;
        emit RewardsDeposited(msg.sender, amount);
    }

    /**
     * @notice Claims accumulated rewards to governance.
     */
    function claimRewards() external onlyGovernance {
        uint256 rewards = totalFeeMonetizationRewards;
        require(rewards > 0, "No rewards");
        totalFeeMonetizationRewards = 0;
        sonicSToken.safeTransfer(governance, rewards);
        emit RewardsClaimed(governance, rewards);
    }

    /**
     * @notice Awards Sonic Points with tiered multipliers for deposits or withdrawals.
     * @param user User address
     * @param amount Amount of USDC involved
     * @param isDeposit True for deposits, false for withdrawals
     * @param useLockup Whether to apply a lockup period
     * @param lockupDays Lockup period in days (0, 30, or 90)
     */
    function awardPoints(
        address user,
        uint256 amount,
        bool isDeposit,
        bool useLockup,
        uint256 lockupDays
    ) external onlyYieldOptimizer {
        require(user != address(0), "Invalid user");
        require(amount > 0, "Invalid amount");
        require(lockupDays == 0 || lockupDays == 30 || lockupDays == 90, "Invalid lockup period");

        // Assign tier for deposits
        if (isDeposit) {
            pointsTierManager.assignTier(user, amount, useLockup, lockupDays);
        }

        // Calculate points with tiered multiplier
        uint256 multiplier = pointsTierManager.getUserMultiplier(user); // e.g., 100 (1x), 200 (2x), 300 (3x)
        uint256 basePoints = isDeposit ? amount * 2 : amount; // 2x for deposits, 1x for withdrawals
        uint256 points = (basePoints * multiplier) / 100; // Adjust for multiplier (100 = 1x)

        userPoints[user] += points;
        emit PointsAwarded(user, points, isDeposit, multiplier);
    }

    /**
     * @notice Claims Sonic Points for the caller (placeholder for post-airdrop).
     */
    function claimPoints() external {
        uint256 points = userPoints[msg.sender];
        require(points > 0, "No points to claim");
        userPoints[msg.sender] = 0;
        // Placeholder: Post-airdrop, transfer $S tokens or equivalent
        // Currently, emit event for tracking until Sonic airdrop is implemented
        emit PointsClaimed(msg.sender, points);
    }

    /**
     * @notice Updates the PointsTierManager address.
     * @param _pointsTierManager New PointsTierManager address
     */
    function setPointsTierManager(address _pointsTierManager) external onlyOwner {
        require(_pointsTierManager != address(0), "Invalid PointsTierManager");
        pointsTierManager = IPointsTierManager(_pointsTierManager);
        emit PointsTierManagerUpdated(_pointsTierManager);
    }

    /**
     * @notice Updates the YieldOptimizer address.
     * @param _yieldOptimizer New YieldOptimizer address
     */
    function setYieldOptimizer(address _yieldOptimizer) external onlyOwner {
        require(_yieldOptimizer != address(0), "Invalid YieldOptimizer");
        yieldOptimizer = _yieldOptimizer;
        emit YieldOptimizerUpdated(_yieldOptimizer);
    }

    /**
     * @notice Updates the governance address.
     * @param _governance New governance address
     */
    function setGovernance(address _governance) external onlyOwner {
        require(_governance != address(0), "Invalid governance");
        governance = _governance;
    }

    /**
     * @notice Authorizes contract upgrades.
     */
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
