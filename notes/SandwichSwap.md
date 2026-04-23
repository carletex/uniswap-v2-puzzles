# `SandwichSwap`

## TL;DR

Victim broadcasts a big WETH→USDC swap with `amountOutMin = 0`. Attacker
runs the same swap **before** them (pushing the price up), lets the victim
execute at the worsened rate, then swaps USDC→WETH **after** (at the now
overshot price). Profit = the victim's slippage.

## Top-down

The `x*y=k` curve is fixed. The *point on the curve* isn't — it depends on
who traded before you. An AMM is **order-dependent** state, unlike a lending
pool where deposit order doesn't matter. Public mempool + no slippage guard
= the attacker picks their execution position twice, sandwiching the victim.

## Numerical walkthrough

Toy pool: **50,000 WETH / 150,000,000 USDC** → mid price 3,000 USDC/WETH,
`k = 7.5e12`. Fees ignored for arithmetic clarity.

| Step        | Action                    | Reserves after (WETH / USDC)         | Got out          |
| ----------- | ------------------------- | ------------------------------------ | ---------------- |
| 0. Start    | —                         | 50,000 / 150,000,000                 | —                |
| 1. Frontrun | Attacker swaps +1,000 WETH| 51,000 / 147,058,823                 | **2,941,176 USDC** |
| 2. Victim   | Victim swaps +1,000 WETH  | 52,000 / 144,230,769                 | 2,828,054 USDC   |
| 3. Backrun  | Attacker swaps +2,941,176 USDC | 50,960.8 / 147,171,945          | **1,039.2 WETH** |

**Attacker**: in 1,000 WETH → out 1,039.2 WETH → **+39.2 WETH profit** (~3.9%).

**Victim**: would've gotten 2,941,176 USDC without the sandwich, got
2,828,054 instead → **−113,122 USDC** (≈ 37.7 WETH at mid). That's where the
attacker's profit comes from — the difference is absorbed by the extra
slippage the victim paid.

## Code shape

Both legs are `swapExactTokensForTokens` calls from the `Attacker` contract:

- `frontrun`: approve WETH → swap all WETH for USDC.
- `backrun`: approve USDC → swap all USDC for WETH.

## Defenses (what the victim should've done)

- `amountOutMin > 0` — the one-line fix. Revert if price moved too far.
- Private mempool (Flashbots Protect / MEV-Share) — hide the intent.
- Split big swaps or route across pools.
