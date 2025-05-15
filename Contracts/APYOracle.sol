// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// OpenZeppelin imports
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

// Interfaces for Chainlink and DeFi protocols
interface IChainlinkSmartData {
    function getAPY(address asset) external view returns (uint256);
}

interface IDeFiProtocol {
    function getAPY() external view returns (uint256);
}

/**
 * @title APYOracle
 * @dev Provides real-time APY data for RWA and DeFi protocols for YieldOptimizer
 */
contract APYOracle is Ownable {
    using SafeMath for uint256;

    // State variables
    address public immutable rwaProtocol; // Sigma Fund token address
    address public immutable chainlinkSmartData; // Chainlink SmartData contract
    address[] public defiProtocols; // List of DeFi protocols (Silo, Beets, Rings, Aave, Eggs)
    mapping(address => bool) public isSupportedProtocol; // Tracks supported protocols

    // Events
    event ProtocolAdded(address indexed protocol);
    event ProtocolRemoved(address indexed protocol);

    /**
     * @dev Constructor initializes RWA and DeFi protocols
     * @param _rwaProtocol Sigma Fund token address
     * @param _chainlinkSmartData Chainlink SmartData address
     * @param _defiProtocols Initial list of DeFi protocols
     */
    constructor(
        address _rwaProtocol,
        address _chainlinkSmartData,
        address[] memory _defiProtocols
    ) Ownable(msg.sender) {
        require(_rwaProtocol != address(0), "Invalid RWA protocol");
        require(_chainlinkSmartData != address(0), "Invalid Chainlink SmartData");
        require(_defiProtocols.length > 0, "No DeFi protocols provided");

        rwaProtocol = _rwaProtocol;
        chainlinkSmartData = _chainlinkSmartData;
        for (uint256 i = 0; i < _defiProtocols.length; i++) {
            require(_defiProtocols[i] != address(0), "Invalid DeFi protocol");
            defiProtocols.push(_defiProtocols[i]);
            isSupportedProtocol[_defiProtocols[i]] = true;
        }
        isSupportedProtocol[_rwaProtocol] = true;
    }

    /**
     * @dev Returns APYs for all supported protocols
     * @return protocols Array of protocol addresses
     * @return apys Array of APYs in basis points
     */
    function getAPYs() external view returns (address[] memory protocols, uint256[] memory apys) {
        uint256 totalProtocols = defiProtocols.length + 1; // RWA + DeFi protocols
        protocols = new address[](totalProtocols);
        apys = new uint256[](totalProtocols);

        // Add RWA protocol
        protocols[0] = rwaProtocol;
        apys[0] = IChainlinkSmartData(chainlinkSmartData).getAPY(rwaProtocol);

        // Add DeFi protocols
        for (uint256 i = 0; i < defiProtocols.length; i++) {
            protocols[i + 1] = defiProtocols[i];
            apys[i + 1] = IDeFiProtocol(defiProtocols[i]).getAPY();
        }

        return (protocols, apys);
    }

    /**
     * @dev Adds a new DeFi protocol
     * @param protocol DeFi protocol address
     */
    function addProtocol(address protocol) external onlyOwner {
        require(protocol != address(0), "Invalid protocol");
        require(!isSupportedProtocol[protocol], "Protocol already supported");

        defiProtocols.push(protocol);
        isSupportedProtocol[protocol] = true;
        emit ProtocolAdded(protocol);
    }

    /**
     * @dev Removes a DeFi protocol
     * @param protocol DeFi protocol address
     */
    function removeProtocol(address protocol) external onlyOwner {
        require(isSupportedProtocol[protocol], "Protocol not supported");
        require(protocol != rwaProtocol, "Cannot remove RWA protocol");

        for (uint256 i = 0; i < defiProtocols.length; i++) {
            if (defiProtocols[i] == protocol) {
                defiProtocols[i] = defiProtocols[defiProtocols.length - 1];
                defiProtocols.pop();
                isSupportedProtocol[protocol] = false;
                emit ProtocolRemoved(protocol);
                break;
            }
        }
    }

    /**
     * @dev Returns supported protocols
     * @return Array of protocol addresses
     */
    function getSupportedProtocols() external view returns (address[] memory) {
        address[] memory protocols = new address[](defiProtocols.length + 1);
        protocols[0] = rwaProtocol;
        for (uint256 i = 0; i < defiProtocols.length; i++) {
            protocols[i + 1] = defiProtocols[i];
        }
        return protocols;
    }
}
