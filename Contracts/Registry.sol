// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

interface ISonicProtocol {
    function isSonicCompliant(address protocol) external view returns (bool);
}

interface IRWAYield {
    function isRWA(address protocol) external view returns (bool);
}

contract Registry is UUPSUpgradeable, OwnableUpgradeable {
    struct Protocol {
        address protocolAddress;
        AggregatorV3Interface apyFeed;
        uint256 riskScore;
        bool isCompound;
        bool isRWA;
        bool isWhitelisted;
        bool isSonicCompliant;
    }

    mapping(address => Protocol) public protocols;
    address[] public activeProtocols;
    ISonicProtocol public sonicProtocol;
    IRWAYield public rwaYield;
    address public governance;

    event ProtocolUpdated(address indexed protocol, bool isWhitelisted);
    event APYFeedUpdated(address indexed protocol, address feed);
    event GovernanceUpdated(address indexed newGovernance);

    modifier onlyGovernance() {
        require(msg.sender == governance, "Not governance");
        _;
    }

    function initialize(address _sonicProtocol, address _rwaYield, address _governance) external initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        sonicProtocol = ISonicProtocol(_sonicProtocol);
        rwaYield = IRWAYield(_rwaYield);
        governance = _governance;
    }

    function updateProtocol(
        address protocol,
        bool isWhitelisted,
        address apyFeed,
        bool isCompound,
        bool isRWA,
        uint256 riskScore
    ) external onlyGovernance {
        require(protocol != address(0), "Invalid protocol");
        bool isSonicCompliant = sonicProtocol.isSonicCompliant(protocol);
        bool isValidRWA = isRWA ? rwaYield.isRWA(protocol) : true;
        require(isValidRWA, "Not an RWA protocol");
        protocols[protocol] = Protocol({
            protocolAddress: protocol,
            apyFeed: AggregatorV3Interface(apyFeed),
            riskScore: riskScore,
            isCompound: isCompound,
            isRWA: isRWA,
            isWhitelisted: isWhitelisted,
            isSonicCompliant: isSonicCompliant
        });

        if (isWhitelisted && !isActiveProtocol(protocol)) {
            activeProtocols.push(protocol);
        } else if (!isWhitelisted && isActiveProtocol(protocol)) {
            removeActiveProtocol(protocol);
        }

        emit ProtocolUpdated(protocol, isWhitelisted);
        if (apyFeed != address(0)) {
            emit APYFeedUpdated(protocol, apyFeed);
        }
    }

    function getActiveProtocols(bool isRWA) external view returns (address[] memory) {
        uint256 count;
        for (uint256 i = 0; i < activeProtocols.length; i++) {
            if (protocols[activeProtocols[i]].isRWA == isRWA) count++;
        }
        address[] memory result = new address[](count);
        uint256 index;
        for (uint256 i = 0; i < activeProtocols.length; i++) {
            if (protocols[activeProtocols[i]].isRWA == isRWA) {
                result[index++] = activeProtocols[i];
            }
        }
        return result;
    }

    function isValidProtocol(address protocol) external view returns (bool) {
        Protocol memory p = protocols[protocol];
        return p.isWhitelisted && p.isSonicCompliant && (address(p.apyFeed) != address(0) || p.riskScore > 0);
    }

    function getProtocolAPYFeed(address protocol) external view returns (address) {
        return address(protocols[protocol].apyFeed);
    }

    function getProtocolRiskScore(address protocol) external view returns (uint256) {
        return protocols[protocol].riskScore;
    }

    function isActiveProtocol(address protocol) internal view returns (bool) {
        for (uint256 i = 0; i < activeProtocols.length; i++) {
            if (activeProtocols[i] == protocol) return true;
        }
        return false;
    }

    function removeActiveProtocol(address protocol) internal {
        for (uint256 i = 0; i < activeProtocols.length; i++) {
            if (activeProtocols[i] == protocol) {
                activeProtocols[i] = activeProtocols[activeProtocols.length - 1];
                activeProtocols.pop();
                break;
            }
        }
    }

    function setGovernance(address newGovernance) external onlyGovernance {
        require(newGovernance != address(0), "Invalid address");
        governance = newGovernance;
        emit GovernanceUpdated(newGovernance);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
