// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";

interface IRegistry {
    function getActiveProtocols(bool isRWA) external view returns (address[] memory);
    function getProtocolAPYFeed(address protocol) external view returns (address);
}

interface ISonicProtocol {
    function getSonicAPY(address protocol) external view returns (uint256);
}

contract UpkeepManager is UUPSUpgradeable, OwnableUpgradeable, AutomationCompatibleInterface {
    IRegistry public registry;
    ISonicProtocol public sonicProtocol;
    address public governance;
    uint256 public lastUpkeepTimestampRWA;
    uint256 public lastUpkeepTimestampNonRWA;
    uint256 public constant UPKEEP_INTERVAL = 1 days;
    uint256 public constant MAX_STALENESS = 30 minutes;
    uint256 public constant MAX_APY = 10000;

    event UpkeepPerformed(bool isRWA, uint256 timestamp);

    modifier onlyGovernance() {
        require(msg.sender == governance, "Not governance");
        _;
    }

    function initialize(address _registry, address _sonicProtocol, address _governance) external initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        registry = IRegistry(_registry);
        sonicProtocol = ISonicProtocol(_sonicProtocol);
        governance = _governance;
        lastUpkeepTimestampRWA = block.timestamp;
        lastUpkeepTimestampNonRWA = block.timestamp;
    }

    function checkUpkeep(bytes calldata checkData)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        bool isRWA = abi.decode(checkData, (bool));
        upkeepNeeded = isRWA
            ? block.timestamp >= lastUpkeepTimestampRWA + UPKEEP_INTERVAL
            : block.timestamp >= lastUpkeepTimestampNonRWA + UPKEEP_INTERVAL;
        return (upkeepNeeded, checkData);
    }

    function performUpkeep(bytes calldata performData) external override {
        bool isRWA = abi.decode(performData, (bool));
        uint256 lastTimestamp = isRWA ? lastUpkeepTimestampRWA : lastUpkeepTimestampNonRWA;
        require(block.timestamp >= lastTimestamp + UPKEEP_INTERVAL, "Upkeep not due");
        if (isRWA) {
            lastUpkeepTimestampRWA = block.timestamp;
        } else {
            lastUpkeepTimestampNonRWA = block.timestamp;
        }

        address[] memory protocols = registry.getActiveProtocols(isRWA);
        for (uint256 i = 0; i < protocols.length; i++) {
            address feed = registry.getProtocolAPYFeed(protocols[i]);
            if (feed != address(0)) {
                try AggregatorV3Interface(feed).latestRoundData() returns (
                    uint80,
                    int256 answer,
                    ,
                    uint256 updatedAt,
                    uint80
                ) {
                    if (answer > 0 && block.timestamp <= updatedAt + MAX_STALENESS && uint256(answer) <= MAX_APY) {
                        // Update APY in Registry or contracts
                    }
                } catch {
                    // Use Sonic APY
                    sonicProtocol.getSonicAPY(protocols[i]);
                }
            }
        }
        emit UpkeepPerformed(isRWA, block.timestamp);
    }

    function manualUpkeep(bool isRWA) external onlyGovernance {
        if (isRWA) {
            lastUpkeepTimestampRWA = block.timestamp;
        } else {
            lastUpkeepTimestampNonRWA = block.timestamp;
        }
        // Similar logic to performUpkeep
        emit UpkeepPerformed(isRWA, block.timestamp);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
