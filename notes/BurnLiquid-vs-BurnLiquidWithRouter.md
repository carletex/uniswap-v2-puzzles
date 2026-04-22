# `BurnLiquid` vs `BurnLiquidWithRouter`

The inverse of the add-liquidity puzzles. You return LP tokens and the pair
pays you back a pro-rata slice of both reserves. Same two-layer split: Pair
(bare metal) vs Router (ergonomic wrapper).

## Core mental model

A Uniswap V2 pair **is** an ERC20 (name `"Uniswap V2"`, symbol `"UNI-V2"`).
Holding LP tokens = holding shares in that pair. Burning them = redeeming
shares. The payout is fully symmetric:

```
amount0 = liquidity * reserve0 / totalSupply
amount1 = liquidity * reserve1 / totalSupply
```

Two outputs from one input, same `liquidity` on both sides → you **can't be
off-ratio**. That's why, unlike the add case, no pre-math is needed.

## `BurnLiquid.sol` — Pair directly

The pair has no `burnFrom` / `amount` arg. `burn(to)` decides how much to
burn by reading its **own** `balanceOf(address(this))` — the LP tokens
sitting inside itself. So the flow is always:

1. `pair.transfer(pair, liquidity)` — physically deliver LP tokens to the pair.
2. `pair.burn(recipient)` — pair reads its LP balance, burns it, sends out
   `amount0` + `amount1` to `recipient`.

Skip step 1 and you'll hit `require(amount0 > 0 && amount1 > 0,
"INSUFFICIENT_LIQUIDITY_BURNED")` — a silent no-op is not possible.

Why this design? The pair has no allowance plumbing for its own LP token
(no `burnFrom`). It trusts what's inside itself at execution time, just like
`mint` trusts its token0/token1 balances. Same self-custodial pattern.

## `BurnLiquidWithRouter.sol` — Router

Mirror of `AddLiquidWithRouter`: `transfer` becomes `approve` + the router
pulls. Plus the usual ergonomic wins.

1. `pair.approve(router, liquidity)` — pair contract IS the LP ERC20.
2. `router.removeLiquidity(tokenA, tokenB, liquidity, minA, minB, to, deadline)`
3. Inside the router:
   - `pair.transferFrom(you, pair, liquidity)` — pulls LP into the pair.
   - `pair.burn(to)` — pair burns and sends underlying to `to`.

Plus: slippage floors, a deadline, automatic token sorting, and pair lookup
via the factory (you pass `(tokenA, tokenB)`, not a pool address).

## The "who calls transferFrom" rule

Same gotcha as in the add puzzles. In `AddLiquidWithRouter` you approved
**USDC to the router**, even though USDC ends up in the pair. Here you
approve **LP tokens to the router**, even though the LP tokens end up in the
pair (where they get burned).

**Rule of thumb:** whoever calls `transferFrom` is who you approve. The final
destination doesn't matter for the allowance — the mover does.

## Why min amounts for a burn?

Burning is symmetric — you can't be off-ratio — but the **ratio itself** can
move between signing and mining (other LPs add/remove, swaps happen). That
shifts how much of each token you get per LP. `amountAMin` / `amountBMin`
bound the worst ratio you'll accept. On mainnet: ~99.5% of expected per side;
in these puzzles we pass `1`.

Burns aren't easily sandwich-attackable (an attacker can't force a
profitable skew), so the floors here are mostly protection against honest
slippage from other LPs in the same block.

## TL;DR

| Concern             | `BurnLiquid` (Pair directly)     | `BurnLiquidWithRouter`                |
| ------------------- | -------------------------------- | ------------------------------------- |
| LP token movement   | `transfer` to pair               | `approve`, router `transferFrom`s     |
| Ratio math          | N/A (symmetric)                  | N/A (symmetric)                       |
| Pair lookup         | You pass pool address            | Router derives from `(tokenA, tokenB)` |
| Token ordering      | You deal with token0 / token1    | Router sorts + un-sorts for you       |
| Slippage / deadline | None                             | `amountAMin` / `amountBMin` + deadline |
| Gas                 | Cheaper                          | A bit more (extra hop, checks)        |

## Lending bridge

LP tokens = vault shares. Burn = withdraw, pro-rata. Twist: **two** underlying
assets, not one, and the pair has no `withdrawFrom` — you deliver shares by
ERC20 `transfer` or by approving the router.

- Pair-direct ↔ `aToken.transfer(pool)` then `pool.withdraw()` yourself.
- Router ↔ `poolManager.withdraw(shares, to)`: handles plumbing + guards.

## Mental symmetry with Add

Add and Burn are structurally the same puzzle twice:

|                    | Add                                  | Burn                                |
| ------------------ | ------------------------------------ | ----------------------------------- |
| Direction          | Two tokens in → LP minted            | LP in → two tokens out              |
| Ratio math?        | Yes (you must match pool ratio)      | No (symmetric, one input)           |
| Pair reads…        | Its own token0/token1 balances       | Its own LP balance                  |
| Bare-metal delivery| `transfer` both tokens to pair       | `transfer` LP to pair               |
| Router delivery    | `approve` both tokens, router pulls  | `approve` LP, router pulls          |

Once the self-custodial "pair reads its own balance" pattern clicks, every
pair-level function in V2 (`mint`, `burn`, `swap`) is the same shape.
