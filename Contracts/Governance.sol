// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// OpenZeppelin imports for security, upgradability, and governance
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

// Interface for veNFT (Sonic's voting escrow token)
interface IVeNFT {
    function balanceOfNFT(uint256 tokenId) external view returns (uint256);
    function balanceOfNFTAt(uint256 tokenId, uint256 blockNumber) external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function locked(uint256 tokenId) external view returns (uint256 amount, uint256 end);
    function totalSupply() external view returns (uint256);
    function tokensOfOwner(address owner) external view returns (uint256[] memory);
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

// Interface for RewardDistributor
interface IRewardDistributor {
    function distributeVotingReward(address voter, uint256 amount) external;
}

/**
 * @title Governance
 * @notice Decentralized governance for Sonic Harvest using veNFT-based voting with per-NFT delegation.
 * @dev Manages proposals, voting, timelock execution, emergency actions, and upgrades.
 *      Enhanced with quadratic voting, dynamic thresholds, and optimized gas usage.
 */
contract Governance is UUPSUpgradeable, PausableUpgradeable, ReentrancyGuard {
    using Math for uint256;

    // State variables
    IVeNFT public immutable veNFT;
    ISonicHarvest public immutable sonicHarvest;
    IRewardDistributor public rewardDistributor;
    uint256 public proposalThresholdBps; // Basis points (0.5% = 50 bps)
    uint256 public votingPeriod;
    uint256 public timelockDelay;
    uint256 public quorumPercentage;
    uint256 public proposalCount;
    uint256 public emergencyActionCount;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(uint256 => bool)) public nftVoted;
    mapping(address => bool) public governanceCouncil;
    address[] public councilMembersList;
    uint256 public councilMembersCount;
    mapping(address => uint256) public councilElectionVotes;
    uint256 public councilApprovalThreshold;
    mapping(uint256 => mapping(address => bool)) public councilApprovals;
    uint256 public lastEmergencyAction;
    mapping(address => uint256) public lastProposalTime;
    mapping(uint256 => uint256) public proposalSnapshotBlock;
    mapping(uint256 => UpgradeProposal) public upgradeProposals;
    uint256 public upgradeTimelock;
    mapping(uint256 => address) public nftDelegations;
    mapping(address => mapping(uint256 => bool)) public delegateeNFTs;
    mapping(address => uint256) public delegatedPower;
    mapping(address => uint256) public proposalDeposits;
    mapping(address => bool) public whitelistedTargets;
    mapping(uint256 => uint256) public vetoProposals;
    mapping(uint256 => uint256) public upgradeVetoProposals;
    mapping(uint256 => mapping(uint256 => address)) public nftDelegationHistory;
    mapping(address => uint256[]) public delegatedNFTs;
    mapping(uint256 => mapping(address => uint256)) public quadraticVotes; // Added for quadratic voting
    uint256 public lastCleanupIndex; // Added for optimized cleanup

    // Constants
    uint256 public constant VOTING_REWARD = 1e18;
    uint256 public constant PROPOSAL_DEPOSIT = 0.01 ether;
    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant MIN_VOTING_PERIOD = 3 days;
    uint256 private constant MAX_VOTING_PERIOD = 14 days;
    uint256 private constant MIN_QUORUM = 2000;
    uint256 private constant MAX_QUORUM = 6000;
    uint256 private constant MIN_PROPOSAL_THRESHOLD_BPS = 5; // 0.05%
    uint256 private constant MIN_COUNCIL_THRESHOLD = 2;
    uint256 private constant EMERGENCY_COOLDOWN = 2 days;
    uint256 private constant MAX_ACTIONS = 10;
    uint256 private constant MAX_DESCRIPTION_LENGTH = 2000;
    uint256 private constant PROPOSAL_COOLDOWN = 1 days;
    uint256 private constant UPGRADE_TIMELOCK = 3 days;
    uint256 private constant VETO_WINDOW = 1 days;
    uint256 private constant MAX_PROPOSALS_PER_BATCH = 5;
    uint256 private constant MAX_CLEANUP_PER_CALL = 10;
    uint256 private constant MAX_NFTS_PER_CHECK = 1000;
    uint256 private constant MAX_COUNCIL_PAGE_SIZE = 50;
    uint256 private constant MIN_TIMELOCK = 1 days;
    uint256 private constant MAX_TIMELOCK = 30 days;

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
        uint256 quorumPercentage;
        uint256 parentProposalId;
        bool isQuadratic; // Added for quadratic voting
    }

    // Action struct
    struct Action {
        address target;
        bytes data;
        uint256 value;
    }

    // Upgrade proposal struct
    struct UpgradeProposal {
        address implementation;
        uint256 proposalTime;
        bool vetoed;
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

    // Proposal template types
    enum ProposalTemplate {
        FeeUpdate,
        FeeRecipientUpdate,
        RecoverFunds,
        EmergencyWithdraw,
        EmergencyTransfer,
        ProtocolWhitelist
    }

    // Events
    event ProposalCreated(uint256 indexed proposalId, address indexed proposer, string description, uint256 startTime, uint256 endTime, uint256 quorumPercentage, uint256 parentProposalId, bool isQuadratic);
    event Voted(uint256 indexed proposalId, address indexed voter, uint256 tokenId, bool support, uint256 weight);
    event ProposalCanceled(uint256 indexed proposalId);
    event ProposalQueued(uint256 indexed proposalId, uint256 eta);
    event ProposalExecuted(uint256 indexed proposalId);
    event EmergencyActionProposed(uint256 indexed actionId, address indexed target, bytes data, address indexed proposer);
    event EmergencyActionApproved(uint256 indexed actionId, address indexed approver);
    event EmergencyActionExecuted(uint256 indexed actionId, address indexed target, bytes data, uint256 timestamp);
    event EmergencyActionVetoed(uint256 indexed actionId, uint256 indexed vetoProposalId);
    event VotingPeriodUpdated(uint256 newPeriod);
    event QuorumUpdated(uint256 newQuorum);
    event ProposalThresholdUpdated(uint256 newThresholdBps);
    event CouncilMemberUpdated(address indexed member, bool added);
    event CouncilElectionVote(address indexed voter, address indexed candidate, uint256 weight);
    event CouncilThresholdUpdated(uint256 newThreshold);
    event UpgradeProposed(uint256 indexed upgradeId, address indexed newImplementation, uint256 eta);
    event UpgradeVetoed(uint256 indexed upgradeId, address indexed implementation);
    event UpgradeExecuted(uint256 indexed upgradeId, address indexed newImplementation);
    event ProposalExpired(uint256 indexed proposalId);
    event ActionExecutionFailed(uint256 indexed proposalId, address indexed target, bytes data, uint256 actionIndex, string reason);
    event NFTDelegationSet(uint256 indexed tokenId, address indexed delegator, address indexed delegatee);
    event NFTDelegationRevoked(uint256 indexed tokenId, address indexed delegator);
    event ProposalDepositRefunded(address indexed proposer, uint256 amount);
    event ProposalDepositWithdrawn(address indexed user, uint256 amount);
    event VotingRewardDistributed(address indexed voter, uint256 amount);
    event RewardDistributionFailed(address indexed voter, uint256 amount, string reason);
    event TargetWhitelisted(address indexed target, bool status);
    event QuadraticVoteCast(uint256 indexed proposalId, address indexed voter, uint256 weight);

    // Modifiers
    modifier onlyCouncil() {
        require(governanceCouncil[msg.sender], "Not council member");
        _;
    }

    modifier onlyGovernance() {
        require(msg.sender == address(this), "Not governance");
        _;
    }

    /**
     * @notice Initializes the governance contract.
     * @param _veNFT Address of the veNFT contract.
     * @param _sonicHarvest Address of the SonicHarvest contract.
     * @param _rewardDistributor Address of the reward distributor contract.
     * @param _councilMembers Array of initial governance council members.
     * @param _councilThreshold Number of council approvals required.
     */
    function initialize(
        address _veNFT,
        address _sonicHarvest,
        address _rewardDistributor,
        address[] calldata _councilMembers,
        uint256 _councilThreshold
    ) external initializer {
        require(_veNFT != address(0), "Invalid veNFT address");
        require(_sonicHarvest != address(0), "Invalid SonicHarvest address");
        require(_rewardDistributor != address(0), "Invalid reward distributor");
        require(_councilMembers.length >= _councilThreshold && _councilThreshold >= MIN_COUNCIL_THRESHOLD, "Invalid council setup");
        require(_councilMembers.length > 0, "Empty council members");

        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        veNFT = IVeNFT(_veNFT);
        sonicHarvest = ISonicHarvest(_sonicHarvest);
        rewardDistributor = IRewardDistributor(_rewardDistributor);
        whitelistedTargets[_sonicHarvest] = true;

        for (uint256 i = 0; i < _councilMembers.length; i++) {
            require(_councilMembers[i] != address(0), "Invalid council member");
            require(!governanceCouncil[_councilMembers[i]], "Duplicate council member");
            governanceCouncil[_councilMembers[i]] = true;
            councilMembersList.push(_councilMembers[i]);
            emit CouncilMemberUpdated(_councilMembers[i], true);
        }
        councilMembersCount = _councilMembers.length;
        councilApprovalThreshold = _councilThreshold;
        emit CouncilThresholdUpdated(_councilThreshold);

        proposalThresholdBps = 50; // 0.5%
        votingPeriod = 7 days;
        require(timelockDelay >= MIN_TIMELOCK && timelockDelay <= MAX_TIMELOCK, "Invalid timelock");
        timelockDelay = 3 days;
        quorumPercentage = 3000; // 30%
        upgradeTimelock = UPGRADE_TIMELOCK;
        proposalCount = 0;
        emergencyActionCount = 0;
        lastCleanupIndex = 1;
    }

    /**
     * @notice Delegates voting power of a specific veNFT.
     * @param tokenId The veNFT token ID.
     * @param delegatee Address to receive voting power.
     */
    function delegateNFT(uint256 tokenId, address delegatee) external nonReentrant whenNotPaused {
        require(veNFT.ownerOf(tokenId) == msg.sender, "Not NFT owner");
        require(delegatee != address(0) && delegatee != msg.sender, "Invalid delegatee");

        address currentDelegatee = nftDelegations[tokenId];
        if (currentDelegatee != address(0)) {
            delegateeNFTs[currentDelegatee][tokenId] = false;
            delegatedPower[currentDelegatee] -= veNFT.balanceOfNFT(tokenId);
            _removeNFTFromDelegatee(currentDelegatee, tokenId);
        }

        nftDelegations[tokenId] = delegatee;
        delegateeNFTs[delegatee][tokenId] = true;
        delegatedPower[delegatee] += veNFT.balanceOfNFT(tokenId);
        delegatedNFTs[delegatee].push(tokenId);
        nftDelegationHistory[tokenId][block.number] = delegatee;

        emit NFTDelegationSet(tokenId, msg.sender, delegatee);
    }

    /**
     * @notice Revokes delegation for a specific veNFT.
     * @param tokenId The veNFT token ID.
     */
    function revokeNFTDelegation(uint256 tokenId) external nonReentrant whenNotPaused {
        require(veNFT.ownerOf(tokenId) == msg.sender, "Not NFT owner");
        address currentDelegatee = nftDelegations[tokenId];
        require(currentDelegatee != address(0), "No delegation set");

        delegateeNFTs[currentDelegatee][tokenId] = false;
        delegatedPower[currentDelegatee] -= veNFT.balanceOfNFT(tokenId);
        _removeNFTFromDelegatee(currentDelegatee, tokenId);
        delete nftDelegations[tokenId];
        nftDelegationHistory[tokenId][block.number] = address(0);

        emit NFTDelegationRevoked(tokenId, msg.sender);
    }

    /**
     * @notice Proposes a new governance action.
     * @param actions Array of actions to execute.
     * @param description Proposal description.
     * @param customQuorum Custom quorum percentage (0 for default).
     * @param parentProposalId ID of parent proposal (0 if none).
     * @param isQuadratic Use quadratic voting.
     * @return proposalId The ID of the created proposal.
     */
    function propose(
        Action[] memory actions,
        string calldata description,
        uint256 customQuorum,
        uint256 parentProposalId,
        bool isQuadratic
    ) external payable nonReentrant whenNotPaused returns (uint256 proposalId) {
        require(msg.value >= PROPOSAL_DEPOSIT, "Insufficient deposit");
        require(actions.length > 0 && actions.length <= MAX_ACTIONS, "Invalid action count");
        require(bytes(description).length > 0 && bytes(description).length <= MAX_DESCRIPTION_LENGTH, "Invalid description length");
        require(block.timestamp >= lastProposalTime[msg.sender] + PROPOSAL_COOLDOWN, "Proposal cooldown active");
        require(parentProposalId == 0 || proposals[parentProposalId].id != 0, "Invalid parent proposal");
        uint256 votingPower = _getVotingPower(msg.sender, 0);
        uint256 threshold = _getDynamicProposalThreshold();
        require(votingPower >= threshold, "Below proposal threshold");
        uint256 effectiveQuorum = customQuorum > 0 ? customQuorum : quorumPercentage;
        require(effectiveQuorum >= MIN_QUORUM && effectiveQuorum <= MAX_QUORUM, "Invalid quorum");

        proposalCount++;
        proposalId = proposalCount;
        Proposal storage newProposal = proposals[proposalId];
        newProposal.id = proposalId;
        newProposal.proposer = msg.sender;
        newProposal.description = description;
        newProposal.startTime = block.timestamp;
        newProposal.endTime = block.timestamp + votingPeriod;
        newProposal.forVotes = 0;
        newProposal.againstVotes = 0;
        newProposal.executed = false;
        newProposal.canceled = false;
        newProposal.state = ProposalState.Pending;
        newProposal.quorumPercentage = effectiveQuorum;
        newProposal.parentProposalId = parentProposalId;
        newProposal.isQuadratic = isQuadratic;

        for (uint256 i = 0; i < actions.length; i++) {
            require(whitelistedTargets[actions[i].target], "Invalid target");
            require(actions[i].target != address(0), "Invalid target address");
            newProposal.actions.push(actions[i]);
        }

        proposalSnapshotBlock[proposalId] = block.number;
        lastProposalTime[msg.sender] = block.timestamp;
        proposalDeposits[msg.sender] += msg.value;

        emit ProposalCreated(proposalId, msg.sender, description, newProposal.startTime, newProposal.endTime, effectiveQuorum, parentProposalId, isQuadratic);
    }

    /**
     * @notice Proposes a governance action using a template.
     * @param template The proposal template type.
     * @param params The parameters for the template.
     * @param description Proposal description.
     * @param isQuadratic Use quadratic voting.
     * @return proposalId The ID of the created proposal.
     */
    function proposeWithTemplate(
        ProposalTemplate template,
        bytes calldata params,
        string calldata description,
        bool isQuadratic
    ) external payable nonReentrant whenNotPaused returns (uint256 proposalId) {
        Action[] memory actions = _generateTemplateActions(template, params);
        return propose(actions, description, 0, 0, isQuadratic);
    }

    /**
     * @notice Proposes multiple governance actions in a batch.
     * @param actions Array of action arrays.
     * @param descriptions Array of descriptions.
     * @param customQuorums Array of custom quorums.
     * @param parentProposalIds Array of parent proposal IDs.
     * @param isQuadratics Array of quadratic voting flags.
     * @return proposalIds Array of created proposal IDs.
     */
    function proposeBatch(
        Action[][] memory actions,
        string[] calldata descriptions,
        uint256[] calldata customQuorums,
        uint256[] calldata parentProposalIds,
        bool[] calldata isQuadratics
    ) external payable nonReentrant whenNotPaused returns (uint256[] memory proposalIds) {
        require(msg.value >= PROPOSAL_DEPOSIT * actions.length, "Insufficient deposit");
        require(actions.length > 0 && actions.length <= MAX_PROPOSALS_PER_BATCH, "Invalid batch size");
        require(
            actions.length == descriptions.length &&
            actions.length == customQuorums.length &&
            actions.length == parentProposalIds.length &&
            actions.length == isQuadratics.length,
            "Array length mismatch"
        );
        uint256 votingPower = _getVotingPower(msg.sender, 0);
        uint256 threshold = _getDynamicProposalThreshold();
        require(votingPower >= threshold, "Below proposal threshold");

        proposalIds = new uint256[](actions.length);
        for (uint256 i = 0; i < actions.length; i++) {
            require(actions[i].length > 0 && actions[i].length <= MAX_ACTIONS, "Invalid action count");
            require(bytes(descriptions[i]).length > 0 && bytes(descriptions[i]).length <= MAX_DESCRIPTION_LENGTH, "Invalid description length");
            require(parentProposalIds[i] == 0 || proposals[parentProposalIds[i]].id != 0, "Invalid parent proposal");
            uint256 effectiveQuorum = customQuorums[i] > 0 ? customQuorums[i] : quorumPercentage;
            require(effectiveQuorum >= MIN_QUORUM && effectiveQuorum <= MAX_QUORUM, "Invalid quorum");

            proposalCount++;
            uint256 proposalId = proposalCount;
            Proposal storage newProposal = proposals[proposalId];
            newProposal.id = proposalId;
            newProposal.proposer = msg.sender;
            newProposal.description = descriptions[i];
            newProposal.startTime = block.timestamp;
            newProposal.endTime = block.timestamp + votingPeriod;
            newProposal.forVotes = 0;
            newProposal.againstVotes = 0;
            newProposal.executed = false;
            newProposal.canceled = false;
            newProposal.state = ProposalState.Pending;
            newProposal.quorumPercentage = effectiveQuorum;
            newProposal.parentProposalId = parentProposalIds[i];
            newProposal.isQuadratic = isQuadratics[i];

            for (uint256 j = 0; j < actions[i].length; j++) {
                require(whitelistedTargets[actions[i][j].target], "Invalid target");
                require(actions[i][j].target != address(0), "Invalid target address");
                newProposal.actions.push(actions[i][j]);
            }

            proposalSnapshotBlock[proposalId] = block.number;
            proposalIds[i] = proposalId;

            emit ProposalCreated(proposalId, msg.sender, descriptions[i], newProposal.startTime, newProposal.endTime, effectiveQuorum, parentProposalIds[i], isQuadratics[i]);
        }

        lastProposalTime[msg.sender] = block.timestamp;
        proposalDeposits[msg.sender] += msg.value;
    }

    /**
     * @notice Votes on a proposal using a specific veNFT.
     * @param proposalId The proposal ID.
     * @param tokenId The veNFT token ID.
     * @param support True for in favor, false against.
     */
    function vote(uint256 proposalId, uint256 tokenId, bool support) external nonReentrant whenNotPaused {
        require(_state(proposalId) == ProposalState.Active, "Voting not active");
        require(veNFT.ownerOf(tokenId) == msg.sender, "Not NFT owner");
        require(!nftVoted[proposalId][tokenId], "NFT already voted");

        uint256 snapshotBlock = proposalSnapshotBlock[proposalId];
        uint256 weight = veNFT.balanceOfNFTAt(tokenId, snapshotBlock);
        require(weight > 0, "No voting power");

        Proposal storage proposal = proposals[proposalId];
        uint256 adjustedWeight = proposal.isQuadratic ? _computeQuadraticWeight(weight) : weight;

        if (support) {
            proposal.forVotes += adjustedWeight;
        } else {
            proposal.againstVotes += adjustedWeight;
        }

        nftVoted[proposalId][tokenId] = true;
        quadraticVotes[proposalId][msg.sender] += adjustedWeight;
        _distributeVotingReward(msg.sender);

        emit Voted(proposalId, msg.sender, tokenId, support, adjustedWeight);
        if (proposal.isQuadratic) {
            emit QuadraticVoteCast(proposalId, msg.sender, adjustedWeight);
        }
    }

    /**
     * @notice Votes on a proposal using delegated power.
     * @param proposalId The proposal ID.
     * @param support True for in favor, false against.
     */
    function voteAsDelegatee(uint256 proposalId, bool support) external nonReentrant whenNotPaused {
        require(_state(proposalId) == ProposalState.Active, "Voting not active");
        uint256 snapshotBlock = proposalSnapshotBlock[proposalId];
        uint256 weight = _getDelegatedPower(msg.sender, snapshotBlock);
        require(weight > 0, "No delegated power");

        Proposal storage proposal = proposals[proposalId];
        uint256 adjustedWeight = proposal.isQuadratic ? _computeQuadraticWeight(weight) : weight;

        if (support) {
            proposal.forVotes += adjustedWeight;
        } else {
            proposal.againstVotes += adjustedWeight;
        }

        quadraticVotes[proposalId][msg.sender] += adjustedWeight;
        _distributeVotingReward(msg.sender);

        emit Voted(proposalId, msg.sender, 0, support, adjustedWeight);
        if (proposal.isQuadratic) {
            emit QuadraticVoteCast(proposalId, msg.sender, adjustedWeight);
        }
    }

    /**
     * @notice Votes on multiple proposals in a single transaction.
     * @param proposalIds Array of proposal IDs.
     * @param tokenIds Array of veNFT token IDs (0 for delegated voting).
     * @param supports Array of support flags.
     */
    function voteBatch(uint256[] calldata proposalIds, uint256[] calldata tokenIds, bool[] calldata supports) external nonReentrant whenNotPaused {
        require(proposalIds.length == tokenIds.length && proposalIds.length == supports.length, "Array length mismatch");
        require(proposalIds.length <= MAX_PROPOSALS_PER_BATCH, "Too many votes");

        for (uint256 i = 0; i < proposalIds.length; i++) {
            uint256 proposalId = proposalIds[i];
            uint256 tokenId = tokenIds[i];
            bool support = supports[i];
            require(_state(proposalId) == ProposalState.Active, "Voting not active");

            uint256 snapshotBlock = proposalSnapshotBlock[proposalId];
            uint256 weight;
            Proposal storage proposal = proposals[proposalId];

            if (tokenId == 0) {
                weight = _getDelegatedPower(msg.sender, snapshotBlock);
                require(weight > 0, "No delegated power");
            } else {
                require(veNFT.ownerOf(tokenId) == msg.sender, "Not NFT owner");
                require(!nftVoted[proposalId][tokenId], "NFT already voted");
                weight = veNFT.balanceOfNFTAt(tokenId, snapshotBlock);
                require(weight > 0, "No voting power");
                nftVoted[proposalId][tokenId] = true;
            }

            uint256 adjustedWeight = proposal.isQuadratic ? _computeQuadraticWeight(weight) : weight;
            if (support) {
                proposal.forVotes += adjustedWeight;
            } else {
                proposal.againstVotes += adjustedWeight;
            }

            quadraticVotes[proposalId][msg.sender] += adjustedWeight;
            emit Voted(proposalId, msg.sender, tokenId, support, adjustedWeight);
            if (proposal.isQuadratic) {
                emit QuadraticVoteCast(proposalId, msg.sender, adjustedWeight);
            }
        }

        _distributeVotingReward(msg.sender);
    }

    /**
     * @notice Queues a successful proposal for execution.
     * @param proposalId The proposal ID.
     */
    function queue(uint256 proposalId) external nonReentrant whenNotPaused {
        require(_state(proposalId) == ProposalState.Succeeded, "Proposal not succeeded");
        Proposal storage proposal = proposals[proposalId];
        proposal.state = ProposalState.Queued;
        emit ProposalQueued(proposalId, block.timestamp + timelockDelay);
    }

    /**
     * @notice Executes a queued proposal.
     * @param proposalId The proposal ID.
     */
    function execute(uint256 proposalId) external nonReentrant whenNotPaused {
        require(_state(proposalId) == ProposalState.Queued, "Proposal not queued");
        require(block.timestamp >= proposals[proposalId].endTime + timelockDelay, "Timelock not elapsed");

        Proposal storage proposal = proposals[proposalId];
        if (proposal.parentProposalId != 0) {
            require(proposals[proposal.parentProposalId].executed, "Parent proposal not executed");
        }

        proposal.executed = true;
        proposal.state = ProposalState.Executed;

        for (uint256 i = 0; i < proposal.actions.length; i++) {
            Action memory action = proposal.actions[i];
            require(address(action.target).code.length > 0, "Target is not a contract");
            (bool success, bytes memory result) = action.target.call{value: action.value}(action.data);
            if (!success) {
                string memory reason = _getRevertMsg(result);
                emit ActionExecutionFailed(proposalId, action.target, action.data, i, reason);
                revert(string(abi.encodePacked("Action failed: ", reason)));
            }
        }

        _refundDeposit(proposal.proposer);
        _cleanupExpiredProposals();

        emit ProposalExecuted(proposalId);
    }

    /**
     * @notice Cancels a proposal.
     * @param proposalId The proposal ID.
     */
    function cancel(uint256 proposalId) external nonReentrant {
        ProposalState state = _state(proposalId);
        require(state != ProposalState.Executed, "Already executed");
        require(msg.sender == proposals[proposalId].proposer || governanceCouncil[msg.sender], "Not authorized");

        Proposal storage proposal = proposals[proposalId];
        proposal.canceled = true;
        proposal.state = ProposalState.Canceled;
        _refundDeposit(proposal.proposer);
        emit ProposalCanceled(proposalId);
    }

    /**
     * @notice Proposes an emergency action.
     * @param target The target contract address.
     * @param data The calldata.
     * @return actionId The ID of the emergency action.
     */
    function proposeEmergencyAction(address target, bytes calldata data) external onlyCouncil nonReentrant returns (uint256 actionId) {
        require(block.timestamp >= lastEmergencyAction + EMERGENCY_COOLDOWN, "Cooldown not elapsed");
        require(target == address(sonicHarvest), "Invalid target");
        _validateEmergencyData(data);

        proposalCount++;
        emergencyActionCount++;
        actionId = proposalCount;
        Proposal storage newProposal = proposals[actionId];
        newProposal.id = actionId;
        newProposal.proposer = msg.sender;
        newProposal.description = "Emergency action";
        newProposal.actions.push(Action(target, data, 0));
        newProposal.state = ProposalState.Pending;

        councilApprovals[actionId][msg.sender] = true;

        emit EmergencyActionProposed(actionId, target, data, msg.sender);
        emit EmergencyActionApproved(actionId, msg.sender);
    }

    /**
     * @notice Approves an emergency action.
     * @param actionId The ID of the emergency action.
     */
    function approveEmergencyAction(uint256 actionId) external onlyCouncil nonReentrant {
        require(proposals[actionId].id == actionId, "Invalid action");
        require(!councilApprovals[actionId][msg.sender], "Already approved");
        require(vetoProposals[actionId] == 0, "Action vetoed");
        councilApprovals[actionId][msg.sender] = true;
        emit EmergencyActionApproved(actionId, msg.sender);

        uint256 approvals = 0;
        for (uint256 i = 0; i < councilMembersCount; i++) {
            if (governanceCouncil[councilMembersList[i]] && councilApprovals[actionId][councilMembersList[i]]) {
                approvals++;
            }
        }
        if (approvals >= councilApprovalThreshold) {
            Proposal storage proposal = proposals[actionId];
            require(proposal.actions.length == 1, "Invalid emergency action");
            Action memory action = proposal.actions[0];
            (bool success, bytes memory result) = action.target.call(action.data);
            if (!success) {
                string memory reason = _getRevertMsg(result);
                revert(string(abi.encodePacked("Emergency action failed: ", reason)));
            }
            lastEmergencyAction = block.timestamp;
            emit EmergencyActionExecuted(actionId, action.target, action.data, block.timestamp);
        }
    }

    /**
     * @notice Proposes a veto for an emergency action.
     * @param actionId The emergency action ID.
     * @return vetoProposalId The ID of the veto proposal.
     */
    function proposeEmergencyVeto(uint256 actionId) external payable nonReentrant whenNotPaused returns (uint256 vetoProposalId) {
        require(msg.value >= PROPOSAL_DEPOSIT, "Insufficient deposit");
        require(proposals[actionId].id == actionId && proposals[actionId].state == ProposalState.Pending, "Invalid action");
        require(block.timestamp <= lastEmergencyAction + VETO_WINDOW, "Veto window closed");
        require(vetoProposals[actionId] == 0, "Veto already proposed");
        uint256 votingPower = _getVotingPower(msg.sender, 0);
        uint256 threshold = _getDynamicProposalThreshold();
        require(votingPower >= threshold, "Below proposal threshold");

        proposalCount++;
        vetoProposalId = proposalCount;
        Proposal storage newProposal = proposals[vetoProposalId];
        newProposal.id = vetoProposalId;
        newProposal.proposer = msg.sender;
        newProposal.description = "Veto emergency action";
        newProposal.startTime = block.timestamp;
        newProposal.endTime = block.timestamp + VETO_WINDOW / 2;
        newProposal.forVotes = 0;
        newProposal.againstVotes = 0;
        newProposal.executed = false;
        newProposal.canceled = false;
        newProposal.state = ProposalState.Pending;
        newProposal.quorumPercentage = quarkPercentage / 2;
        newProposal.isQuadratic = false; // Vetoes use standard voting

        proposalSnapshotBlock[vetoProposalId] = block.number;
        lastProposalTime[msg.sender] = block.timestamp;
        proposalDeposits[msg.sender] += msg.value;
        vetoProposals[actionId] = vetoProposalId;

        emit ProposalCreated(vetoProposalId, msg.sender, "Veto emergency action", newProposal.startTime, newProposal.endTime, newProposal.quorumPercentage, 0, false);
    }

    /**
     * @notice Executes a veto for an emergency action.
     * @param vetoProposalId The veto proposal ID.
     */
    function executeEmergencyVeto(uint256 vetoProposalId) external nonReentrant whenNotPaused {
        require(_state(vetoProposalId) == ProposalState.Succeeded, "Veto not succeeded");
        Proposal storage veto = proposals[vetoProposalId];
        veto.executed = true;
        veto.state = ProposalState.Executed;

        for (uint256 i = 1; i <= proposalCount; i++) {
            if (vetoProposals[i] == vetoProposalId) {
                proposals[i].canceled = true;
                proposals[i].state = ProposalState.Canceled;
                emit EmergencyActionVetoed(i, vetoProposalId);
                delete vetoProposals[i];
                break;
            }
        }

        _refundDeposit(veto.proposer);
        emit ProposalExecuted(vetoProposalId);
    }

    /**
     * @notice Proposes a veto for an upgrade proposal.
     * @param upgradeId The upgrade proposal ID.
     * @return vetoProposalId The ID of the veto proposal.
     */
    function proposeUpgradeVeto(uint256 upgradeId) external payable nonReentrant whenNotPaused returns (uint256 vetoProposalId) {
        require(msg.value >= PROPOSAL_DEPOSIT, "Insufficient deposit");
        require(upgradeProposals[upgradeId].implementation != address(0), "No such upgrade");
        require(!upgradeProposals[upgradeId].vetoed, "Already vetoed");
        require(block.timestamp <= upgradeProposals[upgradeId].proposalTime + VETO_WINDOW, "Veto window closed");
        require(upgradeVetoProposals[upgradeId] == 0, "Veto already proposed");
        uint256 votingPower = _getVotingPower(msg.sender, 0);
        uint256 threshold = _getDynamicProposalThreshold();
        require(votingPower >= threshold, "Below proposal threshold");

        proposalCount++;
        vetoProposalId = proposalCount;
        Proposal storage newProposal = proposals[vetoProposalId];
        newProposal.id = vetoProposalId;
        newProposal.proposer = msg.sender;
        newProposal.description = "Veto upgrade proposal";
        newProposal.startTime = block.timestamp;
        newProposal.endTime = block.timestamp + VETO_WINDOW / 2;
        newProposal.forVotes = 0;
        newProposal.againstVotes = 0;
        newProposal.executed = false;
        newProposal.canceled = false;
        newProposal.state = ProposalState.Pending;
        newProposal.quorumPercentage = quorumPercentage / 2;
        newProposal.isQuadratic = false; // Vetoes use standard voting

        proposalSnapshotBlock[vetoProposalId] = block.number;
        lastProposalTime[msg.sender] = block.timestamp;
        proposalDeposits[msg.sender] += msg.value;
        upgradeVetoProposals[upgradeId] = vetoProposalId;

        emit ProposalCreated(vetoProposalId, msg.sender, "Veto upgrade proposal", newProposal.startTime, newProposal.endTime, newProposal.quorumPercentage, 0, false);
    }

    /**
     * @notice Executes a veto for an upgrade proposal.
     * @param vetoProposalId The veto proposal ID.
     */
    function executeUpgradeVeto(uint256 vetoProposalId) external nonReentrant whenNotPaused {
        require(_state(vetoProposalId) == ProposalState.Succeeded, "Veto not succeeded");
        Proposal storage veto = proposals[vetoProposalId];
        veto.executed = true;
        veto.state = ProposalState.Executed;

        for (uint256 i = 1; i <= proposalCount; i++) {
            if (upgradeVetoProposals[i] == vetoProposalId) {
                upgradeProposals[i].vetoed = true;
                emit UpgradeVetoed(i, upgradeProposals[i].implementation);
                delete upgradeVetoProposals[i];
                break;
            }
        }

        _refundDeposit(veto.proposer);
        emit ProposalExecuted(vetoProposalId);
    }

    /**
     * @notice Votes for a council candidate.
     * @param candidate The candidate address.
     * @param tokenId The veNFT token ID (0 for delegated power).
     */
    function voteForCouncil(address candidate, uint256 tokenId) external nonReentrant whenNotPaused {
        require(candidate != address(0), "Invalid candidate");
        uint256 weight;
        if (tokenId == 0) {
            weight = _getDelegatedPower(msg.sender, block.number);
        } else {
            require(veNFT.ownerOf(tokenId) == msg.sender, "Not NFT owner");
            weight = veNFT.balanceOfNFT(tokenId);
        }
        require(weight > 0, "No voting power");

        councilElectionVotes[candidate] += weight;
        emit CouncilElectionVote(msg.sender, candidate, weight);
    }

    /**
     * @notice Withdraws proposal deposits.
     * @param amount The amount to withdraw (0 for all).
     */
    function withdrawDeposits(uint256 amount) external nonReentrant {
        uint256 balance = proposalDeposits[msg.sender];
        require(balance > 0, "No deposits");
        if (amount == 0) {
            amount = balance;
        } else {
            require(amount <= balance, "Insufficient balance");
        }
        proposalDeposits[msg.sender] -= amount;
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "Withdrawal failed");
        emit ProposalDepositWithdrawn(msg.sender, amount);
    }

    /**
     * @notice Updates governance parameters.
     * @param newPeriod The new voting period.
     */
    function updateVotingPeriod(uint256 newPeriod) external onlyGovernance {
        require(newPeriod >= MIN_VOTING_PERIOD && newPeriod <= MAX_VOTING_PERIOD, "Invalid period");
        votingPeriod = newPeriod;
        emit VotingPeriodUpdated(newPeriod);
    }

    /**
     * @notice Updates the quorum percentage.
     * @param newQuorum The new quorum percentage.
     */
    function updateQuorum(uint256 newQuorum) external onlyGovernance {
        require(newQuorum >= MIN_QUORUM && newQuorum <= MAX_QUORUM, "Invalid quorum");
        quorumPercentage = newQuorum;
        emit QuorumUpdated(newQuorum);
    }

    /**
     * @notice Updates the proposal threshold.
     * @param newThresholdBps The new proposal threshold in basis points.
     */
    function updateProposalThreshold(uint256 newThresholdBps) external onlyGovernance {
        require(newThresholdBps >= MIN_PROPOSAL_THRESHOLD_BPS, "Invalid threshold");
        proposalThresholdBps = newThresholdBps;
        emit ProposalThresholdUpdated(newThresholdBps);
    }

    /**
     * @notice Updates a council member's status.
     * @param member The council member address.
     * @param status True to add, false to remove.
     */
    function updateCouncilMember(address member, bool status) external onlyGovernance {
        require(member != address(0), "Invalid address");
        if (status && !governanceCouncil[member]) {
            governanceCouncil[member] = true;
            councilMembersList.push(member);
            councilMembersCount++;
            emit CouncilMemberUpdated(member, true);
        } else if (!status && governanceCouncil[member]) {
            governanceCouncil[member] = false;
            for (uint256 i = 0; i < councilMembersCount; i++) {
                if (councilMembersList[i] == member) {
                    councilMembersList[i] = councilMembersList[councilMembersCount - 1];
                    councilMembersList.pop();
                    councilMembersCount--;
                    break;
                }
            }
            emit CouncilMemberUpdated(member, false);
        }
        require(councilMembersCount >= councilApprovalThreshold, "Council too small");
    }

    /**
     * @notice Updates the council approval threshold.
     * @param newThreshold The new threshold.
     */
    function updateCouncilThreshold(uint256 newThreshold) external onlyGovernance {
        require(newThreshold >= MIN_COUNCIL_THRESHOLD && newThreshold <= councilMembersCount, "Invalid threshold");
        councilApprovalThreshold = newThreshold;
        emit CouncilThresholdUpdated(newThreshold);
    }

    /**
     * @notice Updates the reward distributor.
     * @param newDistributor The new reward distributor address.
     */
    function updateRewardDistributor(address newDistributor) external onlyGovernance {
        require(newDistributor != address(0), "Invalid address");
        rewardDistributor = IRewardDistributor(newDistributor);
    }

    /**
     * @notice Whitelists a target contract for proposals.
     * @param target The target address.
     * @param status True to whitelist, false to remove.
     */
    function whitelistTarget(address target, bool status) external onlyGovernance {
        require(target != address(0), "Invalid address");
        whitelistedTargets[target] = status;
        emit TargetWhitelisted(target, status);
    }

    /**
     * @notice Proposes a contract upgrade.
     * @param newImplementation The new implementation address.
     * @return upgradeId The ID of the upgrade proposal.
     */
    function proposeUpgrade(address newImplementation) external onlyGovernance returns (uint256 upgradeId) {
        require(newImplementation != address(0), "Invalid implementation");
        proposalCount++;
        upgradeId = proposalCount;
        upgradeProposals[upgradeId] = UpgradeProposal({
            implementation: newImplementation,
            proposalTime: block.timestamp,
            vetoed: false
        });
        emit UpgradeProposed(upgradeId, newImplementation, block.timestamp + upgradeTimelock);
    }

    /**
     * @notice Executes a contract upgrade.
     * @param upgradeId The upgrade proposal ID.
     */
    function executeUpgrade(uint256 upgradeId) external onlyGovernance {
        UpgradeProposal storage proposal = upgradeProposals[upgradeId];
        require(proposal.implementation != address(0), "No such upgrade");
        require(!proposal.vetoed, "Upgrade vetoed");
        require(block.timestamp >= proposal.proposalTime + upgradeTimelock, "Timelock not elapsed");
        _authorizeUpgrade(proposal.implementation);
        emit UpgradeExecuted(upgradeId, proposal.implementation);
        delete upgradeProposals[upgradeId];
    }

    /**
     * @notice Cleans up a single expired proposal.
     * @param proposalId The proposal ID.
     */
    function cleanupExpiredProposal(uint256 proposalId) external nonReentrant {
        require(proposalId <= proposalCount, "Invalid proposal ID");
        require(_state(proposalId) == ProposalState.Expired, "Not expired");
        _refundDeposit(proposals[proposalId].proposer);
        delete proposals[proposalId];
        delete proposalSnapshotBlock[proposalId];
        emit ProposalExpired(proposalId);
    }

    /**
     * @notice Cleans up multiple expired proposals incrementally.
     */
    function cleanupExpiredProposals() external nonReentrant {
        _cleanupExpiredProposals();
    }

    /**
     * @notice Pauses the contract.
     */
    function pause() external onlyGovernance {
        _pause();
    }

    /**
     * @notice Unpauses the contract.
     */
    function unpause() external onlyGovernance {
        _unpause();
    }

    // Internal Functions

    function _authorizeUpgrade(address newImplementation) internal override {
        super._authorizeUpgrade(newImplementation);
    }

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
        } else if (block.timestamp <= proposal.endTime + timelockDelay) {
            return ProposalState.Succeeded;
        } else if (block.timestamp <= proposal.endTime + timelockDelay + 1 days) {
            return ProposalState.Queued;
        } else {
            return ProposalState.Expired;
        }
    }

    function _quorumReached(uint256 proposalId) internal view returns (bool) {
        Proposal storage proposal = proposals[proposalId];
        uint256 totalVotes = proposal.forVotes + proposal.againstVotes;
        uint256 totalSupply = veNFT.totalSupply();
        return totalVotes * BASIS_POINTS / totalSupply >= proposal.quorumPercentage;
    }

    function _getVotingPower(address user, uint256 snapshotBlock) internal view returns (uint256) {
        return _getOwnedVotingPower(user, snapshotBlock) + _getDelegatedPower(user, snapshotBlock);
    }

    function _getOwnedVotingPower(address user, uint256 snapshotBlock) internal view returns (uint256) {
        uint256 power = 0;
        uint256[] memory tokens = veNFT.tokensOfOwner(user);
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 tokenId = tokens[i];
            uint256 balance = snapshotBlock == 0 ? veNFT.balanceOfNFT(tokenId) : veNFT.balanceOfNFTAt(tokenId, snapshotBlock);
            if (nftDelegations[tokenId] == address(0)) {
                power += balance;
            }
        }
        return power;
    }

    function _getDelegatedPower(address delegatee, uint256 snapshotBlock) internal view returns (uint256) {
        uint256 power = 0;
        uint256[] memory tokenIds = delegatedNFTs[delegatee];
        uint256 length = tokenIds.length > MAX_NFTS_PER_CHECK ? MAX_NFTS_PER_CHECK : tokenIds.length;
        for (uint256 i = 0; i < length; i++) {
            uint256 tokenId = tokenIds[i];
            if (delegateeNFTs[delegatee][tokenId]) {
                address delegateeAtSnapshot = nftDelegationHistory[tokenId][snapshotBlock];
                if (delegateeAtSnapshot == delegatee || (delegateeAtSnapshot == address(0) && nftDelegations[tokenId] == delegatee)) {
                    power += veNFT.balanceOfNFTAt(tokenId, snapshotBlock);
                }
            }
        }
        return power;
    }

    function _validateEmergencyData(bytes calldata data) internal pure {
        bytes4 selector;
        assembly {
            selector := calldataload(data.offset)
        }
        if (selector == ISonicHarvest.setEmergencyPause.selector) {
            (bool status) = abi.decode(data[4:], (bool));
            require(status, "Only pause allowed");
        } else if (selector == ISonicHarvest.toggleLeverage.selector) {
            (bool status) = abi.decode(data[4:], (bool));
            require(status == true || status == false, "Invalid leverage status");
        } else if (selector == ISonicHarvest.rebalance.selector) {
            require(data.length == 4, "Invalid rebalance parameters");
        } else {
            revert("Invalid emergency action");
        }
    }

    function _distributeVotingReward(address voter) internal {
        try rewardDistributor.distributeVotingReward(voter, VOTING_REWARD) {
            emit VotingRewardDistributed(voter, VOTING_REWARD);
        } catch Error(string memory reason) {
            emit RewardDistributionFailed(voter, VOTING_REWARD, reason);
        } catch {
            emit RewardDistributionFailed(voter, VOTING_REWARD, "Unknown error");
        }
    }

    function _refundDeposit(address proposer) internal {
        if (proposalDeposits[proposer] >= PROPOSAL_DEPOSIT) {
            uint256 refund = PROPOSAL_DEPOSIT;
            proposalDeposits[proposer] -= refund;
            (bool success, ) = proposer.call{value: refund}("");
            require(success, "Refund failed");
            emit ProposalDepositRefunded(proposer, refund);
        }
    }

    function _cleanupExpiredProposals() internal {
        uint256 cleaned = 0;
        uint256 startIndex = lastCleanupIndex;
        for (uint256 i = startIndex; i <= proposalCount && cleaned < MAX_CLEANUP_PER_CALL; i++) {
            if (_state(i) == ProposalState.Expired) {
                _refundDeposit(proposals[i].proposer);
                delete proposals[i];
                delete proposalSnapshotBlock[i];
                emit ProposalExpired(i);
                cleaned++;
            }
        }
        lastCleanupIndex = startIndex + cleaned;
        if (lastCleanupIndex > proposalCount) {
            lastCleanupIndex = 1; // Reset for next cycle
        }
    }

    function _getRevertMsg(bytes memory result) internal pure returns (string memory) {
        if (result.length < 68) return "Unknown error";
        assembly {
            result := add(result, 0x04)
        }
        return abi.decode(result, (string));
    }

    function _removeNFTFromDelegatee(address delegatee, uint256 tokenId) internal {
        uint256[] storage tokenIds = delegatedNFTs[delegatee];
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (tokenIds[i] == tokenId) {
                tokenIds[i] = tokenIds[tokenIds.length - 1];
                tokenIds.pop();
                break;
            }
        }
    }

    /**
     * @notice Computes quadratic voting weight.
     * @param weight The raw voting power.
     * @return The quadratic weight (square root).
     */
    function _computeQuadraticWeight(uint256 weight) internal pure returns (uint256) {
        return Math.sqrt(weight);
    }

    /**
     * @notice Calculates dynamic proposal threshold based on current veNFT supply.
     * @return The threshold in absolute terms.
     */
    function _getDynamicProposalThreshold() internal view returns (uint256) {
        uint256 totalSupply = veNFT.totalSupply();
        return (totalSupply * proposalThresholdBps) / BASIS_POINTS;
    }

    /**
     * @notice Generates actions for a proposal template.
     * @param template The template type.
     * @param params The encoded parameters.
     * @return actions The generated actions.
     */
    function _generateTemplateActions(ProposalTemplate template, bytes calldata params) internal view returns (Action[] memory actions) {
        actions = new Action[](2);
        if (template == ProposalTemplate.FeeUpdate) {
            (uint256 newManagementFee, uint256 newPerformanceFee) = abi.decode(params, (uint256, uint256));
            actions[0] = Action({
                target: address(sonicHarvest),
                data: abi.encodeCall(ISonicHarvest.proposeUpdateFees, (newManagementFee, newPerformanceFee)),
                value: 0
            });
            actions[1] = Action({
                target: address(sonicHarvest),
                data: abi.encodeCall(ISonicHarvest.executeUpdateFees, (newManagementFee, newPerformanceFee)),
                value: 0
            });
        } else if (template == ProposalTemplate.FeeRecipientUpdate) {
            address newRecipient = abi.decode(params, (address));
            actions[0] = Action({
                target: address(sonicHarvest),
                data: abi.encodeCall(ISonicHarvest.proposeFeeRecipientUpdate, (newRecipient)),
                value: 0
            });
            actions[1] = Action({
                target: address(sonicHarvest),
                data: abi.encodeCall(ISonicHarvest.executeFeeRecipientUpdate, (newRecipient)),
                value: 0
            });
        } else if (template == ProposalTemplate.RecoverFunds) {
            (address protocol, uint256 amount) = abi.decode(params, (address, uint256));
            actions[0] = Action({
                target: address(sonicHarvest),
                data: abi.encodeCall(ISonicHarvest.proposeRecoverFunds, (protocol, amount)),
                value: 0
            });
            actions[1] = Action({
                target: address(sonicHarvest),
                data: abi.encodeCall(ISonicHarvest.executeRecoverFunds, (protocol, amount)),
                value: 0
            });
        } else if (template == ProposalTemplate.EmergencyWithdraw) {
            (address user, uint256 amount) = abi.decode(params, (address, uint256));
            actions[0] = Action({
                target: address(sonicHarvest),
                data: abi.encodeCall(ISonicHarvest.proposeEmergencyWithdraw, (user, amount)),
                value: 0
            });
            actions[1] = Action({
                target: address(sonicHarvest),
                data: abi.encodeCall(ISonicHarvest.executeEmergencyWithdraw, (user, amount)),
                value: 0
            });
        } else if (template == ProposalTemplate.EmergencyTransfer) {
            (address user, uint256 amount) = abi.decode(params, (address, uint256));
            actions[0] = Action({
                target: address(sonicHarvest),
                data: abi.encodeCall(ISonicHarvest.proposeEmergencyTransfer, (user, amount)),
                value: 0
            });
            actions[1] = Action({
                target: address(sonicHarvest),
                data: abi.encodeCall(ISonicHarvest.executeEmergencyTransfer, (user, amount)),
                value: 0
            });
        } else if (template == ProposalTemplate.ProtocolWhitelist) {
            (address protocol, bool status, address apyFeed, bool isCompound) = abi.decode(params, (address, bool, address, bool));
            actions[0] = Action({
                target: address(sonicHarvest),
                data: abi.encodeCall(ISonicHarvest.setProtocolWhitelist, (protocol, status, apyFeed, isCompound)),
                value: 0
            });
            actions[1] = Action({
                target: address(0),
                data: "",
                value: 0
            });
        } else {
            revert("Invalid template");
        }
        return actions;
    }
}
