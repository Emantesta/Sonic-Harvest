// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// Interface for Governance contract
interface IGovernance {
    function rewardDistributor() external view returns (address);
    function isValidVoter(address voter) external view returns (bool);
}

// Interface for YieldOptimizer
interface IYieldOptimizer {
    function depositToProtocol(address token, uint256 amount, address protocol) external;
    function withdrawFromProtocol(address token, uint256 amount, address protocol) external returns (uint256);
}

/**
 * @title VeNFT
 * @notice Voting Escrow NFT contract for Sonic Harvest governance.
 * @dev Locks S tokens to mint soulbound veNFTs, supports Governance.sol, RewardDistributor.sol, and YieldOptimizer.sol integration.
 */
contract VeNFT is ERC721, ERC721Enumerable, ReentrancyGuard, Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IERC20 public immutable sToken; // S token for locking
    address public governance; // Governance contract address
    address public yieldOptimizer; // YieldOptimizer contract address
    uint256 public tokenIdCounter; // Tracks next token ID
    uint256 public constant MAX_LOCK_TIME = 4 * 365 days; // 4 years
    uint256 public constant MIN_LOCK_TIME = 30 days; // 1 month
    uint256 public constant WEEK = 7 days; // For lock time alignment
    uint256 public totalLocked; // Total S tokens locked
    mapping(address => bool) public yieldProtocols; // Approved yield protocols

    // Locked balance per veNFT
    struct LockedBalance {
        uint256 amount; // S tokens locked
        uint256 end; // Lock expiration timestamp
        address yieldProtocol; // Protocol where tokens are staked (if any)
    }

    // Delegation info per veNFT
    struct Delegation {
        address delegatee; // Address delegated to
        uint256 delegatedAt; // Timestamp of delegation
    }

    mapping(uint256 => LockedBalance) public locked; // tokenId => LockedBalance
    mapping(uint256 => Delegation) public delegations; // tokenId => Delegation
    mapping(address => uint256[]) public userTokens; // User => list of owned token IDs
    mapping(address => uint256) public delegatedVotingPower; // Delegatee => total delegated power

    // Events
    event LockCreated(address indexed user, uint256 indexed tokenId, uint256 amount, uint256 lockEnd, address yieldProtocol);
    event LockExtended(address indexed user, uint256 indexed tokenId, uint256 newAmount, uint256 newLockEnd);
    event LockWithdrawn(address indexed user, uint256 indexed tokenId, uint256 amount);
    event Delegated(address indexed delegator, address indexed delegatee, uint256 indexed tokenId);
    event Undelegated(address indexed delegator, address indexed delegatee, uint256 indexed tokenId);
    event GovernanceUpdated(address indexed newGovernance);
    event YieldOptimizerUpdated(address indexed newYieldOptimizer);
    event YieldProtocolAdded(address indexed protocol);
    event YieldProtocolRemoved(address indexed protocol);
    event TokensStaked(address indexed user, uint256 indexed tokenId, address indexed protocol, uint256 amount);
    event TokensUnstaked(address indexed user, uint256 indexed tokenId, address indexed protocol, uint256 amount);

    // Errors
    error ZeroAddress();
    error ZeroAmount();
    error InvalidLockTime();
    error LockExpired();
    error NotOwnerOrApproved();
    error NoLockedAmount();
    error InvalidDelegatee();
    error AlreadyDelegated();
    error NoDelegation();
    error TokensStaked();
    error InvalidProtocol();

    /**
     * @notice Constructor for VeNFT.
     * @param _sToken Address of the S token contract.
     * @param _governance Governance contract address.
     * @param _yieldOptimizer YieldOptimizer contract address.
     * @param _owner Initial owner address.
     */
    constructor(address _sToken, address _governance, address _yieldOptimizer, address _owner)
        ERC721("Sonic Voting Escrow NFT", "veNFT")
        Ownable(_owner)
    {
        if (_sToken == address(0) || _governance == address(0) || _yieldOptimizer == address(0) || _owner == address(0))
            revert ZeroAddress();
        sToken = IERC20(_sToken);
        governance = _governance;
        yieldOptimizer = _yieldOptimizer;
        tokenIdCounter = 1;
        emit GovernanceUpdated(_governance);
        emit YieldOptimizerUpdated(_yieldOptimizer);
    }

    /**
     * @notice Locks S tokens to mint a veNFT, optionally staking in YieldOptimizer.
     * @param amount Amount of S tokens to lock.
     * @param lockTime Lock duration in seconds.
     * @param yieldProtocol Protocol to stake tokens in (address(0) for none).
     * @return tokenId The minted veNFT ID.
     */
    function createLock(uint256 amount, uint256 lockTime, address yieldProtocol)
        external
        nonReentrant
        returns (uint256)
    {
        if (amount == 0) revert ZeroAmount();
        if (lockTime < MIN_LOCK_TIME || lockTime > MAX_LOCK_TIME || lockTime % WEEK != 0) revert InvalidLockTime();
        if (yieldProtocol != address(0) && !yieldProtocols[yieldProtocol]) revert InvalidProtocol();
        if (sToken.balanceOf(msg.sender) < amount || sToken.allowance(msg.sender, address(this)) < amount)
            revert ZeroAmount();

        uint256 tokenId = tokenIdCounter++;
        uint256 lockEnd = block.timestamp.add(lockTime);

        sToken.safeTransferFrom(msg.sender, address(this), amount);
        if (yieldProtocol != address(0)) {
            sToken.safeApprove(yieldOptimizer, amount);
            IYieldOptimizer(yieldOptimizer).depositToProtocol(address(sToken), amount, yieldProtocol);
            emit TokensStaked(msg.sender, tokenId, yieldProtocol, amount);
        }

        _safeMint(msg.sender, tokenId);
        locked[tokenId] = LockedBalance(amount, lockEnd, yieldProtocol);
        userTokens[msg.sender].push(tokenId);
        totalLocked = totalLocked.add(amount);

        emit LockCreated(msg.sender, tokenId, amount, lockEnd, yieldProtocol);
        return tokenId;
    }

    /**
     * @notice Extends an existing lock by adding tokens or time.
     * @param tokenId veNFT ID.
     * @param additionalAmount Additional S tokens (0 if none).
     * @param additionalTime Additional lock time (0 if none).
     */
    function extendLock(uint256 tokenId, uint256 additionalAmount, uint256 additionalTime)
        external
        nonReentrant
    {
        if (!_isApprovedOrOwner(msg.sender, tokenId)) revert NotOwnerOrApproved();
        if (locked[tokenId].amount == 0) revert NoLockedAmount();
        if (block.timestamp >= locked[tokenId].end) revert LockExpired();
        if (additionalAmount == 0 && additionalTime == 0) revert ZeroAmount();
        if (additionalTime > 0 && (additionalTime % WEEK != 0 || locked[tokenId].end.add(additionalTime) > block.timestamp.add(MAX_LOCK_TIME)))
            revert InvalidLockTime();
        if (locked[tokenId].yieldProtocol != address(0)) revert TokensStaked();
        if (additionalAmount > 0 && (sToken.balanceOf(msg.sender) < additionalAmount || sToken.allowance(msg.sender, address(this)) < additionalAmount))
            revert ZeroAmount();

        LockedBalance storage lock = locked[tokenId];
        if (additionalAmount > 0) {
            sToken.safeTransferFrom(msg.sender, address(this), additionalAmount);
            lock.amount = lock.amount.add(additionalAmount);
            totalLocked = totalLocked.add(additionalAmount);
        }
        if (additionalTime > 0) {
            lock.end = lock.end.add(additionalTime);
        }

        if (delegations[tokenId].delegatee != address(0)) {
            _updateDelegatedPower(tokenId, delegations[tokenId].delegatee);
        }

        emit LockExtended(msg.sender, tokenId, lock.amount, lock.end);
    }

    /**
     * @notice Withdraws S tokens after lock expiration.
     * @param tokenId veNFT ID.
     */
    function withdraw(uint256 tokenId) external nonReentrant {
        if (!_isApprovedOrOwner(msg.sender, tokenId)) revert NotOwnerOrApproved();
        LockedBalance memory lock = locked[tokenId];
        if (block.timestamp < lock.end) revert LockExpired();
        if (lock.amount == 0) revert NoLockedAmount();

        if (lock.yieldProtocol != address(0)) {
            uint256 withdrawn = IYieldOptimizer(yieldOptimizer).withdrawFromProtocol(address(sToken), lock.amount, lock.yieldProtocol);
            if (withdrawn < lock.amount) revert ZeroAmount();
            emit TokensUnstaked(msg.sender, tokenId, lock.yieldProtocol, withdrawn);
        }

        if (delegations[tokenId].delegatee != address(0)) {
            address delegatee = delegations[tokenId].delegatee;
            delegatedVotingPower[delegatee] = delegatedVotingPower[delegatee].sub(lock.amount);
            emit Undelegated(msg.sender, delegatee, tokenId);
            delete delegations[tokenId];
        }

        _burn(tokenId);
        totalLocked = totalLocked.sub(lock.amount);
        delete locked[tokenId];

        uint256[] storage tokens = userTokens[msg.sender];
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == tokenId) {
                tokens[i] = tokens[tokens.length - 1];
                tokens.pop();
                break;
            }
        }

        sToken.safeTransfer(msg.sender, lock.amount);
        emit LockWithdrawn(msg.sender, tokenId, lock.amount);
    }

    /**
     * @notice Delegates voting power of a veNFT.
     * @param tokenId veNFT ID.
     * @param delegatee Address to delegate to.
     */
    function delegate(uint256 tokenId, address delegatee) external nonReentrant {
        if (!_isApprovedOrOwner(msg.sender, tokenId)) revert NotOwnerOrApproved();
        if (delegatee == address(0) || delegatee == msg.sender) revert InvalidDelegatee();
        if (locked[tokenId].amount == 0 || block.timestamp >= locked[tokenId].end) revert NoLockedAmount();
        if (!IGovernance(governance).isValidVoter(delegatee)) revert InvalidDelegatee();

        if (delegations[tokenId].delegatee != address(0)) {
            address oldDelegatee = delegations[tokenId].delegatee;
            delegatedVotingPower[oldDelegatee] = delegatedVotingPower[oldDelegatee].sub(balanceOfNFT(tokenId));
            emit Undelegated(msg.sender, oldDelegatee, tokenId);
        }

        delegations[tokenId] = Delegation(delegatee, block.timestamp);
        _updateDelegatedPower(tokenId, delegatee);
        emit Delegated(msg.sender, delegatee, tokenId);
    }

    /**
     * @notice Removes delegation from a veNFT.
     * @param tokenId veNFT ID.
     */
    function undelegate(uint256 tokenId) external nonReentrant {
        if (!_isApprovedOrOwner(msg.sender, tokenId)) revert NotOwnerOrApproved();
        if (delegations[tokenId].delegatee == address(0)) revert NoDelegation();

        address delegatee = delegations[tokenId].delegatee;
        delegatedVotingPower[delegatee] = delegatedVotingPower[delegatee].sub(balanceOfNFT(tokenId));
        emit Undelegated(msg.sender, delegatee, tokenId);
        delete delegations[tokenId];
    }

    /**
     * @notice Stakes locked S tokens in a yield protocol via YieldOptimizer.
     * @param tokenId veNFT ID.
     * @param yieldProtocol Protocol to stake in.
     */
    function stakeInYieldProtocol(uint256 tokenId, address yieldProtocol) external nonReentrant {
        if (!_isApprovedOrOwner(msg.sender, tokenId)) revert NotOwnerOrApproved();
        if (locked[tokenId].amount == 0 || block.timestamp >= locked[tokenId].end) revert NoLockedAmount();
        if (locked[tokenId].yieldProtocol != address(0)) revert TokensStaked();
        if (!yieldProtocols[yieldProtocol]) revert InvalidProtocol();

        LockedBalance storage lock = locked[tokenId];
        sToken.safeApprove(yieldOptimizer, lock.amount);
        IYieldOptimizer(yieldOptimizer).depositToProtocol(address(sToken), lock.amount, yieldProtocol);
        lock.yieldProtocol = yieldProtocol;
        emit TokensStaked(msg.sender, tokenId, yieldProtocol, lock.amount);
    }

    /**
     * @notice Unstakes locked S tokens from a yield protocol.
     * @param tokenId veNFT ID.
     */
    function unstakeFromYieldProtocol(uint256 tokenId) external nonReentrant {
        if (!_isApprovedOrOwner(msg.sender, tokenId)) revert NotOwnerOrApproved();
        if (locked[tokenId].amount == 0 || block.timestamp >= locked[tokenId].end) revert NoLockedAmount();
        if (locked[tokenId].yieldProtocol == address(0)) revert InvalidProtocol();

        LockedBalance storage lock = locked[tokenId];
        address yieldProtocol = lock.yieldProtocol;
        uint256 withdrawn = IYieldOptimizer(yieldOptimizer).withdrawFromProtocol(address(sToken), lock.amount, yieldProtocol);
        if (withdrawn < lock.amount) revert ZeroAmount();
        lock.yieldProtocol = address(0);
        emit TokensUnstaked(msg.sender, tokenId, yieldProtocol, withdrawn);
    }

    /**
     * @notice Updates the Governance contract address.
     * @param newGovernance New Governance address.
     */
    function updateGovernance(address newGovernance) external onlyOwner {
        if (newGovernance == address(0)) revert ZeroAddress();
        if (IGovernance(newGovernance).rewardDistributor() != address(this)) revert InvalidDelegatee();
        governance = newGovernance;
        emit GovernanceUpdated(newGovernance);
    }

    /**
     * @notice Updates the YieldOptimizer contract address.
     * @param newYieldOptimizer New YieldOptimizer address.
     */
    function updateYieldOptimizer(address newYieldOptimizer) external onlyOwner {
        if (newYieldOptimizer == address(0)) revert ZeroAddress();
        yieldOptimizer = newYieldOptimizer;
        emit YieldOptimizerUpdated(newYieldOptimizer);
    }

    /**
     * @notice Adds a yield protocol for staking.
     * @param protocol Protocol address.
     */
    function addYieldProtocol(address protocol) external onlyOwner {
        if (protocol == address(0)) revert ZeroAddress();
        yieldProtocols[protocol] = true;
        emit YieldProtocolAdded(protocol);
    }

    /**
     * @notice Removes a yield protocol.
     * @param protocol Protocol address.
     */
    function removeYieldProtocol(address protocol) external onlyOwner {
        if (!yieldProtocols[protocol]) revert InvalidProtocol();
        yieldProtocols[protocol] = false;
        emit YieldProtocolRemoved(protocol);
    }

    /**
     * @notice Gets voting power of a veNFT.
     * @param tokenId veNFT ID.
     * @return Voting power (amount * remaining time / max lock time).
     */
    function balanceOfNFT(uint256 tokenId) public view returns (uint256) {
        LockedBalance memory lock = locked[tokenId];
        if (lock.amount == 0 || block.timestamp >= lock.end) return 0;
        uint256 remainingTime = lock.end.sub(block.timestamp);
        return lock.amount.mul(remainingTime).div(MAX_LOCK_TIME);
    }

    /**
     * @notice Gets locked S tokens and end time for a veNFT.
     * @param tokenId veNFT ID.
     * @return amount Locked S tokens.
     * @return end Lock expiration timestamp.
     * @return yieldProtocol Staking protocol (if any).
     */
    function getLocked(uint256 tokenId) external view returns (uint256 amount, uint256 end, address yieldProtocol) {
        LockedBalance memory lock = locked[tokenId];
        return (lock.amount, lock.end, lock.yieldProtocol);
    }

    /**
     * @notice Gets total veNFT supply.
     * @return Total minted veNFTs.
     */
    function totalSupply() public view override(ERC721, ERC721Enumerable) returns (uint256) {
        return tokenIdCounter.sub(1);
    }

    /**
     * @notice Gets total voting power delegated to an address.
     * @param delegatee Address to query.
     * @return Total delegated voting power.
     */
    function getDelegatedVotingPower(address delegatee) external view returns (uint256) {
        return delegatedVotingPower[delegatee];
    }

    /**
     * @notice Gets all veNFTs owned by a user.
     * @param user Address to query.
     * @return Array of token IDs.
     */
    function getUserTokens(address user) external view returns (uint256[] memory) {
        return userTokens[user];
    }

    /**
     * @notice Updates delegated voting power.
     */
    function _updateDelegatedPower(uint256 tokenId, address delegatee) internal {
        uint256 votingPower = balanceOfNFT(tokenId);
        delegatedVotingPower[delegatee] = delegatedVotingPower[delegatee].add(votingPower);
    }

    /**
     * @notice Prevents veNFT transfers (soulbound).
     */
    function _beforeTokenTransfer(address from, address to, uint256 tokenId)
        internal
        override(ERC721, ERC721Enumerable)
    {
        require(from == address(0) || to == address(0), "veNFT is soulbound");
        super._beforeTokenTransfer(from, to, tokenId);
    }

    /**
     * @notice Required for ERC721Enumerable.
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
