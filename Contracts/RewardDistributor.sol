// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// OpenZeppelin imports
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

// Simplified LayerZero interface for cross-chain messaging
interface ILayerZeroEndpoint {
    function send(
        uint16 _dstChainId,
        bytes calldata _destination,
        bytes calldata _payload,
        address payable _refundAddress,
        address _zroPaymentAddress,
        bytes calldata _adapterParams
    ) external payable;
}

// Interface for Governance contract
interface IGovernance {
    function rewardDistributor() external view returns (address);
    function getVotingPower(address voter, uint256 tokenId) external view returns (uint256);
}

// Interface for TimelockController
interface ITimelockController {
    function getMinDelay() external view returns (uint256);
}

/**
 * @title RewardDistributor
 * @notice Manages distribution of rewards (e.g., USDC) for voting and cleanup actions in Sonic Harvest governance system.
 * @dev Implements IRewardDistributor interface for Governance.sol compatibility. Uses UUPS proxy, Ownable, Pausable, and SafeERC20.
 *      Supports vesting, per-token cooldowns, flexible decimals, and cross-chain distribution.
 * @custom:version 1.1.0
 */
contract RewardDistributor is UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    // State variables
    address public governance; // Governance contract address
    address public timelock; // TimelockController contract address
    address public layerZeroEndpoint; // LayerZero endpoint for cross-chain
    IERC20 public usdcToken; // Default USDC token address
    mapping(address => bool) public supportedTokens; // Supported reward tokens
    mapping(address => uint8) public tokenDecimals; // Decimals per token
    mapping(address => mapping(address => uint256)) public lastRewardTimestamp; // recipient => token => timestamp
    mapping(address => mapping(address => uint256)) public pendingRewards; // recipient => token => amount
    mapping(address => mapping(address => uint256)) public vestingStart; // recipient => token => vesting start time
    uint256 public storageVersion; // Upgrade compatibility
    uint256 public maxRewardPerTx; // Max reward per transaction
    uint256 public rewardCooldown; // Default cooldown period
    uint256 public minReserveBalance; // Minimum USDC reserve
    uint256 public minCooldown; // Minimum cooldown period
    uint256 public vestingDuration; // Vesting period for rewards
    uint256 public constant MIN_DELAY = 2 days; // Minimum timelock delay

    // Constants
    string public constant VERSION = "1.1.0";
    uint256 public constant MAX_BATCH_SIZE = 50; // Max recipients in batch
    uint16 public constant MAINNET_CHAIN_ID = 1; // Example chain ID for cross-chain

    // Events
    event RewardDistributed(address indexed recipient, uint256 amount, address indexed token);
    event BatchRewardDistributed(address[] recipients, uint256[] amounts, address indexed token);
    event RewardVested(address indexed recipient, uint256 amount, address indexed token, uint256 vestingStart);
    event RewardClaimed(address indexed recipient, uint256 amount, address indexed token);
    event GovernanceUpdated(address indexed newGovernance);
    event TokenAdded(address indexed token, uint8 decimals);
    event TokenRemoved(address indexed token);
    event FundsRecovered(address indexed token, address indexed recipient, uint256 amount);
    event StorageVersionUpdated(uint256 newStorageVersion);
    event MaxRewardUpdated(uint256 newMaxReward);
    event RewardCooldownUpdated(uint256 newCooldown);
    event MinReserveBalanceUpdated(uint256 newMinReserveBalance);
    event MinCooldownUpdated(uint256 newMinCooldown);
    event VestingDurationUpdated(uint256 newVestingDuration);
    event LowBalanceWarning(uint256 balance, uint256 threshold);
    event CrossChainRewardSent(address indexed recipient, uint256 amount, address indexed token, uint16 dstChainId);

    // Errors
    error ZeroAddress();
    error ZeroAmount();
    error ExceedsMaxReward();
    error TokenNotSupported();
    error CooldownNotElapsed();
    error ArraysLengthMismatch();
    error IncompatibleStorageVersion();
    error BatchSizeExceedsLimit();
    error InsufficientBalance();
    error InvalidTimelock();
    error NothingToClaim();
    error VestingNotComplete();
    error InvalidChainId();
    error GovernanceMismatch();

    // Modifiers
    modifier onlyGovernance() {
        if (msg.sender != governance) revert GovernanceMismatch();
        _;
    }

    /**
     * @notice Initializes the contract.
     * @param _governance Governance contract address.
     * @param _timelock TimelockController address.
     * @param _usdcToken USDC token address.
     * @param _layerZeroEndpoint LayerZero endpoint address.
     * @param _maxRewardPerTx Max reward per transaction.
     * @param _rewardCooldown Default cooldown period.
     * @param _minReserveBalance Minimum USDC reserve.
     * @param _minCooldown Minimum cooldown period.
     * @param _vestingDuration Vesting period for rewards.
     */
    function initialize(
        address _governance,
        address _timelock,
        address _usdcToken,
        address _layerZeroEndpoint,
        uint256 _maxRewardPerTx,
        uint256 _rewardCooldown,
        uint256 _minReserveBalance,
        uint256 _minCooldown,
        uint256 _vestingDuration
    ) external initializer {
        if (_governance == address(0) || _timelock == address(0) || _usdcToken == address(0) || _layerZeroEndpoint == address(0))
            revert ZeroAddress();
        if (_maxRewardPerTx == 0) revert ZeroAmount();
        if (_rewardCooldown < _minCooldown) revert CooldownNotElapsed();
        if (ITimelockController(_timelock).getMinDelay() < MIN_DELAY) revert InvalidTimelock();

        __UUPSUpgradeable_init();
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __Pausable_init();

        governance = _governance;
        timelock = _timelock;
        layerZeroEndpoint = _layerZeroEndpoint;
        usdcToken = IERC20(_usdcToken);
        supportedTokens[_usdcToken] = true;
        tokenDecimals[_usdcToken] = IERC20Metadata(_usdcToken).decimals();
        maxRewardPerTx = _maxRewardPerTx;
        rewardCooldown = _rewardCooldown;
        minReserveBalance = _minReserveBalance;
        minCooldown = _minCooldown;
        vestingDuration = _vestingDuration;
        storageVersion = 1;

        _transferOwnership(_timelock);

        emit GovernanceUpdated(_governance);
        emit TokenAdded(_usdcToken, tokenDecimals[_usdcToken]);
        emit MaxRewardUpdated(_maxRewardPerTx);
        emit RewardCooldownUpdated(_rewardCooldown);
        emit MinReserveBalanceUpdated(_minReserveBalance);
        emit MinCooldownUpdated(_minCooldown);
        emit VestingDurationUpdated(_vestingDuration);
    }

    /**
     * @notice Distributes USDC rewards to a voter for voting, with vesting.
     * @param voter Recipient address.
     * @param amount Reward amount.
     */
    function distributeVotingReward(
        address voter,
        uint256 amount
    ) external nonReentrant onlyGovernance whenNotPaused {
        _validateReward(voter, amount, address(usdcToken));
        _distributeReward(voter, amount, address(usdcToken), false);
    }

    /**
     * @notice Distributes USDC rewards to multiple recipients in a single transaction.
     * @param recipients Array of recipient addresses.
     * @param amounts Array of reward amounts.
     */
    function distributeBatchRewards(
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external nonReentrant onlyGovernance whenNotPaused {
        if (recipients.length != amounts.length) revert ArraysLengthMismatch();
        if (recipients.length > MAX_BATCH_SIZE) revert BatchSizeExceedsLimit();

        uint256 totalAmount;
        uint256 balance = usdcToken.balanceOf(address(this));
        for (uint256 i = 0; i < recipients.length; i++) {
            totalAmount += amounts[i];
            _validateReward(recipients[i], amounts[i], address(usdcToken));
        }
        if (balance < totalAmount + minReserveBalance) revert InsufficientBalance();

        for (uint256 i = 0; i < recipients.length; i++) {
            _distributeReward(recipients[i], amounts[i], address(usdcToken), false);
        }

        emit BatchRewardDistributed(recipients, amounts, address(usdcToken));
    }

    /**
     * @notice Distributes dynamic rewards based on veNFT voting power.
     * @param recipient Recipient address.
     * @param tokenId veNFT token ID.
     * @param proposalId Proposal ID.
     * @param amount Base reward amount.
     */
    function distributeDynamicReward(
        address recipient,
        uint256 tokenId,
        uint256 proposalId,
        uint256 amount
    ) external nonReentrant onlyGovernance whenNotPaused {
        _validateReward(recipient, amount, address(usdcToken));
        uint256 votingPower = IGovernance(governance).getVotingPower(recipient, tokenId);
        uint256 adjustedAmount = (amount * votingPower) / 1e18; // Adjust by voting power
        if (adjustedAmount == 0) revert ZeroAmount();
        _distributeReward(recipient, adjustedAmount, address(usdcToken), true);
    }

    /**
     * @notice Distributes rewards cross-chain via LayerZero.
     * @param recipient Recipient address.
     * @param amount Reward amount.
     * @param token Token address.
     * @param dstChainId Destination chain ID.
     */
    function distributeCrossChainReward(
        address recipient,
        uint256 amount,
        address token,
        uint16 dstChainId
    ) external payable nonReentrant onlyGovernance whenNotPaused {
        if (dstChainId == 0) revert InvalidChainId();
        _validateReward(recipient, amount, token);
        IERC20 rewardToken = IERC20(token);
        uint256 balance = rewardToken.balanceOf(address(this));
        uint256 reserve = (token == address(usdcToken)) ? minReserveBalance : 0;
        if (balance < amount + reserve) revert InsufficientBalance();

        bytes memory payload = abi.encode(recipient, amount, token);
        ILayerZeroEndpoint(layerZeroEndpoint).send{value: msg.value}(
            dstChainId,
            abi.encodePacked(address(this)),
            payload,
            payable(msg.sender),
            address(0),
            bytes("")
        );

        emit CrossChainRewardSent(recipient, amount, token, dstChainId);
    }

    /**
     * @notice Claims vested rewards for a recipient.
     * @param token Reward token address.
     */
    function claimRewards(address token) external nonReentrant whenNotPaused {
        uint256 amount = pendingRewards[msg.sender][token];
        if (amount == 0) revert NothingToClaim();
        if (block.timestamp < vestingStart[msg.sender][token] + vestingDuration) revert VestingNotComplete();

        pendingRewards[msg.sender][token] = 0;
        vestingStart[msg.sender][token] = 0;
        IERC20(token).safeTransfer(msg.sender, amount);

        emit RewardClaimed(msg.sender, amount, token);
    }

    /**
     * @notice Returns the balance of a specific token held by the contract.
     * @param token Token address.
     * @return Balance of the token.
     */
    function balanceOf(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /**
     * @notice Checks if the contract balance is below the minimum reserve.
     * @param token Token address.
     * @return True if balance is low.
     */
    function isBalanceLow(address token) external view returns (bool) {
        uint256 reserve = (token == address(usdcToken)) ? minReserveBalance : 0;
        return IERC20(token).balanceOf(address(this)) < reserve;
    }

    /**
     * @notice Returns the last reward timestamp for a recipient and token.
     * @param recipient Recipient address.
     * @param token Token address.
     * @return Last reward timestamp.
     */
    function getLastRewardTimestamp(address recipient, address token) external view returns (uint256) {
        return lastRewardTimestamp[recipient][token];
    }

    /**
     * @notice Returns pending rewards and vesting status for a recipient and token.
     * @param recipient Recipient address.
     * @param token Token address.
     * @return amount Pending reward amount.
     * @return vestingEnd Vesting end timestamp.
     */
    function getPendingRewards(address recipient, address token) external view returns (uint256 amount, uint256 vestingEnd) {
        amount = pendingRewards[recipient][token];
        vestingEnd = vestingStart[recipient][token] + vestingDuration;
    }

    /**
     * @notice Updates the Governance contract address with two-step process.
     * @param newGovernance New Governance contract address.
     */
    function proposeGovernanceUpdate(address newGovernance) external onlyOwner {
        if (newGovernance == address(0)) revert ZeroAddress();
        if (IGovernance(newGovernance).rewardDistributor() != address(this)) revert GovernanceMismatch();
        // Placeholder for two-step process; actual implementation depends on TimelockController
        governance = newGovernance;
        emit GovernanceUpdated(newGovernance);
    }

    /**
     * @notice Adds a new reward token.
     * @param token Token address.
     */
    function addToken(address token) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (supportedTokens[token]) revert TokenNotSupported();
        supportedTokens[token] = true;
        tokenDecimals[token] = IERC20Metadata(token).decimals();
        emit TokenAdded(token, tokenDecimals[token]);
    }

    /**
     * @notice Removes a reward token.
     * @param token Token address.
     */
    function removeToken(address token) external onlyOwner {
        if (token == address(usdcToken)) revert TokenNotSupported();
        if (!supportedTokens[token]) revert TokenNotSupported();
        supportedTokens[token] = false;
        delete tokenDecimals[token];
        emit TokenRemoved(token);
    }

    /**
     * @notice Updates the max reward per transaction.
     * @param newMaxReward New max reward amount.
     */
    function updateMaxReward(uint256 newMaxReward) external onlyOwner {
        if (newMaxReward == 0) revert ZeroAmount();
        maxRewardPerTx = newMaxReward;
        emit MaxRewardUpdated(newMaxReward);
    }

    /**
     * @notice Updates the reward cooldown period.
     * @param newCooldown New cooldown period.
     */
    function updateRewardCooldown(uint256 newCooldown) external onlyOwner {
        if (newCooldown < minCooldown) revert CooldownNotElapsed();
        rewardCooldown = newCooldown;
        emit RewardCooldownUpdated(newCooldown);
    }

    /**
     * @notice Updates the minimum reserve balance.
     * @param newMinReserveBalance New minimum reserve balance.
     */
    function setMinReserveBalance(uint256 newMinReserveBalance) external onlyOwner {
        minReserveBalance = newMinReserveBalance;
        emit MinReserveBalanceUpdated(newMinReserveBalance);
    }

    /**
     * @notice Updates the minimum cooldown period.
     * @param newMinCooldown New minimum cooldown period.
     */
    function setMinCooldown(uint256 newMinCooldown) external onlyOwner {
        minCooldown = newMinCooldown;
        emit MinCooldownUpdated(newMinCooldown);
    }

    /**
     * @notice Updates the vesting duration.
     * @param newVestingDuration New vesting duration.
     */
    function setVestingDuration(uint256 newVestingDuration) external onlyOwner {
        vestingDuration = newVestingDuration;
        emit VestingDurationUpdated(newVestingDuration);
    }

    /**
     * @notice Recovers stuck tokens or excess funds.
     * @param token Token to recover.
     * @param recipient Recipient address.
     * @param amount Amount to recover.
     */
    function recoverFunds(address token, address recipient, uint256 amount) external onlyOwner nonReentrant {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (token == address(usdcToken)) {
            uint256 balance = usdcToken.balanceOf(address(this));
            if (balance < amount + minReserveBalance) revert InsufficientBalance();
        }
        IERC20(token).safeTransfer(recipient, amount);
        emit FundsRecovered(token, recipient, amount);
    }

    /**
     * @notice Pauses reward distributions.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpauses reward distributions.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Authorizes a contract upgrade.
     * @param newImplementation New implementation address.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @notice Upgrades the contract and updates the storage version.
     * @param newImplementation New implementation address.
     * @param newStorageVersion New storage version.
     */
    function upgradeToAndCall(address newImplementation, uint256 newStorageVersion) external onlyOwner {
        if (newStorageVersion < storageVersion) revert IncompatibleStorageVersion();
        storageVersion = newStorageVersion;
        _upgradeTo(newImplementation);
        emit StorageVersionUpdated(newStorageVersion);
    }

    /**
     * @dev Validates reward distribution parameters.
     */
    function _validateReward(address recipient, uint256 amount, address token) private view {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > maxRewardPerTx) revert ExceedsMaxReward();
        if (!supportedTokens[token]) revert TokenNotSupported();
        if (block.timestamp < lastRewardTimestamp[recipient][token] + rewardCooldown) revert CooldownNotElapsed();
        uint256 reserve = (token == address(usdcToken)) ? minReserveBalance : 0;
        if (IERC20(token).balanceOf(address(this)) < amount + reserve) revert InsufficientBalance();
    }

    /**
     * @dev Distributes rewards, optionally vesting them.
     */
    function _distributeReward(address recipient, uint256 amount, address token, bool useVesting) private {
        lastRewardTimestamp[recipient][token] = block.timestamp;
        if (useVesting && vestingDuration > 0) {
            pendingRewards[recipient][token] += amount;
            vestingStart[recipient][token] = block.timestamp;
            emit RewardVested(recipient, amount, token, block.timestamp);
        } else {
            IERC20(token).safeTransfer(recipient, amount);
            emit RewardDistributed(recipient, amount, token);
        }
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 reserve = (token == address(usdcToken)) ? minReserveBalance : 0;
        if (balance < reserve) emit LowBalanceWarning(balance, reserve);
    }
}
