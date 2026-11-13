# Why a bigger prefill chunk costs system RAM — the mechanism, from the code

The short version: **the chunk sets the size of the prompt path's VRAM buffers; those buffers are borrowed from the expert cache; and in resident RAM mode every borrowed slot's expert is duplicated into RAM.** RAM cost = chunk's buffer bytes, converted to expert slots.

## 1. The chunk's buffers are linear in the chunk

`Prefill::bytes_needed_impl` (`src/prefill/prefill.cpp:2717-2746`) counts, buffer for buffer, everything the prompt path writes for a chunk of `T` tokens:

```cpp
const size_t T = (size_t) chunk;
o.take<uint16_t>(GEMM_SCRATCH); o.take<uint8_t>(GEMM_WS);
f(T * N); f(T * D);  ...  f(T * HC);        // emb, R, xn, grs, gated, inj
o.take<uint16_t>(T * (D + ...)); f(T * LR); o.take<uint16_t>(T * LR);
f(T * D); f(T * HC); f(T * N); o.take<uint16_t>(T * N); o.take<uint16_t>(T * N);
o.take<int32_t>(T * kStepCount);
```

Every term is `T ×` a model dimension. These are per-token activations — the residual, the gated/inject vectors, the router logits (`T * LR`), the step-count arrays. **Double the chunk, double the buffers.** Plus the staging ring (`stage_slots(T)`, `prefill.cpp:395-396`, whose comment is "the bytes the prompt path borrows cover every buffer it writes").

## 2. Those buffers come out of the expert cache, not from fresh VRAM

`generate.cpp:736-738`: "the prompt path borrows the top expert-cache slots for its buffers and refills them after the prompt". The size of the loan:

```cpp
auto lend_slots = [&](int64_t c) -> int64_t {
    return slots_from_bytes(strata::prefill::Prefill::bytes_needed(g, ss, c, srcp != nullptr));
};
```
(`generate.cpp:8001-8003`, capped at `kAutoLendPct` = 90 % of the cache when the copies are DMA from pinned RAM, else 85 % — `generate.cpp:8038-8045`.)

So one slot of the loan = one expert blob, and on these packs a slot is ~1.6 MiB (IQ2_XS: 11.61 GiB / 7240 slots). Measured loans, straight from the logs:

| chunk | slots borrowed | bytes |
|---|---|---|
| 8192 (IQ2_XS) | 2520 | 4.03 GiB |
| 16384 (IQ2_XS) | 4692 | 7.53 GiB |
| 32768 (IQ2_XS) | 6397–6532 | 10.26–10.48 GiB |
| 8192 (IQ3_XXS) | 1777 | 2.88 GiB |
| 32768 (IQ3_XXS) | 6041 | 9.73 GiB |

Roughly linear in the chunk, as §1 predicts (3.4× for 4×).

## 3. The step that turns VRAM into RAM

Borrowing VRAM would be free if the cache just lost those entries. It does not. In resident RAM mode the RAM copy must hold the lent slots' experts **as well**:

```
FileExpertSource: RAM budget 37.00 GiB: 17336 of the 27.77 GiB of experts the GPU cache does not hold, by profile rank
FileExpertSource: the prompt path's lend region: 2520 of its 2520 slots keep their experts in RAM too (4.03 GiB of the budget's remaining 9.23 GiB)
FileExpertSource: allocating 31.81 GiB pageable resident cache complement      <- 27.77 + 4.03
```

and `generate.cpp:451` says the same from the swap side: "Swaps that need no exchange (`out` **in the lend region is held in RAM already**…)".

Why it has to be that way: a chunk of `stream_all_min` (1024) tokens or more streams **every** expert the GPU does not hold, routed or not (`generate.cpp:718-721`). During that read the lent slots are busy as buffers, so the experts that normally live in them have to be read from the RAM side — and a copy you read from RAM must exist in RAM. The alternative is reading them off the SSD mid-prompt, which is what the `--resident-budget-gib` budget exists to avoid.

So:

```
resident complement = experts the GPU cache does not hold  +  the lend region's experts
                    =        (fixed by the model)          +   f(chunk)          <- the only part you control
```

Measured, IQ2_XS: 27.77 + 4.03 = 31.81 GiB at chunk 8192; 27.77 + 7.53 = 35.31 GiB at 16384. RSS followed by 3.69 GiB.

## 4. What the chunk is buying, so the trade is on the table

The same comment (`generate.cpp:718-721`) states the reason to go big: a chunk at or above `stream_all_min` streams each non-resident expert **once per chunk**, so a bigger chunk moves fewer bytes per token — the "ubatch" effect. Our own matched run:

| | chunk 8192 | chunk 16384 |
|---|---|---|
| 32K prompt | 1692.3 tok/s | 1929.3 tok/s (**+13.9 %**) |
| 32K first token | 18.97 s | 16.64 s |
| resident complement | 31.81 GiB | 35.31 GiB (**+3.50 GiB**) |

## 5. The two knobs, and what each does

| knob | what it moves |
|---|---|
| `STRATA_PREFILL_AUTO_MAX` (the chunk) | the lend region, so the complement, so RSS: **~0.44 GiB per 1024 tokens of chunk** on IQ2_XS |
| `STRATA_PREFILL_LEND_PCT` (`generate.cpp:8040`) | the ceiling on the loan as a share of the cache (90 % pinned / 85 % otherwise). Lowering it forces the engine to halve the chunk until the buffers fit — a cheaper way to the same place if you want to keep `auto` |

`--no-prefill-borrow` is the other direction: the prompt path reserves its buffers for the whole session instead of borrowing cache slots — more VRAM held permanently, and the lend region's experts no longer need the RAM copy. Untested here.
