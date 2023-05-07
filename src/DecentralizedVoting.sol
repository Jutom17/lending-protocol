// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract DecentralizedVoting {
    struct Proposal {
        uint256 id;
        string title;
        string description;
        uint256 votes;
        uint256 minimumQuorum;
        uint256 period;
        bool finalized;
        bool passed;
    }

    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => uint256)) public userVotes;

    ERC20 public tokenContract;
    uint256 public votingPeriod;
    uint256 public minimumQuorum;
    address public admin;

    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin can perform this action");
        _;
    }

    event ProposalCreated(uint256 id, string title, string description);
    event VoteCast(uint256 id, address voter, uint256 votes);
    event ProposalFinalized(uint256 id, bool passed);

    constructor(address _tokenContract) {
        tokenContract = ERC20(_tokenContract);
        admin = msg.sender;
    }

    function createProposal(
        string memory _title,
        string memory _description,
        uint256 _votingPeriod,
        uint256 _minimumQuorum
    ) external onlyAdmin {
        proposalCount++;
        proposals[proposalCount] = Proposal(
            proposalCount,
            _title,
            _description,
            0,
            _minimumQuorum,
            _votingPeriod,
            false,
            false
        );

        emit ProposalCreated(proposalCount, _title, _description);
    }

    function vote(
        uint256 _id,
        uint256 _votes,
        address _delegatedVoter
    ) external {
        require(_id <= proposalCount, "Invalid proposal ID");

        Proposal storage proposal = proposals[_id];
        require(!proposal.finalized, "Proposal has already been finalized");

        address voter = _delegatedVoter;
        if (voter == address(0)) {
            voter = msg.sender;
        }

        uint256 availableVotes = tokenContract.balanceOf(voter);
        require(availableVotes >= _votes, "Insufficient voting power");

        userVotes[_id][voter] = _votes;
        proposal.votes += _votes;
        tokenContract.transferFrom(msg.sender, address(this), _votes);

        emit VoteCast(_id, voter, _votes);
    }

    function finalizeProposal(uint256 _id) external onlyAdmin {
        require(_id <= proposalCount, "Invalid proposal ID");

        Proposal storage proposal = proposals[_id];
        require(!proposal.finalized, "Proposal has already been finalized");

        if (block.timestamp >= proposal.period) {
            uint256 totalVotes = proposal.votes;

            bool passed = totalVotes >= proposal.minimumQuorum;
            proposal.finalized = true;
            proposal.passed = passed;

            emit ProposalFinalized(_id, passed);
        }
    }
}
