# SONIC HARVEST DEFI PROTOCOL
Sonic Harvest is a decentralized finance (DeFi) yield farming aggregator optimized for the Sonic Blockchain. It maximizes yield by dynamically allocating funds across multiple protocols, including Aave V3, Compound, FlyingTulip, real-world asset (RWA) protocols, and Sonic-native DeFi protocols. Leveraging Sonic’s Fee Monetization, native USDC, RedStone oracles, and Sonic Points for airdrop eligibility, Sonic Harvest offers a secure, scalable, and user-friendly solution for yield optimization.

**Table of Contents**

Overview (#overview)

Features (#features)

Architecture (#architecture)

Prerequisites (#prerequisites)

Installation (#installation)

Deployment (#deployment)

Usage (#usage)

Security Considerations (#security-considerations)

Testing (#testing)

Contributing (#contributing)

License (#license)

Contact (#contact)

**Overview**:
Sonic Harvest is a UUPS-upgradeable, ownable, pausable, and reentrancy-guarded smart contract that aggregates yield farming opportunities on the Sonic Blockchain. It supports:
Dynamic Rebalancing: Allocates funds to protocols based on real-time APY data from Chainlink/RedStone oracles.

**Leveraged Yield Farming**: Supports borrowing from Aave V3, Compound, and FlyingTulip with strict LTV (Loan-to-Value) and health factor checks.

**Governance**: Multi-sig or DAO-based governance with timelocks for upgrades, fee updates, and fund recovery.

**Sonic Ecosystem Integration**: Uses Sonic’s native USDC, Fee Monetization, and Sonic Points for user incentives.

**Safety Mechanisms**: Emergency pause, circuit breakers for oracle failures, and user blacklisting for compliance.

The contract is designed for Sonic’s Blaze testnet and is compatible with SonicVM (EVM-compatible). It aims to provide users with optimized returns while maintaining security and transparency.
#Features
Supported Protocols:
Aave V3 (supply/withdraw, variable-rate borrowing).

Compound (mint/redeem, borrowing with collateral factor checks).

FlyingTulip (dynamic APY, leverage, OFAC compliance).

RWA protocols (e.g., Sigma Fund for tokenized assets).

Sonic-native DeFi protocols (via IDeFiYield interface).

Yield Optimization:
Reallocates funds to protocols with the highest APY, weighted by available liquidity.

Fetches APY data from Chainlink/RedStone oracles, Aave/Compound APIs, or Sonic protocol interfaces.

Leverage Management:
Supports up to 80% LTV for leveraged positions.

Ensures Aave health factor ≥ 1.5 and Compound collateral factor ≥ 1.5e18.

Unwinds leverage during emergency pauses.

Fee Structure:
0.5% management fee on deposits.

10% performance fee on profits.

90% of gas fees contribute to Sonic Fee Monetization rewards.

Governance and Security:
2-day timelock for upgrades, fee changes, and fund recovery.

Emergency pause (7-day max) with user withdrawal support.

Circuit breaker pauses rebalancing if >50% of oracle feeds fail.

Blacklist and OFAC compliance via FlyingTulip.

User Incentives:
Earn Sonic Points (2x for deposits/allocations, 1x for withdrawals) for airdrop eligibility.

Claimable Fee Monetization rewards for governance.

Architecture
Sonic Harvest is built using Solidity 0.8.20 and follows a modular, upgradeable design:
Key Components
Interfaces:
IAaveV3Pool: Interacts with Aave V3 for supply, withdrawal, and borrowing.

ICompound: Manages Compound cToken minting, redemption, and borrowing.

IRWAYield: Handles RWA protocol deposits and withdrawals.

IDeFiYield: Supports Sonic-native DeFi protocols.

IFlyingTulip: Provides dynamic APY, leverage, and compliance checks.

ISonicProtocol: Ensures protocol compliance and fetches Sonic-native APYs.

State Variables:
stablecoin: Sonic’s native USDC (immutable).

allocations: Tracks protocol allocations (amount, APY, leverage status).

userBalances: Records user deposits.

sonicPointsEarned: Tracks user Sonic Points for airdrop.

totalFeeMonetizationRewards: Accumulates Fee Monetization rewards.

Modifiers:
onlyGovernance: Restricts sensitive functions to the governance address.

whenNotEmergencyPaused: Prevents actions during emergency pauses.

sonicFeeMonetization: Calculates and accumulates Fee Monetization rewards.

Events:
Emits events for deposits, withdrawals, rebalancing, fee collection, governance updates, and more for transparency.

Workflow
Deposit: Users deposit USDC, pay a 0.5% management fee, and earn 2x Sonic Points. Funds are allocated to protocols based on APY.

Rebalance: Governance triggers rebalancing to optimize allocations using oracle data. Leveraged positions are adjusted if enabled.

Withdraw: Users withdraw funds, receive profits (minus 10% performance fee), and earn 1x Sonic Points.

Upkeep: Chainlink Automation updates APYs daily. Manual upkeep is available if automation fails.

Emergency: Governance can pause the contract, unwind leverage, or recover funds with a 2-day timelock.

Governance: Updates fees, governance, or whitelists protocols via timelocked actions.

Prerequisites
Node.js: v16 or higher.

Hardhat or Foundry: For compilation, testing, and deployment.

Sonic Blaze Testnet:
RPC: https://rpc.testnet.sonic.network

Chain ID: 64165

Native Token: S

Dependencies:
OpenZeppelin Contracts (@openzeppelin/contracts-upgradeable@4.9.3).

Chainlink Contracts (@chainlink/contracts@0.8).

Wallet: MetaMask or compatible wallet with testnet S tokens and USDC.

Faucet: Use Sonic’s testnet faucet to obtain S and USDC.

Installation
Clone the repository:
bash

git clone https://github.com/your-org/sonic-harvest.git
cd sonic-harvest

Install dependencies:
bash

npm install

Configure environment variables:
Create a .env file:
env

SONIC_TESTNET_RPC=https://rpc.testnet.sonic.network
PRIVATE_KEY=your_private_key
AAVE_POOL_ADDRESS=0x...
COMPOUND_ADDRESS=0x...
FLYINGTULIP_ADDRESS=0x...
RWA_YIELD_ADDRESS=0x...
DEFI_YIELD_ADDRESS=0x...
SONIC_PROTOCOL_ADDRESS=0x...
SONIC_POINTS_TOKEN_ADDRESS=0x...
USDC_ADDRESS=0x...
GOVERNANCE_ADDRESS=0x...
FEE_RECIPIENT_ADDRESS=0x...

Compile contracts:
bash

npx hardhat compile

Deployment
Deploy dependency contracts (if not already deployed):
Deploy mock or real implementations of Aave V3, Compound, FlyingTulip, RWAYield, DeFiYield, SonicProtocol, and SonicPointsToken.

Deploy Sonic Harvest:
bash

npx hardhat run scripts/deploy.js --network sonicTestnet

Initialize the contract:
Call initialize with the addresses from .env:
javascript

const SonicHarvest = await ethers.getContractAt("SonicHarvest", contractAddress);
await SonicHarvest.initialize(
  process.env.USDC_ADDRESS,
  process.env.RWA_YIELD_ADDRESS,
  process.env.DEFI_YIELD_ADDRESS,
  process.env.FLYINGTULIP_ADDRESS,
  process.env.AAVE_POOL_ADDRESS,
  process.env.SONIC_PROTOCOL_ADDRESS,
  process.env.SONIC_POINTS_TOKEN_ADDRESS,
  process.env.FEE_RECIPIENT_ADDRESS,
  process.env.GOVERNANCE_ADDRESS
);

Verify the contract on Sonic’s testnet explorer:
bash

npx hardhat verify --network sonicTestnet <contractAddress> <constructorArgs>

Usage
For Users
Deposit USDC:
Approve USDC for Sonic Harvest:
javascript

const usdc = await ethers.getContractAt("IERC20", process.env.USDC_ADDRESS);
await usdc.approve(sonicHarvestAddress, ethers.utils.parseUnits("10000", 6)); // 10,000 USDC

Deposit 10,000 USDC:
javascript

await SonicHarvest.deposit(ethers.utils.parseUnits("10000", 6));

Check Sonic Points earned:
javascript

const points = await SonicHarvest.sonicPointsEarned(userAddress);
console.log(`Earned Points: ${points.toString()}`);

Withdraw Funds:
Withdraw 5,000 USDC:
javascript

await SonicHarvest.withdraw(ethers.utils.parseUnits("5000", 6));

Claim Sonic Points:
Claim points for airdrop eligibility:
javascript

await SonicHarvest.claimSonicPoints(userAddress);

Emergency Withdraw (if paused):
Withdraw during an emergency pause:
javascript

await SonicHarvest.userEmergencyWithdraw(ethers.utils.parseUnits("5000", 6));

For Governance
Rebalance:
Trigger rebalancing:
javascript

await SonicHarvest.rebalance();

Toggle Leverage:
Enable/disable leverage:
javascript

await SonicHarvest.toggleLeverage(true); // Enable

Update Fees:
Propose and execute fee update:
javascript

await SonicHarvest.proposeUpdateFees(100, 1500); // 1% management, 15% performance
// Wait 2 days
await SonicHarvest.executeUpdateFees(100, 1500);

Recover Funds:
Propose and execute fund recovery:
javascript

await SonicHarvest.proposeRecoverFunds(protocolAddress, ethers.utils.parseUnits("1000", 6));
// Wait 2 days
await SonicHarvest.executeRecoverFunds(protocolAddress, ethers.utils.parseUnits("1000", 6));

Claim Fee Monetization Rewards:
Claim rewards:
javascript

await SonicHarvest.claimFeeMonetizationRewards();

For Developers
Whitelisting Protocols:
Whitelist a new protocol:
javascript

await SonicHarvest.setProtocolWhitelist(newProtocolAddress, true, apyFeedAddress, isCompound);

Manual Upkeep:
Trigger manual upkeep:
javascript

await SonicHarvest.manualUpkeep();

Upgrade Contract:
Deploy a new implementation and propose an upgrade:
javascript

const NewSonicHarvest = await ethers.getContractFactory("SonicHarvest");
const newImplementation = await NewSonicHarvest.deploy();
await SonicHarvest.proposeUpgrade(newImplementation.address);
// Wait 2 days
await SonicHarvest.upgradeTo(newImplementation.address);

Security Considerations
Reentrancy Protection: Uses ReentrancyGuard for all external calls involving transfers.

Upgradeability: UUPS proxy with a 2-day timelock for upgrades, restricted to the owner.

Pausability: Supports emergency pause (7-day max) and regular pause/unpause by governance.

Oracle Safety:
Circuit breaker pauses rebalancing if >50% of feeds fail.

Validates APY data (0 < APY ≤ 100%) and checks for staleness (30 minutes max).

Falls back to last known APYs or Aave/Compound/Sonic APIs if oracles fail.

Compliance:
Blacklist users via updateBlacklist.

OFAC compliance checks via FlyingTulip’s isOFACCompliant.

Leverage Risks:
Caps LTV at 80%.

Ensures Aave health factor ≥ 1.5 and Compound collateral factor ≥ 1.5e18.

Unwinds leverage during pauses to mitigate liquidation risks.

Timelocks: 2-day delay for governance actions (upgrades, fee updates, fund recovery).

Audits: Recommended to undergo a formal audit by a reputable firm before mainnet deployment.

Testing
Setup
Install testing dependencies:
bash

npm install --dev mocha chai @nomiclabs/hardhat-ethers

Deploy mock contracts:
Mock Aave V3, Compound, FlyingTulip, RWAYield, DeFiYield, SonicProtocol, and USDC.

Mock RedStone/Chainlink oracles with sample APYs (e.g., 6–12%).

Fund the test environment:
Use Sonic’s testnet faucet to obtain S and USDC.

Transfer USDC to test accounts.

Test Cases
Run tests with:
bash

npx hardhat test

Core Functionality
Deposit:
Deposit 10,000 USDC, verify 0.5% fee (50 USDC), and check allocation across protocols.

Confirm 2x Sonic Points earned.

Withdraw:
Withdraw 5,000 USDC, verify profit calculation (based on 6–12% APY), 10% performance fee, and 1x Sonic Points.

Rebalance:
Simulate APY changes (e.g., FlyingTulip 8% → 12%), verify reallocation.

Test leverage inclusion when enabled.

Leverage:
Enable leverage, deposit to Aave/Compound/FlyingTulip, verify LTV ≤ 80% and health factor ≥ 1.5.

Test leverage unwinding during pause.

Governance
Fee Updates:
Propose and execute fee update (e.g., 1% management, 15% performance) after 2-day timelock.

Protocol Whitelisting:
Whitelist a new protocol, verify APY feed integration.

Fund Recovery:
Simulate protocol failure, propose and execute fund recovery after timelock.

Governance Update:
Propose and confirm new governance address after 2-day delay.

Security
Emergency Pause:
Trigger emergency pause, verify user withdrawals work, and test auto-unpause after 7 days.

Circuit Breaker:
Simulate >50% oracle feed failures, verify rebalancing pause.

Reentrancy:
Attempt reentrancy attacks on deposit/withdraw, verify protection.

Blacklist:
Blacklist a user, verify they cannot deposit.

Edge Cases
Zero Deposits: Test deposits below MIN_DEPOSIT (reverts).

Empty Protocols: Test rebalancing with no valid protocols (skips allocation).

Stale Oracles: Test with stale APY feeds, verify fallback to last known APYs.

Low Liquidity: Test withdrawals exceeding protocol liquidity, verify partial withdrawals.

Coverage
Aim for ≥95% test coverage using:
bash

npx hardhat coverage

Contributing
We welcome contributions to Sonic Harvest! To contribute:
Fork the repository.

Create a feature branch (git checkout -b feature/your-feature).

Commit changes (git commit -m "Add your feature").

Push to the branch (git push origin feature/your-feature).

Open a pull request with a detailed description.

Please adhere to:
Code Style: Follow Solidity style guide (e.g., 4-space indentation, NatSpec comments).

Testing: Include unit tests for new features.

Governance.sol is a decentralized governance contract for the Sonic Harvest protocol, enabling community-driven decision-making through voting with Sonic Harvest’s voting escrow NFT (veNFT). It supports proposals, voting, timelock execution, emergency actions, and contract upgrades, with features like quadratic voting, dynamic thresholds, and optimized gas usage. The contract is built using OpenZeppelin’s upgradeable, pausable, and reentrancy-protected frameworks, ensuring security and flexibility.
Features
veNFT-Based Voting: Voting power is derived from veNFT tokens, representing locked Sonic tokens with weights based on lock duration and amount.

Quadratic Voting: Optional quadratic voting reduces the influence of large holders by applying the square root to voting weights, promoting fairness.

Proposal System: Users can propose governance actions (e.g., fee updates, protocol whitelisting) with customizable quorum, parent dependencies, and quadratic voting.

Batch Operations: Supports batch proposal creation and voting to optimize gas costs.

Template Proposals: Predefined templates for common actions (e.g., fee updates, emergency withdrawals) simplify proposal creation.

Delegation: Users can delegate veNFT voting power to others, with efficient batch delegation and revocation.

Governance Council: A council of elected members can propose and approve emergency actions (e.g., pausing, rebalancing) with veto mechanisms.

Timelock and Veto: Proposals and upgrades are subject to a timelock delay, with community veto options for emergency actions and upgrades.

Rewards: USDC rewards for voting and cleaning up expired proposals incentivize participation.

Dynamic Thresholds: Proposal thresholds adjust based on total veNFT supply, ensuring scalability.

Storage Cleanup: Expired proposals are cleaned to prevent storage bloat, with rewards for callers.

Upgradability: Uses OpenZeppelin’s UUPS proxy pattern for secure upgrades with storage version checks.

Pausability: Governance can pause non-critical operations during emergencies.

Whitelisting: Only whitelisted targets (e.g., SonicHarvest) can be called by proposals, enhancing security.

Prerequisites
Solidity Version: ^0.8.20

Dependencies:
OpenZeppelin Contracts (@openzeppelin/contracts and @openzeppelin/contracts-upgradeable):
UUPSUpgradeable

PausableUpgradeable

ReentrancyGuard

Math

IERC20

Sonic Interfaces:
IVeNFT: Voting escrow NFT contract for voting power.

ISonicHarvest: Sonic Harvest contract for protocol actions.

IRewardDistributor: Reward distribution contract for USDC rewards.

Installation
Install Dependencies:
bash

npm install @openzeppelin/contracts @openzeppelin/contracts-upgradeable

Compile the Contract:
Use Hardhat, Foundry, or another Solidity compiler:
bash

npx hardhat compile

Deploy the Contract:
Deploy using a proxy pattern (UUPS) with the initialize function. Example using Hardhat:
javascript

const Governance = await ethers.getContractFactory("Governance");
const governance = await upgrades.deployProxy(Governance, [
  veNFTAddress,
  sonicHarvestAddress,
  rewardDistributorAddress,
  usdcTokenAddress,
  councilMembers,
  councilThreshold,
  timelockDelay
], { initializer: 'initialize' });
await governance.deployed();

Usage
Initialization
The contract must be initialized with:
veNFT: Address of the veNFT contract.

sonicHarvest: Address of the SonicHarvest contract.

rewardDistributor: Address of the IRewardDistributor contract.

usdcToken: Address of Sonic’s native USDC token (6 decimals).

councilMembers: Array of initial governance council members.

councilThreshold: Number of council approvals required for emergency actions.

timelockDelay: Timelock duration for proposal execution (1–30 days).

Example:
solidity

governance.initialize(
  "0x...", // veNFT
  "0x...", // sonicHarvest
  "0x...", // rewardDistributor
  "0x...", // usdcToken
  ["0x...", "0x..."], // councilMembers
  2, // councilThreshold
  3 days // timelockDelay
);

Key Functions
Proposal Creation
propose: Create a single proposal with actions, description, custom quorum, parent proposal, quadratic voting flag, and dependency flag.
solidity

Action[] memory actions = new Action[](1);
actions[0] = Action(address(sonicHarvest), abi.encodeCall(ISonicHarvest.rebalance, ()), 0, new uint256[](0));
governance.propose(actions, "Rebalance protocol", 0, 0, true, false);

proposeBatch: Create multiple proposals in one transaction for gas efficiency.

proposeWithTemplate: Use predefined templates (e.g., FeeUpdate, ProtocolWhitelist) for common actions.
solidity

bytes memory params = abi.encode(100, 200); // newManagementFee, newPerformanceFee
governance.proposeWithTemplate(ProposalTemplate.FeeUpdate, params, "Update fees", true);

Voting
vote: Vote on a proposal using a specific veNFT.
solidity

governance.vote(proposalId, tokenId, true); // Vote in favor

voteAsDelegatee: Vote using delegated power with pagination.
solidity

governance.voteAsDelegatee(proposalId, true, 0, 100);

voteBatch: Vote on multiple proposals in one transaction.
solidity

uint256[] memory proposalIds = new uint256[](2);
uint256[] memory tokenIds = new uint256[](2);
bool[] memory supports = new bool[](2);
governance.voteBatch(proposalIds, tokenIds, supports, startIndices, maxNFTs);

Delegation
delegateNFTsBatch: Delegate multiple veNFTs to a delegatee.
solidity

uint256[] memory tokenIds = new uint256[](2);
tokenIds[0] = 1;
tokenIds[1] = 2;
governance.delegateNFTsBatch(tokenIds, delegateeAddress);

revokeNFTsBatch: Revoke delegation for multiple veNFTs.

Execution
queue: Queue a successful proposal for execution after voting.
solidity

governance.queue(proposalId);

execute: Execute a queued proposal after the timelock.
solidity

governance.execute(proposalId);

Emergency Actions
proposeEmergencyAction: Council members propose emergency actions (e.g., pause, rebalance).
solidity

governance.proposeEmergencyAction(address(sonicHarvest), abi.encodeCall(ISonicHarvest.setEmergencyPause, (true)));

approveEmergencyAction: Council members approve emergency actions.

proposeEmergencyVeto: Community members propose a veto for emergency actions.

executeEmergencyVeto: Execute a successful veto.

Upgrades
proposeUpgrade: Propose a contract upgrade with a new implementation and storage version.
solidity

governance.proposeUpgrade(newImplementation, 2);

executeUpgrade: Execute the upgrade after the timelock.

proposeUpgradeVeto: Propose a veto for an upgrade.

executeUpgradeVeto: Execute a successful veto.

Council Elections
voteForCouncil: Vote for council candidates using veNFT or delegated power.
solidity

governance.voteForCouncil(candidateAddress, tokenId);

resetCouncilElection: Reset election votes every 90 days.

Cleanup
cleanupExpiredProposal: Clean a single expired proposal.
solidity

governance.cleanupExpiredProposal(proposalId);

cleanupExpiredProposals: Clean multiple expired proposals incrementally.

Governance Parameters
updateVotingPeriod, updateQuorum, updateProposalThreshold, etc.: Update governance settings (only callable by governance).
solidity

governance.updateVotingPeriod(5 days);

Configuration
Constants
MIN_VOTING_PERIOD: 3 days

MAX_VOTING_PERIOD: 14 days

MIN_QUORUM: 20% (2000 basis points)

MAX_QUORUM: 60% (6000 basis points)

MIN_PROPOSAL_THRESHOLD_BPS: 0.05% (5 basis points)

EMERGENCY_COOLDOWN: 2 days

UPGRADE_TIMELOCK: 3 days

COUNCIL_TERM_DURATION: 180 days

ELECTION_CYCLE_DURATION: 90 days

DEFAULT_PROPOSAL_DEPOSIT: 10 USDC

DEFAULT_VOTING_REWARD: 1 USDC

DEFAULT_CLEANUP_REWARD: 0.1 USDC

Configurable Parameters
votingPeriod: Duration of voting (3–14 days).

timelockDelay: Delay before execution (1–30 days).

vetoWindow: Time to propose vetoes (12 hours–7 days).

quorumPercentage: Required voter turnout (20–60%).

proposalThresholdBps: Minimum voting power to propose (default: 0.5%).

proposalDeposit: USDC deposit for proposals (default: 10 USDC).

votingReward: USDC reward for voting (default: 1 USDC).

cleanupReward: USDC reward for cleanup (default: 0.1 USDC).

maxNFTsPerCheck: Maximum veNFTs to process for delegated voting (default: 1000).

Security Considerations
Reentrancy Protection: Uses ReentrancyGuard to prevent reentrancy attacks.

Pausability: Critical functions can be paused during emergencies.

Whitelisted Targets: Only whitelisted contracts (e.g., SonicHarvest) can be called by proposals.

Timelock: Delays execution to allow community review and vetoes.

Quadratic Voting Cache: Optimizes gas for repeated calculations but requires cleanup to manage storage.

Sybil Resistance: veNFT’s non-fungibility and locking discourage vote splitting.

Council Oversight: Emergency actions require multiple council approvals, with community veto options.

Upgrade Safety: UUPS proxy with storage version checks ensures compatibility.

Events
Key events for tracking governance activities:
ProposalCreated: Emitted when a proposal is created.

Voted: Emitted when a vote is cast.

QuadraticVoteCast: Emitted for quadratic votes.

ProposalExecuted, ProposalCanceled, ProposalExpired: Track proposal lifecycle.

EmergencyActionProposed, EmergencyActionApproved, EmergencyActionExecuted: Track emergency actions.

NFTDelegationSet, BatchDelegationSet: Track delegation changes.

UpgradeProposed, UpgradeExecuted, UpgradeVetoed: Track contract upgrades.

VotingRewardDistributed, CleanupRewardDistributed: Track rewards.

Testing
Run tests using Hardhat or Foundry. Example test suite:
javascript

describe("Governance", function () {
  it("should allow proposal creation and voting", async function () {
    // Deploy and initialize contract
    // Create proposal
    // Vote with veNFT
    // Queue and execute
    // Verify state changes
  });
});

Deployment
Deploy veNFT, SonicHarvest, RewardDistributor, and USDC contracts.

Deploy Governance.sol as a UUPS proxy with the initialize function.

Whitelist SonicHarvest as a target.

Configure initial council and parameters.

Future Improvements
Advanced Voting Modes: Add more voting mechanisms (e.g., ranked-choice voting).

Gas Optimization: Further reduce gas costs for batch operations.

UI Integration: Develop a user-friendly interface for proposal creation and voting.

Cross-Chain Governance: Enable voting across multiple chains.

Dynamic Rewards: Adjust rewards based on participation or proposal complexity.

Documentation: Update this README for new features or changes.

License
Sonic Harvest is licensed under the MIT License (LICENSE). See the LICENSE file for details.
Contact
Project Maintainer: Emantest/Sonic Harvest

Email: support@sonic-harvest.io

Discord: Join our Sonic Harvest Discord

Twitter/X: Follow us on Sonic Harvest Twitter

Issues: Report bugs or feature requests on GitHub Issues

