// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract MultiSigWallet is ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    struct Transaction {
        address to;
        uint256 value;
        bytes data;
        bool executed;
        uint256 confirmations;
        uint256 timestamp;
        address token; // address(0) for ETH, token address for ERC20
    }
    
    mapping(uint256 => Transaction) public transactions;
    mapping(uint256 => mapping(address => bool)) public isConfirmed;
    mapping(address => bool) public isOwner;
    
    address[] public owners;
    uint256 public required;
    uint256 public transactionCount;
    
    event Deposit(address indexed sender, uint256 amount, uint256 balance);
    event TokenDeposit(address indexed sender, address indexed token, uint256 amount);
    event SubmitTransaction(
        address indexed owner,
        uint256 indexed txIndex,
        address indexed to,
        uint256 value,
        bytes data,
        address token
    );
    event ConfirmTransaction(address indexed owner, uint256 indexed txIndex);
    event RevokeConfirmation(address indexed owner, uint256 indexed txIndex);
    event ExecuteTransaction(address indexed owner, uint256 indexed txIndex);
    event OwnerAddition(address indexed owner);
    event OwnerRemoval(address indexed owner);
    event RequirementChange(uint256 required);
    
    modifier onlyWallet() {
        require(msg.sender == address(this), "Only wallet can call this function");
        _;
    }
    
    modifier ownerDoesNotExist(address owner) {
        require(!isOwner[owner], "Owner already exists");
        _;
    }
    
    modifier ownerExists(address owner) {
        require(isOwner[owner], "Owner does not exist");
        _;
    }
    
    modifier transactionExists(uint256 txIndex) {
        require(txIndex < transactionCount, "Transaction does not exist");
        _;
    }
    
    modifier notConfirmed(uint256 txIndex, address owner) {
        require(!isConfirmed[txIndex][owner], "Transaction already confirmed");
        _;
    }
    
    modifier notExecuted(uint256 txIndex) {
        require(!transactions[txIndex].executed, "Transaction already executed");
        _;
    }
    
    modifier notNull(address _address) {
        require(_address != address(0), "Address cannot be null");
        _;
    }
    
    modifier validRequirement(uint256 ownerCount, uint256 _required) {
        require(
            ownerCount <= 20 && _required <= ownerCount && _required != 0 && ownerCount != 0,
            "Invalid requirement"
        );
        _;
    }
    
    constructor(address[] memory _owners, uint256 _required)
        validRequirement(_owners.length, _required)
    {
        for (uint256 i = 0; i < _owners.length; i++) {
            require(!isOwner[_owners[i]] && _owners[i] != address(0), "Invalid owner");
            isOwner[_owners[i]] = true;
        }
        
        owners = _owners;
        required = _required;
    }
    
    receive() external payable {
        if (msg.value > 0) {
            emit Deposit(msg.sender, msg.value, address(this).balance);
        }
    }
    
    function depositToken(address token, uint256 amount) external {
        require(token != address(0), "Invalid token address");
        require(amount > 0, "Amount must be greater than 0");
        
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit TokenDeposit(msg.sender, token, amount);
    }
    
    function submitTransaction(
        address to,
        uint256 value,
        bytes memory data,
        address token
    ) public ownerExists(msg.sender) returns (uint256 txIndex) {
        txIndex = transactionCount;
        
        transactions[txIndex] = Transaction({
            to: to,
            value: value,
            data: data,
            executed: false,
            confirmations: 0,
            timestamp: block.timestamp,
            token: token
        });
        
        transactionCount++;
        
        emit SubmitTransaction(msg.sender, txIndex, to, value, data, token);
        
        confirmTransaction(txIndex);
    }
    
    function confirmTransaction(uint256 txIndex)
        public
        ownerExists(msg.sender)
        transactionExists(txIndex)
        notConfirmed(txIndex, msg.sender)
    {
        Transaction storage transaction = transactions[txIndex];
        transaction.confirmations++;
        isConfirmed[txIndex][msg.sender] = true;
        
        emit ConfirmTransaction(msg.sender, txIndex);
        
        if (transaction.confirmations >= required) {
            executeTransaction(txIndex);
        }
    }
    
    function revokeConfirmation(uint256 txIndex)
        public
        ownerExists(msg.sender)
        transactionExists(txIndex)
        notExecuted(txIndex)
    {
        require(isConfirmed[txIndex][msg.sender], "Transaction not confirmed");
        
        Transaction storage transaction = transactions[txIndex];
        transaction.confirmations--;
        isConfirmed[txIndex][msg.sender] = false;
        
        emit RevokeConfirmation(msg.sender, txIndex);
    }
    
    function executeTransaction(uint256 txIndex)
        public
        ownerExists(msg.sender)
        transactionExists(txIndex)
        notExecuted(txIndex)
        nonReentrant
    {
        Transaction storage transaction = transactions[txIndex];
        
        require(
            transaction.confirmations >= required,
            "Cannot execute transaction"
        );
        
        transaction.executed = true;
        
        bool success;
        if (transaction.token == address(0)) {
            // ETH transaction
            (success, ) = transaction.to.call{value: transaction.value}(transaction.data);
        } else {
            // ERC20 token transaction
            IERC20(transaction.token).safeTransfer(transaction.to, transaction.value);
            success = true;
        }
        
        require(success, "Transaction failed");
        
        emit ExecuteTransaction(msg.sender, txIndex);
    }
    
    function addOwner(address owner)
        public
        onlyWallet
        ownerDoesNotExist(owner)
        notNull(owner)
        validRequirement(owners.length + 1, required)
    {
        isOwner[owner] = true;
        owners.push(owner);
        emit OwnerAddition(owner);
    }
    
    function removeOwner(address owner) public onlyWallet ownerExists(owner) {
        isOwner[owner] = false;
        
        for (uint256 i = 0; i < owners.length - 1; i++) {
            if (owners[i] == owner) {
                owners[i] = owners[owners.length - 1];
                break;
            }
        }
        
        owners.pop();
        
        if (required > owners.length) {
            changeRequirement(owners.length);
        }
        
        emit OwnerRemoval(owner);
    }
    
    function replaceOwner(address owner, address newOwner)
        public
        onlyWallet
        ownerExists(owner)
        ownerDoesNotExist(newOwner)
    {
        for (uint256 i = 0; i < owners.length; i++) {
            if (owners[i] == owner) {
                owners[i] = newOwner;
                break;
            }
        }
        
        isOwner[owner] = false;
        isOwner[newOwner] = true;
        
        emit OwnerRemoval(owner);
        emit OwnerAddition(newOwner);
    }
    
    function changeRequirement(uint256 _required)
        public
        onlyWallet
        validRequirement(owners.length, _required)
    {
        required = _required;
        emit RequirementChange(_required);
    }
    
    function getOwners() public view returns (address[] memory) {
        return owners;
    }
    
    function getTransactionCount(bool pending, bool executed)
        public
        view
        returns (uint256 count)
    {
        for (uint256 i = 0; i < transactionCount; i++) {
            if (
                (pending && !transactions[i].executed) ||
                (executed && transactions[i].executed)
            ) {
                count++;
            }
        }
    }
    
    function getTransaction(uint256 txIndex)
        public
        view
        returns (
            address to,
            uint256 value,
            bytes memory data,
            bool executed,
            uint256 confirmations,
            uint256 timestamp,
            address token
        )
    {
        Transaction storage transaction = transactions[txIndex];
        return (
            transaction.to,
            transaction.value,
            transaction.data,
            transaction.executed,
            transaction.confirmations,
            transaction.timestamp,
            transaction.token
        );
    }
    
    function getConfirmations(uint256 txIndex)
        public
        view
        returns (address[] memory _confirmations)
    {
        address[] memory confirmationsTemp = new address[](owners.length);
        uint256 count = 0;
        
        for (uint256 i = 0; i < owners.length; i++) {
            if (isConfirmed[txIndex][owners[i]]) {
                confirmationsTemp[count] = owners[i];
                count++;
            }
        }
        
        _confirmations = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            _confirmations[i] = confirmationsTemp[i];
        }
    }
    
    function getTransactionIds(
        uint256 from,
        uint256 to,
        bool pending,
        bool executed
    ) public view returns (uint256[] memory _transactionIds) {
        uint256[] memory transactionIdsTemp = new uint256[](transactionCount);
        uint256 count = 0;
        
        for (uint256 i = 0; i < transactionCount; i++) {
            if (
                (pending && !transactions[i].executed) ||
                (executed && transactions[i].executed)
            ) {
                transactionIdsTemp[count] = i;
                count++;
            }
        }
        
        _transactionIds = new uint256[](to - from);
        for (uint256 i = from; i < to; i++) {
            _transactionIds[i - from] = transactionIdsTemp[i];
        }
    }
    
    function getBalance() public view returns (uint256) {
        return address(this).balance;
    }
    
    function getTokenBalance(address token) public view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }
    
    function isConfirmedBy(uint256 txIndex, address owner) 
        public 
        view 
        returns (bool) 
    {
        return isConfirmed[txIndex][owner];
    }
}