// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// OpenZeppelin imports for security and standards
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

// Chainlink interface for Proof of Reserve and SmartData
interface IChainlinkPoR {
    function verifyCollateral(address asset) external view returns (bool);
}

interface IChainlinkSmartData {
    function getAPY(address asset) external view returns (uint256);
}

/**
 * @title RWAYield
 * @dev Manages yield generation from RWA-backed assets (e.g., Sigma Opportunities Fund tokens)
 * with Chainlink PoR for collateral verification and SmartData for APY.
 */
contract RWAYield is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // State variables
    IERC20 public immutable stablecoin; // Stablecoin for deposits (e.g., USDC, sUSD)
    address public immutable sigmaFundToken; // Sigma Opportunities Fund token address
    IChainlinkPoR public immutable chainlinkPoR; // Chainlink Proof of Reserve
    IChainlinkSmartData public immutable chainlinkSmartData; // Chainlink APY data
    mapping(address => uint256) public rwaBalances; // Balances deposited in RWA protocol
    uint256 public totalRWABalance; // Total stablecoins allocated to RWA

    // Events
    event DepositRWA(address indexed protocol, uint256 amount);
    event WithdrawRWA(address indexed protocol, uint256 amount, uint256 profit);
    event RWAYieldUpdated(address indexed protocol, uint256 apy);

    /**
     * @dev Constructor initializes contract with dependencies
     * @param _stablecoin Address of the stablecoin
     * @param _sigmaFundToken Address of Sigma Fund token
     * @param _chainlinkPoR Address of Chainlink PoR contract
     * @param _chainlinkSmartData Address of Chainlink SmartData contract
     */
    constructor(
        address _stablecoin,
        address _sigmaFundToken,
        address _chainlinkPoR,
        address _chainlinkSmartData
    ) Ownable(msg.sender) {
        require(_stablecoin != address(0), "Invalid stablecoin address");
        require(_sigmaFundToken != address(0), "Invalid Sigma Fund address");
        require(_chainlinkPoR != address(0), "Invalid Chainlink PoR address");
        require(_chainlinkSmartData != address(0), "Invalid Chainlink SmartData address");

        stablecoin = IERC20(_stablecoin);
        sigmaFundToken = _sigmaFundToken;
        chainlinkPoR = IChainlinkPoR(_chainlinkPoR);
        chainlinkSmartData = IChainlinkSmartData(_chainlinkSmartData);
    }

    /**
     * @dev Deposits stablecoins into RWA protocol (Sigma Fund)
     * @param protocol RWA protocol address (must be Sigma Fund)
     * @param amount Amount of stablecoin to deposit
     */
    function depositToRWA(address protocol, uint256 amount) external nonReentrant {
        require(msg.sender == owner(), "Only YieldOptimizer");
        require(protocol == sigmaFundToken, "Invalid RWA protocol");
        require(amount > 0, "Amount must be > 0");
        require(chainlinkPoR.verifyCollateral(protocol), "Collateral not verified");

        stablecoin.safeApprove(protocol, amount);
        stablecoin.safeTransfer(protocol, amount);
        rwaBalances[protocol] = rwaBalances[protocol].add(amount);
        totalRWABalance = totalRWABalance.add(amount);

        emit DepositRWA(protocol, amount);
    }

    /**
     * @dev Withdraws stablecoins and profits from RWA protocol
     * @param protocol RWA protocol address
     * @param amount Amount to withdraw
     * @return Total withdrawn amount (principal + profit)
     */
    function withdrawFromRWA(address protocol, uint256 amount)
        external
        nonReentrant
        returns (uint256)
    {
        require(msg.sender == owner(), "Only YieldOptimizer");
        require(protocol == sigmaFundToken, "Invalid RWA protocol");
        require(amount > 0 && amount <= rwaBalances[protocol], "Invalid amount");

        // Assume Sigma Fund returns principal + profit as ERC20 tokens
        uint256 currentBalance = IERC20(protocol).balanceOf(address(this));
        IERC20(protocol).safeTransfer(msg.sender, amount);
        uint256 profit = currentBalance > rwaBalances[protocol]
            ? currentBalance.sub(rwaBalances[protocol])
            : 0;

        rwaBalances[protocol] = rwaBalances[protocol].sub(amount);
        totalRWABalance = totalRWABalance.sub(amount);

        if (profit > 0) {
            IERC20(protocol).safeTransfer(msg.sender, profit);
        }

        emit WithdrawRWA(protocol, amount, profit);
        return amount.add(profit);
    }

    /**
     * @dev Checks if a protocol is an RWA
     * @param protocol Protocol address
     * @return True if RWA (Sigma Fund)
     */
    function isRWA(address protocol) external view returns (bool) {
        return protocol == sigmaFundToken;
    }

    /**
     * @dev Retrieves current APY for RWA protocol
     * @param protocol RWA protocol address
     * @return APY in basis points (e.g., 700 = 7%)
     */
    function getRWAYield(address protocol) external returns (uint256) {
        require(protocol == sigmaFundToken, "Invalid RWA protocol");
        uint256 apy = chainlinkSmartData.getAPY(protocol);
        emit RWAYieldUpdated(protocol, apy);
        return apy;
    }

    /**
     * @dev Returns total RWA balance
     * @return Total stablecoins in RWA
     */
    function getTotalRWABalance() external view returns (uint256) {
        return totalRWABalance;
    }
}
