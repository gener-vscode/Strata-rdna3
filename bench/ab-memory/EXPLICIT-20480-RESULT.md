# Explicit `--prefill 20480` at `--max-context 224000` — measured (2026-11-10)

Arm: `rdna3/configs/iq2_xs-1gpu.json`, restart 12:36:12, engine `fb975936515c`, git `ce61f3b0`.
Snapshot `snapshots/iq2xs-explicit-20480-20261110T044040Z.txt/.keys`,
speed raw `speed-iq2xs-20480-explicit-raw.txt`, report
`bench/results/2026-11-10-community-unknown-qwen-flash-unsloth-ud-iq2-xs/`.

## 1. `20480` was honoured — the explicit path really does what `auto` would not

```
--prefill 20480                                    (an explicit number)
strata serve: the prompt path borrows 5778 CUDA0 cache slots (9.28 GiB)
FileExpertSource: 5778 of the prompt path's 5778 lendable slots keep their experts in RAM too
FileExpertSource: resident 37.12 GiB, pinned 37.12 GiB in 94 s
FileExpertSource: 23.72 GiB really free for a 37.12 GiB page-locked complement; 36.34 GiB free
```

- `prompt chunk auto:` **does not appear** — there is no auto scan any more, so
  `STRATA_PREFILL_AUTO_MAX=20480` is now decoration (it only ever gated `auto`).
- **No `#669` WARNING** (`grep` for `WARNING|does not fit|only N of their experts` = 0) and the
  lend line is `5778 of 5778`: every borrowed slot's expert is in RAM. Healthy.
- Predicted 20480 → `343 + 0.265 × 20480 = 5776` slots, 9.27 GiB. Measured **5778 / 9.28 GiB**.
  The linear law in `EXPLICIT-PREFILL-24576.md` §3 held to 2 slots.
- Identity held again: `(39.4 − 11.54 cache) + 9.28 lend = 37.14` vs logged **37.12**.

## 2. What it cost

| | 16384 (auto, measured 11-09) | **20480 explicit (today)** | Δ |
|---|---|---|---|
| `--max-context` | 224000 | 224000 | — |
| GPU expert cache | 7240 / 11.61 GiB | 7200 / 11.54 GiB | −0.07 (context, not chunk) |
| lend region | 4692 / 7.53 GiB | 5778 / **9.28 GiB** | **+1.75 GiB ← the chunk** |
| resident complement | 35.31 GiB | **37.12 GiB page-locked** | +1.81 |
| engine RSS | 37.71 GiB | **39.57 GiB** | +1.86 |
| VmHWM | 39.54 GiB | 39.59 GiB | +0.05 |
| engine swap | 0 | **0** | — |
| **system swap used** | 159 MiB | **1.19 GiB** (vision 775 MiB) | +1.0 GiB |
| MemAvailable idle | 5.40 GiB | **4.09 → 3.88 GiB** | −1.5 |
| MemAvailable after bench | 3.95 GiB | **4.40 GiB** | +0.45 |
| page cache (`Cached`) | — | **0.78 GiB** | crushed by the lock |
| VRAM free (all loaded → windows) | 738 → 582 MiB | 734 → **598 MiB** | ~same |
| boot cost to pin | 83 s | **94 s**, needs 36.34 GiB free | +11 s |

`systemd` for the service since this boot: **`42.7G memory peak, 0B memory swap peak`** — the
42.7 G peak is the lock pass; swap peak still 0 for the unit, but the machine as a whole has
1.19 GiB in swap now and the page cache is down to 0.78 GiB.

## 3. What it bought — barely anything at bench lengths

| test | 16384 auto | **20480 explicit** | Δ |
|---|---|---|---|
| 32K prompt tok/s | 1929.3 (1921–1933) | **1950.5 (1942.3–1952.9)** | **+1.1 %** (ranges just clear) |
| 32K first token | 16.64 s | **16.46 s** | −0.18 s |
| 16K prompt | 1889.5 | 1948.6 (1721.8–1951.7) | +3.1 % |
| **4K prompt (control)** | 1163.8 | 1203.1 (988.1–1204.4) | **+3.4 % ← control drifted** |
| chat decode | 67.2 (53.8–73.6) | 68.6 (53.4–72.2) | same |
| agent decode | 85.2 (59.0–99.3) | 75.4 (57.0–92.8) | ranges overlap |
| agent cache hit % | 69.29 | 69.58 | same |
| decode hit rate (log) | 80.7 / 81.9 / 74.9 % | 77.9 % | within noise |

**Read this honestly.** The 4K control — a length where the chunk size cannot matter, one
chunk either way — moved +3.4 %. The 32K row is 2 chunks at 16384 **and** 2 chunks at 20480
(32 049 tokens), so there is no chunk-count win at bench length either. So the +1.1 % is
**not separable from baseline drift**; treat 20480's speed gain here as 0 to +1 %.

## 4. Where the chunk-count win actually is (and why the bench cannot see it)

Chunks a prompt of length L costs = `ceil(L / chunk)`:

| real prompt in `logs/rdna3-iq2_xs.log` | @16384 | @20480 | @24576 |
|---|---|---|---|
| 88 422 | 6 | **5** | 4 |
| 92 206 | 6 | **5** | 4 |
| 108 211 | 7 | **6** | 5 |
| 124 241 | 8 | **7** | 6 |
| ~142 000 (now) | 9 | **7** | 6 |

Each chunk re-streams every non-resident expert once, so below ~70 K tokens a bigger chunk
buys nothing (which is exactly what §3 measured: 4K/16K/32K all one or two chunks anyway),
and above ~90 K it cuts 12–22 % of the streaming passes. The bench tops out at 32K, so it
structurally cannot measure the thing that motivated the knob.

## 5. Verdict and the choice now

**20480 works and is stable**: no warning, `N == M`, engine swap 0, post-bench MemAvailable
4.40 GiB. But it spent **+1.75 GiB page-locked** for a gain the bench cannot show, and it put
the box in a state with less slack than either previous arm: RSS 39.57 GiB, ~4 GiB available,
page cache 0.78 GiB, 1.19 GiB of other processes' memory in swap, and a 94 s boot lock that
needs 36.34 GiB free in one go.

- **If prompts above ~90 K are routine for you** (they are in the log): keep `--prefill 20480`.
  It is the largest step that still fits — 6→5, 8→7, 9→7 passes.
- **If big prompts are the exception**: go back to `--prefill auto` (this build picks 16384 on
  gfx1100) and bank the 1.75 GiB. It keeps +13.9 % over 8192 (the one speed win actually
  measured for a chunk change) and returns the page cache and the boot margin.
- **Do not go to 24576**: it needs ~+1.8 GiB on top of this arm (predicted complement 38.3 GiB,
  and 6856 of 7200 cache slots = 95 % of the cache as scratch) and the arm is already
  borrowing swap for other processes. `EXPLICIT-PREFILL-24576.md` §3.
- Free knob, unrelated to the chunk: `--max-context` 160000 → 224000 cost only **0.57 GiB**
  and 351 cache slots (`MAX-CONTEXT-SIZING.md`). That trade is worth having.

## 6. Unmeasured / caveats

- Speed of the 20480 arm vs 16384 at **long prompts** (90 K+) is unmeasured — `tools/strata_bench.py
  --long` stops at 32 K. The §4 table is arithmetic on the logged prompt lengths, not a run.
- Because the 4K control moved +3.4 % between the two arms, the two speed runs are not a clean
  matched pair (page-cache state and boot state differ). Treat §3's deltas as upper bounds.
- Whether the 1.19 GiB of system swap is a one-off from the lock pass (which releases and
  re-grabs page cache) or a steady leak needs one more snapshot after an hour of traffic;
  the engine's own swap was 0 B at 12:36, 12:41 and after the bench.
