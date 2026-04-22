# `SimpleSwap` vs `SimpleSwapWithRouter`

First puzzle that hits the **AMM math**, not just accounting. Add/Burn were
deposits and withdrawals; swaps price-discover against the `x*y=k` curve.

## The core idea: constant product

A V2 pair holds `reserve0` and `reserve1`. It enforces
`reserve0 * reserve1 = k` across every swap (new k must be ≥ old k). That
single rule does a lot of work:

- Defines a **price curve**, not a flat price — marginal price is
  `reserveOut / reserveIn`.
- Creates **slippage**: each unit you buy pushes the next unit's price up.
  Big swaps eat themselves.
- Lets the pair **self-verify**: "I don't care what you sent, as long as `k`
  didn't shrink, you can take what you asked for."

### Fee + the getAmountOut formula

0.3% is skimmed from the input before the k-check:

```
amountInWithFee = amountIn * 997
amountOut       = amountInWithFee * reserveOut / (reserveIn * 1000 + amountInWithFee)
```

That's `UniswapV2Library.getAmountOut`. Falls out of solving

```
(reserveIn + amountInAfterFee) * (reserveOut - amountOut) ≥ reserveIn * reserveOut
```

for `amountOut`. You do this yourself at the pair layer; the router does it
for you.

## `SimpleSwap.sol` — Pair directly

Same self-custodial shape as `mint` / `burn`: **send tokens in, then call the
action.**

1. Read reserves from the pair.
2. Compute `amountOut` using `getAmountOut`.
3. `transfer` WETH to the pair.
4. `swap(amount0Out, amount1Out, to, data)` — filling **only the side you want out**.

Ordering gotcha: the pair stores `(token0, token1)` where `token0` is the
lower address. For USDC/WETH: `USDC = token0`, `WETH = token1`. So
`reserve0 = USDC, reserve1 = WETH`. WETH → USDC swap uses
`amountIn ↔ reserve1 (in)`, `amountOut ↔ reserve0 (out)`, and
`swap(amountOut_USDC, 0, ...)`.

Don't think of `amount0Out` / `amount1Out` as "input or output"; think of
them as **"how much of each side I'm taking out of the pair."** You're taking
USDC, not WETH → `(amountOut, 0)`.

### Why the `data` param?

Empty `""` for a plain swap. If non-empty, the pair does a **flash swap**:
sends you the tokens *first*, then calls `uniswapV2Call(...)` on `to` with
that data, then checks `k` at the end. That's how flash-loan-style swaps
work in V2 — zero-capital arbitrage, collateral swaps for liquidations, etc.
Not needed here but the same function signature does both.

## `SimpleSwapWithRouter.sol` — Router with ETH

Uses `swapExactETHForTokens(amountOutMin, path, to, deadline)` — payable,
takes the ETH via `msg.value`.

1. Call with `{value: ethAmount}` — no approve step (ETH isn't ERC20).
2. Router wraps ETH → WETH inside.
3. Router computes amounts from reserves along the `path`.
4. Router does the `transfer` + `swap` on each pair in the path.

### The `path` argument

Array of token addresses, one pair hop per adjacent entry.
`[WETH, USDC]` = single hop. `[DAI, USDC, WETH, UNI]` = three hops
(DAI/USDC → USDC/WETH → WETH/UNI), assuming those pairs exist. The router
loops through, each hop feeding the next. We'll use real multi-hop in the
MultiHop puzzle.

### The swap function family

The router has a **cross product** of swap functions:

|           | Input = ETH            | Input = Token         | Input = Token, output = ETH |
| --------- | ---------------------- | --------------------- | --------------------------- |
| Exact in  | `swapExactETHForTokens`| `swapExactTokensForTokens` | `swapExactTokensForETH` |
| Exact out | `swapETHForExactTokens`| `swapTokensForExactTokens` | `swapTokensForETHForExactTokens` |

Exact-in: "I have exactly X, give me as much Y as possible (≥ min)."
Exact-out: "I want exactly Y, take as little X as needed (≤ max)."

## TL;DR

| Concern           | `SimpleSwap` (Pair)                     | `SimpleSwapWithRouter`                  |
| ----------------- | --------------------------------------- | --------------------------------------- |
| Input delivery    | `transfer` WETH to pair                 | Send ETH via `msg.value`; router wraps  |
| Output math       | You compute with `getAmountOut`         | Router computes                         |
| Token ordering    | You know token0 vs token1               | Router abstracts via `path`             |
| Multi-hop         | One pair at a time                      | `path` array, any length                |
| Slippage          | None                                    | `amountOutMin`                          |
| Deadline          | None                                    | Yes                                     |
| Flash swap        | Possible via non-empty `data`           | Not exposed                             |

## Mental model reinforcement

Every V2 pair operation is the same self-custodial shape:

- Deliver input → pair reads its own balance → pair does math → pays out.
- `mint`: send two tokens in, pair mints LP.
- `burn`: send LP in, pair returns two tokens.
- `swap`: send one token in, pair returns the other.

Once the "pair trusts its own balances, not function args" pattern clicks,
nothing at the pair layer surprises you.
