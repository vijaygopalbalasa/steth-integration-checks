// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./StETHIntegrationChecks.sol";

interface IStETHTransfers {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice The mistake the guide warns about: it books stETH amounts instead of shares and credits the amount it
///         was asked to pull, not what arrived. Used only to show the checks catch it.
contract NaiveStETHVault {
    address internal constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    mapping(address => uint256) public booked;

    function deposit(uint256 amount) external {
        IStETHTransfers(STETH).transferFrom(msg.sender, address(this), amount);
        booked[msg.sender] += amount;
    }

    function withdrawAll() external {
        uint256 amount = booked[msg.sender];
        booked[msg.sender] = 0;
        IStETHTransfers(STETH).transfer(msg.sender, amount);
    }
}

/// @notice The checks check themselves: the naive vault must fail every check that targets its mistake. Each
///         check runs through an external call that is expected to revert; the one check the mistake does not
///         break (everyone exits after rewards, since the rewards just stay stuck in the vault) runs as is and passes.
contract NaiveVaultIsCaught is StETHIntegrationChecks {
    NaiveStETHVault internal vault;

    function _setUpTarget() internal override {
        vault = new NaiveStETHVault();
    }

    function _holder() internal view override returns (address) {
        return address(vault);
    }

    function _deposit(address user, uint256 amount) internal override {
        vm.startPrank(user);
        STETH.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();
    }

    function _claim(address user) internal view override returns (uint256) {
        return vault.booked(user);
    }

    function _exit(address user) internal override {
        vm.prank(user);
        vault.withdrawAll();
    }

    // The expected reasons carry exact wei figures: they hold at FORK_BLOCK and change if the block does.
    function test_creditNeverExceedsWhatArrived() public override onFork {
        vm.expectRevert(bytes("credited more stETH than arrived: 3333333333333333332 > 3333333333333333331"));
        this.runCredit();
    }

    function test_rewardsReachTheDepositor() public override onFork {
        vm.expectRevert(
            bytes(
                "the depositor's claim did not follow the rebase: 9999999999999999999 !~= 10000988054543373363 (max delta: 2, real delta: 988054543373364)"
            )
        );
        this.runRewards();
    }

    function test_lossesReachTheDepositor() public override onFork {
        vm.expectRevert(
            bytes(
                "the depositor's claim did not follow the rebase: 9999999999999999999 !~= 9990119454566266352 (max delta: 2, real delta: 9880545433733647)"
            )
        );
        this.runLosses();
    }

    /// stETH itself refuses the last withdrawal: the vault holds less than it booked.
    function test_everyDepositorCanExitAfterALoss() public override onFork {
        vm.expectRevert(bytes("BALANCE_EXCEEDED"));
        this.runExitAfterLoss();
    }

    function runCredit() external {
        StETHIntegrationChecks.test_creditNeverExceedsWhatArrived();
    }

    function runRewards() external {
        StETHIntegrationChecks.test_rewardsReachTheDepositor();
    }

    function runLosses() external {
        StETHIntegrationChecks.test_lossesReachTheDepositor();
    }

    function runExitAfterLoss() external {
        StETHIntegrationChecks.test_everyDepositorCanExitAfterALoss();
    }
}
