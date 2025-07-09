// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract TokenVesting is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    struct VestingSchedule {
        bool initialized;
        address beneficiary;
        uint256 cliff;
        uint256 start;
        uint256 duration;
        uint256 slicePeriodSeconds;
        bool revocable;
        uint256 amountTotal;
        uint256 released;
        bool revoked;
    }
    
    IERC20 public token;
    mapping(bytes32 => VestingSchedule) public vestingSchedules;
    mapping(address => uint256) public holdersVestingCount;
    bytes32[] public vestingSchedulesIds;
    uint256 public vestingSchedulesTotalAmount;
    
    event VestingScheduleCreated(
        bytes32 indexed vestingScheduleId,
        address indexed beneficiary,
        uint256 cliff,
        uint256 start,
        uint256 duration,
        uint256 slicePeriodSeconds,
        bool revocable,
        uint256 amount
    );
    
    event TokensReleased(
        bytes32 indexed vestingScheduleId,
        address indexed beneficiary,
        uint256 amount
    );
    
    event VestingScheduleRevoked(
        bytes32 indexed vestingScheduleId,
        address indexed beneficiary,
        uint256 unreleased
    );
    
    constructor(address _token) Ownable(msg.sender) {
        require(_token != address(0), "Token address cannot be zero");
        token = IERC20(_token);
    }
    
    function createVestingSchedule(
        address _beneficiary,
        uint256 _start,
        uint256 _cliff,
        uint256 _duration,
        uint256 _slicePeriodSeconds,
        bool _revocable,
        uint256 _amount
    ) public onlyOwner {
        require(_beneficiary != address(0), "Beneficiary cannot be zero address");
        require(_duration > 0, "Duration must be > 0");
        require(_amount > 0, "Amount must be > 0");
        require(_slicePeriodSeconds >= 1, "Slice period must be >= 1 second");
        require(_duration >= _cliff, "Duration must be >= cliff");
        require(
            getWithdrawableAmount() >= _amount,
            "Cannot create vesting schedule: insufficient tokens"
        );
        
        bytes32 vestingScheduleId = computeNextVestingScheduleIdForHolder(_beneficiary);
        uint256 cliff = _start + _cliff;
        
        vestingSchedules[vestingScheduleId] = VestingSchedule(
            true,
            _beneficiary,
            cliff,
            _start,
            _duration,
            _slicePeriodSeconds,
            _revocable,
            _amount,
            0,
            false
        );
        
        vestingSchedulesTotalAmount += _amount;
        vestingSchedulesIds.push(vestingScheduleId);
        
        uint256 currentVestingCount = holdersVestingCount[_beneficiary];
        holdersVestingCount[_beneficiary] = currentVestingCount + 1;
        
        emit VestingScheduleCreated(
            vestingScheduleId,
            _beneficiary,
            cliff,
            _start,
            _duration,
            _slicePeriodSeconds,
            _revocable,
            _amount
        );
    }
    
    function revoke(bytes32 vestingScheduleId) public onlyOwner {
        VestingSchedule storage vestingSchedule = vestingSchedules[vestingScheduleId];
        require(vestingSchedule.initialized, "Vesting schedule not found");
        require(vestingSchedule.revocable, "Vesting schedule not revocable");
        require(!vestingSchedule.revoked, "Vesting schedule already revoked");
        
        uint256 vestedAmount = _computeReleasableAmount(vestingSchedule);
        
        if (vestedAmount > 0) {
            release(vestingScheduleId, vestedAmount);
        }
        
        uint256 unreleased = vestingSchedule.amountTotal - vestingSchedule.released;
        vestingSchedulesTotalAmount -= unreleased;
        vestingSchedule.revoked = true;
        
        emit VestingScheduleRevoked(vestingScheduleId, vestingSchedule.beneficiary, unreleased);
    }
    
    function release(bytes32 vestingScheduleId, uint256 amount) public nonReentrant {
        VestingSchedule storage vestingSchedule = vestingSchedules[vestingScheduleId];
        require(vestingSchedule.initialized, "Vesting schedule not found");
        
        bool isBeneficiary = msg.sender == vestingSchedule.beneficiary;
        bool isOwner = msg.sender == owner();
        require(isBeneficiary || isOwner, "Only beneficiary or owner can release vested tokens");
        
        uint256 vestedAmount = _computeReleasableAmount(vestingSchedule);
        require(vestedAmount >= amount, "Cannot release more than vested amount");
        
        vestingSchedule.released += amount;
        vestingSchedulesTotalAmount -= amount;
        
        token.safeTransfer(vestingSchedule.beneficiary, amount);
        
        emit TokensReleased(vestingScheduleId, vestingSchedule.beneficiary, amount);
    }
    
    function computeReleasableAmount(bytes32 vestingScheduleId) 
        public 
        view 
        returns (uint256) 
    {
        VestingSchedule storage vestingSchedule = vestingSchedules[vestingScheduleId];
        return _computeReleasableAmount(vestingSchedule);
    }
    
    function _computeReleasableAmount(VestingSchedule memory vestingSchedule)
        internal
        view
        returns (uint256)
    {
        if (!vestingSchedule.initialized || vestingSchedule.revoked) {
            return 0;
        }
        
        uint256 currentTime = block.timestamp;
        
        if (currentTime < vestingSchedule.cliff) {
            return 0;
        } else if (currentTime >= vestingSchedule.start + vestingSchedule.duration) {
            return vestingSchedule.amountTotal - vestingSchedule.released;
        } else {
            uint256 timeFromStart = currentTime - vestingSchedule.start;
            uint256 secondsPerSlice = vestingSchedule.slicePeriodSeconds;
            uint256 vestedSlicePeriods = timeFromStart / secondsPerSlice;
            uint256 vestedSeconds = vestedSlicePeriods * secondsPerSlice;
            uint256 vestedAmount = (vestingSchedule.amountTotal * vestedSeconds) / vestingSchedule.duration;
            
            return vestedAmount - vestingSchedule.released;
        }
    }
    
    function computeVestingScheduleIdForAddressAndIndex(address holder, uint256 index)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(holder, index));
    }
    
    function computeNextVestingScheduleIdForHolder(address holder)
        public
        view
        returns (bytes32)
    {
        return computeVestingScheduleIdForAddressAndIndex(holder, holdersVestingCount[holder]);
    }
    
    function getLastVestingScheduleIdForHolder(address holder)
        public
        view
        returns (bytes32)
    {
        return computeVestingScheduleIdForAddressAndIndex(holder, holdersVestingCount[holder] - 1);
    }
    
    function getVestingSchedule(bytes32 vestingScheduleId)
        public
        view
        returns (VestingSchedule memory)
    {
        return vestingSchedules[vestingScheduleId];
    }
    
    function getVestingSchedulesCountByBeneficiary(address beneficiary)
        public
        view
        returns (uint256)
    {
        return holdersVestingCount[beneficiary];
    }
    
    function getVestingIdAtIndex(uint256 index)
        public
        view
        returns (bytes32)
    {
        require(index < vestingSchedulesIds.length, "Index out of bounds");
        return vestingSchedulesIds[index];
    }
    
    function getVestingScheduleByAddressAndIndex(address holder, uint256 index)
        public
        view
        returns (VestingSchedule memory)
    {
        return getVestingSchedule(computeVestingScheduleIdForAddressAndIndex(holder, index));
    }
    
    function getTotalVestingSchedules() public view returns (uint256) {
        return vestingSchedulesIds.length;
    }
    
    function getWithdrawableAmount() public view returns (uint256) {
        return token.balanceOf(address(this)) - vestingSchedulesTotalAmount;
    }
    
    function withdraw(uint256 amount) public onlyOwner {
        require(
            getWithdrawableAmount() >= amount,
            "Not enough withdrawable funds"
        );
        token.safeTransfer(owner(), amount);
    }
    
    function getVestingSchedulesByBeneficiary(address beneficiary)
        public
        view
        returns (VestingSchedule[] memory)
    {
        uint256 count = holdersVestingCount[beneficiary];
        VestingSchedule[] memory schedules = new VestingSchedule[](count);
        
        for (uint256 i = 0; i < count; i++) {
            schedules[i] = getVestingScheduleByAddressAndIndex(beneficiary, i);
        }
        
        return schedules;
    }
    
    function getBeneficiaryInfo(address beneficiary)
        public
        view
        returns (
            uint256 totalVested,
            uint256 totalReleased,
            uint256 totalReleasable,
            uint256 scheduleCount
        )
    {
        scheduleCount = holdersVestingCount[beneficiary];
        
        for (uint256 i = 0; i < scheduleCount; i++) {
            bytes32 vestingScheduleId = computeVestingScheduleIdForAddressAndIndex(beneficiary, i);
            VestingSchedule storage schedule = vestingSchedules[vestingScheduleId];
            
            if (schedule.initialized && !schedule.revoked) {
                totalVested += schedule.amountTotal;
                totalReleased += schedule.released;
                totalReleasable += _computeReleasableAmount(schedule);
            }
        }
    }
}