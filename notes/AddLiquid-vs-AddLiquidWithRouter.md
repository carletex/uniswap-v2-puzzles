# `AddLiquid` vs `AddLiquidWithRouter`

Both puzzles end with the same goal (LP tokens minted to `msg.sender`), but
they attack it from two very different layers of Uniswap V2.

## `AddLiquid.sol` — talking directly to the Pair contract

You act as a "power user" doing what the router does internally. That means
**you** are responsible for:

1. **Computing the correct ratio.** The pair's `mint()` function mints LP
   tokens based on whatever tokens are already sitting in the pair's balance.
   If you send tokens at the wrong ratio, the surplus on the over-sent side is
   essentially donated (it affects `k` but no LP tokens are minted for it).
   That's why the code does
   `wethAmount = usdcAmount * wethReserve / usdcReserve` — it matches the
   current pool ratio exactly.
2. **Moving the tokens yourself.** You `transfer` both tokens directly to the
   pair address — no approvals needed because the pair doesn't pull anything.
3. **Working with WETH, not ETH.** The Pair only understands ERC20. Native ETH
   has to be wrapped beforehand.
4. **Calling `mint(to)`.** The pair reads its new balances, compares to
   reserves, and mints LP tokens.

No slippage protection, no deadline, no safety rails — the pair trusts you to
have done the math right.

## `AddLiquidWithRouter.sol` — talking to the Router

The Router is a convenience/safety layer on top of the Pair. You delegate the
annoying parts to it:

1. **Approve, don't transfer.** The router pulls tokens from you via
   `transferFrom`, so you `approve(router, amount)` first instead of
   transferring.
2. **Router computes the optimal ratio.** You just say "I'd like to deposit up
   to 1000 USDC and 1 ETH." The router reads the reserves, figures out the
   correct matching amount, pulls only what's needed, and refunds the dust.
3. **ETH is handled natively.** `addLiquidityETH` is payable — you send ETH
   via `msg.value` and the router wraps it to WETH for you.
4. **Slippage + deadline protection.** `amountTokenMin` / `amountETHMin` guard
   against the pool ratio moving against you mid-tx, and `deadline` kills the
   tx if it sits in the mempool too long.
5. **Router calls `mint` on the pair under the hood**, sending LP tokens to
   the `to` address you provide (`msg.sender` in this case).

## TL;DR

| Concern             | `AddLiquid` (Pair directly) | `AddLiquidWithRouter`                 |
| ------------------- | --------------------------- | ------------------------------------- |
| Ratio calculation   | You do it                   | Router does it                        |
| Token movement      | `transfer` to pair          | `approve`, router does `transferFrom` |
| ETH vs WETH         | Must wrap manually          | Router wraps via `msg.value`          |
| Slippage / deadline | None                        | Built-in                              |
| Leftover dust       | You eat it                  | Router refunds                        |
| Gas                 | Cheaper                     | A bit more (extra hop, checks)        |

So `AddLiquid` is the "bare metal" view of how Uniswap V2 actually mints
liquidity, and `AddLiquidWithRouter` is the ergonomic wrapper that 99% of
integrations should use.

---

## Deep dive: `amountTokenMin` and `amountETHMin`

These two parameters are the **slippage protection** for `addLiquidityETH`.
They're the most misunderstood arguments in the whole router API, so it's
worth unpacking carefully.

### The problem they solve

When you call `addLiquidityETH(token, amountTokenDesired, ..., amountETHValue)`
you're telling the router two ceilings:

- "I'm willing to deposit **at most** `amountTokenDesired` of the ERC20."
- "I'm willing to deposit **at most** `msg.value` of ETH." (this is
  `amountETHDesired` implicitly)

But liquidity has to be added at the **current pool ratio**. So the router
can't just take both maxes — it has to scale one side down. Here's the
simplified logic from `UniswapV2Router02._addLiquidity`:

```solidity
// pseudo-code of what the router does
uint amountBOptimal = quote(amountADesired, reserveA, reserveB);
if (amountBOptimal <= amountBDesired) {
    // Side A is the limiter: use all of amountADesired, use amountBOptimal of B.
    (amountA, amountB) = (amountADesired, amountBOptimal);
} else {
    uint amountAOptimal = quote(amountBDesired, reserveB, reserveA);
    // Side B is the limiter: use all of amountBDesired, use amountAOptimal of A.
    (amountA, amountB) = (amountAOptimal, amountBDesired);
}
```

Between the moment you sign the tx and the moment it gets mined, the pool
reserves can change (someone else swapped, added, or removed liquidity). That
means the ratio used for `quote()` can shift, and the router might end up
pulling **less of one token than you expected**.

If you were silent about your minimums, a malicious MEV bot could sandwich
your deposit: shift the price right before your tx, make you deposit at a
terrible ratio, then revert the price after and pocket the difference.

### What `amountTokenMin` / `amountETHMin` actually enforce

The router checks, after the scaling:

```solidity
require(amountToken >= amountTokenMin, "INSUFFICIENT_TOKEN_AMOUNT");
require(amountETH   >= amountETHMin,   "INSUFFICIENT_ETH_AMOUNT");
```

In words: **"I'm willing to deposit less than my desired amount, but not less
than these floors."**

So for each side:

- `amountDesired` = the ceiling (how much you're offering)
- `amountMin` = the floor (the worst ratio you'll tolerate)

The "slippage tolerance" you set in a UI (e.g. Uniswap's 0.5%) is just a
percentage below `amountDesired`:

```
amountTokenMin = amountTokenDesired * (1 - slippageBps / 10_000)
amountETHMin   = amountETHDesired   * (1 - slippageBps / 10_000)
```

### Why we pass `1` in this puzzle

The test runs on a forked mainnet block with a single tx — no one else is
touching the pool, so the ratio can't move. `1` just means "don't revert on
slippage; accept whatever the router computes." On mainnet that would be
**dangerously loose** and a prime sandwich target; you'd use something like
99.5% of the desired amounts.

### Common gotcha

A lot of people think these are the amounts *the router will pull*. They're
not. The router pulls the **optimal** amounts (≤ desired). `amountMin` is
purely an assertion after the fact — a revert condition, not an input to the
math.
