// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

interface IRWAYield {
    function getAvailableLiquidity(address protocol) external view returns (uint256);
}

contract RiskManager is UUPSUpgradeable, OwnableUpgradeable {
    AggregatorV3Interface public priceFeed;
    IRWAYield public rwaYield;
    uint256 public volatilityThreshold;
    uint256 public riskTolerance;
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_STALENESS = 30 minutes;

    mapping(address => uint256) public protocolRiskScores;
    mapping(address => uint256) public protocolVolatility;

    event RiskScoreUpdated(address indexed protocol, uint256 riskScore);
    event VolatilityUpdated(address indexed protocol, uint256 volatility);
    event VolatilityThresholdUpdated(uint256 threshold);
    event RiskToleranceUpdated(uint256 tolerance);

    modifier onlyGovernance() {
        require(msg.sender == governance, "Not governance");
        _;
    }

    address public governance;

    function initialize(address _priceFeed, address _rwaYield, address _governance) external initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        priceFeed = AggregatorV3Interface(_priceFeed);
        rwaYield = IRWAYield(_rwaYield);
        volatilityThreshold = 1000; // 10%
        riskTolerance = 500; // 5%
        governance = _governance;
    }

    function updateProtocolRiskScore(address protocol, uint256 riskScore) external onlyGovernance {
        require(riskScore <= 10000, "Invalid risk score");
        protocolRiskScores[protocol] = riskScore;
        emit RiskScoreUpdated(protocol, riskScore);
    }

    function updateProtocolVolatility(address protocol, uint256 volatilityScore) external onlyGovernance {
        require(volatilityScore <= 10000, "Invalid volatility score");
        protocolVolatility[protocol] = volatilityScore;
        emit VolatilityUpdated(protocol, volatilityScore);
    }

    function setVolatilityThreshold(uint256 _threshold) external onlyGovernance {
        require(_threshold <= 2000, "Threshold too high");
        volatilityThreshold = _threshold;
        emit VolatilityThresholdUpdated(_threshold);
    }

    function setRiskTolerance(uint256 _tolerance) external onlyGovernance {
        require(_tolerance <= 1000, "Tolerance too high");
        riskTolerance = _tolerance;
        emit RiskToleranceUpdated(_tolerance);
    }

    function getMarketVolatility() external view returns (uint256) {
        (, int256 price1, , uint256 updatedAt1, ) = priceFeed.latestRoundData();
        (, int256 price2, , uint256 updatedAt2, ) = priceFeed.getRoundData(uint80(priceFeed.latestRound() - 1));
        if (updatedAt1 <= updatedAt2 || price1 <= 0 || price2 <= 0) return volatilityThreshold;
        uint256 timeDiff = updatedAt1 - updatedAt2;
        uint256 priceDiff = price1 > price2 ? uint256(price1 - price2) : uint256(price2 - price1);
        return (priceDiff * BASIS_POINTS) / uint256(price1);
    }

    function assessLeverageViability(address protocol, uint256 amount, uint256 ltv, bool isRWA) external view returns (bool) {
        uint256 riskScore = protocolRiskScores[protocol] > 0 ? protocolRiskScores[protocol] : 5000;
        uint256 volatility = protocolVolatility[protocol] > 0 ? protocolVolatility[protocol] : 5000;
        uint256 liquidity = isRWA ? rwaYield.getAvailableLiquidity(protocol) : type(uint256).max;
        return riskScore < 7000 && ltv <= 8000 && volatility <= volatilityThreshold && liquidity >= amount;
    }

    function getRiskAdjustedAPY(address protocol, uint256 apy) external view returns (uint256) {
        uint256 riskScore = protocolRiskScores[protocol] > 0 ? protocolRiskScores[protocol] : 5000;
        return (apy * (10000 - riskScore)) / 10000;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
