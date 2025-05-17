// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract GovernanceManager is UUPSUpgradeable, OwnableUpgradeable {
    struct TimelockAction {
        bytes32 actionHash;
        uint256 timestamp;
        bool executed;
    }

    mapping(bytes32 => TimelockAction) public timelockActions;
    address public governance;
    address public aiOracle;
    uint256 public constant TIMELOCK_DELAY = 2 days;

    event ActionProposed(bytes32 indexed actionHash, uint256 timestamp);
    event ActionExecuted(bytes32 indexed actionHash);
    event AIOracleUpdated(address indexed newOracle);

    modifier onlyGovernance() {
        require(msg.sender == governance, "Not governance");
        _;
    }

    modifier onlyAIOracle() {
        require(msg.sender == aiOracle, "Not AI Oracle");
        _;
    }

    function initialize(address _governance, address _aiOracle) external initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        governance = _governance;
        aiOracle = _aiOracle;
    }

    function proposeAction(bytes32 actionHash) external onlyGovernance {
        require(timelockActions[actionHash].timestamp == 0, "Action already proposed");
        timelockActions[actionHash] = TimelockAction({
            actionHash: actionHash,
            timestamp: block.timestamp + TIMELOCK_DELAY,
            executed: false
        });
        emit ActionProposed(actionHash, block.timestamp + TIMELOCK_DELAY);
    }

    function executeAction(bytes32 actionHash) external onlyGovernance {
        TimelockAction storage action = timelockActions[actionHash];
        require(action.timestamp > 0 && block.timestamp >= action.timestamp, "Timelock not elapsed");
        require(!action.executed, "Action already executed");
        action.executed = true;
        emit ActionExecuted(actionHash);
    }

    function updateGovernance(address newGovernance) external onlyGovernance {
        require(newGovernance != address(0), "Invalid address");
        governance = newGovernance;
    }

    function updateAIOracle(address newAIOracle) external onlyGovernance {
        require(newAIOracle != address(0), "Invalid AI Oracle");
        aiOracle = newAIOracle;
        emit AIOracleUpdated(newAIOracle);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
