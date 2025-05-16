// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

// Additional Sonic-native protocol interfaces
interface ISonicNativeVault {
    function deposit(address asset, uint256 amount) external returns (uint256);
    function withdraw(address asset, uint256 amount) external returns (uint256);
}

interface ISonicLiquidityPool {
    function stake(address asset, uint256 amount) external returns (uint256);
    function unstake(address asset, uint256 amount) external returns (uint256);
}

/**
 * @title DeFiYield
 * @dev Manages yield generation for Sonic DeFi protocols, optimized for YieldOptimizer.
 */
contract DeFiYield is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    IERC20 public immutable stablecoin; // Sonic’s native USDC
    mapping(address => bool) public supportedProtocols;
    mapping(address => uint256) public defiBalances;
    uint256 public totalDeFiBalance;

    // Events
    event DepositDeFi(address indexed protocol, uint256 amount);
    event WithdrawDeFi(address indexed protocol, uint256 amount, uint256 profit);

    constructor(address _stablecoin, address[] memory _protocols) Ownable(msg.sender) {
        require(_stablecoin != address(0), "Invalid stablecoin address");
        stablecoin = IERC20(_stablecoin);
        for (uint256 i = 0; i < _protocols.length; i++) {
            require(_protocols[i] != address(0), "Invalid protocol address");
            supportedProtocols[_protocols[i]] = true;
        }
    }

    /**
     * @dev Deposits stablecoins into a DeFi protocol with gas-efficient approvals
     */
    function depositToDeFi(address protocol, uint256 amount) external nonReentrant {
        require(msg.sender == owner(), "Only YieldOptimizer");
        require(supportedProtocols[protocol], "Unsupported protocol");
        require(amount > 0, "Amount must be > 0");

        // Optimized approval to avoid redundant calls
        uint256 allowance = stablecoin.allowance(address(this), protocol);
        if (allowance < amount) {
            stablecoin.safeApprove(protocol, 0);
            stablecoin.safeApprove(protocol, type(uint256).max); // Max approval for gas efficiency
        }

        // Protocol-specific deposit logic
        if (protocol == address(0xSiloFinance)) {
            ISiloFinance(protocol).deposit(address(stablecoin), amount);
        } else if (protocol == address(0xBeets)) {
            IBeets(protocol).depositToPool(address(stablecoin), amount);
        } else if (protocol == address(0xRingsProtocol)) {
            IRingsProtocol(protocol).stake(address(stablecoin), amount);
        } else if (protocol == address(0xAave)) {
            IAave(protocol).supply(address(stablecoin), amount);
        } else if (protocol == address(0xEggsFinance)) {
            IEggsFinance(protocol).mintEggs(amount);
        } else if (protocol == address(0xSonicNativeVault)) {
            ISonicNativeVault(protocol).deposit(address(stablecoin), amount);
        } else if (protocol == address(0xSonicLiquidityPool)) {
            ISonicLiquidityPool(protocol).stake(address(stablecoin), amount);
        } else {
            revert("Unknown protocol");
        }

        defiBalances[protocol] = defiBalances[protocol].add(amount);
        totalDeFiBalance = totalDeFiBalance.add(amount);
        emit DepositDeFi(protocol, amount);
    }

    /**
     * @dev Withdraws stablecoins and profits with error handling
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

        try
            protocol == address(0xSiloFinance)
                ? ISiloFinance(protocol).withdraw(address(stablecoin), amount)
                : protocol == address(0xBeets)
                    ? IBeets(protocol).withdrawFromPool(address(stablecoin), amount)
                    : protocol == address(0xRingsProtocol)
                        ? IRingsProtocol(protocol).unstake(address(stablecoin), amount)
                        : protocol == address(0xAave)
                            ? IAave(protocol).withdraw(address(stablecoin), amount)
                            : protocol == address(0xEggsFinance)
                                ? IEggsFinance(protocol).redeemEggs(amount)
                                : protocol == address(0xSonicNativeVault)
                                    ? ISonicNativeVault(protocol).withdraw(address(stablecoin), amount)
                                    : ISonicLiquidityPool(protocol).unstake(address(stablecoin), amount)
        returns (uint256 amountWithdrawn) {
            withdrawn = amountWithdrawn;
        } catch {
            emit WithdrawDeFi(protocol, amount, 0);
            return 0;
        }

        uint256 profit = withdrawn > initialBalance ? withdrawn.sub(initialBalance) : 0;
        defiBalances[protocol] = defiBalances[protocol].sub(amount);
        totalDeFiBalance = totalDeFiBalance.sub(amount);

        if (withdrawn > 0) {
            stablecoin.safeTransfer(msg.sender, withdrawn);
        }

        emit WithdrawDeFi(protocol, amount, profit);
        return withdrawn;
    }

    function getTotalDeFiBalance() external view returns (uint256) {
        return totalDeFiBalance;
    }
}
