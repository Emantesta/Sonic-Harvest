// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../interfaces/IStakingManager.sol";

contract PointsTierManager is OwnableUpgradeable, UUPSUpgradeable {
    // Struct to define a tier's requirements and multiplier
    struct Tier {
        uint256 minDeposit; // Minimum deposit for tier (USDC, 6 decimals)
        uint256 lockupDays; // Required lockup period (0 if none)
        uint256 multiplier; // Points multiplier (e.g., 200 for 2x, 500 for 5x)
    }

    // Struct to store a user's tier information
    struct UserTier {
        uint256 depositAmount; // Total deposit amount (USDC)
        uint256 lockupEnd; // Timestamp when longest lockup ends
        uint256 tierIndex; // Index of assigned tier
    }

    // Array of tiers
    Tier[] public tiers;
    // Mapping of user address to their tier details
    mapping(address => UserTier) public userTiers;
    // Reference to StakingManager for access control
    IStakingManager public stakingManager;

    // Events for transparency
    event TierAssigned(address indexed user, uint256 tierIndex, uint256 deposit, uint256 lockupEnd);
    event TierUpdated(uint256 tierIndex, uint256 minDeposit, uint256 lockupDays, uint256 multiplier);

    /**
     * @notice Initializes the contract with StakingManager and default tiers.
     * @param _stakingManager Address of the StakingManager contract
     */
    function initialize(address _stakingManager) external initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();

        require(_stakingManager != address(0), "Invalid StakingManager");
        stakingManager = IStakingManager(_stakingManager);

        // Initialize tiers
        tiers.push(Tier(0, 0, 200)); // Basic: 0 USDC, no lockup, 2x
        tiers.push(Tier(10_001 * 1e6, 30, 300)); // Silver: 10,001 USDC or 30-day lockup, 3x
        tiers.push(Tier(50_001 * 1e6, 90, 500)); // Gold: 50,001 USDC or 90-day lockup, 5x
    }

    /**
     * @notice Assigns a tier to a user based on their total deposit and lockup status.
     * @param user User address
     * @param totalAmount Total deposited amount (USDC, 6 decimals)
     * @param hasLockup True if the user has any active lockup
     * @param maxLockupDays Longest lockup period in days (0, 30, or 90)
     */
    function assignTier(
        address user,
        uint256 totalAmount,
        bool hasLockup,
        uint256 maxLockupDays
    ) external {
        require(msg.sender == address(stakingManager), "Only StakingManager");
        require(user != address(0), "Invalid user");
        require(totalAmount >= 1 * 1e6, "Deposit below minimum");
        require(maxLockupDays == 0 || maxLockupDays == 30 || maxLockupDays == 90, "Invalid lockup period");

        uint256 selectedTier = 0;
        uint256 lockupEnd = 0;

        // Iterate tiers in reverse to prioritize higher tiers
        for (uint256 i = tiers.length - 1; i >= 0; i--) {
            if (totalAmount >= tiers[i].minDeposit || (hasLockup && maxLockupDays >= tiers[i].lockupDays)) {
                selectedTier = i;
                if (hasLockup && maxLockupDays >= tiers[i].lockupDays) {
                    lockupEnd = block.timestamp + (maxLockupDays * 1 days);
                }
                break;
            }
        }

        userTiers[user] = UserTier(totalAmount, lockupEnd, selectedTier);
        emit TierAssigned(user, selectedTier, totalAmount, lockupEnd);
    }

    /**
     * @notice Returns the user's current points multiplier.
     * @param user User address
     * @return Multiplier (e.g., 200 for 2x, 300 for 3x, 500 for 5x)
     */
    function getUserMultiplier(address user) external view returns (uint256) {
        UserTier memory userTier = userTiers[user];
        if (userTier.lockupEnd > 0 && block.timestamp > userTier.lockupEnd) {
            return tiers[0].multiplier; // Revert to Basic tier if lockup expired
        }
        return tiers[userTier.tierIndex].multiplier;
    }

    /**
     * @notice Updates a tier's parameters.
     * @param tierIndex Index of the tier to update
     * @param minDeposit Minimum deposit (USDC)
     * @param lockupDays Required lockup period (days)
     * @param multiplier Points multiplier (e.g., 200 for 2x)
     */
    function updateTier(
        uint256 tierIndex,
        uint256 minDeposit,
        uint256 lockupDays,
        uint256 multiplier
    ) external onlyOwner {
        require(tierIndex < tiers.length, "Invalid tier");
        require(multiplier >= 100, "Multiplier too low");
        require(lockupDays == 0 || lockupDays == 30 || lockupDays == 90, "Invalid lockup period");

        tiers[tierIndex] = Tier(minDeposit, lockupDays, multiplier);
        emit TierUpdated(tierIndex, minDeposit, lockupDays, multiplier);
    }

    /**
     * @notice Authorizes contract upgrades.
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
