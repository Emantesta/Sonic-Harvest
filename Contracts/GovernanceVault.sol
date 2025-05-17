a// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract GovernanceVault is OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    struct Stake {
        uint256 amount;
        uint256 stakeTime;
        uint256 lockupDays;
    }

    IERC20 public stakeToken;
    mapping(address => Stake) public stakes;
    mapping(address => uint256) public votingPower;
    uint256 public totalStaked;
    uint256 public profitPool; // Accumulated profits for distribution
    mapping(address => uint256) public profitShares;

    uint256 public constant DISCOUNT_25_THRESHOLD = 1_000 * 1e6;
    uint256 public constant DISCOUNT_50_THRESHOLD = 5_000 * 1e6;
    uint256 public constant LOCKUP_25_DAYS = 30;
    uint256 public constant LOCKUP_50_DAYS = 90;
    uint256 public constant PROFIT_SHARE_PERCENT = 20; // 20% of net profits

    event Staked(address indexed user, uint256 amount, uint256 lockupDays);
    event Unstaked(address indexed user, uint256 amount);
    event ProfitDistributed(uint256 amount);
    event ProfitClaimed(address indexed user, uint256 amount);

    function initialize(address _stakeToken) external initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        stakeToken = IERC20(_stakeToken);
    }

    function stake(uint256 amount, uint256 lockupDays) external {
        require(amount >= 1 * 1e6, "Amount too low");
        require(lockupDays == 0 || lockupDays == LOCKUP_25_DAYS || lockupDays == LOCKUP_50_DAYS, "Invalid lockup");

        stakeToken.safeTransferFrom(msg.sender, address(this), amount);
        stakes[msg.sender] = Stake(amount, block.timestamp, lockupDays);
        votingPower[msg.sender] += amount;
        totalStaked += amount;

        emit Staked(msg.sender, amount, lockupDays);
    }

    function unstake() external {
        Stake memory userStake = stakes[msg.sender];
        require(userStake.amount > 0, "No stake");
        require(userStake.lockupDays == 0 || block.timestamp >= userStake.stakeTime + userStake.lockupDays * 1 days, "Locked");

        uint256 amount = userStake.amount;
        delete stakes[msg.sender];
        votingPower[msg.sender] -= amount;
        totalStaked -= amount;

        stakeToken.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function distributeProfits(uint256 netProfit) external onlyOwner {
        uint256 share = (netProfit * PROFIT_SHARE_PERCENT) / 100;
        profitPool += share;
        stakeToken.safeTransferFrom(msg.sender, address(this), share);
        emit ProfitDistributed(share);
    }

    function claimProfitShare() external {
        require(totalStaked > 0, "No stakes");
        uint256 userStake = stakes[msg.sender].amount;
        require(userStake > 0, "No stake");

        uint256 share = (profitPool * userStake) / totalStaked;
        require(share > 0, "No profits to claim");

        profitPool -= share;
        profitShares[msg.sender] += share;
        stakeToken.safeTransfer(msg.sender, share);
        emit ProfitClaimed(msg.sender, share);
    }

    function getFeeDiscount(address user) external view returns (uint256) {
        // Existing logic from fee discount section
        Stake memory userStake = stakes[user];
        if (userStake.amount == 0 || (userStake.lockupDays > 0 && block.timestamp > userStake.stakeTime + userStake.lockupDays * 1 days)) {
            return 0;
        }
        if (userStake.amount >= DISCOUNT_50_THRESHOLD && userStake.lockupDays >= LOCKUP_50_DAYS) {
            return 50;
        }
        if (userStake.amount >= DISCOUNT_25_THRESHOLD && userStake.lockupDays >= LOCKUP_25_DAYS) {
            return 25;
        }
        return 0;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
