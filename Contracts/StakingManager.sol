// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ISonicProtocol {
    function depositFeeMonetizationRewards(address recipient, uint256 amount) external returns (bool);
}

contract StakingManager is UUPSUpgradeable, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    IERC20 public sonicSToken;
    IERC20 public sonicPointsToken;
    ISonicProtocol public sonicProtocol;
    address public governance;
    uint256 public totalFeeMonetizationRewards;
    mapping(address => uint256) public sonicPointsEarned;

    event PointsEarned(address indexed user, uint256 points);
    event RewardsDeposited(address indexed sender, uint256 amount);
    event PointsClaimed(address indexed user, uint256 points);
    event RewardsClaimed(address indexed recipient, uint256 amount);

    modifier onlyGovernance() {
        require(msg.sender == governance, "Not governance");
        _;
    }

    function initialize(
        address _sonicSToken,
        address _sonicPointsToken,
        address _sonicProtocol,
        address _governance
    ) external initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        sonicSToken = IERC20(_sonicSToken);
        sonicPointsToken = IERC20(_sonicPointsToken);
        sonicProtocol = ISonicProtocol(_sonicProtocol);
        governance = _governance;
    }

    function depositRewards(uint256 amount) external {
        sonicSToken.safeTransferFrom(msg.sender, address(this), amount);
        totalFeeMonetizationRewards += amount;
        emit RewardsDeposited(msg.sender, amount);
    }

    function claimRewards() external onlyGovernance {
        uint256 rewards = totalFeeMonetizationRewards;
        require(rewards > 0, "No rewards");
        totalFeeMonetizationRewards = 0;
        sonicSToken.safeTransfer(governance, rewards);
        emit RewardsClaimed(governance, rewards);
    }

    function earnPoints(address user, uint256 amount, bool isAllocation) external onlyGovernance {
        uint256 points = isAllocation ? amount * 2 : amount;
        sonicPointsEarned[user] += points;
        emit PointsEarned(user, points);
    }

    function claimPoints(address user) external {
        uint256 points = sonicPointsEarned[user];
        require(points > 0, "No points");
        sonicPointsEarned[user] = 0;
        sonicPointsToken.safeTransfer(user, points);
        emit PointsClaimed(user, points);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
