// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./StETHIntegrationChecks.sol";

interface IWstETH {
    function wrap(uint256 stETHAmount) external returns (uint256);
    function unwrap(uint256 wstETHAmount) external returns (uint256);
    function getStETHByWstETH(uint256 wstETHAmount) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Lido's own wrapper, the reference: it accounts in shares, so it should pass every check.
contract WstETHReference is StETHIntegrationChecks {
    IWstETH internal constant WSTETH = IWstETH(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);

    function _holder() internal pure override returns (address) {
        return address(WSTETH);
    }

    function _deposit(address user, uint256 amount) internal override {
        vm.startPrank(user);
        STETH.approve(address(WSTETH), amount);
        WSTETH.wrap(amount);
        vm.stopPrank();
    }

    function _claim(address user) internal view override returns (uint256) {
        return WSTETH.getStETHByWstETH(WSTETH.balanceOf(user));
    }

    function _exit(address user) internal override {
        uint256 balance = WSTETH.balanceOf(user);
        vm.prank(user);
        WSTETH.unwrap(balance);
    }
}

interface IStrategyManager {
    function depositIntoStrategy(address strategy, address token, uint256 amount) external returns (uint256);
    function stakerDepositShares(address staker, address strategy) external view returns (uint256);
}

interface IStrategy {
    function sharesToUnderlyingView(uint256 amountShares) external view returns (uint256);
}

interface IDelegationManager {
    struct Withdrawal {
        address staker;
        address delegatedTo;
        address withdrawer;
        uint256 nonce;
        uint32 startBlock;
        address[] strategies;
        uint256[] scaledShares;
    }

    struct QueuedWithdrawalParams {
        address[] strategies;
        uint256[] depositShares;
        address deprecatedWithdrawer;
    }

    function queueWithdrawals(QueuedWithdrawalParams[] calldata params) external returns (bytes32[] memory);
    function completeQueuedWithdrawal(Withdrawal calldata withdrawal, address[] calldata tokens, bool receiveAsTokens)
        external;
    function getQueuedWithdrawals(address staker)
        external
        view
        returns (Withdrawal[] memory withdrawals, uint256[][] memory shares);
    function minWithdrawalDelayBlocks() external view returns (uint32);
}

/// @notice EigenLayer's stETH strategy, the largest stETH holder outside Lido's own contracts. Deposits go through
///         the StrategyManager; exits are queued in the DelegationManager and completed after its delay.
contract EigenLayerStETHStrategy is StETHIntegrationChecks {
    IStrategyManager internal constant MANAGER = IStrategyManager(0x858646372CC42E1A627fcE94aa7A7033e7CF075A);
    IDelegationManager internal constant DELEGATION = IDelegationManager(0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A);
    address internal constant STRATEGY = 0x93c4b944D05dfe6df7645A86cd2206016c51564D;

    function _holder() internal pure override returns (address) {
        return STRATEGY;
    }

    function _deposit(address user, uint256 amount) internal override {
        vm.startPrank(user);
        STETH.approve(address(MANAGER), amount);
        MANAGER.depositIntoStrategy(STRATEGY, address(STETH), amount);
        vm.stopPrank();
    }

    function _claim(address user) internal view override returns (uint256) {
        return IStrategy(STRATEGY).sharesToUnderlyingView(MANAGER.stakerDepositShares(user, STRATEGY));
    }

    function _exit(address user) internal override {
        address[] memory strategies = new address[](1);
        strategies[0] = STRATEGY;
        uint256[] memory shares = new uint256[](1);
        shares[0] = MANAGER.stakerDepositShares(user, STRATEGY);
        IDelegationManager.QueuedWithdrawalParams[] memory params = new IDelegationManager.QueuedWithdrawalParams[](1);
        params[0] = IDelegationManager.QueuedWithdrawalParams(strategies, shares, user);
        vm.prank(user);
        DELEGATION.queueWithdrawals(params);

        vm.roll(block.number + DELEGATION.minWithdrawalDelayBlocks() + 1);
        (IDelegationManager.Withdrawal[] memory queued,) = DELEGATION.getQueuedWithdrawals(user);
        address[] memory tokens = new address[](1);
        tokens[0] = address(STETH);
        vm.prank(user);
        DELEGATION.completeQueuedWithdrawal(queued[0], tokens, true);
    }
}
