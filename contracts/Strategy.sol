// SPDX-License-Identifier: MIT

pragma solidity ^0.5.0;

import "@openzeppelin-2/contracts/math/Math.sol";
import "@openzeppelin-2/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-2/contracts/ownership/Ownable.sol";

import "../../utils/LPTokenWrapper.sol";

interface IGasPrice {
    function maxGasPrice() external returns (uint256);
}

contract GasThrottler {
    bool public shouldGasThrottle = true;

    address public gasprice =
        address(0xA43509661141F254F54D9A326E8Ec851A0b95307);

    modifier gasThrottle() {
        if (shouldGasThrottle && Address.isContract(gasprice)) {
            require(
                tx.gasprice <= IGasPrice(gasprice).maxGasPrice(),
                "gas is too high!"
            );
        }
        _;
    }
}

interface IRewardPool {
    function deposit(uint256 amount) external;

    function stake(uint256 amount) external;

    function withdraw(uint256 amount) external;

    function earned(address account) external view returns (uint256);

    function getReward() external;

    function balanceOf(address account) external view returns (uint256);
}

contract StrategyCommonRewardPool is StratManager, FeeManager, GasThrottler {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // Tokens
    address public native; // wFTM
    address public output; // wFTM
    address public want; // beFTM

    // Third party contracts
    address public rewardPool;

    // Routes
    address[] public outputToNativeRoute;
    address[] public outputToWantRoute;

    bool public harvestOnDeposit;
    uint256 public lastHarvest;

    event StratHarvest(
        address indexed harvester,
        uint256 wantHarvested,
        uint256 tvl
    );
    event Deposit(uint256 tvl); // emit Deposit(balanceOf());
    event Withdraw(uint256 tvl); // emit Withdraw(balanceOf());
    event ChargedFees(
        uint256 callFees,
        uint256 beefyFees,
        uint256 strategistFees
    );

    constructor(
        address _want,
        address _rewardPool,
        address _vault,
        address _unirouter,
        address _keeper,
        address _strategist,
        address _beefyFeeRecipient,
        address[] memory _outputToNativeRoute,
        address[] memory _outputToWantRoute
    )
        public
        StratManager(
            _keeper,
            _strategist,
            _unirouter,
            _vault,
            _beefyFeeRecipient
        )
    {
        want = _want;
        rewardPool = _rewardPool; // 0xe00d25938671525c2542a689e42d1cfa56de5888

        output = _outputToNativeRoute[0];
        native = _outputToNativeRoute[_outputToNativeRoute.length - 1];
        outputToNativeRoute = _outputToNativeRoute;

        require(
            _outputToWantRoute[0] == output,
            "outputToWantRoute[0] != output"
        );
        require(
            _outputToWantRoute[_outputToWantRoute.length - 1] == want,
            "outputToWantRoute[last] != want"
        );
        outputToWantRoute = _outputToWantRoute;

        _giveAllowances();
    }

    // Puts the funds to work
    function deposit() public whenNotPaused {
        uint256 wantBal = balanceOfWant();

        if (wantBal > 0) {
            IRewardPool(rewardPool).stake(wantBal);
            emit Deposit(balanceOf()); // event Deposit(uint256 tvl);
        }
    }

    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 wantBal = balanceOfWant();

        if (wantBal < _amount) {
            IRewardPool(rewardPool).withdraw(_amount.sub(wantBal));
            wantBal = balanceOfWant();
        }

        if (wantBal > _amount) {
            wantBal = _amount;
        }

        if (tx.origin != owner() && !paused()) {
            uint256 withdrawalFeeAmount = wantBal.mul(withdrawalFee).div(
                WITHDRAWAL_MAX
            ); // withdrawalFee = 1 (0.01%) || WITHDRAWAL_MAX = 10000
            wantBal = wantBal.sub(withdrawalFeeAmount);
        }

        IERC20(want).safeTransfer(vault, wantBal);

        emit Withdraw(balanceOf()); // event Withdraw(uint256 tvl);
    }

    function beforeDeposit() external override {
        if (harvestOnDeposit) {
            require(msg.sender == vault, "!vault");
            _harvest(tx.origin);
        }
    }

    function harvest() external virtual gasThrottle {
        _harvest(tx.origin);
    }

    function harvest(address callFeeRecipient) external virtual gasThrottle {
        _harvest(callFeeRecipient);
    }

    function managerHarvest() external onlyManager {
        _harvest(tx.origin);
    }

    // Compounds earnings and charges performance fee
    function _harvest(address callFeeRecipient) internal whenNotPaused {
        IRewardPool(rewardPool).getReward();
        uint256 outputBal = IERC20(output).balanceOf(address(this)); // wFTM
        if (outputBal > 0) {
            chargeFees(callFeeRecipient);
            swapRewards();
            uint256 wantHarvested = balanceOfWant();
            deposit();

            lastHarvest = block.timestamp;
            emit StratHarvest(msg.sender, wantHarvested, balanceOf());
        }
    }

    // Performance fees
    function chargeFees(address callFeeRecipient) internal {
        uint256 nativeBal = IERC20(output).balanceOf(address(this)).mul(45).div(
            1000
        );

        uint256 callFeeAmount = nativeBal.mul(callFee).div(MAX_FEE); // 11
        IERC20(native).safeTransfer(callFeeRecipient, callFeeAmount);

        uint256 beefyFeeAmount = nativeBal.mul(beefyFee).div(MAX_FEE); // 877
        IERC20(native).safeTransfer(beefyFeeRecipient, beefyFeeAmount);

        uint256 strategistFee = nativeBal.mul(STRATEGIST_FEE).div(MAX_FEE); // 112
        IERC20(native).safeTransfer(strategist, strategistFee);

        emit ChargedFees(callFeeAmount, beefyFeeAmount, strategistFee); // MAX_FEE = 1000
    }

    // Swaps rewards
    function swapRewards() internal {
        if (output == want) {
            // Do nothing
        } else {
            uint256 outputBal = IERC20(output).balanceOf(address(this));
            // IUniswapRouterETH = 0xa38cd27185a464914D3046f0AB9d43356B34829D (Solidly)
            IUniswapRouterETH(unirouter).swapExactTokensForTokensSimple(
                outputBal,
                0,
                output,
                want,
                true,
                address(this),
                now
            );
        }
    }

    // Calculate the total underlaying 'want' held by the strat (TVL).
    function balanceOf() public view returns (uint256) {
        return balanceOfWant().add(balanceOfPool());
    }

    // It calculates how much 'want' this contract holds.
    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    // It calculates how much 'want' the strategy has working in the farm.
    function balanceOfPool() public view returns (uint256) {
        return IRewardPool(rewardPool).balanceOf(address(this));
    }

    // Returns rewards unharvested.
    function rewardsAvailable() public view returns (uint256) {
        return IRewardPool(rewardPool).earned(address(this));
    }

    // Native reward amount for calling harvest.
    function callReward() public view returns (uint256) {
        uint256 outputBal = rewardsAvailable();
        uint256 nativeOut;
        if (outputBal > 0) {
            try
                IUniswapRouterETH(unirouter).getAmountsOut(
                    outputBal,
                    outputToNativeRoute
                )
            returns (uint256[] memory amountOut) {
                nativeOut = amountOut[amountOut.length - 1];
            } catch {}
        }

        return nativeOut.mul(45).div(1000).mul(callFee).div(MAX_FEE); // Returns for harvester
    }

    function outputToNative() public view returns (address[] memory) {
        return outputToNativeRoute; // output = wFTM || native = wFTM
    }

    function outputToWant() public view returns (address[] memory) {
        return outputToWantRoute; // [wFTM, beFTM]
    }

    function setHarvestOnDeposit(bool _harvestOnDeposit) external onlyManager {
        harvestOnDeposit = _harvestOnDeposit;
        if (harvestOnDeposit == true) {
            setWithdrawalFee(0);
        } else {
            setWithdrawalFee(10);
        }
    }

    // Called as part of strat migration. Sends all the available funds back to the vault.
    function retireStrat() external {
        require(msg.sender == vault, "!vault");

        IRewardPool(rewardPool).withdraw(balanceOfPool());

        uint256 wantBal = balanceOfWant();
        IERC20(want).transfer(vault, wantBal);
    }

    // Pauses deposits and withdraws all funds from third party systems.
    function panic() public onlyManager {
        pause();
        IRewardPool(rewardPool).withdraw(balanceOfPool());
    }

    function pause() public onlyManager {
        _pause();

        _removeAllowances();
    }

    function unpause() external onlyManager {
        _unpause();

        _giveAllowances();

        deposit();
    }

    function _giveAllowances() internal {
        IERC20(want).safeApprove(rewardPool, uint256(-1));
        IERC20(output).safeApprove(unirouter, uint256(-1));
    }

    function _removeAllowances() internal {
        IERC20(want).safeApprove(rewardPool, 0);
        IERC20(output).safeApprove(unirouter, 0);
    }
}
