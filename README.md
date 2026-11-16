# LastPing

## A dead-man's switch that listens for silence

LastPing protects crypto against a very ordinary failure: the only person who
can move it stops showing up. The owner places assets in a vault and proves
they are still present by sending a lightweight **ping**. If those pings stop,
a Reactive Smart Contract notices the missing signal, opens a public grace
period, and gives the owner one last chance to cancel. Only after that second
deadline passes does the vault release everything to the beneficiary chosen in
advance.

There is no custodian to trust and no keeper service to keep alive. The
important event is not a transaction that arrives; it is the transaction that
does **not** arrive.

> **Demo video:** [`demo-video.mp4`](demo-video.mp4) shows the complete live
> cycle in under three minutes: arming, a trigger, a last-minute save, a
> second trigger, and release.

## Why Reactive is the missing piece

An ordinary vault can react when somebody calls it, but it cannot wake itself
up merely because time passed and an expected check-in never appeared.
LastPing's watcher lives on Reactive Lasna and combines two subscriptions:

1. `Ping` events from `Heartbeat` on Base Sepolia update the owner's
   last-seen time.
2. `Cron100` ticks repeatedly let the watcher compare that stored time with
   the present.

When the inactivity limit is crossed, the watcher requests a callback to Base
Sepolia. When a ping arrives during the grace period, it requests the opposite
callback and stands the vault down. After a successful release, it removes its
own CRON subscription so it does not continue consuming fees for a finished
job.

## Live deployment

The system is deployed on Base Sepolia (chain ID `84532`) and Reactive Lasna
(chain ID `5318007`). Base Sepolia is both the origin and destination chain.

| Contract | Network | Address |
| --- | --- | --- |
| `Heartbeat` | Base Sepolia | [`0x4FBe7f95F7BBAf3598DCFB11c563d3a9881bdE29`](https://sepolia.basescan.org/address/0x4FBe7f95F7BBAf3598DCFB11c563d3a9881bdE29) |
| `MockERC20` — Test USD (`tUSD`, 6 decimals) | Base Sepolia | [`0x3f1558963cb84012aa7a2f35541c9b7435939ed5`](https://sepolia.basescan.org/address/0x3f1558963cb84012aa7a2f35541c9b7435939ed5) |
| `SwitchVault` | Base Sepolia | [`0xf3584B57db27988179869c2651e6a328C86deDf3`](https://sepolia.basescan.org/address/0xf3584B57db27988179869c2651e6a328C86deDf3) |
| `LastPingReactive` | Reactive Lasna | [`0x33ef98c3f866451893606ee54b18e0100a40fc0f`](https://lasna.reactscan.net/address/0x33ef98c3f866451893606ee54b18e0100a40fc0f) |

Deployment context:

| Item | Value |
| --- | --- |
| Owner / deployer | `0xc6c7cEB4D6E5808947d163cA2a41C7c468697643` |
| Beneficiary | `0xc8B2CC3AD7E08926cf7746d8B068cCB53726A405` |
| Base Sepolia callback proxy | `0x476F44b11F5C942c58f4c8E3d0300E5710743585` |
| Reactive system contract | `0x8888888888888888888888888888888888888888` |
| Reactive faucet contract on Base Sepolia | `0x2afaFD298b23b62760711756088F75B7409f5967` |

Deployment transactions:

| Deployment | Transaction |
| --- | --- |
| `Heartbeat` | [`0x6af5524b298cd2b9bd89e118070a952ca2dcc59500867a82ea3c4ae3d0fc1d8c`](https://sepolia.basescan.org/tx/0x6af5524b298cd2b9bd89e118070a952ca2dcc59500867a82ea3c4ae3d0fc1d8c) |
| `MockERC20` | [`0x672ed618a089729370eeaf821b72156393b31add0c713dcffbe641329c000b46`](https://sepolia.basescan.org/tx/0x672ed618a089729370eeaf821b72156393b31add0c713dcffbe641329c000b46) |
| `LastPingReactive` | [`0x7e928fe71254176adbc7d135e5d04d7d513214c3b00da7942f7e5163c27e1f0e`](https://lasna.reactscan.net/tx/0x7e928fe71254176adbc7d135e5d04d7d513214c3b00da7942f7e5163c27e1f0e) |
| `SwitchVault` | [`0x230fc702e19d561230fe135bb0e19a6ff36f45ea3b4a1417b776091d33910a94`](https://sepolia.basescan.org/tx/0x230fc702e19d561230fe135bb0e19a6ff36f45ea3b4a1417b776091d33910a94) |
| Watcher linked to vault (`setVault`) | [`0xfc826a25173433efb24ded987e1ee0c660a2ef95e8696e92f6b165b5d19baffe`](https://lasna.reactscan.net/tx/0xfc826a25173433efb24ded987e1ee0c660a2ef95e8696e92f6b165b5d19baffe) |

## Complete live-loop evidence

The following transactions are the canonical run executed on 16 November
2026. Together they cover the whole origin → Reactive → callback path.

| Phase | Chain | What happened | Transaction |
| --- | --- | --- | --- |
| Conversion | Base Sepolia | Sent `0.05 ETH` to the Reactive faucet contract; `5 lREACT` was credited to the owner on Lasna | [`0x24d83c3b5d8b76dac00ab02512513b37a340494f75fceed34e87a675cf563a72`](https://sepolia.basescan.org/tx/0x24d83c3b5d8b76dac00ab02512513b37a340494f75fceed34e87a675cf563a72) |
| Reserves | Lasna | Funded the watcher's system-contract reserves with `4 lREACT` via `depositTo` | [`0x50ef74f3e878000b7f50111de864cfa95cf4efe122dfd827fcf7b7e80bf8658e`](https://lasna.reactscan.net/tx/0x50ef74f3e878000b7f50111de864cfa95cf4efe122dfd827fcf7b7e80bf8658e) |
| Reserves | Base Sepolia | Funded the vault's callback-proxy reserves with `0.01 ETH` via `depositTo` | [`0xfe20897bae4725cfb778b44824900ddb4f77cf0aeed449b40bae96246c573f9b`](https://sepolia.basescan.org/tx/0xfe20897bae4725cfb778b44824900ddb4f77cf0aeed449b40bae96246c573f9b) |
| Arm | Base Sepolia | Registered the beneficiary in `Heartbeat` | [`0xdd10d1780028535418d4258a44fb111c17b97c34ab29093c623e73f6a6cb11dc`](https://sepolia.basescan.org/tx/0xdd10d1780028535418d4258a44fb111c17b97c34ab29093c623e73f6a6cb11dc) |
| Arm | Base Sepolia | Deposited `0.02 ETH` into `SwitchVault` | [`0x7ec8091e82b195834119b801926a56b28fa8254cdc16db9ce698f0c0f4537c53`](https://sepolia.basescan.org/tx/0x7ec8091e82b195834119b801926a56b28fa8254cdc16db9ce698f0c0f4537c53) |
| Arm | Base Sepolia | Approved the vault to receive `500 tUSD` | [`0x37770a0673877660e8056eb82637bc24732f809d8865e6a80dd514fa8ad583ab`](https://sepolia.basescan.org/tx/0x37770a0673877660e8056eb82637bc24732f809d8865e6a80dd514fa8ad583ab) |
| Arm | Base Sepolia | Deposited `500 tUSD` into `SwitchVault` | [`0x731dd43f798490bfbd5a2af7010276000cfbb86122115f12e244405b18b75f85`](https://sepolia.basescan.org/tx/0x731dd43f798490bfbd5a2af7010276000cfbb86122115f12e244405b18b75f85) |
| Arm | Base Sepolia | Sent the arming ping; both vault and watcher entered `Armed` | [`0xf69acce443fa0805e36e31c5750aa688e3cbef2a7490b767d9a78513412cc737`](https://sepolia.basescan.org/tx/0xf69acce443fa0805e36e31c5750aa688e3cbef2a7490b767d9a78513412cc737) |
| Trigger #1 | Lasna | A Cron100 reaction detected 365 seconds without a ping and emitted `TriggerRequested` | [`0xc3088661e72bc0fae7777d649ce2f6ea5e24b9cc9720814137f093ef3e8697dd`](https://lasna.reactscan.net/tx/0xc3088661e72bc0fae7777d649ce2f6ea5e24b9cc9720814137f093ef3e8697dd) |
| Trigger #1 | Base Sepolia | The `triggerSwitch` callback put the vault into `Triggered` and started its own 180-second grace clock | [`0xc83a3828dbd7f7081e53fa2ea07f7baa82ac7af001fd55c6f210c1a08f7b6d2a`](https://sepolia.basescan.org/tx/0xc83a3828dbd7f7081e53fa2ea07f7baa82ac7af001fd55c6f210c1a08f7b6d2a) |
| Cancel by ping | Base Sepolia | The owner pinged 44 seconds into the grace period | [`0x8718537fc5849cdb5872bcc6840bbd8ce6f899390ead20ff92613c9e725ad75e`](https://sepolia.basescan.org/tx/0x8718537fc5849cdb5872bcc6840bbd8ce6f899390ead20ff92613c9e725ad75e) |
| Cancel by ping | Lasna | The watcher emitted `CancelRequested` | [`0x351ab09989f2f54406dbda005ed5ff62684a8b9ac2d0a354abe9caecac2f37a0`](https://lasna.reactscan.net/tx/0x351ab09989f2f54406dbda005ed5ff62684a8b9ac2d0a354abe9caecac2f37a0) |
| Cancel by ping | Base Sepolia | The `cancelTrigger` callback returned the vault to `Armed` | [`0x6a8fe667035b2016a33f31f7eddc223d3c725e320dbca4adc7ad4e23a94d7001`](https://sepolia.basescan.org/tx/0x6a8fe667035b2016a33f31f7eddc223d3c725e320dbca4adc7ad4e23a94d7001) |
| Trigger #2 | Lasna | After another 386 seconds of silence, the watcher emitted the second `TriggerRequested` | [`0x2fcd6661477db0f247e235ea5db6d869ac8fe4d5182415eae651fbfadae8e960`](https://lasna.reactscan.net/tx/0x2fcd6661477db0f247e235ea5db6d869ac8fe4d5182415eae651fbfadae8e960) |
| Trigger #2 | Base Sepolia | The second `triggerSwitch` callback restarted the vault's grace period | [`0xa9391388f1f83d19c64701e585114daed4da8a2353e5f27b01d6d8ef093b6786`](https://sepolia.basescan.org/tx/0xa9391388f1f83d19c64701e585114daed4da8a2353e5f27b01d6d8ef093b6786) |
| Release | Lasna | Once the watcher's grace period elapsed, it emitted `ReleaseRequested` | [`0x741b097658f256465f3f576da9bfe7d8030360a949a0cd252861bbc1bed6a602`](https://lasna.reactscan.net/tx/0x741b097658f256465f3f576da9bfe7d8030360a949a0cd252861bbc1bed6a602) |
| Release | Base Sepolia | The `release` callback landed after the vault's own deadline; the vault paid the beneficiary and became inert | [`0x44ba0c82f3b1ab8852bdd34a59954aeff9e1b7a1b3409cf73cb4c1254701db80`](https://sepolia.basescan.org/tx/0x44ba0c82f3b1ab8852bdd34a59954aeff9e1b7a1b3409cf73cb4c1254701db80) |

## Final state

| Account or contract | Final reading |
| --- | --- |
| Beneficiary | `0.020000 ETH` + `500.000000 tUSD` received |
| `SwitchVault` | `0 ETH`, `0 tUSD`, phase `Released` |
| Owner on Base Sepolia | `0.019982284746186330 ETH` |
| Owner on Lasna | `0.744045499998440455 lREACT` |
| Owner's remaining `tUSD` | `500.000000 tUSD` |
| `LastPingReactive` | Phase `Released`; `cronSubscribed = false`; contract balance `0.0763473 lREACT` |

Fee-payment readouts after the run:

| Payment point | Reserves | Debt | Consumed |
| --- | ---: | ---: | ---: |
| Reactive system contract for the watcher | `3.8462046 lREACT` | `0` | Approximately `0.1537954 lREACT` |
| Base Sepolia callback proxy for the vault | `0.009996454183550999 ETH` | `0` | Approximately `0.0000035 ETH` |

## Architecture

```text
Base Sepolia                                      Reactive Lasna
-------------                                     --------------

Owner ── ping() ──> Heartbeat ── Ping log ──────> LastPingReactive
                    │                                  │
                    │                                  │ Cron100:
                    │                                  │ compare now
                    │                                  │ with lastPingAt
                    │                                  │
SwitchVault <───────┴──────── callback ────────────────┘
    │
    └── after vault-side grace check ──> Beneficiary
```

### `Heartbeat`

A small proof-of-life register. Calling `ping()` emits
`Ping(owner, at)`. Registration also records the intended beneficiary so the
watcher can learn that a switch exists.

### `LastPingReactive`

An `AbstractReactive` contract that stores `lastPingAt`, the timing
configuration, and the current phase. It handles three decisions:

- a ping while `Armed` refreshes the deadline;
- a ping while `Triggered` requests cancellation;
- CRON reactions request first the trigger and later the release.

### `SwitchVault`

An `AbstractCallback` contract that holds ETH and the demo ERC-20. Its state
machine is `Armed → Triggered → Released`, with cancellation returning it to
`Armed`. The vault does not release merely because the watcher asks: before
paying, it checks its own `triggeredAt + gracePeriod` deadline. Callback entry
points are restricted to the Reactive callback proxy and to this project's
watcher.

### Safety properties

- **A trigger is not a transfer.** The grace period creates a public,
  reversible warning state.
- **Any ping during grace cancels.** A temporary loss of access does not have
  to become a permanent release.
- **The vault keeps its own clock.** A faulty or premature release request
  cannot bypass the vault-side deadline.
- **The beneficiary is passive.** They cannot trigger, accelerate, or redirect
  the release.
- **The watcher stops billing itself.** After release it unsubscribes from
  CRON instead of paying for ticks forever.

## Demo parameters and funding disclosure

The live demonstration deliberately used short periods and a small testnet
budget:

| Parameter | Live value |
| --- | ---: |
| Inactivity period | `300 seconds` |
| Grace period | `180 seconds` |
| Watcher schedule | `Cron100` |
| ETH deposited in the vault | `0.02 ETH` |
| `tUSD` deposited in the vault | `500 tUSD` |
| Base Sepolia ETH converted to lREACT | `0.05 ETH → 5 lREACT` |
| Watcher reserves | `4 lREACT` |
| Vault callback reserves | `0.01 ETH` |
| Watcher funding at deployment | `0.1 lREACT` |

These are constructor and funding choices, not separate demo logic. A real
deployment should choose far longer owner-specific periods and a less frequent
CRON schedule to reduce ongoing tick costs. The token is a mock ERC-20 created
for this testnet demonstration.

## Run the tests

The repository vendors its Foundry dependencies under `lib/`, so no Git
submodule step is required.

Prerequisite: Foundry.

```bash
forge build
forge test
```

Expected result:

```text
Ran 4 test suites: 32 tests passed, 0 failed, 0 skipped (32 total tests)
```

The suites cover each contract separately and an end-to-end lifecycle test:
arming, absence detection, trigger, cancellation by ping, a second trigger,
and release.

## Project layout

```text
src/
  Heartbeat.sol          Proof-of-life events
  LastPingReactive.sol   Reactive watcher and phase logic
  SwitchVault.sol        Custody, grace enforcement, and release
  MockERC20.sol          Testnet demonstration token
  IERC20.sol             Minimal token interface
test/
  Heartbeat.t.sol
  LastPingReactive.t.sol
  SwitchVault.t.sol
  Lifecycle.t.sol        Full state-machine integration coverage
  mocks/MockSystemContract.sol
lib/
  forge-std/             Vendored test dependency
  reactive-lib-omni/     Vendored Reactive Omni library
```

## License

Released under the [MIT License](LICENSE).
