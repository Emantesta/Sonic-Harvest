// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IAaveV3Pool {
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf) external;
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf) external returns (uint256);
}

interface ICompound {
    function getAccountLiquidity(address account) external view returns (uint256, uint256, uint256);
    function borrow(uint256 borrowAmount) external returns (uint256);
    function repayBorrow(uint256 repayAmount) external returns (uint256);
}

interface IFlyingTulip {
    function depositToPool(address pool, uint256 amount, bool useLeverage) external returns (uint256);
    function withdrawFromPool(address pool, uint256 amount) external returns (uint256);
    function getLTV(address pool, uint256 collateral) external view returns (uint256);
    function borrowWithLTV(address pool, uint256 collateral, uint256 borrowAmount) external;
    function repayBorrow(address pool, uint256 amount) external;
    function isProtocolHealthy(address pool) external view returns (bool);
}

interface IRiskManager {
    function assessLeverageViability(address protocol, uint256 amount, uint256 ltv, bool isRWA) external view returns (bool);
}

interface IRWAYield {
    function getAvailableLiquidity(address protocol) external view returns (uint256);
}

contract LooperCore is UUPSUpgradeable, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    IERC20 public stablecoin;
    IAaveV3Pool public aavePool;
    ICompound public compound;
    IFlyingTulip public flyingTulip;
    IRiskManager public riskManager;
    IRWAYield public rwaYield;
    address public governance;
    uint256 public constant MAX_LTV = 8000;
    uint256 public constant MIN_HEALTH_FACTOR = 1.5e18;
    uint256 public constant MIN_COLLATERAL_FACTOR = 1.5e18;
    uint256 public constant AAVE_REFERRAL_CODE = 0;

    event LeverageApplied(address indexed protocol, uint256 collateral, uint256 borrowAmount);
    event LeverageUnwound(address indexed protocol, uint256 repayAmount);

    modifier onlyGovernance() {
        require(msg.sender == governance, "Not governance");
        _;
    }

    function initialize(
        address _stablecoin,
        address _aavePool,
        address _compound,
        address _flyingTulip,
        address _riskManager,
        address _rwaYield,
        address _governance
    ) external initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        stablecoin = IERC20(_stablecoin);
        aavePool = IAaveV3Pool(_aavePool);
        compound = ICompound(_compound);
        flyingTulip = IFlyingTulip(_flyingTulip);
        riskManager = IRiskManager(_riskManager);
        rwaYield = IRWAYield(_rwaYield);
        governance = _governance;
    }

    function applyLeverage(address protocol, uint256 amount, uint256 ltv, bool isRWA) external onlyGovernance {
        require(riskManager.assessLeverageViability(protocol, amount, ltv, isRWA), "Leverage not viable");
        uint256 borrowAmount = (amount * ltv) / 10000;
        if (isRWA) {
            stablecoin.safeApprove(address(flyingTulip), 0);
            stablecoin.safeApprove(address(flyingTulip), borrowAmount);
            flyingTulip.borrowWithLTV(protocol, amount, borrowAmount);
        } else if (protocol == address(aavePool)) {
            (, , uint256 availableBorrowsBase, , , uint256 healthFactor) = aavePool.getUserAccountData(address(this));
            require(healthFactor >= MIN_HEALTH_FACTOR && borrowAmount <= availableBorrowsBase, "Aave borrow invalid");
            stablecoin.safeApprove(protocol, 0);
            stablecoin.safeApprove(protocol, borrowAmount);
            aavePool.borrow(address(stablecoin), borrowAmount, 2, AAVE_REFERRAL_CODE, address(this));
        } else if (protocol == address(compound)) {
            (, uint256 collateralFactor, uint256 liquidity) = compound.getAccountLiquidity(address(this));
            require(collateralFactor >= MIN_COLLATERAL_FACTOR && borrowAmount <= liquidity, "Compound borrow invalid");
            stablecoin.safeApprove(protocol, 0);
            stablecoin.safeApprove(protocol, borrowAmount);
            require(compound.borrow(borrowAmount) == 0, "Compound borrow failed");
        }
        emit LeverageApplied(protocol, amount, borrowAmount);
    }

    function unwindLeverage(address protocol, uint256 repayAmount, bool isRWA) external onlyGovernance {
        stablecoin.safeApprove(protocol, 0);
        stablecoin.safeApprove(protocol, repayAmount);
        if (isRWA) {
            stablecoin.safeApprove(address(flyingTulip), 0);
            stablecoin.safeApprove(address(flyingTulip), repayAmount);
            flyingTulip.repayBorrow(protocol, repayAmount);
        } else if (protocol == address(aavePool)) {
            aavePool.repay(address(stablecoin), repayAmount, 2, address(this));
        } else if (protocol == address(compound)) {
            require(compound.repayBorrow(repayAmount) == 0, "Compound repay failed");
        }
        emit LeverageUnwound(protocol, repayAmount);
    }

    function checkLiquidationRisk(address protocol, uint256 collateral, uint256 borrowAmount, bool isRWA) external view returns (bool) {
        if (isRWA) {
            return flyingTulip.isProtocolHealthy(protocol) &&
                   flyingTulip.getLTV(protocol, collateral) <= MAX_LTV &&
                   rwaYield.getAvailableLiquidity(protocol) >= borrowAmount;
        } else {
            return true; // Simplified for non-RWA (extend as needed)
        }
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
