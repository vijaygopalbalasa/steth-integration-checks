// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

interface IStETH {
    function submit(address referral) external payable returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function sharesOf(address account) external view returns (uint256);
    function getPooledEthByShares(uint256 sharesAmount) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Checks taken from Lido's stETH and wstETH integration guide
///         (https://docs.lido.fi/guides/lido-tokens-integration-guide), run unchanged against any contract that
///         takes stETH deposits. A target says how to deposit, how to read a depositor's claim in stETH and how to
///         exit; the checks assume nothing else about it. Everything runs on a fork of Ethereum mainnet. A rebase
///         is made by moving the consensus-layer validator balance that Lido itself reads to price stETH (the
///         number a daily oracle report updates), so every share's value moves exactly as in a report; unlike a
///         report it mints no fee shares.
///           ETH_RPC=<mainnet RPC that serves block 26277000> forge test -vv
///         Without ETH_RPC every check is reported as skipped, never as a pass.
abstract contract StETHIntegrationChecks is Test {
    IStETH internal constant STETH = IStETH(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
    uint256 internal constant FORK_BLOCK = 26_277_000; // Oct 26 2026
    /// Lido packs the consensus-layer validator balance (low 128 bits) with the pending balance (high 128 bits).
    bytes32 internal constant CL_BALANCES_SLOT = keccak256("lido.Lido.clValidatorsBalanceAndClPendingBalance");
    /// The guide's corner case: a transfer can arrive 1 or 2 wei short because balances are derived from shares.
    uint256 internal constant WEI_TOLERANCE = 2;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    bool internal ready;

    // ───────────── what each target provides ─────────────

    /// The contract whose stETH balance holds the deposits.
    function _holder() internal view virtual returns (address);
    /// Approve and deposit `amount` stETH as `user`.
    function _deposit(address user, uint256 amount) internal virtual;
    /// What the target owes `user`, in stETH, as the target itself reports it.
    function _claim(address user) internal view virtual returns (uint256);
    /// Withdraw everything `user` holds in the target back to `user` as stETH.
    function _exit(address user) internal virtual;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, FORK_BLOCK);
        _setUpTarget();
        ready = true;
    }

    /// Deploy or configure the target on the fork, if it needs it.
    function _setUpTarget() internal virtual {}

    modifier onFork() {
        vm.skip(!ready);
        _;
    }

    // ───────────── helpers ─────────────

    /// Stake ETH with Lido as `user`; returns the stETH it got.
    function _fund(address user, uint256 eth) internal returns (uint256) {
        vm.deal(user, eth);
        vm.prank(user);
        STETH.submit{value: eth}(address(0));
        return STETH.balanceOf(user);
    }

    function _shareRate() internal view returns (uint256) {
        return STETH.getPooledEthByShares(1e27);
    }

    /// Move the validator balance by `ppm` parts per million (negative for a loss) and check the share rate moved.
    function _rebase(int256 ppm) internal {
        uint256 packed = uint256(vm.load(address(STETH), CL_BALANCES_SLOT));
        uint256 validators = packed & type(uint128).max;
        uint256 delta = validators * uint256(ppm < 0 ? -ppm : ppm) / 1e6;
        uint256 moved = ppm < 0 ? validators - delta : validators + delta;
        uint256 rateBefore = _shareRate();
        vm.store(address(STETH), CL_BALANCES_SLOT, bytes32((packed >> 128) << 128 | moved));
        if (ppm < 0) assertLt(_shareRate(), rateBefore, "the loss did not lower the share rate");
        else assertGt(_shareRate(), rateBefore, "the rewards did not raise the share rate");
    }

    /// stETH that reached the holder during a deposit, measured in shares so the measure adds no rounding of its own.
    function _arrivedDuring(uint256 sharesBefore) internal view returns (uint256) {
        return STETH.getPooledEthByShares(STETH.sharesOf(_holder()) - sharesBefore);
    }

    function _claimFollowsTheRate(int256 ppm) internal {
        _deposit(alice, _fund(alice, 10 ether));
        uint256 claimBefore = _claim(alice);
        uint256 rateBefore = _shareRate();
        _rebase(ppm);
        uint256 expected = claimBefore * _shareRate() / rateBefore;
        uint256 claimAfter = _claim(alice);
        emit log_named_uint("claim before (wei)", claimBefore);
        emit log_named_uint("claim after (wei)", claimAfter);
        emit log_named_uint("claim if it followed the rate (wei)", expected);
        assertApproxEqAbs(claimAfter, expected, WEI_TOLERANCE, "the depositor's claim did not follow the rebase");
    }

    function _everyoneExits(int256 ppm) internal {
        address[3] memory users = [alice, bob, carol];
        uint256[3] memory eth = [uint256(1 ether + 1), 7.777777777777777777 ether, 0.123456789123456789 ether];
        for (uint256 i; i < 3; ++i) {
            _deposit(users[i], _fund(users[i], eth[i]));
        }
        _rebase(ppm);
        for (uint256 i; i < 3; ++i) {
            uint256 claim = _claim(users[i]);
            uint256 before = STETH.balanceOf(users[i]);
            _exit(users[i]);
            uint256 got = STETH.balanceOf(users[i]) - before;
            emit log_named_uint("claim (wei)", claim);
            emit log_named_uint("received on exit (wei)", got);
            assertGe(got + WEI_TOLERANCE, claim, "an exit returned less than the claim");
        }
    }

    // ───────────── the checks ─────────────

    /// Guide, "1-2 wei corner case": a deposit must not be credited with more stETH than actually arrived.
    function test_creditNeverExceedsWhatArrived() public virtual onFork {
        uint256 amount = _fund(alice, 3.333333333333333333 ether);
        uint256 sharesBefore = STETH.sharesOf(_holder());
        uint256 claimBefore = _claim(alice);
        _deposit(alice, amount);
        uint256 arrived = _arrivedDuring(sharesBefore);
        uint256 credited = _claim(alice) - claimBefore;
        emit log_named_uint("deposited (wei)", amount);
        emit log_named_uint("arrived (wei)", arrived);
        emit log_named_uint("credited (wei)", credited);
        assertLe(credited, arrived, "credited more stETH than arrived");
    }

    /// Guide, "rebasing" and "share-based accounting": rewards reach the depositor (+100 ppm, about a day of them).
    function test_rewardsReachTheDepositor() public virtual onFork {
        _claimFollowsTheRate(100);
    }

    /// Guide, "negative rebases": a loss reaches the depositor too, instead of falling on whoever exits last.
    function test_lossesReachTheDepositor() public virtual onFork {
        _claimFollowsTheRate(-1_000);
    }

    /// Three depositors with odd amounts, a day of rewards, then everyone exits with their claim.
    function test_everyDepositorCanExitAfterRewards() public virtual onFork {
        _everyoneExits(100);
    }

    /// The same after a 0.1 percent loss: the last exit must not revert or come up short.
    function test_everyDepositorCanExitAfterALoss() public virtual onFork {
        _everyoneExits(-1_000);
    }
}
