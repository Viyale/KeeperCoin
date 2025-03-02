// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
   KeeperCoin DAO Full version:
   - Implements a fixed total supply with deflationary mechanics via automatic annual burn and dynamic burn on every transfer.
   - DAO treasury is allocated 15% of the total supply.
   - DAO governance allows community proposals to update critical parameters such as burn rates, transfer fees, treasury management, timelock delays, and more.
   - Developer withdrawal funds are available after 5 years; if no withdrawal occurs within a 1-year grace period, the remaining allocation is transferred to the DAO treasury.
   - Proposals involving fund transfers require additional quorum (fundsProposalThreshold) and multi-signature approvals.
   - Treasury proposals require that voters hold at least 5% of the allocated treasury tokens, and vote weight is calculated via treasuryVoteWeightRate (basis points, 1 basis point = 0.01%) and capped by treasuryMaxVoteWeight. A minimum unique voter count (treasuryMinVoterCount) is enforced.
   - All critical functions are protected with ReentrancyGuard and can be paused using Pausable.
   - “Code is law” is applied, meaning that the smart contract governs itself automatically.
*/

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract KeeperCoinDAOFull is ERC20, ReentrancyGuard, Pausable {
    // Basic Variables
    address public developer;
    uint public deploymentTime;
    uint public nextAnnualBurn;
    uint public nextDeveloperWithdrawalTime;

    uint public constant TOTAL_SUPPLY = 18500000e18;
    uint public constant DEV_ALLOCATION = 600000e18;
    uint public treasuryAllocation;  // 15% of total supply
    uint public treasuryQuorum;      // Quorum for treasury proposals (5% of treasuryAllocation)

    // Additional Quorum for proposals involving funds (e.g. TreasurySpending, DeveloperWithdrawal)
    uint public fundsProposalThreshold = 200e18;

    // Developer withdrawal grace period: if no withdrawal within 1 year after the withdrawal window opens, remaining funds go to treasury.
    uint public developerWithdrawalGracePeriod = 365 days;

    // Timelock delay (modifiable via DAO proposals)
    uint public timelockDelay;

    // Treasury Voting Parameters
    uint public treasuryVoteWeightRate; // in basis points (1 basis point = 0.01%), initial value 1
    uint public treasuryMinVoterCount;  // Minimum unique voters required for treasury proposals (default 5)
    uint public treasuryMaxVoteWeight;  // Maximum vote weight per address (default 1e16, ~0.01 KPT)

    // Annual Burn Parameters
    uint public annualBurnRate;
    bool public annualBurnEnabled;
    uint public remainingAllocation = DEV_ALLOCATION;

    // Developer Withdrawal Parameters
    uint public maxDeveloperWithdrawal;
    uint public developerWithdrawalBurnPercentage;

    // Transfer Fee and Voting Fee (expressed as tenths of percent, etc.)
    uint public transferFeeRate;
    uint public votingFee;

    // Emergency Voting Threshold
    uint public emergencyVotingThreshold = 100e18;

    // Dynamic Burn Parameters (for transfers)
    uint public tier1Threshold;
    uint public tier2Threshold;
    uint public tier3Threshold;
    uint public minDynamicBurnRate;
    uint public midDynamicBurnRate;
    uint public maxDynamicBurnRate;

    // Additional Parameters for Governance
    uint public minStakeForVoting = 100e18; // Minimum tokens required to vote (Quadratic Voting)
    uint public multiSigApprovalsRequired = 3; // Required number of approvers for certain proposals

    // Pause start time for emergency control
    uint public pauseStartTime;

    // DAO Proposal Types
    enum ProposalType { 
        AnnualBurnChange,          
        AnnualBurnRateChange,      
        DeveloperWithdrawal,       
        WithdrawalLimitChange,     
        WithdrawalBurnChange,      
        TransferFeeRateChange,     
        EmergencyControl,
        VotingFeeChange,
        EmergencyVotingThresholdChange,
        DynamicBurnParametersChange,
        TreasurySpending,
        TreasuryAllocationChange,
        TreasuryVoteWeightChange,
        TimelockDelayChange,
        TreasuryVoterParticipationChange
    }

    struct Proposal {
        uint id;
        ProposalType proposalType;
        bool proposedState;
        uint newAnnualBurnRate;
        uint withdrawalAmount;
        uint newWithdrawalLimit;
        uint newBurnPercentage;
        uint newTransferFeeRate;
        uint newVotingFee;
        uint newEmergencyVotingThreshold;
        uint newTier1Threshold;
        uint newTier2Threshold;
        uint newTier3Threshold;
        uint newMinDynamicBurnRate;
        uint newMidDynamicBurnRate;
        uint newMaxDynamicBurnRate;
        uint newTreasurySpendingAmount;
        address treasuryRecipient;
        uint newTreasuryAllocation;
        uint newTreasuryQuorum;
        uint newTreasuryVoteWeightRate;
        uint newTimelockDelay;
        // Treasury voting parameters proposals
        uint newTreasuryMinVoterCount;
        uint newTreasuryMaxVoteWeight;
        // Unique voter count for treasury proposals
        uint uniqueVoterCount;
        uint startTime;
        uint endTime;
        uint votesFor;
        uint votesAgainst;
        bool executed;
    }
    uint public proposalCount;
    mapping(uint => Proposal) public proposals;
    mapping(uint => mapping(address => bool)) public hasVoted;
    mapping(uint => address[]) public proposalApprovers; // For multi-sig approvals

    // Events
    event AnnualBurnExecuted(uint amount, uint timestamp);
    event ProposalCreated(
        uint proposalId,
        ProposalType proposalType,
        bool proposedState,
        uint newAnnualBurnRate,
        uint withdrawalAmount,
        uint newWithdrawalLimit,
        uint newBurnPercentage,
        uint newTransferFeeRate,
        uint newVotingFee,
        uint newEmergencyVotingThreshold,
        uint newTier1Threshold,
        uint newTier2Threshold,
        uint newTier3Threshold,
        uint newMinDynamicBurnRate,
        uint newMidDynamicBurnRate,
        uint newMaxDynamicBurnRate,
        uint newTreasurySpendingAmount,
        address treasuryRecipient,
        uint newTreasuryAllocation,
        uint newTreasuryQuorum,
        uint newTreasuryVoteWeightRate,
        uint newTimelockDelay,
        uint newTreasuryMinVoterCount,
        uint newTreasuryMaxVoteWeight,
        uint startTime,
        uint endTime
    );
    event Voted(uint proposalId, address voter, bool support, uint weight);
    event ProposalExecuted(
        uint proposalId,
        ProposalType proposalType,
        bool newState,
        uint newAnnualBurnRate,
        uint withdrawalAmount,
        uint newWithdrawalLimit,
        uint newBurnPercentage,
        uint newTransferFeeRate,
        uint newVotingFee,
        uint newEmergencyVotingThreshold,
        uint newTier1Threshold,
        uint newTier2Threshold,
        uint newTier3Threshold,
        uint newMinDynamicBurnRate,
        uint newMidDynamicBurnRate,
        uint newMaxDynamicBurnRate,
        uint newTreasurySpendingAmount,
        address treasuryRecipient,
        uint newTreasuryAllocation,
        uint newTreasuryQuorum,
        uint newTreasuryVoteWeightRate,
        uint newTimelockDelay,
        uint timestamp
    );
    event DeveloperWithdrawalExecuted(uint netAmount, uint burnedAmount, uint timestamp);

    constructor() ERC20("KeeperCoin", "KPT") {
        developer = msg.sender;
        deploymentTime = block.timestamp;
        nextAnnualBurn = block.timestamp + 365 days;
        nextDeveloperWithdrawalTime = block.timestamp + 5 * 365 days + 30 days;

        // Token allocation settings
        treasuryAllocation = (TOTAL_SUPPLY * 15) / 100;
        treasuryQuorum = (treasuryAllocation * 5) / 100;

        // Initial governance settings
        treasuryVoteWeightRate = 1;         // 1 basis point = 0.01%
        timelockDelay = 3 days;
        treasuryMinVoterCount = 5;
        treasuryMaxVoteWeight = 1e16;         // Approximately 0.01 KPT
        annualBurnEnabled = false;
        annualBurnRate = 2;
        maxDeveloperWithdrawal = 10_000e18;
        developerWithdrawalBurnPercentage = 50;
        transferFeeRate = 10;
        votingFee = 1;
        emergencyVotingThreshold = 100e18;
        minStakeForVoting = 100e18;
        multiSigApprovalsRequired = 3;

        // Dynamic burn settings
        tier1Threshold = 100000 * 1e18;
        tier2Threshold = 10000 * 1e18;
        tier3Threshold = 1000 * 1e18;
        minDynamicBurnRate = 1;
        midDynamicBurnRate = 5;
        maxDynamicBurnRate = 10;

        // Mint tokens: DAO treasury, developer, and deployer receive their allocations
        _mint(address(this), treasuryAllocation);
        _mint(developer, DEV_ALLOCATION);
        _mint(msg.sender, TOTAL_SUPPLY - treasuryAllocation - DEV_ALLOCATION);
    }

    // Before transfer: if annual burn is enabled and it's time, execute auto burn.
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override whenNotPaused {
        require(from != address(0), "Invalid sender");
        require(to != address(0), "Invalid recipient");
        require(amount > 0, "Amount must be > 0");

        if (annualBurnEnabled && block.timestamp >= nextAnnualBurn) {
            _autoBurn();
        }
        super._beforeTokenTransfer(from, to, amount);
    }

    // Auto burn function: burns a percentage of total supply based on annualBurnRate.
    function _autoBurn() internal nonReentrant {
        uint burnAmount = (totalSupply() * annualBurnRate) / 100;
        uint contractBalance = balanceOf(address(this));
        if (burnAmount > contractBalance) {
            burnAmount = contractBalance;
        }
        require(burnAmount > 0, "Burn amount must be > 0");
        _burn(address(this), burnAmount);
        nextAnnualBurn = block.timestamp + 365 days;
        emit AnnualBurnExecuted(burnAmount, block.timestamp);
    }

    // Transfer function override: applies dynamic burn on each transfer.
    function _transfer(address sender, address recipient, uint256 amount) internal override nonReentrant {
        require(sender != address(0), "Invalid sender");
        require(recipient != address(0), "Invalid recipient");
        require(amount > 0, "Amount must be > 0");
        require(balanceOf(sender) >= amount, "Insufficient balance");

        uint senderBalance = balanceOf(sender);
        uint computedRate;
        if (senderBalance >= tier1Threshold) {
            computedRate = minDynamicBurnRate;
        } else if (senderBalance >= tier2Threshold) {
            computedRate = minDynamicBurnRate + ((tier1Threshold - senderBalance) * (midDynamicBurnRate - minDynamicBurnRate)) / (tier1Threshold - tier2Threshold);
        } else if (senderBalance >= tier3Threshold) {
            computedRate = midDynamicBurnRate + ((tier2Threshold - senderBalance) * (maxDynamicBurnRate - midDynamicBurnRate)) / (tier2Threshold - tier3Threshold);
        } else {
            computedRate = maxDynamicBurnRate;
        }
        uint burnAmount = (amount * computedRate) / 1000;
        uint netAmount = amount - burnAmount;
        super._burn(sender, burnAmount);
        super._transfer(sender, recipient, netAmount);
    }

    // ----------------------------------
    // DAO Proposal Functions
    // ----------------------------------

    // (1) AnnualBurnChange Proposal
    function createProposalAnnualBurnChange(bool _newState) external returns (uint) {
        proposalCount++;
        uint start = block.timestamp;
        uint end = block.timestamp + 3 days;
        proposals[proposalCount] = Proposal({
            id: proposalCount,
            proposalType: ProposalType.AnnualBurnChange,
            proposedState: _newState,
            newAnnualBurnRate: 0,
            withdrawalAmount: 0,
            newWithdrawalLimit: 0,
            newBurnPercentage: 0,
            newTransferFeeRate: 0,
            newVotingFee: 0,
            newEmergencyVotingThreshold: 0,
            newTier1Threshold: 0,
            newTier2Threshold: 0,
            newTier3Threshold: 0,
            newMinDynamicBurnRate: 0,
            newMidDynamicBurnRate: 0,
            newMaxDynamicBurnRate: 0,
            newTreasurySpendingAmount: 0,
            treasuryRecipient: address(0),
            newTreasuryAllocation: 0,
            newTreasuryQuorum: 0,
            newTreasuryVoteWeightRate: 0,
            newTimelockDelay: 0,
            newTreasuryMinVoterCount: 0,
            newTreasuryMaxVoteWeight: 0,
            uniqueVoterCount: 0,
            startTime: start,
            endTime: end,
            votesFor: 0,
            votesAgainst: 0,
            executed: false
        });
        emit ProposalCreated(proposalCount, ProposalType.AnnualBurnChange, _newState, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, start, end);
        return proposalCount;
    }

    // (2) AnnualBurnRateChange Proposal
    function createProposalAnnualBurnRateChange(uint _newAnnualBurnRate) external returns (uint) {
        require(_newAnnualBurnRate >= 1 && _newAnnualBurnRate <= 10, "Burn rate must be between 1 and 10");
        proposalCount++;
        uint start = block.timestamp;
        uint end = block.timestamp + 3 days;
        proposals[proposalCount] = Proposal({
            id: proposalCount,
            proposalType: ProposalType.AnnualBurnRateChange,
            proposedState: false,
            newAnnualBurnRate: _newAnnualBurnRate,
            withdrawalAmount: 0,
            newWithdrawalLimit: 0,
            newBurnPercentage: 0,
            newTransferFeeRate: 0,
            newVotingFee: 0,
            newEmergencyVotingThreshold: 0,
            newTier1Threshold: 0,
            newTier2Threshold: 0,
            newTier3Threshold: 0,
            newMinDynamicBurnRate: 0,
            newMidDynamicBurnRate: 0,
            newMaxDynamicBurnRate: 0,
            newTreasurySpendingAmount: 0,
            treasuryRecipient: address(0),
            newTreasuryAllocation: 0,
            newTreasuryQuorum: 0,
            newTreasuryVoteWeightRate: 0,
            newTimelockDelay: 0,
            newTreasuryMinVoterCount: 0,
            newTreasuryMaxVoteWeight: 0,
            uniqueVoterCount: 0,
            startTime: start,
            endTime: end,
            votesFor: 0,
            votesAgainst: 0,
            executed: false
        });
        emit ProposalCreated(proposalCount, ProposalType.AnnualBurnRateChange, false, _newAnnualBurnRate, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, start, end);
        return proposalCount;
    }

    // (3) DeveloperWithdrawal Proposal
    function createProposalDeveloperWithdrawal(uint _amount) external returns (uint) {
        require(_amount <= maxDeveloperWithdrawal, "Exceeds current withdrawal limit");
        require(_amount <= remainingAllocation, "Not enough allocation");
        proposalCount++;
        uint start = block.timestamp;
        uint end = block.timestamp + 3 days;
        proposals[proposalCount] = Proposal({
            id: proposalCount,
            proposalType: ProposalType.DeveloperWithdrawal,
            proposedState: false,
            newAnnualBurnRate: 0,
            withdrawalAmount: _amount,
            newWithdrawalLimit: 0,
            newBurnPercentage: 0,
            newTransferFeeRate: 0,
            newVotingFee: 0,
            newEmergencyVotingThreshold: 0,
            newTier1Threshold: 0,
            newTier2Threshold: 0,
            newTier3Threshold: 0,
            newMinDynamicBurnRate: 0,
            newMidDynamicBurnRate: 0,
            newMaxDynamicBurnRate: 0,
            newTreasurySpendingAmount: 0,
            treasuryRecipient: address(0),
            newTreasuryAllocation: 0,
            newTreasuryQuorum: 0,
            newTreasuryVoteWeightRate: 0,
            newTimelockDelay: 0,
            newTreasuryMinVoterCount: 0,
            newTreasuryMaxVoteWeight: 0,
            uniqueVoterCount: 0,
            startTime: start,
            endTime: end,
            votesFor: 0,
            votesAgainst: 0,
            executed: false
        });
        emit ProposalCreated(proposalCount, ProposalType.DeveloperWithdrawal, false, 0, _amount, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, start, end);
        return proposalCount;
    }

    // (4) WithdrawalLimitChange Proposal
    function createProposalWithdrawalLimitChange(uint _newLimit) external returns (uint) {
        proposalCount++;
        uint start = block.timestamp;
        uint end = block.timestamp + 3 days;
        proposals[proposalCount] = Proposal({
            id: proposalCount,
            proposalType: ProposalType.WithdrawalLimitChange,
            proposedState: false,
            newAnnualBurnRate: 0,
            withdrawalAmount: 0,
            newWithdrawalLimit: _newLimit,
            newBurnPercentage: 0,
            newTransferFeeRate: 0,
            newVotingFee: 0,
            newEmergencyVotingThreshold: 0,
            newTier1Threshold: 0,
            newTier2Threshold: 0,
            newTier3Threshold: 0,
            newMinDynamicBurnRate: 0,
            newMidDynamicBurnRate: 0,
            newMaxDynamicBurnRate: 0,
            newTreasurySpendingAmount: 0,
            treasuryRecipient: address(0),
            newTreasuryAllocation: 0,
            newTreasuryQuorum: 0,
            newTreasuryVoteWeightRate: 0,
            newTimelockDelay: 0,
            newTreasuryMinVoterCount: 0,
            newTreasuryMaxVoteWeight: 0,
            uniqueVoterCount: 0,
            startTime: start,
            endTime: end,
            votesFor: 0,
            votesAgainst: 0,
            executed: false
        });
        emit ProposalCreated(proposalCount, ProposalType.WithdrawalLimitChange, false, 0, 0, _newLimit, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, start, end);
        return proposalCount;
    }

    // (5) WithdrawalBurnChange Proposal
    function createProposalWithdrawalBurnChange(uint _newBurnPercentage) external returns (uint) {
        require(_newBurnPercentage >= 5 && _newBurnPercentage <= 95, "Burn percentage must be between 5 and 95");
        proposalCount++;
        uint start = block.timestamp;
        uint end = block.timestamp + 3 days;
        proposals[proposalCount] = Proposal({
            id: proposalCount,
            proposalType: ProposalType.WithdrawalBurnChange,
            proposedState: false,
            newAnnualBurnRate: 0,
            withdrawalAmount: 0,
            newWithdrawalLimit: 0,
            newBurnPercentage: _newBurnPercentage,
            newTransferFeeRate: 0,
            newVotingFee: 0,
            newEmergencyVotingThreshold: 0,
            newTier1Threshold: 0,
            newTier2Threshold: 0,
            newTier3Threshold: 0,
            newMinDynamicBurnRate: 0,
            newMidDynamicBurnRate: 0,
            newMaxDynamicBurnRate: 0,
            newTreasurySpendingAmount: 0,
            treasuryRecipient: address(0),
            newTreasuryAllocation: 0,
            newTreasuryQuorum: 0,
            newTreasuryVoteWeightRate: 0,
            newTimelockDelay: 0,
            newTreasuryMinVoterCount: 0,
            newTreasuryMaxVoteWeight: 0,
            uniqueVoterCount: 0,
            startTime: start,
            endTime: end,
            votesFor: 0,
            votesAgainst: 0,
            executed: false
        });
        emit ProposalCreated(proposalCount, ProposalType.WithdrawalBurnChange, false, 0, 0, 0, _newBurnPercentage, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, start, end);
        return proposalCount;
    }

    // (6) TransferFeeRateChange Proposal
    function createProposalTransferFeeRateChange(uint _newTransferFeeRate) external returns (uint) {
        require(_newTransferFeeRate >= 1 && _newTransferFeeRate <= 20, "Transfer fee rate must be between 1 and 20");
        proposalCount++;
        uint start = block.timestamp;
        uint end = block.timestamp + 3 days;
        proposals[proposalCount] = Proposal({
            id: proposalCount,
            proposalType: ProposalType.TransferFeeRateChange,
            proposedState: false,
            newAnnualBurnRate: 0,
            withdrawalAmount: 0,
            newWithdrawalLimit: 0,
            newBurnPercentage: 0,
            newTransferFeeRate: _newTransferFeeRate,
            newVotingFee: 0,
            newEmergencyVotingThreshold: 0,
            newTier1Threshold: 0,
            newTier2Threshold: 0,
            newTier3Threshold: 0,
            newMinDynamicBurnRate: 0,
            newMidDynamicBurnRate: 0,
            newMaxDynamicBurnRate: 0,
            newTreasurySpendingAmount: 0,
            treasuryRecipient: address(0),
            newTreasuryAllocation: 0,
            newTreasuryQuorum: 0,
            newTreasuryVoteWeightRate: 0,
            newTimelockDelay: 0,
            newTreasuryMinVoterCount: 0,
            newTreasuryMaxVoteWeight: 0,
            uniqueVoterCount: 0,
            startTime: start,
            endTime: end,
            votesFor: 0,
            votesAgainst: 0,
            executed: false
        });
        emit ProposalCreated(proposalCount, ProposalType.TransferFeeRateChange, false, 0, 0, 0, 0, _newTransferFeeRate, 0, 0, 0, 0, 0, 0, 0, 0, 0, start, end);
        return proposalCount;
    }

    // (7) EmergencyControl Proposal
    function createProposalEmergencyControl(bool _pause) external returns (uint) {
        proposalCount++;
        uint start = block.timestamp;
        uint end = block.timestamp + 3 days;
        proposals[proposalCount] = Proposal({
            id: proposalCount,
            proposalType: ProposalType.EmergencyControl,
            proposedState: _pause,
            newAnnualBurnRate: 0,
            withdrawalAmount: 0,
            newWithdrawalLimit: 0,
            newBurnPercentage: 0,
            newTransferFeeRate: 0,
            newVotingFee: 0,
            newEmergencyVotingThreshold: 0,
            newTier1Threshold: 0,
            newTier2Threshold: 0,
            newTier3Threshold: 0,
            newMinDynamicBurnRate: 0,
            newMidDynamicBurnRate: 0,
            newMaxDynamicBurnRate: 0,
            newTreasurySpendingAmount: 0,
            treasuryRecipient: address(0),
            newTreasuryAllocation: 0,
            newTreasuryQuorum: 0,
            newTreasuryVoteWeightRate: 0,
            newTimelockDelay: 0,
            newTreasuryMinVoterCount: 0,
            newTreasuryMaxVoteWeight: 0,
            uniqueVoterCount: 0,
            startTime: start,
            endTime: end,
            votesFor: 0,
            votesAgainst: 0,
            executed: false
        });
        emit ProposalCreated(proposalCount, ProposalType.EmergencyControl, _pause, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, start, end);
        return proposalCount;
    }

    // (8) VotingFeeChange Proposal
    function createProposalVotingFeeChange(uint _newVotingFee) external returns (uint) {
        proposalCount++;
        uint start = block.timestamp;
        uint end = block.timestamp + 3 days;
        proposals[proposalCount] = Proposal({
            id: proposalCount,
            proposalType: ProposalType.VotingFeeChange,
            proposedState: false,
            newAnnualBurnRate: 0,
            withdrawalAmount: 0,
            newWithdrawalLimit: 0,
            newBurnPercentage: 0,
            newTransferFeeRate: 0,
            newVotingFee: _newVotingFee,
            newEmergencyVotingThreshold: 0,
            newTier1Threshold: 0,
            newTier2Threshold: 0,
            newTier3Threshold: 0,
            newMinDynamicBurnRate: 0,
            newMidDynamicBurnRate: 0,
            newMaxDynamicBurnRate: 0,
            newTreasurySpendingAmount: 0,
            treasuryRecipient: address(0),
            newTreasuryAllocation: 0,
            newTreasuryQuorum: 0,
            newTreasuryVoteWeightRate: 0,
            newTimelockDelay: 0,
            newTreasuryMinVoterCount: 0,
            newTreasuryMaxVoteWeight: 0,
            uniqueVoterCount: 0,
            startTime: start,
            endTime: end,
            votesFor: 0,
            votesAgainst: 0,
            executed: false
        });
        emit ProposalCreated(proposalCount, ProposalType.VotingFeeChange, false, 0, 0, 0, 0, 0, _newVotingFee, 0, 0, 0, 0, 0, 0, 0, 0, start, end);
        return proposalCount;
    }

    // (9) EmergencyVotingThresholdChange Proposal
    function createProposalEmergencyVotingThresholdChange(uint _newThreshold) external returns (uint) {
        require(_newThreshold > 0, "Threshold must be > 0");
        proposalCount++;
        uint start = block.timestamp;
        uint end = block.timestamp + 3 days;
        proposals[proposalCount] = Proposal({
            id: proposalCount,
            proposalType: ProposalType.EmergencyVotingThresholdChange,
            proposedState: false,
            newAnnualBurnRate: 0,
            withdrawalAmount: 0,
            newWithdrawalLimit: 0,
            newBurnPercentage: 0,
            newTransferFeeRate: 0,
            newVotingFee: 0,
            newEmergencyVotingThreshold: _newThreshold,
            newTier1Threshold: 0,
            newTier2Threshold: 0,
            newTier3Threshold: 0,
            newMinDynamicBurnRate: 0,
            newMidDynamicBurnRate: 0,
            newMaxDynamicBurnRate: 0,
            newTreasurySpendingAmount: 0,
            treasuryRecipient: address(0),
            newTreasuryAllocation: 0,
            newTreasuryQuorum: 0,
            newTreasuryVoteWeightRate: 0,
            newTimelockDelay: 0,
            newTreasuryMinVoterCount: 0,
            newTreasuryMaxVoteWeight: 0,
            uniqueVoterCount: 0,
            startTime: start,
            endTime: end,
            votesFor: 0,
            votesAgainst: 0,
            executed: false
        });
        emit ProposalCreated(proposalCount, ProposalType.EmergencyVotingThresholdChange, false, 0, 0, 0, 0, 0, 0, _newThreshold, 0, 0, 0, 0, 0, 0, 0, start, end);
        return proposalCount;
    }

    // (10) DynamicBurnParametersChange Proposal
    function createProposalDynamicBurnParametersChange(
        uint _newTier1Threshold,
        uint _newTier2Threshold,
        uint _newTier3Threshold,
        uint _newMinDynamicBurnRate,
        uint _newMidDynamicBurnRate,
        uint _newMaxDynamicBurnRate
    ) external returns (uint) {
        require(_newTier1Threshold > _newTier2Threshold, "Tier1 must be greater than Tier2");
        require(_newTier2Threshold > _newTier3Threshold, "Tier2 must be greater than Tier3");
        require(_newMinDynamicBurnRate < _newMidDynamicBurnRate, "Min rate must be less than mid rate");
        require(_newMidDynamicBurnRate < _newMaxDynamicBurnRate, "Mid rate must be less than max rate");
        proposalCount++;
        uint start = block.timestamp;
        uint end = block.timestamp + 3 days;
        proposals[proposalCount] = Proposal({
            id: proposalCount,
            proposalType: ProposalType.DynamicBurnParametersChange,
            proposedState: false,
            newAnnualBurnRate: 0,
            withdrawalAmount: 0,
            newWithdrawalLimit: 0,
            newBurnPercentage: 0,
            newTransferFeeRate: 0,
            newVotingFee: 0,
            newEmergencyVotingThreshold: 0,
            newTier1Threshold: _newTier1Threshold,
            newTier2Threshold: _newTier2Threshold,
            newTier3Threshold: _newTier3Threshold,
            newMinDynamicBurnRate: _newMinDynamicBurnRate,
            newMidDynamicBurnRate: _newMidDynamicBurnRate,
            newMaxDynamicBurnRate: _newMaxDynamicBurnRate,
            newTreasurySpendingAmount: 0,
            treasuryRecipient: address(0),
            newTreasuryAllocation: 0,
            newTreasuryQuorum: 0,
            newTreasuryVoteWeightRate: 0,
            newTimelockDelay: 0,
            newTreasuryMinVoterCount: 0,
            newTreasuryMaxVoteWeight: 0,
            uniqueVoterCount: 0,
            startTime: start,
            endTime: end,
            votesFor: 0,
            votesAgainst: 0,
            executed: false
        });
        emit ProposalCreated(proposalCount, ProposalType.DynamicBurnParametersChange, false, 0, 0, 0, 0, 0, 0, 0, _newTier1Threshold, _newTier2Threshold, _newTier3Threshold, _newMinDynamicBurnRate, _newMidDynamicBurnRate, _newMaxDynamicBurnRate, 0, address(0), 0, 0, 0, end);
        return proposalCount;
    }

    // (11) TreasurySpending Proposal
    function createProposalTreasurySpending(uint _amount, address _recipient) external returns (uint) {
        require(_amount <= treasuryAllocation, "Amount exceeds treasury funds");
        proposalCount++;
        uint start = block.timestamp;
        uint end = block.timestamp + 3 days;
        proposals[proposalCount] = Proposal({
            id: proposalCount,
            proposalType: ProposalType.TreasurySpending,
            proposedState: false,
            newAnnualBurnRate: 0,
            withdrawalAmount: 0,
            newWithdrawalLimit: 0,
            newBurnPercentage: 0,
            newTransferFeeRate: 0,
            newVotingFee: 0,
            newEmergencyVotingThreshold: 0,
            newTier1Threshold: 0,
            newTier2Threshold: 0,
            newTier3Threshold: 0,
            newMinDynamicBurnRate: 0,
            newMidDynamicBurnRate: 0,
            newMaxDynamicBurnRate: 0,
            newTreasurySpendingAmount: _amount,
            treasuryRecipient: _recipient,
            newTreasuryAllocation: 0,
            newTreasuryQuorum: 0,
            newTreasuryVoteWeightRate: 0,
            newTimelockDelay: 0,
            newTreasuryMinVoterCount: 0,
            newTreasuryMaxVoteWeight: 0,
            uniqueVoterCount: 0,
            startTime: start,
            endTime: end,
            votesFor: 0,
            votesAgainst: 0,
            executed: false
        });
        emit ProposalCreated(proposalCount, ProposalType.TreasurySpending, false, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, _amount, _recipient, 0, 0, 0, start, end);
        return proposalCount;
    }

    // (12) TreasuryAllocationChange Proposal
    function createProposalTreasuryAllocationChange(uint _newTreasuryAllocation, uint _newTreasuryQuorum) external returns (uint) {
        require(_newTreasuryAllocation <= TOTAL_SUPPLY, "Invalid allocation amount");
        require(_newTreasuryQuorum <= _newTreasuryAllocation, "Quorum cannot exceed allocation");
        proposalCount++;
        uint start = block.timestamp;
        uint end = block.timestamp + 3 days;
        proposals[proposalCount] = Proposal({
            id: proposalCount,
            proposalType: ProposalType.TreasuryAllocationChange,
            proposedState: false,
            newAnnualBurnRate: 0,
            withdrawalAmount: 0,
            newWithdrawalLimit: 0,
            newBurnPercentage: 0,
            newTransferFeeRate: 0,
            newVotingFee: 0,
            newEmergencyVotingThreshold: 0,
            newTier1Threshold: 0,
            newTier2Threshold: 0,
            newTier3Threshold: 0,
            newMinDynamicBurnRate: 0,
            newMidDynamicBurnRate: 0,
            newMaxDynamicBurnRate: 0,
            newTreasurySpendingAmount: 0,
            treasuryRecipient: address(0),
            newTreasuryAllocation: _newTreasuryAllocation,
            newTreasuryQuorum: _newTreasuryQuorum,
            newTreasuryVoteWeightRate: 0,
            newTimelockDelay: 0,
            newTreasuryMinVoterCount: 0,
            newTreasuryMaxVoteWeight: 0,
            uniqueVoterCount: 0,
            startTime: start,
            endTime: end,
            votesFor: 0,
            votesAgainst: 0,
            executed: false
        });
        emit ProposalCreated(proposalCount, ProposalType.TreasuryAllocationChange, false, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, _newTreasuryAllocation, _newTreasuryQuorum, 0, start, end);
        return proposalCount;
    }

    // (13) TreasuryVoteWeightChange Proposal
    function createProposalTreasuryVoteWeightChange(uint _newTreasuryVoteWeightRate) external returns (uint) {
        proposalCount++;
        uint start = block.timestamp;
        uint end = block.timestamp + 3 days;
        proposals[proposalCount] = Proposal({
            id: proposalCount,
            proposalType: ProposalType.TreasuryVoteWeightChange,
            proposedState: false,
            newAnnualBurnRate: 0,
            withdrawalAmount: 0,
            newWithdrawalLimit: 0,
            newBurnPercentage: 0,
            newTransferFeeRate: 0,
            newVotingFee: 0,
            newEmergencyVotingThreshold: 0,
            newTier1Threshold: 0,
            newTier2Threshold: 0,
            newTier3Threshold: 0,
            newMinDynamicBurnRate: 0,
            newMidDynamicBurnRate: 0,
            newMaxDynamicBurnRate: 0,
            newTreasurySpendingAmount: 0,
            treasuryRecipient: address(0),
            newTreasuryAllocation: 0,
            newTreasuryQuorum: 0,
            newTreasuryVoteWeightRate: _newTreasuryVoteWeightRate,
            newTimelockDelay: 0,
            newTreasuryMinVoterCount: 0,
            newTreasuryMaxVoteWeight: 0,
            uniqueVoterCount: 0,
            startTime: start,
            endTime: end,
            votesFor: 0,
            votesAgainst: 0,
            executed: false
        });
        emit ProposalCreated(proposalCount, ProposalType.TreasuryVoteWeightChange, false, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, _newTreasuryVoteWeightRate, 0, start, end);
        return proposalCount;
    }

    // (14) TimelockDelayChange Proposal
    function createProposalTimelockDelayChange(uint _newTimelockDelay) external returns (uint) {
        proposalCount++;
        uint start = block.timestamp;
        uint end = block.timestamp + 3 days;
        proposals[proposalCount] = Proposal({
            id: proposalCount,
            proposalType: ProposalType.TimelockDelayChange,
            proposedState: false,
            newAnnualBurnRate: 0,
            withdrawalAmount: 0,
            newWithdrawalLimit: 0,
            newBurnPercentage: 0,
            newTransferFeeRate: 0,
            newVotingFee: 0,
            newEmergencyVotingThreshold: 0,
            newTier1Threshold: 0,
            newTier2Threshold: 0,
            newTier3Threshold: 0,
            newMinDynamicBurnRate: 0,
            newMidDynamicBurnRate: 0,
            newMaxDynamicBurnRate: 0,
            newTreasurySpendingAmount: 0,
            treasuryRecipient: address(0),
            newTreasuryAllocation: 0,
            newTreasuryQuorum: 0,
            newTreasuryVoteWeightRate: 0,
            newTimelockDelay: _newTimelockDelay,
            newTreasuryMinVoterCount: 0,
            newTreasuryMaxVoteWeight: 0,
            uniqueVoterCount: 0,
            startTime: start,
            endTime: end,
            votesFor: 0,
            votesAgainst: 0,
            executed: false
        });
        emit ProposalCreated(proposalCount, ProposalType.TimelockDelayChange, false, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, _newTimelockDelay, start, end);
        return proposalCount;
    }

    // (15) TreasuryVoterParticipationChange Proposal
    function createProposalTreasuryVoterParticipationChange(uint _newMinVoterCount, uint _newMaxVoteWeight) external returns (uint) {
        proposalCount++;
        uint start = block.timestamp;
        uint end = block.timestamp + 3 days;
        proposals[proposalCount] = Proposal({
            id: proposalCount,
            proposalType: ProposalType.TreasuryVoterParticipationChange,
            proposedState: false,
            newAnnualBurnRate: 0,
            withdrawalAmount: 0,
            newWithdrawalLimit: 0,
            newBurnPercentage: 0,
            newTransferFeeRate: 0,
            newVotingFee: 0,
            newEmergencyVotingThreshold: 0,
            newTier1Threshold: 0,
            newTier2Threshold: 0,
            newTier3Threshold: 0,
            newMinDynamicBurnRate: 0,
            newMidDynamicBurnRate: 0,
            newMaxDynamicBurnRate: 0,
            newTreasurySpendingAmount: 0,
            treasuryRecipient: address(0),
            newTreasuryAllocation: 0,
            newTreasuryQuorum: 0,
            newTreasuryVoteWeightRate: 0,
            newTimelockDelay: 0,
            newTreasuryMinVoterCount: _newMinVoterCount,
            newTreasuryMaxVoteWeight: _newMaxVoteWeight,
            uniqueVoterCount: 0,
            startTime: start,
            endTime: end,
            votesFor: 0,
            votesAgainst: 0,
            executed: false
        });
        emit ProposalCreated(proposalCount, ProposalType.TreasuryVoterParticipationChange, false, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, _newMinVoterCount, _newMaxVoteWeight, start, end);
        return proposalCount;
    }

    // ----------------------------------
    // Voting Function
    // ----------------------------------
    // For treasury-related proposals, voters must hold at least 5% of the treasury allocation.
    // Vote weight is calculated via Quadratic Voting (square root of balance) and capped at treasuryMaxVoteWeight.
    // Each unique voter increases the proposal's uniqueVoterCount.
    function voteOnProposal(uint _proposalId, bool support) external {
        Proposal storage proposal = proposals[_proposalId];
        require(block.timestamp >= proposal.startTime, "Voting not started");
        require(block.timestamp <= proposal.endTime, "Voting ended");
        require(!hasVoted[_proposalId][msg.sender], "Already voted");

        uint voterWeight;
        if (
            proposal.proposalType == ProposalType.TreasurySpending || 
            proposal.proposalType == ProposalType.TreasuryAllocationChange || 
            proposal.proposalType == ProposalType.TreasuryVoteWeightChange || 
            proposal.proposalType == ProposalType.TreasuryVoterParticipationChange
        ) {
            require(balanceOf(msg.sender) >= (treasuryAllocation * 5) / 100, "Not eligible to vote on treasury proposals");
            voterWeight = (balanceOf(msg.sender) * treasuryVoteWeightRate) / 10000;
            if (voterWeight > treasuryMaxVoteWeight) {
                voterWeight = treasuryMaxVoteWeight;
            }
            proposal.uniqueVoterCount += 1;
        } else {
            if (votingFee > 0) {
                require(balanceOf(msg.sender) >= votingFee, "Not enough tokens for voting fee");
                _burn(msg.sender, votingFee);
            }
            voterWeight = balanceOf(msg.sender);
        }
        require(voterWeight > 0, "No voting power");

        if (support) {
            proposal.votesFor += voterWeight;
        } else {
            proposal.votesAgainst += voterWeight;
        }
        hasVoted[_proposalId][msg.sender] = true;
        emit Voted(_proposalId, msg.sender, support, voterWeight);
    }

    // ----------------------------------
    // Execute Proposal Function
    // ----------------------------------
    function executeProposal(uint _proposalId) external nonReentrant {
        Proposal storage proposal = proposals[_proposalId];
        require(block.timestamp > proposal.endTime + timelockDelay, "Timelock not expired");
        require(!proposal.executed, "Proposal already executed");
        require(proposal.votesFor + proposal.votesAgainst >= emergencyVotingThreshold, "Not enough quorum");
        
        // For proposals involving fund transfers, check additional quorum
        if (
            proposal.proposalType == ProposalType.DeveloperWithdrawal || 
            proposal.proposalType == ProposalType.TreasurySpending
        ) {
            require(proposal.votesFor + proposal.votesAgainst >= fundsProposalThreshold, "Not enough funds proposal quorum");
        }
        
        // For treasury-related proposals, ensure minimum unique voter count
        if (
            proposal.proposalType == ProposalType.TreasurySpending ||
            proposal.proposalType == ProposalType.TreasuryAllocationChange ||
            proposal.proposalType == ProposalType.TreasuryVoteWeightChange ||
            proposal.proposalType == ProposalType.TreasuryVoterParticipationChange
        ) {
            require(proposal.uniqueVoterCount >= treasuryMinVoterCount, "Not enough unique voters for treasury proposals");
        }
        
        if (proposal.votesFor > proposal.votesAgainst) {
            if (proposal.proposalType == ProposalType.AnnualBurnChange) {
                annualBurnEnabled = proposal.proposedState;
                emit ProposalExecuted(_proposalId, ProposalType.AnnualBurnChange, annualBurnEnabled, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, block.timestamp);
            } else if (proposal.proposalType == ProposalType.AnnualBurnRateChange) {
                require(proposal.newAnnualBurnRate >= 1 && proposal.newAnnualBurnRate <= 10, "Invalid burn rate");
                annualBurnRate = proposal.newAnnualBurnRate;
                emit ProposalExecuted(_proposalId, ProposalType.AnnualBurnRateChange, false, annualBurnRate, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, block.timestamp);
            } else if (proposal.proposalType == ProposalType.DeveloperWithdrawal) {
                if (block.timestamp > nextDeveloperWithdrawalTime + developerWithdrawalGracePeriod) {
                    emit ProposalExecuted(_proposalId, ProposalType.DeveloperWithdrawal, false, 0, proposal.withdrawalAmount, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, block.timestamp);
                } else {
                    uint amount = proposal.withdrawalAmount;
                    require(amount <= maxDeveloperWithdrawal, "Amount exceeds current withdrawal limit");
                    require(amount <= remainingAllocation, "Not enough allocation");
                    remainingAllocation -= amount;
                    uint burnAmount = (amount * developerWithdrawalBurnPercentage) / 100;
                    uint netAmount = amount - burnAmount;
                    _burn(address(this), burnAmount);
                    super._transfer(address(this), developer, netAmount);
                    nextDeveloperWithdrawalTime = block.timestamp + 30 days;
                    emit DeveloperWithdrawalExecuted(netAmount, burnAmount, block.timestamp);
                    emit ProposalExecuted(_proposalId, ProposalType.DeveloperWithdrawal, false, 0, amount, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, block.timestamp);
                }
            } else if (proposal.proposalType == ProposalType.WithdrawalLimitChange) {
                maxDeveloperWithdrawal = proposal.newWithdrawalLimit;
                emit ProposalExecuted(_proposalId, ProposalType.WithdrawalLimitChange, false, 0, 0, proposal.newWithdrawalLimit, 0, 0, 0, 0, 0, 0, 0, 0, 0, block.timestamp);
            } else if (proposal.proposalType == ProposalType.WithdrawalBurnChange) {
                developerWithdrawalBurnPercentage = proposal.newBurnPercentage;
                emit ProposalExecuted(_proposalId, ProposalType.WithdrawalBurnChange, false, 0, 0, 0, developerWithdrawalBurnPercentage, 0, 0, 0, 0, 0, 0, 0, 0, block.timestamp);
            } else if (proposal.proposalType == ProposalType.TransferFeeRateChange) {
                require(proposal.newTransferFeeRate >= 1 && proposal.newTransferFeeRate <= 20, "Invalid transfer fee rate");
                transferFeeRate = proposal.newTransferFeeRate;
                emit ProposalExecuted(_proposalId, ProposalType.TransferFeeRateChange, false, 0, 0, 0, 0, transferFeeRate, 0, 0, 0, 0, 0, 0, 0, block.timestamp);
            } else if (proposal.proposalType == ProposalType.EmergencyControl) {
                if (proposal.proposedState) {
                    _pause();
                    pauseStartTime = block.timestamp;
                } else {
                    _unpause();
                    pauseStartTime = 0;
                }
                emit ProposalExecuted(_proposalId, ProposalType.EmergencyControl, proposal.proposedState, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, block.timestamp);
            } else if (proposal.proposalType == ProposalType.VotingFeeChange) {
                votingFee = proposal.newVotingFee;
                emit ProposalExecuted(_proposalId, ProposalType.VotingFeeChange, false, 0, 0, 0, 0, 0, votingFee, 0, 0, 0, 0, 0, 0, block.timestamp);
            } else if (proposal.proposalType == ProposalType.EmergencyVotingThresholdChange) {
                emergencyVotingThreshold = proposal.newEmergencyVotingThreshold;
                emit ProposalExecuted(_proposalId, ProposalType.EmergencyVotingThresholdChange, false, 0, 0, 0, 0, 0, 0, proposal.newEmergencyVotingThreshold, 0, 0, 0, 0, 0, block.timestamp);
            } else if (proposal.proposalType == ProposalType.DynamicBurnParametersChange) {
                tier1Threshold = proposal.newTier1Threshold;
                tier2Threshold = proposal.newTier2Threshold;
                tier3Threshold = proposal.newTier3Threshold;
                minDynamicBurnRate = proposal.newMinDynamicBurnRate;
                midDynamicBurnRate = proposal.newMidDynamicBurnRate;
                maxDynamicBurnRate = proposal.newMaxDynamicBurnRate;
                emit ProposalExecuted(_proposalId, ProposalType.DynamicBurnParametersChange, false, 0, 0, 0, 0, 0, 0, 0, tier1Threshold, tier2Threshold, tier3Threshold, minDynamicBurnRate, midDynamicBurnRate, maxDynamicBurnRate, 0, address(0), 0, 0, block.timestamp);
            } else if (proposal.proposalType == ProposalType.TreasurySpending) {
                uint amount = proposal.newTreasurySpendingAmount;
                require(amount <= treasuryAllocation, "Amount exceeds treasury funds");
                require(proposalApprovers[_proposalId].length >= multiSigApprovalsRequired, "Not enough approvals");
                require(proposal.votesFor + proposal.votesAgainst >= treasuryQuorum, "Not enough treasury quorum");
                treasuryAllocation -= amount;
                // ERC20 token transfer from DAO treasury to recipient
                _transfer(address(this), proposal.treasuryRecipient, amount);
                emit ProposalExecuted(_proposalId, ProposalType.TreasurySpending, false, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, amount, proposal.treasuryRecipient, 0, 0, block.timestamp);
            } else if (proposal.proposalType == ProposalType.TreasuryAllocationChange) {
                treasuryAllocation = proposal.newTreasuryAllocation;
                treasuryQuorum = proposal.newTreasuryQuorum;
                emit ProposalExecuted(_proposalId, ProposalType.TreasuryAllocationChange, false, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, address(0), treasuryAllocation, treasuryQuorum, block.timestamp);
            } else if (proposal.proposalType == ProposalType.TreasuryVoteWeightChange) {
                treasuryVoteWeightRate = proposal.newTreasuryVoteWeightRate;
                emit ProposalExecuted(_proposalId, ProposalType.TreasuryVoteWeightChange, false, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, address(0), 0, 0, proposal.newTreasuryVoteWeightRate, block.timestamp);
            } else if (proposal.proposalType == ProposalType.TimelockDelayChange) {
                timelockDelay = proposal.newTimelockDelay;
                emit ProposalExecuted(_proposalId, ProposalType.TimelockDelayChange, false, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, proposal.newTimelockDelay, block.timestamp);
            } else if (proposal.proposalType == ProposalType.TreasuryVoterParticipationChange) {
                treasuryMinVoterCount = proposal.newTreasuryMinVoterCount;
                treasuryMaxVoteWeight = proposal.newTreasuryMaxVoteWeight;
                emit ProposalExecuted(_proposalId, ProposalType.TreasuryVoterParticipationChange, false, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, proposal.newTreasuryMinVoterCount, proposal.newTreasuryMaxVoteWeight, block.timestamp);
            }
        }
        proposal.executed = true;
    }

    // Multi-sig approval for treasury spending proposals
    function approveProposal(uint _proposalId) external {
        require(balanceOf(msg.sender) >= treasuryAllocation / 10, "Insufficient balance to approve");
        proposalApprovers[_proposalId].push(msg.sender);
    }

    // Developer Withdrawal Check:
    // If no withdrawal occurs within the grace period after the withdrawal window opens, the remaining developer allocation is transferred to the DAO treasury.
    function checkDeveloperWithdrawal() external {
        if (block.timestamp > nextDeveloperWithdrawalTime + developerWithdrawalGracePeriod) {
            treasuryAllocation += remainingAllocation;
            remainingAllocation = 0;
        }
    }

    // forceUnpause: Allows the developer to unpause the contract if it has been paused for at least 7 days.
    function forceUnpause() external nonReentrant {
        require(msg.sender == developer, "Unauthorized");
        require(paused(), "Contract is not paused");
        require(block.timestamp - pauseStartTime >= 7 days, "Must be paused for at least 7 days");
        _unpause();
        pauseStartTime = 0;
    }
}

