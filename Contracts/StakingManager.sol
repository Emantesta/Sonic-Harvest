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
    function assignTier(address user, uint256 totalAmount, bool hasLockup, uint256 maxLockupDays) external;
    function getUserMultiplier(address user) external view returns (uint256);
}

/**
 * @title StakingManager
 * @notice Manages Sonic Points and fee monetization rewards, integrating with PointsTierManager for tiered multipliers.
 * @dev Uses UUPS proxy, supports Sonic’s fee monetization, and distributes rewards proportional to user points.
 */
contract StakingManager is UUPSUpgradeable, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    IERC20 public sonicSToken; // Token for fee monetization rewards ($S)
    ISonicProtocol public sonicProtocol; // Sonic Protocol for reward deposits
    IPointsTierManager public pointsTierManager; // Manages staking tiers and multipliers
    address public governance; // Governance address for reward claims
    address public yieldOptimizer; // YieldOptimizer for point awards
    uint256 public totalFeeMonetizationRewards; // Total rewards accumulated
    uint256 public totalPoints; // Sum of all user points
    mapping(address => uint256) public userPoints; // User Sonic Points balance
    mapping(address => uint256) public claimableRewards; // User claimable rewards
    uint256 public constant POINTS_TO_TOKEN_RATE = 1e16; // 1 point = 0.01 $S (1e18 / 1e16 = 0.01)

    // Events
    event PointsAwarded(
        address indexed user,
        uint256 totalAmount,
        uint256 points,
        bool isDeposit,
        bool hasLockup,
        uint256 maxLockupDays
    );
    event RewardsDeposited(address indexed sender, uint256 amount);
    event RewardsClaimed(address indexed recipient, uint256 amount);
    event PointsClaimed(address indexed user, uint256 points, uint256 tokens);
    event PointsTierManagerUpdated(address indexed newPointsTierManager);
    event YieldOptimizerUpdated(address indexed newYieldOptimizer);
    event GovernanceUpdated(address indexed newGovernance);

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
     * @notice Deposits fee monetization rewards and distributes to users.
     * @param amount Amount of sonicSToken to deposit
     */
    function depositRewards(uint256 amount) external {
        require(amount > 0, "Invalid amount");
        sonicSToken.safeTransferFrom(msg.sender, address(this), amount);
        totalFeeMonetizationRewards += amount;

        // Distribute rewards to users based on points
        if (totalPoints > 0) {
            // Snapshot users with points (in practice, iterate over active users or use an EnumerableSet)
            // For simplicity, assume rewards are held in totalFeeMonetizationRewards and allocated in awardPoints
            bool success = sonicProtocol.depositFeeMonetizationRewards(address(this), amount);
            require(success, "Sonic deposit failed");
        }

        emit RewardsDeposited(msg.sender, amount);
    }

    /**
     * @notice Claims accumulated rewards for users or governance.
     * @param recipient Address to receive rewards (governance or user)
     */
    function claimRewards(address recipient) external {
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
     * @notice Awards Sonic Points with tiered multipliers and distributes rewards.
     * @param user User address
     * @param totalAmount Total deposited amount (USDC, 6 decimals)
     * @param isDeposit True for deposits, false for withdrawals
     * @param hasLockup True if user has any active lockup
     * @param maxLockupDays Longest lockup period in days (0, 30, or 90)
     */
    function awardPoints(
        address user,
        uint256 totalAmount,
        bool isDeposit,
        bool hasLockup,
        uint256 maxLockupDays
    ) external onlyYieldOptimizer {
        require(user != address(0), "Invalid user");
        require(totalAmount >= 1 * 1e6, "Amount below minimum");
        require(maxLockupDays == 0 || maxLockupDays == 30 || maxLockupDays == 90, "Invalid lockup period");

        // Update tier
        pointsTierManager.assignTier(user, totalAmount, hasLockup, maxLockupDays);

        // Calculate points
        uint256 multiplier = pointsTierManager.getUserMultiplier(user); // e.g., 200 (2x), 300 (3x), 500 (5x)
        uint256 points = (totalAmount * multiplier) / 100; // Adjust for multiplier (100 = 1x)

        // Update user points and total points
        if (isDeposit) {
            userPoints[user] += points;
            totalPoints += points;

            // Allocate rewards proportional to points
            if (totalFeeMonetizationRewards > 0 && totalPoints > 0) {
                uint256 rewardShare = (totalFeeMonetizationRewards * points) / totalPoints;
                claimableRewards[user] += rewardShare;
                totalFeeMonetizationRewards -= rewardShare;
            }
        } else {
            uint256 pointsToDeduct = points > userPoints[user] ? userPoints[user] : points;
            userPoints[user] -= pointsToDeduct;
            totalPoints -= pointsToDeduct;

            // Reduce rewards proportional to points deducted
            if (claimableRewards[user] > 0 && userPoints[user] > 0) {
                uint256 rewardReduction = (claimableRewards[user] * pointsToDeduct) / userPoints[user];
                claimableRewards[user] -= rewardReduction;
                totalFeeMonetizationRewards += rewardReduction; // Return to pool
            } else {
                totalFeeMonetizationRewards += claimableRewards[user];
                claimableRewards[user] = 0;
            }
        }

        emit PointsAwarded(user, totalAmount, points, isDeposit, hasLockup, maxLockupDays);
    }

    /**
     * @notice Claims Sonic Points and converts to $S tokens (post-airdrop).
     * @dev Assumes 1 point = 0.01 $S (POINTS_TO_TOKEN_RATE = 1e16)
     */
    function claimPoints() external {
        uint256 points = userPoints[msg.sender];
        require(points > 0, "No points to claim");

        // Convert points to $S tokens (18 decimals)
        uint256 tokens = (points * POINTS_TO_TOKEN_RATE) / 1e18; // e.g., 1000 points = 10 $S
        require(tokens <= sonicSToken.balanceOf(address(this)), "Insufficient tokens");

        userPoints[msg.sender] = 0;
        totalPoints -= points;

        // Adjust rewards if points are claimed
        if (claimableRewards[msg.sender] > 0) {
            totalFeeMonetizationRewards += claimableRewards[msg.sender];
            claimableRewards[msg.sender] = 0;
        }

        sonicSToken.safeTransfer(msg.sender, tokens);
        emit PointsClaimed(msg.sender, points, tokens);
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
        emit GovernanceUpdated(_governance);
    }

    /**
     * @notice Authorizes contract upgrades.
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
