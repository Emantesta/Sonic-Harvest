// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// OpenZeppelin imports for security, upgradability, and governance
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
    function balanceOf(address token) external view returns (uint256);
}

/**
 * @title Governance
 * @notice Decentralized governance for Sonic Harvest using veNFT-based voting with per-NFT delegation.
 * @dev Manages proposals, voting, timelock execution, emergency actions, and upgrades. Enhanced with
 *      quadratic voting, dynamic thresholds, optimized gas usage, and configurable parameters.
 */
contract Governance is UUPSUpgradeable, PausableUpgradeable, ReentrancyGuard {
    using Math for uint256;

    // State variables
    IVeNFT public immutable veNFT;
    ISonicHarvest public immutable sonicHarvest;
    IRewardDistributor public rewardDistributor;
    IERC20 public usdcToken; // Sonic native USDC for deposits and rewards
    uint256 public proposalThresholdBps; // Basis points (0.5% = 50 bps)
    uint256 public votingPeriod;
    uint256 public timelockDelay;
    uint256 public vetoWindow; // Configurable veto window
    uint256 public quorumPercentage;
    uint256 public proposalCount;
    uint256 public upgradeProposalCount; // Separate counter for upgrades
    uint256 public emergencyActionCount;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(uint256 => bool)) public nftVoted;
    mapping(address => bool) public governanceCouncil;
    address[] public councilMembersList;
    uint256 public councilMembersCount;
    mapping(address => uint256) public councilElectionVotes;
    mapping(address => uint256) public councilTermEnd; // Term limits for council members
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
    mapping(address => uint256) public proposalDeposits; // In USDC
    mapping(address => bool) public whitelistedTargets;
    mapping(uint256 => uint256) public vetoProposals;
    mapping(uint256 => uint256) public upgradeVetoProposals;
    mapping(uint256 => mapping(uint256 => address)) public nftDelegationHistory;
    mapping(address => uint256[]) public delegatedNFTs;
    mapping(address => mapping(uint256 => uint256)) public delegatedNFTsIndex; // Index for efficient NFT removal
    mapping(uint256 => mapping(address => uint256)) public quadraticVotes;
    mapping(uint256 => uint256) public quadraticWeightCache; // Cache for quadratic voting
    uint256 public lastCleanupIndex;
    uint256 public proposalDeposit; // Configurable deposit amount in USDC
    uint256 public votingReward; // Configurable voting reward in USDC
    uint256 public cleanupReward; // Reward for cleanup in USDC
    uint256 public maxNFTsPerCheck; // Configurable max NFTs to check
    uint256 public councilElectionCycle; // Tracks election cycles
    uint256 public lastElectionReset; // Timestamp of last election reset
    uint256 public storageVersion; // For upgrade compatibility check

    // Constants
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MIN_VOTING_PERIOD = 3 days;
    uint256 public constant MAX_VOTING_PERIOD = 14 days;
    uint256 public constant MIN_QUORUM = 2000; // 20%
    uint256 public constant MAX_QUORUM = 6000; // 60%
    uint256 public constant MIN_PROPOSAL_THRESHOLD_BPS = 5; // 0.05%
    uint256 public constant MIN_COUNCIL_THRESHOLD = 2;
    uint256 public constant EMERGENCY_COOLDOWN = 2 days;
    uint256 public constant MAX_ACTIONS = 10;
    uint256 public constant MAX_DESCRIPTION_LENGTH = 2000;
    uint256 public constant PROPOSAL_COOLDOWN = 1 days;
    uint256 public constant UPGRADE_TIMELOCK = 3 days;
    uint256 public constant MIN_VETO_WINDOW = 12 hours;
    uint256 public constant MAX_VETO_WINDOW = 7 days;
    uint256 public constant MAX_PROPOSALS_PER_BATCH = 5;
    uint256 public constant MAX_CLEANUP_PER_CALL = 10;
    uint256 public constant DEFAULT_MAX_NFTS_PER_CHECK = 1000;
    uint256 public constant MAX_COUNCIL_PAGE_SIZE = 50;
    uint256 public constant MIN_TIMELOCK = 1 days;
    uint256 public constant MAX_TIMELOCK = 30 days;
    uint256 public constant COUNCIL_TERM_DURATION = 180 days; // 6-month term
    uint256 public constant ELECTION_CYCLE_DURATION = 90 days; // 3-month election cycle
    uint256 public constant DEFAULT_PROPOSAL_DEPOSIT = 10 * 1e6; // 10 USDC (6 decimals)
    uint256 public constant DEFAULT_VOTING_REWARD = 1 * 1e6; // 1 USDC
    uint256 public constant DEFAULT_CLEANUP_REWARD = 0.1 * 1e6; // 0.1 USDC

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
        bool isQuadratic;
        bool hasDependencies; // Flag for interdependent actions
    }

    // Action struct
    struct Action {
        address target;
        bytes data;
        uint256 value;
        uint256[] dependencies; // Indices of dependent actions
    }

    // Upgrade proposal struct
    struct UpgradeProposal {
        address implementation;
        uint256 proposalTime;
        bool vetoed;
        uint256 storageVersion; // For compatibility check
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
    event ProposalCreated(uint256 indexed proposalId, address indexed proposer, string description, uint256 startTime, uint256 endTime, uint256 quorumPercentage, uint256 parentProposalId, bool isQuadratic, bool hasDependencies);
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
    event CouncilMemberUpdated(address indexed member, bool added, uint256 termEnd);
    event CouncilElectionVote(address indexed voter, address indexed candidate, uint256 weight);
    event CouncilThresholdUpdated(uint256 newThreshold);
    event UpgradeProposed(uint256 indexed upgradeId, address indexed newImplementation, uint256 eta, uint256 storageVersion);
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
    event ProposalDepositUpdated(uint256 newDeposit);
    event VotingRewardUpdated(uint256 newReward);
    event CleanupRewardUpdated(uint256 newReward);
    event VetoWindowUpdated(uint256 newWindow);
    event MaxNFTsPerCheckUpdated(uint256 newMax);
    event CouncilElectionReset(uint256 cycle, uint256 timestamp);
    event CleanupRewardDistributed(address indexed caller, uint256 amount);
    event BatchDelegationSet(address indexed delegator, uint256[] tokenIds, address indexed delegatee);
    event BatchDelegationRevoked(address indexed delegator, uint256[] tokenIds);

    // Modifiers
    modifier onlyCouncil() {
        require(governanceCouncil[msg.sender], "Not council member");
        require(councilTermEnd[msg.sender] > block.timestamp, "Council term expired");
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
     * @param _usdcToken Address of the Sonic native USDC token.
     * @param _councilMembers Array of initial governance council members.
     * @param _councilThreshold Number of council approvals required.
     * @param _timelockDelay Timelock delay for proposal execution.
     */
    function initialize(
        address _veNFT,
        address _sonicHarvest,
        address _rewardDistributor,
        address _usdcToken,
        address[] calldata _councilMembers,
        uint256 _councilThreshold,
        uint256 _timelockDelay
    ) external initializer {
        require(_veNFT != address(0), "Invalid veNFT address");
        require(_sonicHarvest != address(0), "Invalid SonicHarvest address");
        require(_rewardDistributor != address(0), "Invalid reward distributor");
        require(_usdcToken != address(0), "Invalid USDC address");
        require(_councilMembers.length >= _councilThreshold && _councilThreshold >= MIN_COUNCIL_THRESHOLD, "Invalid council setup");
        require(_councilMembers.length > 0, "Empty council members");
        require(_timelockDelay >= MIN_TIMELOCK && _timelockDelay <= MAX_TIMELOCK, "Invalid timelock");

        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        veNFT = IVeNFT(_veNFT);
        sonicHarvest = ISonicHarvest(_sonicHarvest);
        rewardDistributor = IRewardDistributor(_rewardDistributor);
        usdcToken = IERC20(_usdcToken);
        whitelistedTargets[_sonicHarvest] = true;

        for (uint256 i = 0; i < _councilMembers.length; i++) {
            require(_councilMembers[i] != address(0), "Invalid council member");
            require(!governanceCouncil[_councilMembers[i]], "Duplicate council member");
            governanceCouncil[_councilMembers[i]] = true;
            councilMembersList.push(_councilMembers[i]);
            councilTermEnd[_councilMembers[i]] = block.timestamp + COUNCIL_TERM_DURATION;
            emit CouncilMemberUpdated(_councilMembers[i], true, councilTermEnd[_councilMembers[i]]);
        }
        councilMembersCount = _councilMembers.length;
        councilApprovalThreshold = _councilThreshold;
        emit CouncilThresholdUpdated(_councilThreshold);

        proposalThresholdBps = 50; // 0.5%
        votingPeriod = 7 days;
        timelockDelay = _timelockDelay;
        vetoWindow = 1 days;
        quorumPercentage = 3000; // 30%
        upgradeTimelock = UPGRADE_TIMELOCK;
        proposalCount = 0;
        upgradeProposalCount = 0;
        emergencyActionCount = 0;
        lastCleanupIndex = 1;
        proposalDeposit = DEFAULT_PROPOSAL_DEPOSIT;
        votingReward = DEFAULT_VOTING_REWARD;
        cleanupReward = DEFAULT_CLEANUP_REWARD;
        maxNFTsPerCheck = DEFAULT_MAX_NFTS_PER_CHECK;
        councilElectionCycle = 1;
        lastElectionReset = block.timestamp;
        storageVersion = 1;
    }

    /**
     * @notice Delegates voting power of multiple veNFTs.
     * @param tokenIds Array of veNFT token IDs.
     * @param delegatee Address to receive voting power.
     */
    function delegateNFTsBatch(uint256[] calldata tokenIds, address delegatee) external nonReentrant whenNotPaused {
        require(delegatee != address(0) && delegatee != msg.sender, "Invalid delegatee");
        require(tokenIds.length > 0, "No tokens provided");

        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            require(veNFT.ownerOf(tokenId) == msg.sender, "Not NFT owner");

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
            delegatedNFTsIndex[delegatee][tokenId] = delegatedNFTs[delegatee].length - 1;
            nftDelegationHistory[tokenId][block.number] = delegatee;

            emit NFTDelegationSet(tokenId, msg.sender, delegatee);
        }

        emit BatchDelegationSet(msg.sender, tokenIds, delegatee);
    }

    /**
     * @notice Revokes delegation for multiple veNFTs.
     * @param tokenIds Array of veNFT token IDs.
     */
    function revokeNFTsBatch(uint256[] calldata tokenIds) external nonReentrant whenNotPaused {
        require(tokenIds.length > 0, "No tokens provided");

        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
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

        emit BatchDelegationRevoked(msg.sender, tokenIds);
    }

    /**
     * @notice Proposes a new governance action.
     * @param actions Array of actions to execute (with dependencies).
     * @param description Proposal description.
     * @param customQuorum Custom quorum percentage (0 for default).
     * @param parentProposalId ID of parent proposal (0 if none). Parent must be executed for this proposal to execute.
     * @param isQuadratic Use quadratic voting for fairer vote distribution (square root of weight).
     * @param hasDependencies True if actions depend on each other.
     * @return proposalId The ID of the created proposal.
     */
    function propose(
        Action[] memory actions,
        string calldata description,
        uint256 customQuorum,
        uint256 parentProposalId,
        bool isQuadratic,
        bool hasDependencies
    ) external nonReentrant whenNotPaused returns (uint256 proposalId) {
        require(usdcToken.transferFrom(msg.sender, address(this), proposalDeposit), "Deposit transfer failed");
        require(actions.length > 0 && actions.length <= MAX_ACTIONS, "Invalid action count");
        require(bytes(description).length > 0 && bytes(description).length <= MAX_DESCRIPTION_LENGTH, "Invalid description length");
        require(block.timestamp >= lastProposalTime[msg.sender] + PROPOSAL_COOLDOWN, "Proposal cooldown active");
        require(parentProposalId == 0 || proposals[parentProposalId].id != 0, "Invalid parent proposal");
        uint256 votingPower = _getVotingPower(msg.sender, 0);
        uint256 threshold = _getDynamicProposalThreshold();
        require(votingPower >= threshold, "Below proposal threshold");
        uint256 effectiveQuorum = customQuorum > 0 ? customQuorum : quorumPercentage;
        require(effectiveQuorum >= MIN_QUORUM && effectiveQuorum <= MAX_QUORUM, "Invalid quorum");
        if (hasDependencies) {
            _validateActionDependencies(actions);
        }

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
        newProposal.hasDependencies = hasDependencies;

        for (uint256 i = 0; i < actions.length; i++) {
            require(whitelistedTargets[actions[i].target], "Invalid target");
            require(actions[i].target != address(0), "Invalid target address");
            newProposal.actions.push(actions[i]);
        }

        proposalSnapshotBlock[proposalId] = block.number;
        lastProposalTime[msg.sender] = block.timestamp;
        proposalDeposits[msg.sender] += proposalDeposit;

        emit ProposalCreated(proposalId, msg.sender, description, newProposal.startTime, newProposal.endTime, effectiveQuorum, parentProposalId, isQuadratic, hasDependencies);
    }

    /**
     * @notice Proposes multiple governance actions in a batch.
     * @dev All proposals share the proposer's voting power check for gas efficiency.
     *      Each proposal can have its own actions, description, quorum, parent, and voting mode.
     * @param actions Array of action arrays (each with dependencies).
     * @param descriptions Array of descriptions.
     * @param customQuorums Array of custom quorums.
     * @param parentProposalIds Array of parent proposal IDs.
     * @param isQuadratics Array of quadratic voting flags.
     * @param hasDependencies Array of dependency flags.
     * @return proposalIds Array of created proposal IDs.
     */
    function proposeBatch(
        Action[][] memory actions,
        string[] calldata descriptions,
        uint256[] calldata customQuorums,
        uint256[] calldata parentProposalIds,
        bool[] calldata isQuadratics,
        bool[] calldata hasDependencies
    ) external nonReentrant whenNotPaused returns (uint256[] memory proposalIds) {
        require(actions.length > 0 && actions.length <= MAX_PROPOSALS_PER_BATCH, "Invalid batch size");
        require(
            actions.length == descriptions.length &&
            actions.length == customQuorums.length &&
            actions.length == parentProposalIds.length &&
            actions.length == isQuadratics.length &&
            actions.length == hasDependencies.length,
            "Array length mismatch"
        );
        uint256 totalDeposit = proposalDeposit * actions.length;
        require(usdcToken.transferFrom(msg.sender, address(this), totalDeposit), "Deposit transfer failed");
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
            if (hasDependencies[i]) {
                _validateActionDependencies(actions[i]);
            }

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
            newProposal.hasDependencies = hasDependencies[i];

            for (uint256 j = 0; j < actions[i].length; j++) {
                require(whitelistedTargets[actions[i][j].target], "Invalid target");
                require(actions[i][j].target != address(0), "Invalid target address");
                newProposal.actions.push(actions[i][j]);
            }

            proposalSnapshotBlock[proposalId] = block.number;
            proposalIds[i] = proposalId;

            emit ProposalCreated(proposalId, msg.sender, descriptions[i], newProposal.startTime, newProposal.endTime, effectiveQuorum, parentProposalIds[i], isQuadratics[i], hasDependencies[i]);
        }

        lastProposalTime[msg.sender] = block.timestamp;
        proposalDeposits[msg.sender] += totalDeposit;
    }

    /**
     * @notice Proposes a governance action using a predefined template.
     * @param template The proposal template type (e.g., FeeUpdate, ProtocolWhitelist).
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
    ) external nonReentrant whenNotPaused returns (uint256 proposalId) {
        Action[] memory actions = _generateTemplateActions(template, params);
        return propose(actions, description, 0, 0, isQuadratic, template != ProposalTemplate.ProtocolWhitelist); // ProtocolWhitelist has no dependencies
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
        uint256 adjustedWeight = _computeQuadraticWeight(proposalId, weight, proposal.isQuadratic);

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
     * @notice Votes on a proposal using delegated power with pagination.
     * @param proposalId The proposal ID.
     * @param support True for in favor, false against.
     * @param startIndex Starting index for delegated NFTs.
     * @param maxNFTs Maximum NFTs to process (capped by maxNFTsPerCheck).
     */
    function voteAsDelegatee(uint256 proposalId, bool support, uint256 startIndex, uint256 maxNFTs) external nonReentrant whenNotPaused {
        require(_state(proposalId) == ProposalState.Active, "Voting not active");
        uint256 snapshotBlock = proposalSnapshotBlock[proposalId];
        uint256 weight = _getDelegatedPower(msg.sender, snapshotBlock, startIndex, maxNFTs);
        require(weight > 0, "No delegated power");

        Proposal storage proposal = proposals[proposalId];
        uint256 adjustedWeight = _computeQuadraticWeight(proposalId, weight, proposal.isQuadratic);

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
     * @param startIndices Array of start indices for delegated voting.
     * @param maxNFTs Array of max NFTs for delegated voting.
     */
    function voteBatch(
        uint256[] calldata proposalIds,
        uint256[] calldata tokenIds,
        bool[] calldata supports,
        uint256[] calldata startIndices,
        uint256[] calldata maxNFTs
    ) external nonReentrant whenNotPaused {
        require(
            proposalIds.length == tokenIds.length &&
            proposalIds.length == supports.length &&
            proposalIds.length == startIndices.length &&
            proposalIds.length == maxNFTs.length,
            "Array length mismatch"
        );
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
                weight = _getDelegatedPower(msg.sender, snapshotBlock, startIndices[i], maxNFTs[i]);
                require(weight > 0, "No delegated power");
            } else {
                require(veNFT.ownerOf(tokenId) == msg.sender, "Not NFT owner");
                require(!nftVoted[proposalId][tokenId], "NFT already voted");
                weight = veNFT.balanceOfNFTAt(tokenId, snapshotBlock);
                require(weight > 0, "No voting power");
                nftVoted[proposalId][tokenId] = true;
            }

            uint256 adjustedWeight = _computeQuadraticWeight(proposalId, weight, proposal.isQuadratic);
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
     * @notice Executes a queued proposal with dependency checks.
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

        bool[] memory executed = new bool[](proposal.actions.length);
        for (uint256 i = 0; i < proposal.actions.length; i++) {
            if (proposal.hasDependencies) {
                for (uint256 j = 0; j < proposal.actions[i].dependencies.length; j++) {
                    uint256 depIndex = proposal.actions[i].dependencies[j];
                    require(depIndex < proposal.actions.length, "Invalid dependency index");
                    require(executed[depIndex], "Dependency not executed");
                }
            }
            Action memory action = proposal.actions[i];
            require(address(action.target).code.length > 0, "Target is not a contract");
            (bool success, bytes memory result) = action.target.call{value: action.value}(action.data);
            if (!success) {
                string memory reason = _getRevertMsg(result);
                emit ActionExecutionFailed(proposalId, action.target, action.data, i, reason);
                revert(string(abi.encodePacked("Action failed at index ", _toString(i), ": ", reason)));
            }
            executed[i] = true;
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
     * @notice Proposes an emergency action (e.g., pause, rebalance).
     * @param target The target contract address (must be sonicHarvest).
     * @param data The calldata (must be a valid emergency function).
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
        newProposal.actions.push(Action(target, data, 0, new uint256[](0)));
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
            if (governanceCouncil[councilMembersList[i]] && councilApprovals[actionId][councilMembersList[i]] && councilTermEnd[councilMembersList[i]] > block.timestamp) {
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
    function proposeEmergencyVeto(uint256 actionId) external nonReentrant whenNotPaused returns (uint256 vetoProposalId) {
        require(usdcToken.transferFrom(msg.sender, address(this), proposalDeposit), "Deposit transfer failed");
        require(proposals[actionId].id == actionId && proposals[actionId].state == ProposalState.Pending, "Invalid action");
        require(block.timestamp <= lastEmergencyAction + vetoWindow, "Veto window closed");
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
        newProposal.endTime = block.timestamp + vetoWindow / 2;
        newProposal.forVotes = 0;
        newProposal.againstVotes = 0;
        newProposal.executed = false;
        newProposal.canceled = false;
        newProposal.state = ProposalState.Pending;
        newProposal.quorumPercentage = quorumPercentage / 2;
        newProposal.isQuadratic = false;

        proposalSnapshotBlock[vetoProposalId] = block.number;
        lastProposalTime[msg.sender] = block.timestamp;
        proposalDeposits[msg.sender] += proposalDeposit;
        vetoProposals[actionId] = vetoProposalId;

        emit ProposalCreated(vetoProposalId, msg.sender, "Veto emergency action", newProposal.startTime, newProposal.endTime, newProposal.quorumPercentage, 0, false, false);
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
    function proposeUpgradeVeto(uint256 upgradeId) external nonReentrant whenNotPaused returns (uint256 vetoProposalId) {
        require(usdcToken.transferFrom(msg.sender, address(this), proposalDeposit), "Deposit transfer failed");
        require(upgradeProposals[upgradeId].implementation != address(0), "No such upgrade");
        require(!upgradeProposals[upgradeId].vetoed, "Already vetoed");
        require(block.timestamp <= upgradeProposals[upgradeId].proposalTime + vetoWindow, "Veto window closed");
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
        newProposal.endTime = block.timestamp + vetoWindow / 2;
        newProposal.forVotes = 0;
        newProposal.againstVotes = 0;
        newProposal.executed = false;
        newProposal.canceled = false;
        newProposal.state = ProposalState.Pending;
        newProposal.quorumPercentage = quorumPercentage / 2;
        newProposal.isQuadratic = false;

        proposalSnapshotBlock[vetoProposalId] = block.number;
        lastProposalTime[msg.sender] = block.timestamp;
        proposalDeposits[msg.sender] += proposalDeposit;
        upgradeVetoProposals[upgradeId] = vetoProposalId;

        emit ProposalCreated(vetoProposalId, msg.sender, "Veto upgrade proposal", newProposal.startTime, newProposal.endTime, newProposal.quorumPercentage, 0, false, false);
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

        for (uint256 i = 1; i <= upgradeProposalCount; i++) {
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
        _resetElectionIfNeeded();
        uint256 weight;
        if (tokenId == 0) {
            weight = _getDelegatedPower(msg.sender, block.number, 0, maxNFTsPerCheck);
        } else {
            require(veNFT.ownerOf(tokenId) == msg.sender, "Not NFT owner");
            weight = veNFT.balanceOfNFT(tokenId);
        }
        require(weight > 0, "No voting power");

        councilElectionVotes[candidate] += weight;
        emit CouncilElectionVote(msg.sender, candidate, weight);
    }

    /**
     * @notice Withdraws proposal deposits in USDC.
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
        require(usdcToken.transfer(msg.sender, amount), "Withdrawal failed");
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
     * @notice Updates the proposal deposit amount in USDC.
     * @param newDeposit The new deposit amount.
     */
    function updateProposalDeposit(uint256 newDeposit) external onlyGovernance {
        require(newDeposit > 0, "Invalid deposit");
        proposalDeposit = newDeposit;
        emit ProposalDepositUpdated(newDeposit);
    }

    /**
     * @notice Updates the voting reward amount in USDC.
     * @param newReward The new reward amount.
     */
    function updateVotingReward(uint256 newReward) external onlyGovernance {
        require(newReward > 0, "Invalid reward");
        votingReward = newReward;
        emit VotingRewardUpdated(newReward);
    }

    /**
     * @notice Updates the cleanup reward amount in USDC.
     * @param newReward The new reward amount.
     */
    function updateCleanupReward(uint256 newReward) external onlyGovernance {
        require(newReward > 0, "Invalid reward");
        cleanupReward = newReward;
        emit CleanupRewardUpdated(newReward);
    }

    /**
     * @notice Updates the veto window duration.
     * @param newWindow The new veto window duration.
     */
    function updateVetoWindow(uint256 newWindow) external onlyGovernance {
        require(newWindow >= MIN_VETO_WINDOW && newWindow <= MAX_VETO_WINDOW, "Invalid veto window");
        vetoWindow = newWindow;
        emit VetoWindowUpdated(newWindow);
    }

    /**
     * @notice Updates the maximum NFTs to check for delegated power.
     * @param newMax The new maximum.
     */
    function updateMaxNFTsPerCheck(uint256 newMax) external onlyGovernance {
        require(newMax > 0, "Invalid max NFTs");
        maxNFTsPerCheck = newMax;
        emit MaxNFTsPerCheckUpdated(newMax);
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
            councilTermEnd[member] = block.timestamp + COUNCIL_TERM_DURATION;
            emit CouncilMemberUpdated(member, true, councilTermEnd[member]);
        } else if (!status && governanceCouncil[member]) {
            governanceCouncil[member] = false;
            councilTermEnd[member] = 0;
            for (uint256 i = 0; i < councilMembersCount; i++) {
                if (councilMembersList[i] == member) {
                    councilMembersList[i] = councilMembersList[councilMembersCount - 1];
                    councilMembersList.pop();
                    councilMembersCount--;
                    break;
                }
            }
            emit CouncilMemberUpdated(member, false, 0);
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
     * @notice Proposes a contract upgrade with storage version.
     * @param newImplementation The new implementation address.
     * @param newStorageVersion The storage version of the new implementation.
     * @return upgradeId The ID of the upgrade proposal.
     */
    function proposeUpgrade(address newImplementation, uint256 newStorageVersion) external onlyGovernance returns (uint256 upgradeId) {
        require(newImplementation != address(0), "Invalid implementation");
        require(newStorageVersion >= storageVersion, "Incompatible storage version");
        upgradeProposalCount++;
        upgradeId = upgradeProposalCount;
        upgradeProposals[upgradeId] = UpgradeProposal({
            implementation: newImplementation,
            proposalTime: block.timestamp,
            vetoed: false,
            storageVersion: newStorageVersion
        });
        emit UpgradeProposed(upgradeId, newImplementation, block.timestamp + upgradeTimelock, newStorageVersion);
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
        require(proposal.storageVersion >= storageVersion, "Incompatible storage version");
        storageVersion = proposal.storageVersion;
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
        _cleanupProposal(proposalId);
        _distributeCleanupReward(msg.sender);
    }

    /**
     * @notice Cleans up multiple expired proposals incrementally with rewards.
     */
    function cleanupExpiredProposals() external nonReentrant {
        _cleanupExpiredProposals();
        _distributeCleanupReward(msg.sender);
    }

    /**
     * @notice Resets council election votes if cycle duration has passed.
     */
    function resetCouncilElection() external nonReentrant {
        _resetElectionIfNeeded();
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

    /**
     * @notice Authorizes a contract upgrade (UUPS requirement).
     * @param newImplementation The new implementation address.
     */
    function _authorizeUpgrade(address newImplementation) internal override {
        super._authorizeUpgrade(newImplementation);
    }

    /**
     * @notice Gets the current state of a proposal.
     * @param proposalId The proposal ID.
     * @return The proposal state.
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
        } else if (block.timestamp <= proposal.endTime + timelockDelay) {
            return ProposalState.Succeeded;
        } else if (block.timestamp <= proposal.endTime + timelockDelay + 1 days) {
            return ProposalState.Queued;
        } else {
            return ProposalState.Expired;
        }
    }

    /**
     * @notice Checks if a proposal has reached quorum.
     * @param proposalId The proposal ID.
     * @return True if quorum is reached.
     */
    function _quorumReached(uint256 proposalId) internal view returns (bool) {
        Proposal storage proposal = proposals[proposalId];
        uint256 totalVotes = proposal.forVotes + proposal.againstVotes;
        uint256 totalSupply = veNFT.totalSupply();
        return totalVotes * BASIS_POINTS / totalSupply >= proposal.quorumPercentage;
    }

    /**
     * @notice Gets the total voting power of a user.
     * @param user The user address.
     * @param snapshotBlock The block number for snapshot (0 for current).
     * @return The voting power.
     */
    function _getVotingPower(address user, uint256 snapshotBlock) internal view returns (uint256) {
        return _getOwnedVotingPower(user, snapshotBlock) + _getDelegatedPower(user, snapshotBlock, 0, maxNFTsPerCheck);
    }

    /**
     * @notice Gets the voting power from owned NFTs.
     * @param user The user address.
     * @param snapshotBlock The block number for snapshot.
     * @return The owned voting power.
     */
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

    /**
     * @notice Gets the delegated voting power with pagination.
     * @param delegatee The delegatee address.
     * @param snapshotBlock The block number for snapshot.
     * @param startIndex The starting index for delegated NFTs.
     * @param maxNFTs The maximum number of NFTs to process.
     * @return The delegated voting power.
     */
    function _getDelegatedPower(address delegatee, uint256 snapshotBlock, uint256 startIndex, uint256 maxNFTs) internal view returns (uint256) {
        uint256 power = 0;
        uint256[] memory tokenIds = delegatedNFTs[delegatee];
        uint256 endIndex = startIndex + maxNFTs > tokenIds.length ? tokenIds.length : startIndex + maxNFTs;
        for (uint256 i = startIndex; i < endIndex; i++) {
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

    /**
     * @notice Validates emergency action data.
     * @param data The calldata to validate.
     */
    function _validateEmergencyData(bytes calldata data) internal pure {
        bytes4 selector = bytes4(data);
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

    /**
     * @notice Distributes voting rewards in USDC.
     * @param voter The voter address.
     */
    function _distributeVotingReward(address voter) internal {
        require(rewardDistributor.balanceOf(address(usdcToken)) >= votingReward, "Insufficient distributor balance");
        try rewardDistributor.distributeVotingReward(voter, votingReward) {
            emit VotingRewardDistributed(voter, votingReward);
        } catch Error(string memory reason) {
            emit RewardDistributionFailed(voter, votingReward, reason);
        } catch {
            emit RewardDistributionFailed(voter, votingReward, "Unknown error");
        }
    }

    /**
     * @notice Distributes cleanup rewards in USDC.
     * @param caller The caller address.
     */
    function _distributeCleanupReward(address caller) internal {
        require(rewardDistributor.balanceOf(address(usdcToken)) >= cleanupReward, "Insufficient distributor balance");
        try rewardDistributor.distributeVotingReward(caller, cleanupReward) {
            emit CleanupRewardDistributed(caller, cleanupReward);
        } catch Error(string memory reason) {
            emit RewardDistributionFailed(caller, cleanupReward, reason);
        } catch {
            emit RewardDistributionFailed(caller, cleanupReward, "Unknown error");
        }
    }

    /**
     * @notice Refunds a proposal deposit in USDC.
     * @param proposer The proposer address.
     */
    function _refundDeposit(address proposer) internal {
        if (proposalDeposits[proposer] >= proposalDeposit) {
            uint256 refund = proposalDeposit;
            proposalDeposits[proposer] -= refund;
            require(usdcToken.transfer(proposer, refund), "Refund failed");
            emit ProposalDepositRefunded(proposer, refund);
        }
    }

    /**
     * @notice Cleans up multiple expired proposals incrementally.
     */
    function _cleanupExpiredProposals() internal {
        uint256 cleaned = 0;
        uint256 startIndex = lastCleanupIndex;
        for (uint256 i = startIndex; i <= proposalCount && cleaned < MAX_CLEANUP_PER_CALL; i++) {
            if (_state(i) == ProposalState.Expired) {
                _cleanupProposal(i);
                cleaned++;
            }
        }
        lastCleanupIndex = startIndex + cleaned;
        if (lastCleanupIndex > proposalCount) {
            lastCleanupIndex = 1;
        }
    }

    /**
     * @notice Cleans up a single expired proposal, clearing storage.
     * @param proposalId The proposal ID.
     */
    function _cleanupProposal(uint256 proposalId) internal {
        _refundDeposit(proposals[proposalId].proposer);
        for (uint256 i = 0; i < councilMembersCount; i++) {
            delete quadraticVotes[proposalId][councilMembersList[i]];
        }
        uint256[] memory tokenIds = veNFT.tokensOfOwner(address(0)); // Dummy call to get possible token IDs
        for (uint256 i = 0; i < tokenIds.length && i < maxNFTsPerCheck; i++) {
            delete nftVoted[proposalId][tokenIds[i]];
        }
        delete proposals[proposalId];
        delete proposalSnapshotBlock[proposalId];
        emit ProposalExpired(proposalId);
    }

    /**
     * @notice Extracts revert message from failed call.
     * @param result The return data from the failed call.
     * @return The revert message.
     */
    function _getRevertMsg(bytes memory result) internal pure returns (string memory) {
        if (result.length < 68) return "Unknown error";
        try this.decodeRevertMsg(result) returns (string memory reason) {
            return reason;
        } catch {
            return "Custom error or invalid format";
        }
    }

    /**
     * @notice Decodes revert message for external use.
     * @param result The return data.
     * @return The decoded revert message.
     */
    function decodeRevertMsg(bytes calldata result) external pure returns (string memory) {
        return abi.decode(result[4:], (string));
    }

    /**
     * @notice Removes an NFT from a delegatee's list efficiently.
     * @param delegatee The delegatee address.
     * @param tokenId The NFT token ID.
     */
    function _removeNFTFromDelegatee(address delegatee, uint256 tokenId) internal {
        uint256[] storage tokenIds = delegatedNFTs[delegatee];
        uint256 index = delegatedNFTsIndex[delegatee][tokenId];
        if (index < tokenIds.length && tokenIds[index] == tokenId) {
            tokenIds[index] = tokenIds[tokenIds.length - 1];
            delegatedNFTsIndex[delegatee][tokenIds[index]] = index;
            tokenIds.pop();
            delete delegatedNFTsIndex[delegatee][tokenId];
        }
    }

    /**
     * @notice Computes quadratic voting weight with caching.
     * @dev Quadratic voting uses square root to reduce influence of large holders, increasing fairness but adding gas cost.
     *      Cache reduces repeated Math.sqrt calls for same weight.
     * @param proposalId The proposal ID.
     * @param weight The raw voting weight.
     * @param isQuadratic True to apply quadratic voting.
     * @return The adjusted weight.
     */
    function _computeQuadraticWeight(uint256 proposalId, uint256 weight, bool isQuadratic) internal returns (uint256) {
        if (!isQuadratic) return weight;
        if (quadraticWeightCache[weight] != 0) {
            return quadraticWeightCache[weight];
        }
        uint256 adjustedWeight = Math.sqrt(weight);
        quadraticWeightCache[weight] = adjustedWeight;
        return adjustedWeight;
    }

    /**
     * @notice Gets the dynamic proposal threshold based on total veNFT supply.
     * @return The threshold in voting power.
     */
    function _getDynamicProposalThreshold() internal view returns (uint256) {
        uint256 totalSupply = veNFT.totalSupply();
        return (totalSupply * proposalThresholdBps) / BASIS_POINTS;
    }

    /**
     * @notice Validates action dependencies to ensure no circular or invalid dependencies.
     * @param actions The array of actions.
     */
    function _validateActionDependencies(Action[] memory actions) internal pure {
        for (uint256 i = 0; i < actions.length; i++) {
            for (uint256 j = 0; j < actions[i].dependencies.length; j++) {
                uint256 depIndex = actions[i].dependencies[j];
                require(depIndex < i, "Dependency must precede action");
            }
        }
    }

    /**
     * @notice Resets council election votes if cycle duration has passed.
     */
    function _resetElectionIfNeeded() internal {
        if (block.timestamp >= lastElectionReset + ELECTION_CYCLE_DURATION) {
            for (uint256 i = 0; i < councilMembersCount; i++) {
                delete councilElectionVotes[councilMembersList[i]];
            }
            councilElectionCycle++;
            lastElectionReset = block.timestamp;
            emit CouncilElectionReset(councilElectionCycle, block.timestamp);
        }
    }

    /**
     * @notice Generates actions for a proposal template.
     * @param template The template type.
     * @param params The template parameters.
     * @return actions The generated actions.
     */
    function _generateTemplateActions(ProposalTemplate template, bytes calldata params) internal view returns (Action[] memory actions) {
        actions = new Action[](2);
        if (template == ProposalTemplate.FeeUpdate) {
            (uint256 newManagementFee, uint256 newPerformanceFee) = abi.decode(params, (uint256, uint256));
            actions[0] = Action({
                target: address(sonicHarvest),
                data: abi.encodeCall(ISonicHarvest.proposeUpdateFees, (newManagementFee, newPerformanceFee)),
                value: 0,
                dependencies: new uint256[](0)
            });
            actions[1] = Action({
                target: address(sonicHarvest),
                data: abi.encodeCall(ISonicHarvest.executeUpdateFees, (newManagementFee, newPerformanceFee)),
                value: 0,
                dependencies: new uint256[](1)
            });
            actions[1].dependencies[0] = 0;
        } else if (template == ProposalTemplate.FeeRecipientUpdate) {
            address newRecipient = abi.decode(params, (address));
            actions[0] = Action({
                target: address(sonicHarvest),
                data: abi.encodeCall(ISonicHarvest.proposeFeeRecipientUpdate, (newRecipient)),
                value: 0,
                dependencies: new uint256[](0)
            });
            actions[1] = Action({
                target: address(sonicHarvest),
                data: abi.encodeCall(ISonicHarvest.executeFeeRecipientUpdate, (newRecipient)),
                value: 0,
                dependencies: new uint256[](1)
            });
            actions[1].dependencies[0] = 0;
        } else if (template == ProposalTemplate.RecoverFunds) {
            (address protocol, uint256 amount) = abi.decode(params, (address, uint256));
            actions[0] = Action({
                target: address(sonicHarvest),
                data: abi.encodeCall(ISonicHarvest.proposeRecoverFunds, (protocol, amount)),
                value: 0,
                dependencies: new uint256[](0)
            });
            actions[1] = Action({
                target: address(sonicHarvest),
                data: abi.encodeCall(ISonicHarvest.executeRecoverFunds, (protocol, amount)),
                value: 0,
                dependencies: new uint256[](1)
            });
            actions[1].dependencies[0] = 0;
        } else if (template == ProposalTemplate.EmergencyWithdraw) {
            (address user, uint256 amount) = abi.decode(params, (address, uint256));
            actions[0] = Action({
                target: address(sonicHarvest),
                data: abi.encodeCall(ISonicHarvest.proposeEmergencyWithdraw, (user, amount)),
                value: 0,
                dependencies: new uint256[](0)
            });
            actions[1] = Action({
                target: address(sonicHarvest),
                data: abi.encodeCall(ISonicHarvest.executeEmergencyWithdraw, (user, amount)),
                value: 0,
                dependencies: new uint256[](1)
            });
            actions[1].dependencies[0] = 0;
        } else if (template == ProposalTemplate.EmergencyTransfer) {
            (address user, uint256 amount) = abi.decode(params, (address, uint256));
            actions[0] = Action({
                target: address(sonicHarvest),
                data: abi.encodeCall(ISonicHarvest.proposeEmergencyTransfer, (user, amount)),
                value: 0,
                dependencies: new uint256[](0)
            });
            actions[1] = Action({
                target: address(sonicHarvest),
                data: abi.encodeCall(ISonicHarvest.executeEmergencyTransfer, (user, amount)),
                value: 0,
                dependencies: new uint256[](1)
            });
            actions[1].dependencies[0] = 0;
        } else if (template == ProposalTemplate.ProtocolWhitelist) {
            (address protocol, bool status, address apyFeed, bool isCompound) = abi.decode(params, (address, bool, address, bool));
            actions[0] = Action({
                target: address(sonicHarvest),
                data: abi.encodeCall(ISonicHarvest.setProtocolWhitelist, (protocol, status, apyFeed, isCompound)),
                value: 0,
                dependencies: new uint256[](0)
            });
            actions[1] = Action({
                target: address(0),
                data: "",
                value: 0,
                dependencies: new uint256[](0)
            });
        } else {
            revert("Invalid template");
        }
        return actions;
    }

    /**
     * @notice Converts uint256 to string for error messages.
     * @param value The value to convert.
     * @return The string representation.
     */
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits--;
            buffer[digits] = bytes1(uint8(48 + value % 10));
            value /= 10;
        }
        return string(buffer);
    }
}
