# What if `--prefill 24576` (explicit) instead of `auto`?

Asked 2026-11-10 after `MAX-CONTEXT-SIZING.md` §4 showed `STRATA_PREFILL_AUTO_MAX=24576`
never took effect (the engine settled on `prompt chunk auto: 16384 tokens`).
Same machine / model / engine `fb975936515c` as that doc.

## 1. Short answer

It **would** take 24576 — that is the whole point of writing the number instead of `auto`.
The RAM guard rails are Windows-only and gfx12-only, so on this box (Linux, gfx1100) an
explicit chunk is honoured as far as it *fits the GPU cache*, and nothing steps it down for
memory reasons. It would lend **~6856 slots / 11.0 GiB instead of 4691 / 7.53 GiB**, which
pushes the resident complement from **34.81 → ~38.3 GiB page-locked (+3.5 GiB)**, against
5.52 GiB MemAvailable at boot and 5.12 GiB live.

**Do not do it on this box.** There is no RAM for it: 38.3 GiB page-locked means the boot
either swaps or trips `resident_soft`'s fallback to plain mmap, and mmap decode is much
slower than any prefill win the chunk could give.

## 2. What the code actually does with a number (this tree, `src/program/generate.cpp`)

| line | behaviour | applies to gfx1100/Linux? |
|---|---|---|
| `:2685` | `o.prefill_chunk = o.prefill_auto ? o.prefill_auto_max : std::atoll(v.c_str())` — an explicit N is used as written | yes |
| `:2695-2696` | `prefill_auto_cap = auto_chunk_cap(win_hip, bare_auto && prefill_auto)`; cap applied if > 0. `auto_chunk_cap` = `win_hip && bare_auto ? 6144 : 0` (`include/strata/platform/host_limits.hpp:19-26`) | **no** (not Windows) |
| `:2697` `warn_user_chunk` | warns about a user chunk ≥ 8192 **only** when `win_hip` | **no** warning on Linux |
| `:8076` | the `#2090` RAM guard (step 32768 → 16384 → 8192 when free RAM cannot cover the loan + 6 GiB) is gated by `if (o.prefill_gfx12_16k && auto_ceiling > 8192)`. `prefill_gfx12_16k` is set true **only** under `gfx_arch_is_gfx12()` (`:2968-2976`) | **no** — gfx12 only |
| `:8623` | `if (o.prefill_auto) k = std::min(k, kAutoLendPct * xc.slots() / 100)` — **the 90 % lend cap only exists for auto** | removed for explicit |
| `:8994-8998` | explicit path: `for (c = o.prefill_chunk; c >= 256; c /= 2) if (fits(c, false, only)) return c;` — comment: *"an explicit --prefill is the operator's number, and a loan of it only has to fit"* | yes |

So an explicit chunk's only hard limit is the GPU cache itself (`k + 128 <= xcache.slots()`),
not the 90 % cap and not host RAM. Today: 7551 slots → ceiling 7423 slots.

The backstop is **after the fact**, at `:8684`: if the RAM cannot keep the lent experts, it
prints the `#669/#765` WARNING and reads them from the SSD on every chunk — the comment in
that block says prompts can read **~3× slower** than with `--prefill auto`, and it already
measures this fork's behaviour ("31 GB: auto:32768 read prompts ~3x slower than auto").

## 3. The cost arithmetic (measured slope, validated on three points)

Loan slots are linear in chunk: `slots ≈ 343 + 0.265 × chunk`, slot size 1.643 MiB
(`12.11 GiB / 7551 slots`, and `7.53 GiB / 4691 slots` agree):

| chunk | predicted | measured |
|---|---|---|
| 8192 | 2520 slots / 4.04 GiB | 2520 / 4.03 ✅ |
| 16384 | 4691 / 7.53 | 4691 / 7.53 ✅ |
| ~23296 (auto, `AUTO_MAX=32768`) | 6516 / 10.45 | 6397–6532 / 10.26–10.48 ✅ |
| **24576** | **6856 / 11.0** | not run |

Note the 23296 row: 6516 slots is exactly 90 % of that arm's 7240-slot cache — auto's
ceiling is the **90 % lend cap**, which today would be 6795 slots (10.88 GiB) on the
7551-slot cache. 24576 wants 6856, i.e. **just above the auto cap** — so `auto` declines it
and settles lower (the fixed `STRATA_PREFILL_RING=192` pulls the answer down further to
16384). Writing the number removes that cap.

Resident identity, checked to 0.02 GiB in `MAX-CONTEXT-SIZING.md` §2:

```
complement = (39.4 experts − 12.11 GPU cache) + lend
current    =  27.29  +  7.53  = 34.82   (log: 34.81)
explicit   =  27.29  + 11.0   = 38.3     ← +3.5 GiB, page-locked
```

Headroom, measured on the running arm: MemAvailable **5.52 GiB** at idle, **5.12 GiB** live,
engine RSS 36.8 → 37.3 GiB, VmHWM 37.49. And boot already strains:
`23.04 GiB really free for a 34.81 GiB page-locked complement; the model files' cached pages
were released: 36.23 GiB free`. 38.3 GiB is past that point. `--resident-experts` is
`resident_soft=true` with a 4 GiB headroom → it would warn and drop to plain mmap.

Second-order problem: 6856 of 7551 slots lent = **90.8 % of the cache is scratch while a big
prompt runs**, leaving ~700 slots for hot experts. Auto's 90 % rule exists to avoid exactly
this; between chunks, decode has almost nothing resident.

## 4. What 24576 would buy (not measured for the explicit arm)

Chunk passes per prompt at the traffic actually seen in `logs/rdna3-iq2_xs.log`:

| prompt | @16384 | @24576 |
|---|---|---|
| 88 422 | 6 | 4 |
| 108 211 | 7 | 5 |
| 124 241 | 8 | 6 |
| 142 000 | 9 | 6 |

Fewer full streams of the non-resident experts, so a real gain exists. But it is 1.5 × tokens
per chunk versus 2 × for the 8192 → 16384 step that measured **+13.9 %** on a 32K prompt
(`MATCHED-IQ2XS-8192-vs-16384.md`); expect less than half of that, and it must be paid for
with RAM this box does not have.

## 5. If you still want to measure it

Do not edit the live config (it was truncated by a bad edit before). Make an arm file, and
buy the 3.5 GiB from the only place that has it — do **not** rely on `resident_soft` to
absorb it:

- Drop `--max-context` 160000 → 128000: returns ~0.28 GiB (9 MiB / 1k tokens). Small.
- The remaining ~3.2 GiB only comes from a smaller GPU cache or from letting lend spill:
  `--resident-budget-gib 34` keeps ~400 slots' worth out of RAM and prints the `#669`
  WARNING — measured direction: SSD reads on every chunk, ~3× slower prompts. Bad trade.

Lines to read after starting it (all four decide the verdict):

```
prompt chunk auto: 24576 tokens        (or the halved value it fell back to)
the prompt path's lend region: N of its M slots keep their experts in RAM too   want N == M
WARNING: a prompt chunk of 24576 tokens lends ... only N of their experts fit in RAM   → stop
resident NN.NN GiB of experts in RAM (page-locked)   +   no mmap fallback line
```

Then `bash bench/ab-memory/snapshot.sh --label iq2xs-explicit-24576 --repo
/home/tommy/repo/Strata-rdna3 --log logs/rdna3-iq2_xs.log --note "explicit --prefill 24576"
--out bench/ab-memory/snapshots`, and watch `MemAvailable` at **the next big prompt**, not at
idle — the loan is charged per chunk and 8192 vs 16384 dropped available by 1.7 GiB under
load (`MATCHED-IQ2XS-8192-vs-16384.md`).

## 6. Still unmeasured

- No explicit-chunk arm has been run, so §3's 6856 slots / 11.0 GiB is the validated linear
  extrapolation, not a measurement.
- The speed column for explicit 24576 is unmeasured; the +13.9 % figure is 8192 → 16384.
- Whether `resident_soft` falls back to mmap or the run simply swaps first, at 38.3 GiB,
  is unknown without running it.
