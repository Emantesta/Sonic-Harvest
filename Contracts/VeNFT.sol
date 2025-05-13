// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title VeNFT
 * @notice Voting Escrow NFT contract for Sonic Harvest governance on Sonic Blockchain.
 * @dev Locks S tokens to mint soulbound veNFTs for voting power in Governance.sol.
 *      Supports lock creation, extension, withdrawal, and delegation.
 */
contract VeNFT is ERC721, ERC721Enumerable, ReentrancyGuard, Ownable {
    using SafeMath for uint256;

    IERC20 public immutable sToken; // S token for locking
    uint256 public tokenIdCounter; // Tracks next token ID
    uint256 public constant MAX_LOCK_TIME = 4 * 365 days; // 4 years
    uint256 public constant MIN_LOCK_TIME = 30 days; // 1 month
    uint256 public constant WEEK = 7 days; // For lock time alignment

    // Locked balance per veNFT
    struct LockedBalance {
        uint256 amount; // S tokens locked
        uint256 end; // Lock expiration timestamp
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
    event LockCreated(address indexed user, uint256 indexed tokenId, uint256 amount, uint256 lockEnd);
    event LockExtended(address indexed user, uint256 indexed tokenId, uint256 newAmount, uint256 newLockEnd);
    event LockWithdrawn(address indexed user, uint256 indexed tokenId, uint256 amount);
    event Delegated(address indexed delegator, address indexed delegatee, uint256 indexed tokenId);
    event Undelegated(address indexed delegator, address indexed delegatee, uint256 indexed tokenId);

    /**
     * @notice Constructor for VeNFT.
     * @param _sToken Address of the S token contract.
     * @param _owner Initial owner for administrative functions.
     */
    constructor(address _sToken, address _owner) ERC721("Sonic Voting Escrow NFT", "veNFT") Ownable(_owner) {
        require(_sToken != address(0), "Invalid S token address");
        require(_owner != address(0), "Invalid owner address");
        sToken = IERC20(_sToken);
        tokenIdCounter = 1;
    }

    /**
     * @notice Locks S tokens to mint a veNFT.
     * @param amount Amount of S tokens to lock.
     * @param lockTime Lock duration in seconds (1 month to 4 years, week-aligned).
     * @return tokenId The minted veNFT ID.
     */
    function createLock(uint256 amount, uint256 lockTime) external nonReentrant returns (uint256) {
        require(amount > 0, "Zero amount");
        require(lockTime >= MIN_LOCK_TIME && lockTime <= MAX_LOCK_TIME, "Invalid lock time");
        require(lockTime % WEEK == 0, "Lock time must be week-aligned");
        require(sToken.balanceOf(msg.sender) >= amount, "Insufficient S tokens");
        require(sToken.allowance(msg.sender, address(this)) >= amount, "Approve S tokens");

        uint256 tokenId = tokenIdCounter++;
        uint256 lockEnd = block.timestamp.add(lockTime);

        // Transfer S tokens to contract
        sToken.transferFrom(msg.sender, address(this), amount);

        // Mint veNFT
        _safeMint(msg.sender, tokenId);
        locked[tokenId] = LockedBalance(amount, lockEnd);
        userTokens[msg.sender].push(tokenId);

        emit LockCreated(msg.sender, tokenId, amount, lockEnd);
        return tokenId;
    }

    /**
     * @notice Extends an existing lock by adding tokens or time.
     * @param tokenId veNFT ID to extend.
     * @param additionalAmount Additional S tokens to lock (can be 0).
     * @param additionalTime Additional lock time in seconds (can be 0, week-aligned).
     */
    function extendLock(uint256 tokenId, uint256 additionalAmount, uint256 additionalTime) external nonReentrant {
        require(_isApprovedOrOwner(msg.sender, tokenId), "Not owner or approved");
        require(locked[tokenId].amount > 0, "No locked amount");
        require(block.timestamp < locked[tokenId].end, "Lock expired");
        require(additionalAmount > 0 || additionalTime > 0, "No extension provided");
        if (additionalTime > 0) {
            require(additionalTime % WEEK == 0, "Additional time must be week-aligned");
            require(locked[tokenId].end.add(additionalTime) <= block.timestamp.add(MAX_LOCK_TIME), "Exceeds max lock time");
        }
        if (additionalAmount > 0) {
            require(sToken.balanceOf(msg.sender) >= additionalAmount, "Insufficient S tokens");
            require(sToken.allowance(msg.sender, address(this)) >= additionalAmount, "Approve S tokens");
            sToken.transferFrom(msg.sender, address(this), additionalAmount);
        }

        LockedBalance storage lock = locked[tokenId];
        lock.amount = lock.amount.add(additionalAmount);
        if (additionalTime > 0) {
            lock.end = lock.end.add(additionalTime);
        }

        // Update delegation if active
        if (delegations[tokenId].delegatee != address(0)) {
            _updateDelegatedPower(tokenId, delegations[tokenId].delegatee);
        }

        emit LockExtended(msg.sender, tokenId, lock.amount, lock.end);
    }

    /**
     * @notice Withdraws S tokens after lock expiration.
     * @param tokenId veNFT ID to unlock.
     */
    function withdraw(uint256 tokenId) external nonReentrant {
        require(_isApprovedOrOwner(msg.sender, tokenId), "Not owner or approved");
        LockedBalance memory lock = locked[tokenId];
        require(block.timestamp >= lock.end, "Lock not expired");
        require(lock.amount > 0, "No locked amount");

        // Remove delegation if active
        if (delegations[tokenId].delegatee != address(0)) {
            address delegatee = delegations[tokenId].delegatee;
            delegatedVotingPower[delegatee] = delegatedVotingPower[delegatee].sub(lock.amount);
            emit Undelegated(msg.sender, delegatee, tokenId);
            delete delegations[tokenId];
        }

        // Burn veNFT
        _burn(tokenId);
        delete locked[tokenId];

        // Remove from user's token list
        uint256[] storage tokens = userTokens[msg.sender];
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == tokenId) {
                tokens[i] = tokens[tokens.length - 1];
                tokens.pop();
                break;
            }
        }

        // Transfer S tokens back
        sToken.transfer(msg.sender, lock.amount);

        emit LockWithdrawn(msg.sender, tokenId, lock.amount);
    }

    /**
     * @notice Delegates voting power of a veNFT to another address.
     * @param tokenId veNFT ID to delegate.
     * @param delegatee Address to receive voting power.
     */
    function delegate(uint256 tokenId, address delegatee) external nonReentrant {
        require(_isApprovedOrOwner(msg.sender, tokenId), "Not owner or approved");
        require(delegatee != address(0), "Invalid delegatee");
        require(delegatee != msg.sender, "Cannot delegate to self");
        require(locked[tokenId].amount > 0, "No locked amount");
        require(block.timestamp < locked[tokenId].end, "Lock expired");

        // Remove existing delegation
        if (delegations[tokenId].delegatee != address(0)) {
            address oldDelegatee = delegations[tokenId].delegatee;
            delegatedVotingPower[oldDelegatee] = delegatedVotingPower[oldDelegatee].sub(locked[tokenId].amount);
            emit Undelegated(msg.sender, oldDelegatee, tokenId);
        }

        // Set new delegation
        delegations[tokenId] = Delegation(delegatee, block.timestamp);
        _updateDelegatedPower(tokenId, delegatee);

        emit Delegated(msg.sender, delegatee, tokenId);
    }

    /**
     * @notice Removes delegation from a veNFT.
     * @param tokenId veNFT ID to undelegate.
     */
    function undelegate(uint256 tokenId) external nonReentrant {
        require(_isApprovedOrOwner(msg.sender, tokenId), "Not owner or approved");
        require(delegations[tokenId].delegatee != address(0), "No delegation");

        address delegatee = delegations[tokenId].delegatee;
        delegatedVotingPower[delegatee] = delegatedVotingPower[delegatee].sub(locked[tokenId].amount);
        emit Undelegated(msg.sender, delegatee, tokenId);
        delete delegations[tokenId];
    }

    /**
     * @notice Gets voting power of a veNFT.
     * @param tokenId veNFT ID.
     * @return Voting power (amount * remaining time / max lock time).
     */
    function balanceOfNFT(uint256 tokenId) public view returns (uint256) {
        LockedBalance memory lock = locked[tokenId];
        if (lock.amount == 0 || block.timestamp >= lock.end) {
            return 0;
        }
        uint256 remainingTime = lock.end.sub(block.timestamp);
        return lock.amount.mul(remainingTime).div(MAX_LOCK_TIME);
    }

    /**
     * @notice Gets locked S tokens and end time for a veNFT.
     * @param tokenId veNFT ID.
     * @return amount Locked S tokens.
     * @return end Lock expiration timestamp.
     */
    function locked(uint256 tokenId) external view returns (uint256 amount, uint256 end) {
        LockedBalance memory lock = locked[tokenId];
        return (lock.amount, lock.end);
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
     * @notice Updates delegated voting power for a delegatee.
     * @param tokenId veNFT ID.
     * @param delegatee Address receiving delegated power.
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
