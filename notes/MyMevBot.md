# `MyMevBot`

## TL;DR

Two V2 pools share WETH. One (`USDC/WETH`) is at market price; the other
(`USDT/WETH`) is skewed so that USDT is *cheap* relative to WETH. Flash-
borrow USDC from a V3 pool, cycle `USDC → WETH → USDT → USDC` via the V2
router's multi-hop, repay flash + fee, keep the delta.

## Top-down

Three moving parts that weren't in prior puzzles:

1. **V3 flash loan** (borrow source). Different API than V2.
2. **Cross-pool arbitrage**. Two pools disagree on a price; we move value
   between them.
3. **Multi-hop routing**. One `swapExactTokensForTokens` call with
   `path.length == 4` does three hops.

## How the skew is created

```solidity
transfer(ETH_USDT_pool, 3_000_000e6);   // $3M USDT
transfer(ETH_USDT_pool, 10 ether);       // ~$35k WETH
IUniswapV2Pair.mint(0xB0b);
```

V2 `mint` syncs `reserves` to the **full contract balance** — even when the
deposit is imbalanced. LP tokens are minted on `min(amt0/R0, amt1/R1)`
basis so the LP-ing party gets cheated out of the excess, but the *reserves*
absorb everything. The $3M USDT side massively outweighs 10 WETH, so the
USDT/WETH ratio jumps — more USDT per WETH, i.e. **WETH expensive in USDT
terms**. Equivalently: USDT is cheap.

Arb rule: in the skewed pool, sell the scarce/expensive side (WETH), buy
the abundant/cheap side (USDT).

## The V3 flash loan leg

```solidity
flashLenderPool.flash(recipient, amount0, amount1, data);
```

V3 ships tokens to `recipient`, then calls `uniswapV3FlashCallback(fee0,
fee1, data)` on `msg.sender`. By callback-end, the pool must have received
back `amount + fee` of each token. **Push model — no `approve`.** You
`transfer` the repayment directly.

Fee = pool's swap tier × borrowed. This pool is the 5 bps USDC/WETH tier, so
flash fee = 0.05% of borrowed USDC. On 10k USDC that's 5 USDC.

## Cycle path and why it's one router call

```solidity
path = [USDC, WETH, USDT, USDC];
router.swapExactTokensForTokens(borrowed, 0, path, address(this), deadline);
```

The V2 router accepts arbitrary-length paths as long as each adjacent pair
has a factory pool (all three do: `USDC/WETH`, `WETH/USDT`, `USDT/USDC`).
It loops through, each pair forwarding output tokens directly to the next
pair — intermediate tokens never touch us. One `approve` of USDC to the
router is all that's needed.

## Numbers (at the test's fork block)

Borrow 10,000 USDC, run the cycle:

| Item                      | Value             |
| ------------------------- | ----------------- |
| Flash-borrowed            | 10,000.00 USDC    |
| USDC out after 3 hops     | ~10,377.73 USDC   |
| Gross arb profit          | ~377.73 USDC      |
| Flash fee (5 bps)         | 5.00 USDC         |
| **Net profit**            | **~372.73 USDC**  |

### Why not borrow more?

Tried 100k USDC — came back with only ~99.57k, a *loss*. Culprit is the
closing `USDT → USDC` hop: the V2 USDT/USDC pair has always been shallow
(V3 ate the stable-swap flow years ago). At 100k notional the price impact
on that single hop wipes out the ~6% skew we harvested on the WETH/USDT
leg. The deep legs (USDC/WETH, WETH/USDT) scale fine; the shallow leg sets
the ceiling.

## Wiring summary

```
performArbitrage
  └─ flashLenderPool.flash(this, 10k USDC, 0, encoded_amount)
       └─ [V3 sends 10k USDC to us]
       └─ uniswapV3FlashCallback(fee0, 0, data)
            ├─ callMeCallMe()                     (puzzle's built-in check)
            ├─ usdc.approve(router, borrowed)
            ├─ router.swapExactTokensForTokens([USDC, WETH, USDT, USDC])
            └─ usdc.transfer(flashLenderPool, borrowed + fee0)   // repay
```

## Defenses (real-world)

- LPs shouldn't add imbalanced — but this puzzle's skew is the attacker's
  gift, not a defense concern.
- Price-oracle-gated DEXes reject trades that diverge from a reference.
  V2 has none; all arbs are permissioned only by gas cost.
