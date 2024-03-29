// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/utils/math/SafeMath.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import './IwULX.sol';

// The Ultron Garden is a fork of MasterChef by SushiSwap
// The biggest change made is using per second instead of per block for rewards
// This is due to Ultrons extremely inconsistent block times
// The other biggest change was the removal of the migration functions
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once wULX is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. 
contract MasterChef is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of wULXs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accwULXPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accwULXPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. wULXs to distribute per block.
        uint256 lastRewardTime;  // Last block time that wULXs distribution occurs.
        uint256 accwULXPerShare; // Accumulated wULXs per share, times 1e12. See below.
    }

    // such a ultron token!
    address public wULX;

    // wULX tokens created per block.
    uint256 public wULXPerSecond;

    // set a max wULX per second, which can never be higher than 1 per second
    uint256 public constant maxwULXPerSecond = 1e18;

    uint256 public constant MaxAllocPoint = 4000;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block time when wULX mining starts.
    uint256 public immutable startTime;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event LogUpdatePool(uint indexed pid, uint lastRewardTime, uint lpSupply, uint accBooPerShare);

    constructor(
        address _wULX,
        uint256 _wULXPerSecond,
        uint256 _startTime
    ) {
        wULX = _wULX;
        wULXPerSecond = _wULXPerSecond;
        startTime = _startTime;
    }

    bytes4 private constant SELECTOR = bytes4(keccak256("balanceOf(address)"));
    function isContract(address _address) private view returns (bool success) {
        uint32 size;
        assembly {
            size := extcodesize(_address)
        }
        success = size > 0;
    } 
    function isLpToken(address token) private returns (bool success) {
        bytes memory data = abi.encodeWithSelector(SELECTOR, address(this));

        assembly {
            success := call(
                gas(),            // gas remaining
                token,         // destination address
                0,              // no ether
                add(data, 32),  // input buffer (starts after the first 32 bytes in the `data` array)
                mload(data),    // input length (loaded from the first 32 bytes in the `data` array)
                0,              // output buffer
                0               // output length
            )
        }
    }

    function _mintWETH(address _to, uint256 amount) private {
        IwULX(wULX).mint(_to, amount);
    }

    function _transferWETH(address _to, uint256 amount) private {
        IwULX(wULX).transfer(_to, amount);
    }

    // Safe wULX transfer function, just in case if rounding error causes pool to not have enough wULXs.
    function _safewULXTransfer(address _to, uint256 _amount) internal {
        uint256 wULXBal = IwULX(wULX).balanceOf(address(this));
        if (_amount > wULXBal) {
            _transferWETH(_to, wULXBal);
        } else {
            _transferWETH(_to, _amount);
        }
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Changes wULX token reward per second, with a cap of maxwULX per second
    // Good practice to update pools without messing up the contract
    function setwULXPerSecond(uint256 _wULXPerSecond) external onlyOwner {
        require(_wULXPerSecond <= maxwULXPerSecond, "setwULXPerSecond: too many wULXs!");

        // This MUST be done or pool rewards will be calculated with new wULX per second
        // This could unfairly punish small pools that dont have frequent deposits/withdraws/harvests
        massUpdatePools(); 

        wULXPerSecond = _wULXPerSecond;
    }

    function checkForDuplicate(IERC20 _lpToken) internal view {
        uint256 length = poolInfo.length;
        for (uint256 _pid = 0; _pid < length; _pid++) {
            require(poolInfo[_pid].lpToken != _lpToken, "add: pool already exists!!!!");
        }
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(uint256 _allocPoint, IERC20 _lpToken) external onlyOwner {
        require(isContract(address(_lpToken)), "not contract");
        require(isLpToken(address(_lpToken)), "not lp");
        require(_allocPoint <= MaxAllocPoint, "add: too many alloc points!!");

        checkForDuplicate(_lpToken); // ensure you cant add duplicate pools

        massUpdatePools();

        uint256 lastRewardTime = block.timestamp > startTime ? block.timestamp : startTime;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardTime: lastRewardTime,
            accwULXPerShare: 0
        }));
    }

    // Update the given pool's wULX allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint) external onlyOwner {
        require(_allocPoint <= MaxAllocPoint, "add: too many alloc points!!");

        massUpdatePools();

        totalAllocPoint = totalAllocPoint - poolInfo[_pid].allocPoint + _allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        _from = _from > startTime ? _from : startTime;
        if (_to < startTime) {
            return 0;
        }
        return _to - _from;
    }

    // View function to see pending wULXs on frontend.
    function pendingwULX(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accwULXPerShare = pool.accwULXPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.timestamp > pool.lastRewardTime && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardTime, block.timestamp);
            uint256 wULXReward = multiplier.mul(wULXPerSecond).mul(pool.allocPoint).div(totalAllocPoint);
            accwULXPerShare = accwULXPerShare.add(wULXReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accwULXPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public returns (PoolInfo memory pool) {
        pool = poolInfo[_pid];
        if (block.timestamp > pool.lastRewardTime) {
            uint256 lpSupply = pool.lpToken.balanceOf(address(this));
            if (lpSupply > 0) {
                uint256 multiplier = getMultiplier(pool.lastRewardTime, block.timestamp);
                uint256 wULXReward = multiplier.mul(wULXPerSecond).mul(pool.allocPoint).div(totalAllocPoint);

                _mintWETH(address(this), wULXReward);

                pool.accwULXPerShare = pool.accwULXPerShare.add(wULXReward.mul(1e12).div(lpSupply));
            }
            pool.lastRewardTime = block.timestamp;
            poolInfo[_pid] = pool;
            emit LogUpdatePool(_pid, pool.lastRewardTime, lpSupply, pool.accwULXPerShare);
        }
    }

    // Deposit LP tokens to MasterChef for wULX allocation.
    function deposit(uint256 _pid, uint256 _amount) public {

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        updatePool(_pid);

        uint256 pending = user.amount.mul(pool.accwULXPerShare).div(1e12).sub(user.rewardDebt);

        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.amount.mul(pool.accwULXPerShare).div(1e12);

        if(pending > 0) {
            _safewULXTransfer(msg.sender, pending);
        }
        pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);

        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public {  
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        require(user.amount >= _amount, "withdraw: not good");

        updatePool(_pid);

        uint256 pending = user.amount.mul(pool.accwULXPerShare).div(1e12).sub(user.rewardDebt);

        user.amount = user.amount.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accwULXPerShare).div(1e12);

        if(pending > 0) {
            _safewULXTransfer(msg.sender, pending);
        }
        pool.lpToken.safeTransfer(address(msg.sender), _amount);
        
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint oldUserAmount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;

        pool.lpToken.safeTransfer(address(msg.sender), oldUserAmount);
        emit EmergencyWithdraw(msg.sender, _pid, oldUserAmount);
    }

    /// @notice Batch harvest all rewards from all staked pools
    /// @dev This function has an unbounded gas cost. Take care not to call it from other smart contracts if you don't know what you're doing.
    function harvestAll() external {
        uint256 length = poolInfo.length;
        uint calc;
        uint pending;
        UserInfo storage user;
        PoolInfo memory pool;
        uint totalPending;
        for (uint256 pid = 0; pid < length; ++pid) {
            user = userInfo[pid][msg.sender];
            if (user.amount > 0) {
                pool = updatePool(pid);

                calc = user.amount.mul(pool.accwULXPerShare).div(1e12);
                pending = calc - user.rewardDebt;
                user.rewardDebt = calc;

                if(pending > 0) {
                    totalPending+=pending;
                }
            }
        }
        if (totalPending > 0) {
            _safewULXTransfer(msg.sender, totalPending);
        }
    }
}
