# stETH integration checks

Foundry checks taken from Lido's [stETH and wstETH integration guide](https://docs.lido.fi/guides/lido-tokens-integration-guide),
run unchanged against any contract that takes stETH deposits. A target tells the checks how to deposit, how to
read a depositor's claim in stETH and how to exit. The checks assume nothing else about it.

Everything runs on a fork of Ethereum mainnet. A rebase is made by moving the consensus-layer validator balance that
Lido itself reads to price stETH (the number a daily oracle report updates), so every share's value moves the way it
does after a report.

## The checks

| Check | From the guide | Passes when |
|---|---|---|
| `test_creditNeverExceedsWhatArrived` | 1-2 wei corner case | a deposit is never credited with more stETH than actually arrived |
| `test_rewardsReachTheDepositor` | rebasing, share-based accounting | after +100 ppm (about a day of rewards) the claim follows stETH's share rate within 2 wei |
| `test_lossesReachTheDepositor` | negative rebases | after a 0.1 percent loss the claim follows the share rate down, instead of the loss landing on whoever exits last |
| `test_everyDepositorCanExitAfterRewards` | share-based accounting | three depositors with odd amounts all exit with their claim, within 2 wei |
| `test_everyDepositorCanExitAfterALoss` | negative rebases | the same after the loss, and the last exit does not revert |

## Results on mainnet (fork at block 26,277,000, Oct 26 2026)

| Target | Address | Result |
|---|---|---|
| wstETH (Lido's wrapper, the reference) | `0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0` | 5 of 5 pass |
| EigenLayer stETH strategy (via StrategyManager and DelegationManager) | `0x93c4b944D05dfe6df7645A86cd2206016c51564D` | 5 of 5 pass |

Both credit what arrived or 1 wei less, follow the share rate to the wei, and return every claim on exit within 1 wei.

## The checks check themselves

`test/SelfCheck.t.sol` deploys a vault that makes the mistake the guide warns about: it books stETH amounts instead
of shares and credits the amount it was asked to pull. It must fail four checks, each for its own reason, and it does:

- credit: it books 1 wei more than arrived;
- rewards: the claim stays flat while stETH grows, so the rewards are stuck in the vault;
- losses: the claim stays flat while stETH shrinks;
- exit after a loss: stETH refuses the last withdrawal (`BALANCE_EXCEEDED`), because the vault holds less than it booked.

It passes the fifth (everyone exits after rewards) because the stuck rewards do not stop anyone leaving. The rewards
check is the one that catches that.

## Run it

```bash
forge build
ETH_RPC=<mainnet RPC that serves block 26277000> forge test -vv   # https://eth.drpc.org worked on Oct 26 2026
forge test                                                          # without ETH_RPC every check is reported as skipped
```

## Add an integration

Write a contract in `test/` that inherits `StETHIntegrationChecks` and implements four functions: `_holder()` (the
contract that ends up holding the stETH), `_deposit(user, amount)`, `_claim(user)` (what the target says it owes the
user, in stETH) and `_exit(user)`. `test/Targets.t.sol` has two examples. The checks never change per integration.

## Limits

- The rebase moves the validator balance directly; unlike a real oracle report it mints no fee shares and does not
  finalize withdrawals. Share-based accounting cannot tell the difference, which is what the checks test.
- Five items of the guide are covered. Not yet: withdrawal-queue requests and their NFTs, the permit front-running
  fallback, bridged wstETH and its rate feeds on L2s, stake-limit handling, and the absence of `Transfer` events on
  rebase.
- A pass means the integration behaved as the guide describes at this block for these amounts. It is not an audit.

MIT licence.
