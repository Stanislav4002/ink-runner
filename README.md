# Ink Runner

A paid arcade runner on Ink. One ETH fee per run, the whole pot goes to the top 10 of each round.

Chain: Ink mainnet, chain ID **57073**, RPC `https://rpc-gel.inkonchain.com`, explorer `https://explorer.inkonchain.com`.

---

## 1. Pick the entry fee

The contract stores the fee in wei, so you set it once at deploy and adjust it later when ETH moves.

| ETH price | ~$1 in ETH | value for the constructor |
|---|---|---|
| $2,000 | 0.0005 | `500000000000000` |
| $2,400 | 0.000417 | `417000000000000` |
| $3,000 | 0.000333 | `333000000000000` |

Round duration is in seconds. One week is `604800`.

## 2. Deploy with Remix

1. Open [remix.ethereum.org](https://remix.ethereum.org), create `InkRunner.sol`, paste the contract.
2. Compiler tab: select **0.8.24** or newer, enable optimization (200 runs), compile.
3. Deploy tab: Environment → **Injected Provider**. Make sure the wallet is on Ink.
4. Constructor arguments: `_entryFee` from the table, `_roundDuration` = `604800`.
5. Deploy, confirm, copy the contract address.
6. Optional but worth it: verify the source on the explorer so people can read it.

## 3. Wire up the front end

In `index.html`, replace:

```js
const CONTRACT = "0xYOUR_CONTRACT_ADDRESS";
```

Then host the file anywhere static — GitHub Pages, Vercel, Netlify. It is a single file with no build step.

The page needs an injected wallet, so it will not work inside an iframe preview. Open it on its own domain, or in a wallet's in-app browser on mobile.

## 4. Run a round

- Players press **Pay & play**, which calls `startRun()` and pays the fee.
- The level is generated from the seed in the `RunStarted` event, so every run is different and reproducible.
- On game over the client calls `submitScore(runId, score, jumps)`. The full jump timeline lands in the event log.
- When the timer hits zero **anyone** can call `finalizeRound()`. The pot is credited to the top 10 by weight.
- Winners call `claim()` themselves. Nothing is pushed, so a failing address cannot block the round.

Payout weights: 30 / 20 / 12 / 10 / 8 / 6 / 5 / 4 / 3 / 2 percent. If fewer than ten people played, the unallocated share rolls into the next round's pot.

## 5. Admin functions

| Function | What it does |
|---|---|
| `setEntryFee(wei)` | Adjust the fee as ETH moves |
| `setRoundDuration(seconds)` | Change round length, minimum 1 hour |
| `setPaused(bool)` | Stop new runs; submissions and claims still work |
| `transferOwnership(address)` | Hand over control |
| `sweepUnaccounted(address)` | Recover ETH sent to the contract by accident. It cannot touch the pot or anyone's winnings — those are tracked separately |

## Known limits — say these out loud when you post it

**Scores come from the client.** Anyone who opens devtools can call `submitScore` with a fake number. There is a hard cap of 100,000, and the jump timeline is stored so a cheat is provable after the fact, but nothing stops it at the moment of submission. For a toy with a small pot that is an acceptable trade. For anything bigger you would verify the run by replaying the input sequence against the seed.

**The seed uses `blockhash`.** Good enough to make levels unpredictable, not good enough to be a randomness source for anything valuable.

**One run, one fee.** There is no free mode. If you want people to try before paying, add a practice button that skips the contract entirely and does not touch the leaderboard.
