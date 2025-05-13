// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// OpenZeppelin imports for security, upgradability, and governance
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

// Interface for veNFT (Sonic's voting escrow token)
interface IVeNFT {
    function balanceOfNFT(uint256 tokenId) external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function locked(uint256 tokenId) external view returns (uint256 amount, uint256 end);
    function totalSupply() external view returns (uint256);
}

// Interface for SonicHarvest
interface ISonicHarvest {
    function proposeUpdateFees(uint256 newManagementFee, uint256 newPerformanceFee) external;
    function executeUpdateFees(uint256 newManagementFee, uint256 newPerformanceFee) external;
    function proposeFeeRecipientUpdate(address newRecipient) external;
    function executeFeeRecipientUpdate(address newRecipient) external;
    function proposeRecoverFunds(address protocol, uint256 amount) external;
    function executeRecoverFunds(address protocol, uint256 amount) external;
    function proposeEmergencyWithdraw(address user, uint256 amount) external;
    function executeEmergencyWithdraw(address user, uint256 amount) external;
    function proposeEmergencyTransfer(address user, uint256 amount) external;
    function executeEmergencyTransfer(address user, uint256 amount) external;
    function setProtocolWhitelist(address protocol, bool status, address apyFeed, bool isCompound) external;
    function setEmergencyPause(bool status) external;
    function toggleLeverage(bool status) external;
    function rebalance() external;
}

/**
 * @title Governance
 * @notice Decentralized governance for Sonic Harvest using veNFT-based voting.
 * @dev Manages proposals, voting, and timelock execution, integrating with SonicHarvest.sol.
 */
contract Governance is UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuard {
    using SafeMath for uint256;

    // State variables
    IVeNFT public immutable veNFT; // Sonic's veNFT for voting power
    ISonicHarvest public immutable sonicHarvest; // SonicHarvest contract
    uint256 public proposalThreshold; // Minimum veNFT balance to propose (1% of total supply)
    uint256 public votingPeriod; // Duration of voting (7 days)
    uint256 public timelockDelay; // Timelock for execution (2 days)
    uint256 public quorumPercentage; // Required vote participation (20%)
    uint256 public proposalCount; // Total proposals
    mapping(uint256 => Proposal) public proposals; // Proposal ID to details
    mapping(uint256 => mapping(address => bool)) public hasVoted; // Voter participation
    mapping(uint256 => mapping(uint256 => bool)) public nftVoted; // NFT voting status
    address public emergencyAdmin; // Emergency admin for fallback
    uint256 public lastEmergencyAction; // Last emergency action timestamp

    // Proposal struct
    struct Proposal {
        uint256 id;
        address proposer;
        string description;
        Action[] actions;
        uint256 startTime;
        uint256 endTime;
        uint256 forVotes;
        uint256 againstVotes;
        bool executed;
        bool canceled;
        ProposalState state;
    }

    // Action struct for proposals
    struct Action {
        address target; // Contract to call (SonicHarvest)
        bytes data; // Calldata for function execution
        uint256 value; // ETH value (0 for Sonic)
    }

    // Proposal states
    enum ProposalState {
        Pending,
        Active,
        Canceled,
        Defeated,
        Succeeded,
        Queued,
        Expired,
        Executed
    }

    // Constants
    uint256 private constant BASIS_POINTS = 10000; // For percentage calculations
    uint256 private constant MIN_VOTING_PERIOD = 3 days;
    uint256 private constant MAX_VOTING_PERIOD = 14 days;
    uint256 private constant MIN_QUORUM = 1000; // 10%
    uint256 private constant MAX_QUORUM = 5000; // 50%
    uint256 private constant MIN_PROPOSAL_THRESHOLD = 1e16; // 0.01% of veNFT supply
    uint256 private constant EMERGENCY_COOLDOWN = 1 days;
    uint256 private constant MAX_ACTIONS = 10; // Max actions per proposal

    // Events
    event ProposalCreated(uint256 indexed proposalId, address proposer, string description, uint256 startTime, uint256 endTime);
    event Voted(uint256 indexed proposalId, address voter, uint256 tokenId, bool support, uint256 weight);
    event ProposalCanceled(uint256 indexed proposalId);
    event ProposalQueued(uint256 indexed proposalId, uint256 eta);
    event ProposalExecuted(uint256 indexed proposalId);
    event EmergencyAction(address indexed target, bytes data, uint256 timestamp);
    event VotingPeriodUpdated(uint256 newPeriod);
    event QuorumUpdated(uint256 newQuorum);
    event ProposalThresholdUpdated(uint256 newThreshold);
    event EmergencyAdminUpdated(address indexed newAdmin);

    // Modifiers
    modifier onlyEmergencyAdmin() {
        require(msg.sender == emergencyAdmin, "Not emergency admin");
        _;
    }

    /**
     * @notice Initializes the governance contract.
     * @param _veNFT Address of the veNFT contract.
     * @param _sonicHarvest Address of the SonicHarvest contract.
     * @param _emergencyAdmin Address for emergency actions.
     */
    function initialize(
        address _veNFT,
        address _sonicHarvest,
        address _emergencyAdmin
    ) external initializer {
        require(_veNFT != address(0), "Invalid veNFT address");
        require(_sonicHarvest != address(0), "Invalid SonicHarvest address");
        require(_emergencyAdmin != address(0), "Invalid emergency admin");

        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        veNFT = IVeNFT(_veNFT);
        sonicHarvest = ISonicHarvest(_sonicHarvest);
        emergencyAdmin = _emergencyAdmin;
        proposalThreshold = veNFT.totalSupply().mul(100).div(BASIS_POINTS); // 1% of veNFT supply
        votingPeriod = 7 days;
        timelockDelay = 2 days;
        quorumPercentage = 2000; // 20%
        proposalCount = 0;
    }

    /**
     * @notice Proposes a new governance action.
     * @param actions Array of actions to execute.
     * @param description Proposal description.
     * @return Proposal ID.
     */
    function propose(
        Action[] calldata actions,
        string calldata description
    ) external nonReentrant whenNotPaused returns (uint256) {
        require(actions.length > 0 && actions.length <= MAX_ACTIONS, "Invalid action count");
        require(bytes(description).length > 0, "Description required");
        uint256 votingPower = _getVotingPower(msg.sender);
        require(votingPower >= proposalThreshold, "Below proposal threshold");

        proposalCount++;
        uint256 proposalId = proposalCount;
        Proposal storage newProposal = proposals[proposalId];
        newProposal.id = proposalId;
        newProposal.proposer = msg.sender;
        newProposal.description = description;
        newProposal.startTime = block.timestamp;
        newProposal.endTime = block.timestamp.add(votingPeriod);
        newProposal.forVotes = 0;
        newProposal.againstVotes = 0;
        newProposal.executed = false;
        newProposal.canceled = false;
        newProposal.state = ProposalState.Pending;

        for (uint256 i = 0; i < actions.length; i++) {
            require(actions[i].target == address(sonicHarvest), "Invalid target");
            newProposal.actions.push(actions[i]);
        }

        emit ProposalCreated(proposalId, msg.sender, description, newProposal.startTime, newProposal.endTime);
        return proposalId;
    }

    /**
     * @notice Votes on a proposal using an veNFT.
     * @param proposalId Proposal ID.
     * @param tokenId veNFT token ID.
     * @param support Vote for (true) or against (false).
     */
    function vote(uint256 proposalId, uint256 tokenId, bool support) external nonReentrant whenNotPaused {
        require(_state(proposalId) == ProposalState.Active, "Voting not active");
        require(veNFT.ownerOf(tokenId) == msg.sender, "Not NFT owner");
        require(!nftVoted[proposalId][tokenId], "NFT already voted");

        uint256 weight = veNFT.balanceOfNFT(tokenId);
        require(weight > 0, "No voting power");

        Proposal storage proposal = proposals[proposalId];
        if (support) {
            proposal.forVotes = proposal.forVotes.add(weight);
        } else {
            proposal.againstVotes = proposal.againstVotes.add(weight);
        }

        hasVoted[proposalId][msg.sender] = true;
        nftVoted[proposalId][tokenId] = true;

        emit Voted(proposalId, msg.sender, tokenId, support, weight);
    }

    /**
     * @notice Queues a successful proposal for execution.
     * @param proposalId Proposal ID.
     */
    function queue(uint256 proposalId) external nonReentrant whenNotPaused {
        require(_state(proposalId) == ProposalState.Succeeded, "Proposal not succeeded");
        Proposal storage proposal = proposals[proposalId];
        proposal.state = ProposalState.Queued;
        emit ProposalQueued(proposalId, block.timestamp.add(timelockDelay));
    }

    /**
     * @notice Executes a queued proposal.
     * @param proposalId Proposal ID.
     */
    function execute(uint256 proposalId) external nonReentrant whenNotPaused {
        require(_state(proposalId) == ProposalState.Queued, "Proposal not queued");
        require(block.timestamp >= proposals[proposalId].endTime.add(timelockDelay), "Timelock not elapsed");

        Proposal storage proposal = proposals[proposalId];
        proposal.executed = true;
        proposal.state = ProposalState.Executed;

        for (uint256 i = 0; i < proposal.actions.length; i++) {
            Action memory action = proposal.actions[i];
            (bool success, ) = action.target.call{value: action.value}(action.data);
            require(success, "Action execution failed");
        }

        emit ProposalExecuted(proposalId);
    }

    /**
     * @notice Cancels a proposal.
     * @param proposalId Proposal ID.
     */
    function cancel(uint256 proposalId) external nonReentrant {
        ProposalState state = _state(proposalId);
        require(state != ProposalState.Executed, "Already executed");
        require(msg.sender == proposals[proposalId].proposer || msg.sender == emergencyAdmin, "Not authorized");

        Proposal storage proposal = proposals[proposalId];
        proposal.canceled = true;
        proposal.state = ProposalState.Canceled;
        emit ProposalCanceled(proposalId);
    }

    /**
     * @notice Performs an emergency action (fallback for critical failures).
     * @param target Contract to call (SonicHarvest).
     * @param data Calldata for function execution.
     */
    function emergencyAction(address target, bytes calldata data) external onlyEmergencyAdmin nonReentrant {
        require(block.timestamp >= lastEmergencyAction.add(EMERGENCY_COOLDOWN), "Cooldown not elapsed");
        require(target == address(sonicHarvest), "Invalid target");

        (bool success, ) = target.call(data);
        require(success, "Emergency action failed");

        lastEmergencyAction = block.timestamp;
        emit EmergencyAction(target, data, block.timestamp);
    }

    /**
     * @notice Updates the voting period.
     * @param newPeriod New voting period in seconds.
     */
    function updateVotingPeriod(uint256 newPeriod) external onlyOwner {
        require(newPeriod >= MIN_VOTING_PERIOD && newPeriod <= MAX_VOTING_PERIOD, "Invalid period");
        votingPeriod = newPeriod;
        emit VotingPeriodUpdated(newPeriod);
    }

    /**
     * @notice Updates the quorum percentage.
     * @param newQuorum New quorum percentage in basis points.
     */
    function updateQuorum(uint256 newQuorum) external onlyOwner {
        require(newQuorum >= MIN_QUORUM && newQuorum <= MAX_QUORUM, "Invalid quorum");
        quorumPercentage = newQuorum;
        emit QuorumUpdated(newQuorum);
    }

    /**
     * @notice Updates the proposal threshold.
     * @param newThreshold New threshold as a fraction of veNFT supply.
     */
    function updateProposalThreshold(uint256 newThreshold) external onlyOwner {
        require(newThreshold >= MIN_PROPOSAL_THRESHOLD, "Invalid threshold");
        proposalThreshold = newThreshold;
        emit ProposalThresholdUpdated(newThreshold);
    }

    /**
     * @notice Updates the emergency admin.
     * @param newAdmin New emergency admin address.
     */
    function updateEmergencyAdmin(address newAdmin) external onlyOwner {
        require(newAdmin != address(0), "Invalid address");
        emergencyAdmin = newAdmin;
        emit EmergencyAdminUpdated(newAdmin);
    }

    /**
     * @notice Proposes a contract upgrade with timelock.
     * @param newImplementation Address of the new implementation.
     */
    function proposeUpgrade(address newImplementation) external onlyOwner {
        require(newImplementation != address(0), "Invalid implementation");
        _authorizeUpgrade(newImplementation);
    }

    /**
     * @notice Authorizes contract upgrades.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        // Timelock handled by SonicHarvest's proposeUpgrade
    }

    /**
     * @notice Gets the state of a proposal.
     * @param proposalId Proposal ID.
     * @return Proposal state.
     */
    function _state(uint256 proposalId) internal view returns (ProposalState) {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.canceled) {
            return ProposalState.Canceled;
        } else if (proposal.executed) {
            return ProposalState.Executed;
        } else if (block.timestamp < proposal.startTime) {
            return ProposalState.Pending;
        } else if (block.timestamp <= proposal.endTime) {
            return ProposalState.Active;
        } else if (!_quorumReached(proposalId) || proposal.forVotes <= proposal.againstVotes) {
            return ProposalState.Defeated;
        } else if (block.timestamp <= proposal.endTime.add(timelockDelay)) {
            return ProposalState.Succeeded;
        } else if (block.timestamp <= proposal.endTime.add(timelockDelay).add(1 days)) {
            return ProposalState.Queued;
        } else {
            return ProposalState.Expired;
        }
    }

    /**
     * @notice Checks if quorum is reached for a proposal.
     * @param proposalId Proposal ID.
     * @return True if quorum reached.
     */
    function _quorumReached(uint256 proposalId) internal view returns (bool) {
        Proposal storage proposal = proposals[proposalId];
        uint256 totalVotes = proposal.forVotes.add(proposal.againstVotes);
        uint256 totalSupply = veNFT.totalSupply();
        return totalVotes.mul(BASIS_POINTS).div(totalSupply) >= quorumPercentage;
    }

    /**
     * @notice Gets the voting power of an address.
     * @param user Address to query.
     * @return Total voting power.
     */
    function _getVotingPower(address user) internal view returns (uint256) {
        uint256 power = 0;
        // Iterate through user's NFTs (simplified; assumes external NFT enumeration)
        for (uint256 i = 1; i <= veNFT.totalSupply(); i++) {
            try veNFT.ownerOf(i) returns (address owner) {
                if (owner == user) {
                    power = power.add(veNFT.balanceOfNFT(i));
                }
            } catch {
                continue;
            }
        }
        return power;
    }

    /**
     * @notice Gets proposal details.
     * @param proposalId Proposal ID.
     * @return Proposal struct.
     */
    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        return proposals[proposalId];
    }

    /**
     * @notice Gets the voting status of an address for a proposal.
     * @param proposalId Proposal ID.
     * @param user Address to query.
     * @return True if voted.
     */
    function hasUserVoted(uint256 proposalId, address user) external view returns (bool) {
        return hasVoted[proposalId][user];
    }
}
