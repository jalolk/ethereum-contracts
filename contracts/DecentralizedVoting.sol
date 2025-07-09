// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract DecentralizedVoting {
    struct Candidate {
        uint id;
        string name;
        uint voteCount;
    }
    
    struct Voter {
        bool hasVoted;
        uint votedCandidateId;
        bool isRegistered;
    }
    
    address public owner;
    string public electionName;
    bool public votingOpen;
    
    mapping(uint => Candidate) public candidates;
    mapping(address => Voter) public voters;
    
    uint public candidatesCount;
    uint public totalVotes;
    
    event VoterRegistered(address voter);
    event VoteCast(address voter, uint candidateId);
    event CandidateAdded(uint candidateId, string name);
    event VotingStatusChanged(bool isOpen);
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this function");
        _;
    }
    
    modifier onlyWhenVotingOpen() {
        require(votingOpen, "Voting is not open");
        _;
    }
    
    modifier onlyRegisteredVoter() {
        require(voters[msg.sender].isRegistered, "Voter is not registered");
        _;
    }
    
    constructor(string memory _electionName) {
        owner = msg.sender;
        electionName = _electionName;
        votingOpen = false;
    }
    
    function addCandidate(string memory _name) public onlyOwner {
        candidatesCount++;
        candidates[candidatesCount] = Candidate(candidatesCount, _name, 0);
        emit CandidateAdded(candidatesCount, _name);
    }
    
    function registerVoter(address _voter) public onlyOwner {
        require(!voters[_voter].isRegistered, "Voter already registered");
        voters[_voter] = Voter(false, 0, true);
        emit VoterRegistered(_voter);
    }
    
    function openVoting() public onlyOwner {
        require(candidatesCount > 0, "No candidates available");
        votingOpen = true;
        emit VotingStatusChanged(true);
    }
    
    function closeVoting() public onlyOwner {
        votingOpen = false;
        emit VotingStatusChanged(false);
    }
    
    function vote(uint _candidateId) public onlyWhenVotingOpen onlyRegisteredVoter {
        require(!voters[msg.sender].hasVoted, "You have already voted");
        require(_candidateId > 0 && _candidateId <= candidatesCount, "Invalid candidate ID");
        
        voters[msg.sender].hasVoted = true;
        voters[msg.sender].votedCandidateId = _candidateId;
        
        candidates[_candidateId].voteCount++;
        totalVotes++;
        
        emit VoteCast(msg.sender, _candidateId);
    }
    
    function getResults() public view returns (Candidate[] memory) {
        require(!votingOpen, "Voting is still open");
        
        Candidate[] memory results = new Candidate[](candidatesCount);
        for (uint i = 1; i <= candidatesCount; i++) {
            results[i-1] = candidates[i];
        }
        return results;
    }
    
    function getWinner() public view returns (string memory winnerName, uint winnerVotes) {
        require(!votingOpen, "Voting is still open");
        require(candidatesCount > 0, "No candidates");
        
        uint maxVotes = 0;
        uint winnerId = 0;
        
        for (uint i = 1; i <= candidatesCount; i++) {
            if (candidates[i].voteCount > maxVotes) {
                maxVotes = candidates[i].voteCount;
                winnerId = i;
            }
        }
        
        return (candidates[winnerId].name, maxVotes);
    }
}