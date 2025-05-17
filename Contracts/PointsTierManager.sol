// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../interfaces/IStakingManager.sol";

contract PointsTierManager is OwnableUpgradeable, UUPSUpgradeable {
    struct Tier {
        uint256 minDeposit; // Minimum deposit for tier (USDC)
        uint256 lockupDays; // Optional lockup period (0 if none)
        uint256 multiplier; // Points multiplier (e.g., 200 for 2x, 500 for 5x)
    }

    struct UserTier {
        uint256 depositAmount;
        uint256 lockupEnd; // Timestamp when lockup ends
        uint256 tierIndex; // Index of assigned tier
    }

    Tier[] public tiers;
    mapping(address => UserTier) public userTiers;
    IStakingManager public stakingManager;

    event TierAssigned(address indexed user, uint256 tierIndex, uint256 deposit, uint256 lockupEnd);
    event TierUpdated(uint256 tierIndex, uint256 minDeposit, uint256 lockupDays, uint256 multiplier);

    function initialize(address _stakingManager) external initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();

        stakingManager = IStakingManager(_stakingManager);

        // Initialize tiers (Basic: 2x, Silver: 3x, Gold: 5x)
        tiers.push(Tier(0, 0, 200)); // Basic: 0 USDC, no lockup, 2x
        tiers.push(Tier(10_001 * 1e6, 30, 300)); // Silver: 10,001 USDC or 30-day lockup, 3x
        tiers.push(Tier(50_001 * 1e6, 90, 500)); // Gold: 50,001 USDC or 90-day lockup, 5x
    }

    function assignTier(address user, uint256 deposit, bool useLockup, uint256 lockupDays) external {
        require(msg.sender == address(stakingManager), "Only StakingManager");
        require(deposit >= 1 * 1e6, "Deposit below minimum");

        uint256 selectedTier = 0;
        uint256 lockupEnd = 0;

        // Check tiers based on deposit or lockup
        for (uint256 i = tiers.length - 1; i >= 0; i--) {
            if (deposit >= tiers[i].minDeposit || (useLockup && lockupDays >= tiers[i].lockupDays)) {
                selectedTier = i;
                if (useLockup && lockupDays >= tiers[i].lockupDays) {
                    lockupEnd = block.timestamp + (lockupDays * 1 days);
                }
                break;
            }
        }

        userTiers[user] = UserTier(deposit, lockupEnd, selectedTier);
        emit TierAssigned(user, selectedTier, deposit, lockupEnd);
    }

    function getUserMultiplier(address user) external view returns (uint256) {
        UserTier memory userTier = userTiers[user];
        if (userTier.lockupEnd > 0 && block.timestamp > userTier.lockupEnd) {
            return tiers[0].multiplier; // Revert to Basic if lockup expired
        }
        return tiers[userTier.tierIndex].multiplier;
    }

    function updateTier(uint256 tierIndex, uint256 minDeposit, uint256 lockupDays, uint256 multiplier) external onlyOwner {
        require(tierIndex < tiers.length, "Invalid tier");
        tiers[tierIndex] = Tier(minDeposit, lockupDays, multiplier);
        emit TierUpdated(tierIndex, minDeposit, lockupDays, multiplier);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
