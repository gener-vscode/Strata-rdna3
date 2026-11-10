# How far to push `--max-context` (IQ2_XS, 7900 XT + 46.4 GiB RAM)

Measured 2026-11-10 on the running config `rdna3/configs/iq2_xs-1gpu.json`
(snapshot `snapshots/iq2xs-24576-funded-20261110T040530Z.txt/.keys`, engine `fb975936515c`, git `ce61f3b0`).

## 1. Short answer

Raise `--max-context` from 160000 to **224000**. It costs **about 0.56 GiB of RAM**, and
that is all. It is by far the cheapest big knob on this machine.

| from → to | extra RAM (= extra complement) | extra GPU cache given up | verdict |
|---|---|---|---|
| 160000 → 192000 | +0.28 GiB | 351 slots / 0.57 GiB | free |
| 160000 → 224000 | **+0.56 GiB** | 351 slots / 0.57 GiB | **recommended** |
| 160000 → 229346 (native max) | +0.61 GiB | 383 slots | fine, no gain over 224000 |

The expensive thing on this box is the **prefill chunk**, not the context. Do not raise the
chunk and the context together — the run that died (`43.5G memory peak, 5.5G memory swap peak`,
then a 60 s stall) had `chunk 32768 + conversation-cache 2048 + ctx 224000` at once.

## 2. Why the context is nearly free in RAM, and where it really goes

`--max-context` sizes buffers that live on the **GPU**, not in host RAM
(`cudaMalloc(&sbuf, session_bytes(g, o.max_context, …))`, `src/program/generate.cpp:5412`,
repeated for each split stage at `:5448` and `:5830`). The log marks the result as
*"the session (KV, GDN state, PLE history)"*. Most layers are GDN (linear attention), whose
state is a constant size regardless of context, so the per-token term is small.

Then the expert cache takes whatever VRAM is left:

```
expert cache auto: 13.04 GiB free, 832 MiB reserved (+125 MiB for the draft head) -> 5974 slots
```

So the chain is:

```
more context  ->  more VRAM for KV/session  ->  smaller expert cache
              ->  more experts outside the cache  ->  bigger RAM complement  (1:1)
```

In resident RAM mode the complement is *defined* as "every expert the GPU cache does not
hold, plus the prompt path's lend region", so the GiB the context takes from the cache comes
back in RAM. It is an identity, not an estimate:

```
complement = (39.4 GiB experts − cache GiB) + lend GiB
```

Checked against the log on four arms (39.4 experts, lend 7.53 GiB):

| ctx | cache GiB | predicted complement | log says |
|---|---|---|---|
| 160000 | 12.11 | 34.82 | **34.81** |
| 224000 (res 768) | 11.61 | 35.32 | **35.31** |
| 224000 (res 832) | 11.54 | 35.39 | **35.37** |
| 128000 (no-borrow, 6.14) | 6.14 | — | 33.24 (lend 0.0: 33.26) |

To 0.02 GiB. So the *only* RAM cost of the context is the cache it displaces, and that is
~9 MiB per 1000 tokens.

## 3. Measured rate: about 9 MiB per 1000 tokens

Derived from the final expert-cache size in every logged `--serve` start
(`logs/rdna3-iq2_xs.log`), which is what the context is charged against:

| pair | Δtokens | cache GiB | MiB per 1000 tokens |
|---|---|---|---|
| 160000 conv0 res832 → 224000 conv2048 res832 | +64000 | 12.11 → 11.54 | **9.12** |
| 160000 conv0 res832 → 224000 conv2048 res768 | +64000 | 12.11 → 11.61 | **8.00** |
| 160000 conv0 res512 → 184000 conv1536 res512 | +24000 | 12.42 → 12.18 | **10.24** |

Use **9 MiB / 1k tokens** (a spread of 8–10; the pairs differ in conversation cache too, so
treat ±1 as measurement noise). On this machine `--max-context` alone has therefore never
cost more than 0.6 GiB across its entire usable range.

## 4. The current arm, measured (this is the missing snapshot)

```
expert cache 7551 slots, 12.11 GiB of VRAM          (conversation cache OFF grew it: 7200 -> 7551)
FileExpertSource: resident 34.81 GiB, pinned 34.81 GiB in 83 s
FileExpertSource: 4691 of the prompt path's 4691 lendable slots keep their experts in RAM too
strata serve: 738 MiB of VRAM free with everything loaded
strata serve: decode expert cache hit rate: 80.7% / 81.9% / 74.9%
```

| | at 12:05 (idle) | at 12:17 (after traffic) |
|---|---|---|
| engine RSS | 36.81 GiB | 37.27 GiB |
| engine VmHWM | 37.49 GiB | 37.49 GiB |
| engine swap | **0 B** | — |
| MemAvailable | 5.52 GiB | **5.12 GiB** |
| system swap used | 284 MiB | 284 MiB |

**No warning lines.** `grep -cE 'WARNING|does not fit|only [0-9]+ of their experts'` since the
11:54 restart returns **0**, and the lend line reads `4691 of 4691` — that is the healthy
state the 32768 arm failed (`6252 of 6532 … the others are read from the files`).

So the `--resident-experts` (whole complement, soft, 4 GiB headroom) choice is working: it
paid 34.81 GiB, everything fit, nothing spilled to files, `resident_soft` did not fall back
to plain mmap.

### Two things this snapshot corrected in my earlier notes

1. **The complement is page-locked, not pageable.** `STRATA_RESIDENT_PIN` is *not* in the
   current config, so the default applies. 34.81 GiB is locked and the kernel cannot move or
   reclaim it. It was a tight fit: `23.04 GiB really free for a 34.81 GiB page-locked
   complement; the model files' cached pages were released: 36.23 GiB free`, then 83 s of
   layer-by-layer copy. A restart that needs 35.4 GiB locked is the real risk, not steady state.
2. **`STRATA_PREFILL_AUTO_MAX=24576` is not being used.** The engine chose
   `prompt chunk auto: 16384 tokens` — the ceiling is a ceiling, not a target. So this config
   is currently *the 16384 arm* with conversation cache off and a pinned complement; setting
   24576 made no difference to the chunk, and the extra context it used to buy is not there.

## 5. Guard rails — read these four lines after a restart with a bigger context

1. `prompt chunk auto: NNNNN tokens` — expect 16384.
2. `expert cache NNNN slots, X.XX GiB of VRAM` — expect ~11.5 GiB at 224000, i.e. −0.57 GiB
   and −351 slots vs today. Hit rate moved 74.9–81.9% today on 7551 slots; re-read it here.
3. `N of the prompt path's M lendable slots keep their experts in RAM too` — **want N == M.**
4. `resident NNN GiB of experts in RAM (page-locked)` plus the absence of
   `mmap`/`does not fit`. If it says page-locked but MemAvailable after boot is under
   4 GiB, roll the context back: locked pages are not reclaimable, and that is how the box
   thrashes.

Also worth knowing: `Cached` is down to **2.62 GiB** now, because the pinning pass released
the model files' page cache. The prefill plan still prints *"5.8 GiB available for the page
cache"* — that figure is computed before the lock, so drive reads are more likely than that
line promises, now more than before.

## 6. Still unmeasured (say so, do not infer)

- A **matched** `--max-context`-only pair. Every logged row differs in conversation cache
  and/or `--vram-reserve-mib` as well, so 9 MiB/1k comes from the cache-size arithmetic plus
  two corroborating pairs, not a clean A/B. The RAM side, by contrast, is guaranteed by the
  identity in §2 and is checked to 0.02 GiB.
- The 192000 row is an interpolation.
- Whether −351 cache slots changes decode speed at 224000. Today's hit rate spans 74.9–81.9%
  across requests, so one more or fewer 5% of cache is inside that noise; a bench would be
  needed to separate them.
- `--pool-workers 7`, a `--vram-reserve-mib` sweep, and a real 24576-chunk run (the engine
  does not pick it on its own today).
