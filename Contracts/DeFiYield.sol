// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// OpenZeppelin imports
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

// Interfaces for Sonic DeFi protocols (simplified for clarity)
interface ISiloFinance {
    function deposit(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount) external returns (uint256);
}

interface IBeets {
    function depositToPool(address pool, uint256 amount) external;
    function withdrawFromPool(address pool, uint256 amount) external returns (uint256);
}

interface IRingsProtocol {
    function stake(address asset, uint256 amount) external returns (address stakedToken);
    function unstake(address stakedToken, uint256 amount) external returns (uint256);
}

interface IAave {
    function supply(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount) external returns (uint256);
}

interface IEggsFinance {
    function mintEggs(uint256 amount) external;
    function redeemEggs(uint256 amount) external returns (uint256);
}

/**
 * @title DeFiYield
 * @dev Manages yield generation from Sonic DeFi protocols (Silo, Beets, Rings, Aave, Eggs)
 * for YieldOptimizer.
 */
contract DeFiYield is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // State variables
    IERC20 public immutable stablecoin; // Stablecoin for deposits (e.g., USDC)
    mapping(address => bool) public supportedProtocols; // Supported DeFi protocols
    mapping(address => uint256) public defiBalances; // Balances in each protocol
    uint256 public totalDeFiBalance; // Total stablecoins allocated to DeFi

    // Events
    event DepositDeFi(address indexed protocol, uint256 amount);
    event WithdrawDeFi(address indexed protocol, uint256 amount, uint256 profit);

    /**
     * @dev Constructor initializes contract with stablecoin and supported protocols
     * @param _stablecoin Address of the stablecoin
     * @param _protocols Array of supported DeFi protocol addresses
     */
    constructor(address _stablecoin, address[] memory _protocols) Ownable(msg.sender) {
        require(_stablecoin != address(0), "Invalid stablecoin address");
        require(_protocols.length > 0, "No protocols provided");

        stablecoin = IERC20(_stablecoin);
        for (uint256 i = 0; i < _protocols.length; i++) {
            require(_protocols[i] != address(0), "Invalid protocol address");
            supportedProtocols[_protocols[i]] = true;
        }
    }

    /**
     * @dev Deposits stablecoins into a DeFi protocol
     * @param protocol DeFi protocol address
     * @param amount Amount to deposit
     */
    function depositToDeFi(address protocol, uint256 amount) external nonReentrant {
        require(msg.sender == owner(), "Only YieldOptimizer");
        require(supportedProtocols[protocol], "Unsupported protocol");
        require(amount > 0, "Amount must be > 0");

        stablecoin.safeApprove(protocol, amount);

        if (protocol == address(0xSiloFinance)) { // Replace with actual address
            ISiloFinance(protocol).deposit(address(stablecoin), amount);
        } else if (protocol == address(0xBeets)) {
            IBeets(protocol).depositToPool(address(stablecoin), amount);
        } else if (protocol == address(0xRingsProtocol)) {
            IRingsProtocol(protocol).stake(address(stablecoin), amount);
        } else if (protocol == address(0xAave)) {
            IAave(protocol).supply(address(stablecoin), amount);
        } else if (protocol == address(0xEggsFinance)) {
            IEggsFinance(protocol).mintEggs(amount);
        } else {
            revert("Unknown protocol");
        }

        defiBalances[protocol] = defiBalances[protocol].add(amount);
        totalDeFiBalance = totalDeFiBalance.add(amount);

        emit DepositDeFi(protocol, amount);
    }

    /**
     * @dev Withdraws stablecoins and profits from a DeFi protocol
     * @param protocol DeFi protocol address
     * @param amount Amount to withdraw
     * @return Total withdrawn amount (principal + profit)
     */
    function withdrawFromDeFi(address protocol, uint256 amount)
        external
        nonReentrant
        returns (uint256)
    {
        require(msg.sender == owner(), "Only YieldOptimizer");
        require(supportedProtocols[protocol], "Unsupported protocol");
        require(amount > 0 && amount <= defiBalances[protocol], "Invalid amount");

        uint256 initialBalance = stablecoin.balanceOf(address(this));
        uint256 withdrawn;

        if (protocol == address(0xSiloFinance)) {
            withdrawn = ISiloFinance(protocol).withdraw(address(stablecoin), amount);
        } else if (protocol == address(0xBeets)) {
            withdrawn = IBeets(protocol).withdrawFromPool(address(stablecoin), amount);
        } else if (protocol == address(0xRingsProtocol)) {
            withdrawn = IRingsProtocol(protocol).unstake(address(stablecoin), amount);
        } else if (protocol == address(0xAave)) {
            withdrawn = IAave(protocol).withdraw(address(stablecoin), amount);
        } else if (protocol == address(0xEggsFinance)) {
            withdrawn = IEggsFinance(protocol).redeemEggs(amount);
        } else {
            revert("Unknown protocol");
        }

        uint256 finalBalance = stablecoin.balanceOf(address(this));
        uint256 profit = finalBalance > initialBalance ? finalBalance.sub(initialBalance) : 0;

        defiBalances[protocol] = defiBalances[protocol].sub(amount);
        totalDeFiBalance = totalDeFiBalance.sub(amount);

        if (withdrawn > 0) {
            stablecoin.safeTransfer(msg.sender, withdrawn);
        }

        emit WithdrawDeFi(protocol, amount, profit);
        return withdrawn;
    }

    /**
     * @dev Returns total DeFi balance
     * @return Total stablecoins in DeFi protocols
     */
    function getTotalDeFiBalance() external view returns (uint256) {
        return totalDeFiBalance;
    }
}
