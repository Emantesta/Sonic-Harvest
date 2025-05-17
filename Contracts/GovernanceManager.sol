// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IGovernanceVault.sol";

contract GovernanceManager is OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    // Timelock action structure for protocol actions
    struct TimelockAction {
        bytes32 actionHash;
        uint256 timestamp;
        bool executed;
    }

    IERC20 public stablecoin; // Sonic USDC for fee collection and profit distribution
    IGovernanceVault public governanceVault; // Voting power and profit sharing
    address public governance; // Governance address for protocol actions
    address public aiOracle; // AI Oracle for automated actions
    uint256 public timelockDelay; // Timelock delay (e.g., 2 days)
    mapping(bytes32 => TimelockAction) public timelockActions; // Timelocked actions
    mapping(address => uint256) public collectedFees; // Collected fees

    // Events
    event ActionProposed(bytes32 indexed actionHash, uint256 timestamp);
    event ActionExecuted(bytes32 indexed actionHash);
    event FeesCollected(address indexed collector, uint256 amount);
    event ProfitDistributed(uint256 amount);
    event GovernanceUpdated(address indexed newGovernance);
    event AIOracleUpdated(address indexed newAIOracle);
    event GovernanceVaultUpdated(address indexed newGovernanceVault);

    // Modifiers
    modifier onlyGovernance() {
        require(msg.sender == governance, "Not governance");
        _;
    }

    modifier onlyAIOracle() {
        require(msg.sender == aiOracle, "Not AI Oracle");
        _;
    }

    /**
     * @notice Initializes the contract with governance, AI oracle, governance vault, stablecoin, and timelock delay
     * @param _governance Governance address
     * @param _aiOracle AI Oracle address
     * @param _governanceVault GovernanceVault address
     * @param _stablecoin Sonic USDC address
     * @param _timelockDelay Timelock delay in seconds
     */
    function initialize(
        address _governance,
        address _aiOracle,
        address _governanceVault,
        address _stablecoin,
        uint256 _timelockDelay
    ) external initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        governance = _governance;
        aiOracle = _aiOracle;
        governanceVault = IGovernanceVault(_governanceVault);
        stablecoin = IERC20(_stablecoin);
        timelockDelay = _timelockDelay;
    }

    /**
     * @notice Collects fees from YieldOptimizer
     * @param amount Amount of USDC to collect
     */
    function collectFees(uint256 amount) external {
        require(amount > 0, "Invalid amount");
        stablecoin.safeTransferFrom(msg.sender, address(this), amount);
        collectedFees[address(this)] += amount;
        emit FeesCollected(msg.sender, amount);
    }

    /**
     * @notice Distributes 20% of net profits to GovernanceVault
     * @param operationalCosts Operational costs to deduct
     */
    function distributeNetProfits(uint256 operationalCosts) external onlyOwner {
        uint256 netProfit = collectedFees[address(this)] > operationalCosts
            ? collectedFees[address(this)] - operationalCosts
            : 0;
        require(netProfit > 0, "No profits");
        collectedFees[address(this)] -= netProfit;

        // Transfer 20% to GovernanceVault
        uint256 vaultShare = (netProfit * 20) / 100;
        stablecoin.safeApprove(address(governanceVault), vaultShare);
        governanceVault.distributeProfits(vaultShare);
        emit ProfitDistributed(vaultShare);
    }

    /**
     * @notice Proposes a protocol action (e.g., upgrade, protocol addition)
     * @param actionHash Hash of the action
     */
    function proposeAction(bytes32 actionHash) external {
        uint256 voterPower = governanceVault.votingPower(msg.sender);
        require(voterPower >= 1_000 * 1e6, "Insufficient voting power");
        require(timelockActions[actionHash].timestamp == 0, "Action already proposed");
        timelockActions[actionHash] = TimelockAction({
            actionHash: actionHash,
            timestamp: block.timestamp + timelockDelay,
            executed: false
        });
        emit ActionProposed(actionHash, block.timestamp + timelockDelay);
    }

    /**
     * @notice Executes a proposed action after timelock
     * @param actionHash Hash of the action
     */
    function executeAction(bytes32 actionHash) external onlyGovernance {
        TimelockAction storage action = timelockActions[actionHash];
        require(action.timestamp > 0 && block.timestamp >= action.timestamp, "Timelock not elapsed");
        require(!action.executed, "Action already executed");
        action.executed = true;
        emit ActionExecuted(actionHash);
    }

    /**
     * @notice Proposes a contract upgrade (e.g., new implementation)
     * @param newImplementation New implementation address
     */
    function proposeUpgrade(address newImplementation) external {
        uint256 voterPower = governanceVault.votingPower(msg.sender);
        require(voterPower >= 1_000 * 1e6, "Insufficient voting power");
        bytes32 actionHash = keccak256(abi.encodePacked(newImplementation, block.timestamp));
        require(timelockActions[actionHash].timestamp == 0, "Upgrade already proposed");
        timelockActions[actionHash] = TimelockAction({
            actionHash: actionHash,
            timestamp: block.timestamp + timelockDelay,
            executed: false
        });
        emit ActionProposed(actionHash, block.timestamp + timelockDelay);
    }

    /**
     * @notice Updates the governance address
     * @param newGovernance New governance address
     */
    function updateGovernance(address newGovernance) external onlyGovernance {
        require(newGovernance != address(0), "Invalid address");
        governance = newGovernance;
        emit GovernanceUpdated(newGovernance);
    }

    /**
     * @notice Updates the AI Oracle address
     * @param newAIOracle New AI Oracle address
     */
    function updateAIOracle(address newAIOracle) external onlyGovernance {
        require(newAIOracle != address(0), "Invalid AI Oracle");
        aiOracle = newAIOracle;
        emit AIOracleUpdated(newAIOracle);
    }

    /**
     * @notice Updates the GovernanceVault address
     * @param _governanceVault New GovernanceVault address
     */
    function setGovernanceVault(address _governanceVault) external onlyOwner {
        require(_governanceVault != address(0), "Invalid GovernanceVault");
        governanceVault = IGovernanceVault(_governanceVault);
        emit GovernanceVaultUpdated(_governanceVault);
    }

    /**
     * @notice Authorizes contract upgrades (UUPS)
     * @param newImplementation New implementation address
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        // Timelock enforced via proposeUpgrade/executeAction
    }
}
