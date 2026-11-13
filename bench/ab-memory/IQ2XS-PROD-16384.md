# The production IQ2_XS config: how much RAM the 16384 chunk costs

Same machine, same engine binary `fb975936515c`, same model `Qwen3.8-Flash-Next-UD-IQ2_XS` (39.4 GiB of experts). Four lines moved from the 8192 arm to what is in `rdna3/configs/iq2_xs-1gpu.json` now:

| setting | 8192 arm (22:53) | production arm (23:06) |
|---|---|---|
| `STRATA_PREFILL_AUTO_MAX` | 8192 | **16384** |
| `--vram-reserve-mib` | 512 | **768** |
| `--conversation-cache-mib` | 1536 | **2048** |
| `--max-context` | 184000 | **224000** |

## 1. The answer: +4.1 GiB resident, +4.3 GiB RSS at idle, +6.0 GiB after one big prompt

| measured | 8192 arm | production arm | extra |
|---|---|---|---|
| GPU expert cache | 7600 slots / 12.18 GiB | 7240 slots / 11.61 GiB | **−0.57 GiB** |
| experts outside the cache | 27.20 GiB | 27.77 GiB | **+0.57 GiB** |
| lend region kept in RAM | 2519 slots / 4.04 GiB | 4692 slots / **7.53 GiB** | **+3.49 GiB** |
| resident complement | 31.24 GiB | **35.31 GiB** | **+4.07 GiB** |
| engine RSS (idle snapshot) | 33.44 GiB | **37.71 GiB** | **+4.27 GiB** |
| engine RSS after one 108K prompt | 33.44 GiB | **39.43 GiB** | **+5.99 GiB** |
| engine VmHWM | 33.51 GiB | 39.43 GiB | +5.92 GiB |
| `MemAvailable` (idle) | 9.56 GiB | **5.40 GiB** | −4.16 GiB |
| `MemAvailable` (after the prompt) | 9.56 GiB | **3.59 GiB** | −5.97 GiB |
| parked conversation | 1.47 GiB | 1.69 GiB | +0.22 GiB |
| VRAM used / free | 19.88 / **444 MiB** | 19.67 / **672 MiB** | −0.21 GiB / **+228 MiB** |
| #2065 "card too full" warning | yes, every request | **none in this run** | fixed |
| swap in use | 159 MiB | 159 MiB | the same |

Complement adds up again: 27.77 + 7.53 = 35.30 ≈ 35.31 GiB.

## 2. Where the extra 4.1 GiB came from

| term | extra | cause |
|---|---|---|
| lend region | **+3.49 GiB** | chunk 8192 → 16384. The engine borrows 4692 cache slots instead of 2519, and in resident mode every borrowed slot's expert is also kept in RAM. |
| experts outside the cache | **+0.57 GiB** | `--vram-reserve-mib 512 → 768` shrinks the GPU cache (12.18 → 11.61 GiB), so 0.57 GiB more has to live in RAM. |
| parked conversation | +0.22 GiB | `--conversation-cache-mib 1536 → 2048`; one conversation really is parked: `parked=1 bytes=1819200856` (1.69 GiB), 109761 tokens in 731.9 ms. |

So: **the chunk is the whole story (3.49 of 4.07 GiB)**, the bigger VRAM reserve adds 0.57 GiB of it back as RAM, and the conversation cache is a rounding error.

The `--vram-reserve-mib 768` is the part that paid for itself: the card now ends at 672 MiB free instead of 444 MiB, and the `#2065` warning that fired on every request in the 8192 arm is gone. That is the fix the engine itself was asking for.

## 3. What the extra RAM bought, from the one big prompt this run served

```
production (chunk 16384): prompt 108211 tokens = 0 reused + 108211 read in 65546 ms (1650.9 tok/s),
                          1551 generated in 20922 ms (74.1 tok/s)
8192 arm:                 prompt 88422 tokens = 0 reused + 88422 read in 59662 ms (1482.0 tok/s),
                          1095 generated in 15899 ms (68.9 tok/s)
```

1650.9 against 1482.0 tok/s on cold prompts = **+11 %** prefill, and 74.1 against 68.9 tok/s decode. Different prompt lengths (108K against 88K), so this is directional, not a controlled number. The controlled version is still `strata_bench.py --long --runs 3` on both arms.

## 4. Headroom, which is the thing to watch

After one 108K-token request the machine has **3.59 GiB available**, RSS 39.43 GiB, and VmHWM equals RSS — the engine is sitting on its own peak. Swap is untouched (159 MiB), so nothing has spilled yet.

The budget is tight because `--resident-budget-gib 37` is still the number driving the complement, and the complement (35.31 GiB) plus the parked conversation (1.69 GiB) plus KV for a 224K window is most of the 46 GiB. Two cheap ways to make room if it bites:

- `--resident-budget-gib 34` → the complement stops earlier and more experts fall to the file tier (the engine already prints "the rest are read from the files").
- back to `STRATA_PREFILL_AUTO_MAX=8192` → gives the 3.49 GiB straight back, at the prefill cost in section 3.

## 5. Two production-readiness notes from this run's log

- `--pool-workers 8` on 8 physical cores still warns: "Two workers on one core share its memory bandwidth and slow each other down. Recommended: --pool-workers 7". Speed only, no RAM.
- `STRATA_HIPBLASLT_TUNING` points at `gfx1100-hipblaslt-100200.txt` while the runtime hipBLASLt is 100202, so the tuning table is refused and hipBLASEx is used. Upstream's file for this card is `gfx1100-hipblaslt-100202.txt`.

## 6. The bench suite on this arm (`strata_bench.py --long --runs 3`, 23:18)

Saved in `speed-iq2xs-16384/2026-11-09-community-unknown-qwen-flash-unsloth-ud-iq2-xs/README.md`.

| test | this arm (IQ2_XS, chunk 16384) | median | range |
|---|---|---|---|
| 32K prompt | | **1929.3 tok/s** | 1921.1 – 1932.9 |
| 32K first token | | 16.64 s | 16.61 – 16.71 |
| 16K prompt | | 1889.5 tok/s | 1679.1 – 1890.3 |
| 4K prompt | | 1163.8 tok/s | 970.0 – 1163.9 |
| chat decode | | 67.2 tok/s | 53.8 – 73.6 |
| agent decode | | 85.2 tok/s | 59.0 – 99.3 |
| agent cache hit | | 69.29 % | 69.29 – 69.57 |
| agent re-read tokens/session | | 143 | 3 – 145 |

**Read the caveat with this table.** The only other bench folder here, `speed-8192/`, is the **IQ3_XXS** model, not IQ2_XS at 8192. Putting 1929.3 beside its 1781.2 compares two different quantisations and is not the chunk's doing. The same-model evidence is still only the engine's own cold-prompt lines:

```
IQ2_XS, chunk 8192  (22:53 run):  88422 read, 0 reused in 59662 ms = 1482.0 tok/s
IQ2_XS, chunk 16384 (23:06 run): 108211 read, 0 reused in 65546 ms = 1650.9 tok/s
                                  124241 read, 0 reused in 66273 ms = 1874.7 tok/s
                                   32049 read, 0 reused in 16611 ms = 1929.3 tok/s
```

The 16384 arm reads **more** tokens per second on **longer** cold prompts (1874.7 at 124K against 1482.0 at 88K), which is the strongest same-model signal we have that the bigger chunk earns its RAM. A real matched pair needs one more bench run with `STRATA_PREFILL_AUTO_MAX=8192` on this IQ2_XS config.

## 7. Memory straight after that bench

`snapshots/fork-iq2xs-16384-after-bench-*`.

| | this arm idle (23:07) | this arm after the bench |
|---|---|---|
| engine RSS | 37.71 GiB | 38.96 GiB |
| engine VmHWM | 37.78 GiB | **39.54 GiB** |
| `MemAvailable` | 5.40 GiB | **3.95 GiB** |
| VRAM used | 19.67 GiB | 19.71 GiB |
| swap in use | 159 MiB | 159 MiB |
| complement / lend | 35.31 GiB / 4692 slots | unchanged |
| `#2065` card-too-full warning | none | none (windows captured at 622 / 588 / 570 / 568 / 564 MiB free) |

The bench put about 1.25 GiB on RSS and left the peak at 39.54 GiB; the resident complement itself did not move. The card stayed out of the warning zone for the whole run, which is the `--vram-reserve-mib 768` doing its job.

## 8. Not measured

No `STRATA_PREFILL_AUTO_MAX=8192` bench on this same IQ2_XS config (the matched pair). No `--resident-budget-gib` sweep. No conversation-cache hit-rate comparison; `agent re-read tokens/session` went 73 → 143 between the two folders, but those are different models and n=3.
