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
    mapping(address => uint256) public claimableRewards; // User claimable rewards

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
    event PointsClaimed(address indexed user, uint256 points);
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
     * @notice Deposits fee monetization rewards.
     * @param amount Amount of sonicSToken to deposit
     */
    function depositRewards(uint256 amount) external {
        require(amount > 0, "Invalid amount");
        sonicSToken.safeTransferFrom(msg.sender, address(this), amount);
        totalFeeMonetizationRewards += amount;
        bool success = sonicProtocol.depositFeeMonetizationRewards(address(this), amount);
        require(success, "Sonic deposit failed");
        emit RewardsDeposited(msg.sender, amount);
    }

    /**
     * @notice Claims accumulated rewards to governance or users.
     * @param recipient Address to receive rewards (governance or user)
     */
    function claimRewards(address recipient) external onlyGovernance {
        require(recipient != address(0), "Invalid recipient");
        uint256 amount = recipient == governance ? totalFeeMonetizationRewards : claimableRewards[recipient];
        require(amount > 0, "No rewards to claim");

        if (recipient == governance) {
            totalFeeMonetizationRewards = 0;
        } else {
            claimableRewards[recipient] = 0;
        }

        sonicSToken.safeTransfer(recipient, amount);
        emit RewardsClaimed(recipient, amount);
    }

    /**
     * @notice Awards Sonic Points with tiered multipliers for deposits or withdrawals.
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

        // Update tier for deposits or withdrawals
        pointsTierManager.assignTier(user, totalAmount, hasLockup, maxLockupDays);

        // Calculate points using the user's current multiplier
        uint256 multiplier = pointsTierManager.getUserMultiplier(user); // e.g., 200 (2x), 300 (3x), 500 (5x)
        uint256 points = (totalAmount * multiplier) / 100; // Adjust for multiplier (100 = 1x)

        // Update user points
        if (isDeposit) {
            userPoints[user] += points;
            // Allocate proportional rewards to user (e.g., based on points)
            uint256 rewardShare = (totalFeeMonetizationRewards * points) / (totalFeeMonetizationRewards + points + 1);
            claimableRewards[user] += rewardShare;
        } else {
            userPoints[user] = userPoints[user] >= points ? userPoints[user] - points : 0;
            // Reduce claimable rewards proportionally
            uint256 rewardShare = (claimableRewards[user] * points) / (userPoints[user] + points + 1);
            claimableRewards[user] = claimableRewards[user] >= rewardShare ? claimableRewards[user] - rewardShare : 0;
        }

        emit PointsAwarded(user, totalAmount, points, isDeposit, hasLockup, maxLockupDays);
    }

    /**
     * @notice Claims Sonic Points for the caller (placeholder for post-airdrop).
     */
    function claimPoints() external {
        uint256 points = userPoints[msg.sender];
        require(points > 0, "No points to claim");
        userPoints[msg.sender] = 0;
        // Placeholder: Post-airdrop, transfer $S tokens or equivalent
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
        emit GovernanceUpdated(_governance);
    }

    /**
     * @notice Authorizes contract upgrades.
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
