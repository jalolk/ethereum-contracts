// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract DeFiStaking is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;
    
    struct StakingPool {
        IERC20 stakingToken;
        IERC20 rewardToken;
        uint256 rewardRate; // Reward per second per token staked
        uint256 lastUpdateTime;
        uint256 rewardPerTokenStored;
        uint256 totalSupply;
        uint256 minimumStake;
        uint256 lockPeriod; // Lock period in seconds
        bool active;
    }
    
    struct UserInfo {
        uint256 balance;
        uint256 userRewardPerTokenPaid;
        uint256 rewards;
        uint256 stakedTime;
    }
    
    mapping(uint256 => StakingPool) public pools;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    
    uint256 public poolCount;
    uint256 public constant REWARD_PRECISION = 1e18;
    
    constructor() Ownable(msg.sender) {}
    
    event PoolCreated(
        uint256 indexed poolId,
        address stakingToken,
        address rewardToken,
        uint256 rewardRate,
        uint256 minimumStake,
        uint256 lockPeriod
    );
    
    event Staked(address indexed user, uint256 indexed poolId, uint256 amount);
    event Withdrawn(address indexed user, uint256 indexed poolId, uint256 amount);
    event RewardPaid(address indexed user, uint256 indexed poolId, uint256 reward);
    event RewardRateUpdated(uint256 indexed poolId, uint256 newRate);
    event PoolStatusChanged(uint256 indexed poolId, bool active);
    
    modifier updateReward(uint256 poolId, address account) {
        StakingPool storage pool = pools[poolId];
        pool.rewardPerTokenStored = rewardPerToken(poolId);
        pool.lastUpdateTime = block.timestamp;
        
        if (account != address(0)) {
            UserInfo storage user = userInfo[poolId][account];
            user.rewards = earned(poolId, account);
            user.userRewardPerTokenPaid = pool.rewardPerTokenStored;
        }
        _;
    }
    
    modifier poolExists(uint256 poolId) {
        require(poolId < poolCount, "Pool does not exist");
        _;
    }
    
    modifier poolActive(uint256 poolId) {
        require(pools[poolId].active, "Pool is not active");
        _;
    }
    
    function createPool(
        address _stakingToken,
        address _rewardToken,
        uint256 _rewardRate,
        uint256 _minimumStake,
        uint256 _lockPeriod
    ) external onlyOwner {
        require(_stakingToken != address(0), "Invalid staking token");
        require(_rewardToken != address(0), "Invalid reward token");
        require(_rewardRate > 0, "Reward rate must be greater than 0");
        
        pools[poolCount] = StakingPool({
            stakingToken: IERC20(_stakingToken),
            rewardToken: IERC20(_rewardToken),
            rewardRate: _rewardRate,
            lastUpdateTime: block.timestamp,
            rewardPerTokenStored: 0,
            totalSupply: 0,
            minimumStake: _minimumStake,
            lockPeriod: _lockPeriod,
            active: true
        });
        
        emit PoolCreated(
            poolCount,
            _stakingToken,
            _rewardToken,
            _rewardRate,
            _minimumStake,
            _lockPeriod
        );
        
        poolCount++;
    }
    
    function rewardPerToken(uint256 poolId) public view returns (uint256) {
        StakingPool storage pool = pools[poolId];
        if (pool.totalSupply == 0) {
            return pool.rewardPerTokenStored;
        }
        
        return pool.rewardPerTokenStored + (
            ((block.timestamp - pool.lastUpdateTime) * pool.rewardRate * REWARD_PRECISION) / pool.totalSupply
        );
    }
    
    function earned(uint256 poolId, address account) public view returns (uint256) {
        UserInfo storage user = userInfo[poolId][account];
        return (user.balance * (rewardPerToken(poolId) - user.userRewardPerTokenPaid)) / REWARD_PRECISION + user.rewards;
    }
    
    function stake(uint256 poolId, uint256 amount) 
        external 
        nonReentrant 
        whenNotPaused 
        poolExists(poolId) 
        poolActive(poolId) 
        updateReward(poolId, msg.sender) 
    {
        require(amount > 0, "Cannot stake 0");
        
        StakingPool storage pool = pools[poolId];
        UserInfo storage user = userInfo[poolId][msg.sender];
        
        require(amount >= pool.minimumStake, "Amount below minimum stake");
        
        pool.totalSupply += amount;
        user.balance += amount;
        user.stakedTime = block.timestamp;
        
        pool.stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        
        emit Staked(msg.sender, poolId, amount);
    }
    
    function withdraw(uint256 poolId, uint256 amount) 
        public 
        nonReentrant 
        poolExists(poolId) 
        updateReward(poolId, msg.sender) 
    {
        require(amount > 0, "Cannot withdraw 0");
        
        StakingPool storage pool = pools[poolId];
        UserInfo storage user = userInfo[poolId][msg.sender];
        
        require(user.balance >= amount, "Insufficient balance");
        require(
            block.timestamp >= user.stakedTime + pool.lockPeriod,
            "Tokens are still locked"
        );
        
        pool.totalSupply -= amount;
        user.balance -= amount;
        
        pool.stakingToken.safeTransfer(msg.sender, amount);
        
        emit Withdrawn(msg.sender, poolId, amount);
    }
    
    function getReward(uint256 poolId) 
        public 
        nonReentrant 
        poolExists(poolId) 
        updateReward(poolId, msg.sender) 
    {
        UserInfo storage user = userInfo[poolId][msg.sender];
        uint256 reward = user.rewards;
        
        if (reward > 0) {
            user.rewards = 0;
            pools[poolId].rewardToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, poolId, reward);
        }
    }
    
    function exit(uint256 poolId) external {
        UserInfo storage user = userInfo[poolId][msg.sender];
        withdraw(poolId, user.balance);
        getReward(poolId);
    }
    
    function compound(uint256 poolId) 
        external 
        nonReentrant 
        poolExists(poolId) 
        poolActive(poolId) 
        updateReward(poolId, msg.sender) 
    {
        require(
            address(pools[poolId].stakingToken) == address(pools[poolId].rewardToken),
            "Cannot compound different tokens"
        );
        
        UserInfo storage user = userInfo[poolId][msg.sender];
        uint256 reward = user.rewards;
        
        if (reward > 0) {
            user.rewards = 0;
            
            // Stake the reward
            pools[poolId].totalSupply += reward;
            user.balance += reward;
            user.stakedTime = block.timestamp;
            
            emit RewardPaid(msg.sender, poolId, reward);
            emit Staked(msg.sender, poolId, reward);
        }
    }
    
    function emergencyWithdraw(uint256 poolId) 
        external 
        nonReentrant 
        poolExists(poolId) 
    {
        UserInfo storage user = userInfo[poolId][msg.sender];
        uint256 amount = user.balance;
        
        require(amount > 0, "No tokens to withdraw");
        
        pools[poolId].totalSupply -= amount;
        user.balance = 0;
        user.rewards = 0;
        
        pools[poolId].stakingToken.safeTransfer(msg.sender, amount);
        
        emit Withdrawn(msg.sender, poolId, amount);
    }
    
    function updateRewardRate(uint256 poolId, uint256 newRate) 
        external 
        onlyOwner 
        poolExists(poolId) 
        updateReward(poolId, address(0)) 
    {
        require(newRate > 0, "Reward rate must be greater than 0");
        pools[poolId].rewardRate = newRate;
        emit RewardRateUpdated(poolId, newRate);
    }
    
    function setPoolStatus(uint256 poolId, bool active) 
        external 
        onlyOwner 
        poolExists(poolId) 
    {
        pools[poolId].active = active;
        emit PoolStatusChanged(poolId, active);
    }
    
    function getPoolInfo(uint256 poolId) 
        external 
        view 
        poolExists(poolId) 
        returns (
            address stakingToken,
            address rewardToken,
            uint256 rewardRate,
            uint256 totalSupply,
            uint256 minimumStake,
            uint256 lockPeriod,
            bool active
        ) 
    {
        StakingPool storage pool = pools[poolId];
        return (
            address(pool.stakingToken),
            address(pool.rewardToken),
            pool.rewardRate,
            pool.totalSupply,
            pool.minimumStake,
            pool.lockPeriod,
            pool.active
        );
    }
    
    function getUserInfo(uint256 poolId, address user) 
        external 
        view 
        poolExists(poolId) 
        returns (
            uint256 balance,
            uint256 earnedAmount,
            uint256 stakedTime,
            uint256 unlockTime
        ) 
    {
        UserInfo storage userStake = userInfo[poolId][user];
        return (
            userStake.balance,
            earned(poolId, user),
            userStake.stakedTime,
            userStake.stakedTime + pools[poolId].lockPeriod
        );
    }
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
}