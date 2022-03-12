// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

interface IERC20 {
    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function transfer(address recipient, uint256 amount)
        external
        returns (bool);

    function allowance(address owner, address spender)
        external
        view
        returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );
}

contract StakingRewards {
    IERC20 public rewardsToken;
    IERC20 public stakingToken;

    uint256 public rewardRate = 100; // Tokens per second
    uint256 public lastUpdateTime; // Last time this contract was called
    uint256 public rewardPerTokenStored; // Reward Rate / Token staked at each given time

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards; // Updates the user rewards

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances; // Tokens staked per user

    constructor(address _stakingToken, address _rewardsToken) {
        stakingToken = IERC20(_stakingToken);
        rewardsToken = IERC20(_rewardsToken);
    }

    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored +
            (((block.timestamp - lastUpdateTime) * rewardRate * 1e18) /
                _totalSupply);
    }

    function earned(address account) public view returns (uint256) {
        return
            ((_balances[account] *
                (rewardPerToken() - userRewardPerTokenPaid[account])) / 1e18) +
            rewards[account];
    }

    // Updates the reward of the user
    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = block.timestamp;

        rewards[account] = earned(account); // Store what the user can claim so far
        userRewardPerTokenPaid[account] = rewardPerTokenStored;
        _;
    }

    // 1st update the reward
    function stake(uint256 _amount) external updateReward(msg.sender) {
        _totalSupply += _amount; // Updates the total supply of staked tokens
        _balances[msg.sender] += _amount; // Updates the balance of staked tokens of the user
        stakingToken.transferFrom(msg.sender, address(this), _amount); // Transfer to the contract
    }

    // 1st update the reward
    function withdraw(uint256 _amount) external updateReward(msg.sender) {
        _totalSupply -= _amount;
        _balances[msg.sender] -= _amount;
        stakingToken.transfer(msg.sender, _amount);
    }

    function getReward() external updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        rewards[msg.sender] = 0;
        rewardsToken.transfer(msg.sender, reward);
    }
}
