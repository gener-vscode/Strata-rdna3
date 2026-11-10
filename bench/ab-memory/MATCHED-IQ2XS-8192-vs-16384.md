# Matched pair at last: IQ2_XS, chunk 8192 against chunk 16384

Everything else identical: same engine `fb975936515c`, same `Qwen3.8-Flash-Next-UD-IQ2_XS`, same pack, `--max-context 224000`, `--conversation-cache-mib 2048 --conversation-cache-slots 2`, `--vram-reserve-mib 768`, `--resident-budget-gib 37`, `STRATA_RESIDENT_PIN=0`, `--expert-cache auto`, `--prefill auto`. Only `STRATA_PREFILL_AUTO_MAX` differs.

| arm | start | chunk the engine picked |
|---|---|---|
| A | 23:06:26 | 16384 tokens, 192-slot ring |
| B | 23:5x | 8192 tokens, 192-slot ring |

Snapshots: `snapshots/fork-iq2xs-16384-prod-*`, `...-after-bench-*`, `fork-iq2xs-8192-prod-*`, `...-after-bench-*`.
Bench folders: `speed-iq2xs-16384/…`, `speed-iq2xs-8192/…` (both `strata_bench.py --url http://127.0.0.1:8080 --long --runs 3`).

## 1. Memory: the chunk costs 3.50 GiB, exactly as the lend region says

| measured | B: chunk 8192 | A: chunk 16384 | extra from the chunk |
|---|---|---|---|
| GPU expert cache | 7240 slots / 11.61 GiB | 7240 slots / 11.61 GiB | none |
| experts outside the cache | 27.77 GiB (17336) | 27.77 GiB (17336) | none |
| **lend region kept in RAM** | **2520 slots / 4.03 GiB** | **4692 slots / 7.53 GiB** | **+3.50 GiB** |
| **resident complement** | **31.81 GiB** | **35.31 GiB** | **+3.50 GiB** |
| engine RSS, idle | 34.02 GiB | 37.71 GiB | +3.69 GiB |
| engine RSS, after the bench | 35.43 GiB | 38.96 GiB | +3.53 GiB |
| engine VmHWM, after the bench | 35.96 GiB | 39.54 GiB | +3.58 GiB |
| `MemAvailable`, idle | 9.01 GiB | 5.40 GiB | −3.61 GiB |
| `MemAvailable`, after the bench | 7.66 GiB | 3.95 GiB | −3.71 GiB |
| VRAM free, everything loaded | 672 MiB | 672 MiB | none |
| swap after the bench | 210 MiB | 159 MiB | −51 MiB |

The complement adds up on both sides (27.77 + 4.03 = 31.80; 27.77 + 7.53 = 35.30), and the RSS delta lands on the lend delta within 0.2 GiB. The GPU cache is identical, so the whole difference is system RAM.

## 2. Speed: the chunk buys 13.9 % at 32K and nothing at 4K

| test | B: 8192 | A: 16384 | change |
|---|---|---|---|
| **32K prompt tok/s** | 1692.3 (1680.3–1705.4) | **1929.3 (1921.1–1932.9)** | **+13.9 %** |
| 32K first token | 18.97 s | **16.64 s** | **−12.3 %** |
| 16K prompt tok/s | 1675.5 (1568.4–1681.5) | **1889.5 (1679.1–1890.3)** | **+12.8 %** |
| 16K first token | 9.61 s | 8.52 s | −11.3 % |
| 4K prompt tok/s | 1163.4 (965.3–1170.0) | 1163.8 (970.0–1163.9) | **0.0 %** |
| 4K first token | 3.47 s | 3.47 s | none |
| chat decode tok/s | 61.9 (50.1–68.1) | 67.2 (53.8–73.6) | +8.6 % (ranges overlap) |
| chat first token | 0.46 s | 0.43 s | −6.5 % |
| agent decode tok/s | 77.4 (58.3–96.6) | 85.2 (59.0–99.3) | +10.1 % (ranges overlap) |
| agent turn first token | 3.35 s | 3.36 s | none |
| agent cache hit | 69.58 % | 69.29 % | none |
| agent re-read tokens/session | 3.00 (2–5) | 143.00 (3–145) | worse on A, one outlier, n=3 |

The 4K row is the control: a 4K prompt is one chunk either way, and the two arms are identical to 0.4 tok/s. So the 16K/32K gains are the chunk, not the machine drifting between runs.

The decode rows are not clean: every range overlaps. Take them as "no decode penalty", not as "+8 %".

## 3. The trade, in one line

**3.50 GiB of system RAM buys +13.9 % prefill on 32K prompts and −2.3 s to the first token.** On this machine (46 GiB) the 16384 arm still ends the bench with 3.95 GiB available and no swap growth, so it is affordable; the 8192 arm leaves 7.66 GiB free, which is the choice if something else on the box needs the room.

Scaling check against the earlier IQ3_XXS pair (chunk 32768 → 8192 gave lend 9.73 → 2.88 GiB, complement 35.99 → 29.14): the loan grows with the chunk on both models, and the RAM follows the loan.

## 4. Two things this pair did not settle

- **VRAM pressure is not the chunk's doing.** Both arms start at 672 MiB free, and the 8192 arm still hit `WARNING: only 508 MiB of VRAM free … below 512 MiB (#2065)` mid-run, where the engine now asks for `--vram-reserve-mib 832`. At 224K context, 768 is not enough; that is a separate change to test.
- **Conversation-cache behaviour differs by traffic, not by chunk.** The 8192 arm parked bigger snapshots (`parked=1 bytes=2061508444` = 1.92 GiB, then 1.94 GiB, with evictions) than the 16384 arm (1.69 GiB), because the bench turns landed differently. Do not read that as a chunk effect.

## 5. What to change in `rdna3/configs/iq2_xs-1gpu.json`, on this evidence

- Keep `STRATA_PREFILL_AUTO_MAX=16384` if the box is otherwise idle: it is worth 13.9 % on long prompts for 3.5 GiB.
- Raise `--vram-reserve-mib` to 832 (the engine's own number now) — the 508 MiB warning appeared even at 768.
- `--pool-workers 8` still warns on 8 physical cores; 7 is the engine's recommendation.

## 6. `--pool-workers`: what it does here, and why 7 is the number to try

The machine is a Ryzen 7 7800X3D: **8 physical cores, 16 threads** (`nproc` 16, `Thread(s) per core: 2`).

- The warning comes from `src/kernels/cpu/pool.cpp:1009`.
- The default is `pool_workers = 0`, which means **"all physical cores minus the host's"** (`src/program/generate.cpp:614`) — on this box, 7. Writing 8 is what forces the oversubscription, and the engine's own log says which one it wanted: `CPU pool tasks/phase: 27 (automatic), participating threads: 9` (8 workers plus the host worker, on 8 cores).
- `STRATA_PREFILL_CPU_SHARE=0` (`src/prefill/prefill.cpp:240-269`) turns off the one path that lends the pool to **prefill** chunks. So `prompt tok/s` should barely move; what the pool costs is the experts it evaluates on the CPU during **decode**.

Expectation, not a measurement: a small decode gain, no prefill change. Every number in this file was taken with 8 workers, so "7 is better" is still unmeasured — it needs the same matched pair, one line changed, same bench.

## 7. `STRATA_PREFILL_CPU_SHARE=0` — there is nothing to "turn back on", and it is off on AMD by design

From `src/prefill/prefill.cpp:240-254`:

- What it does: a chunk **below `stream_all_min()`** hands the decode CPU pool — idle while a prompt is being read — the few non-resident experts that chunk's tokens route to, instead of streaming them over PCIe.
- Who arms it by default: "ON BY DEFAULT where it was measured (**CUDA builds**, one GPU, no batch slots) … the layer split, batch slots and **HIP stay off**", with `bool g_share_default = false`.

So on this 7900 XT the share is off whether or not the config says `0`. Writing `0` is not suppressing a default we would otherwise get; writing `auto` or a number forces a path upstream has never measured on AMD.

`STRATA_PREFILL_CPU_SHARE_MAX=4096` is dead config while the share is off: `cpu_share_max()` only feeds `g_stream_min_share` when `cpu_share_on()` is true (`prefill.cpp:2823`).

The gains upstream measured (RTX 5090 + 9950X3D, 600-token prompts, share 0.65):

| pack | ms off | ms on | gain |
|---|---|---|---|
| UD-Q4_K_XL | 1528–1548 | 1296–1369 | −13 % |
| Q2_0 | 472–491 | 445–448 | −7 % |
| **IQ2_XS** | **507** | **490** | **−3.4 %** |
| IQ2_XS, 250 tokens | 402 | 368 | −8.5 % |

IQ2_XS is the weakest of the three packs listed, and all of it is CUDA.

Three reasons it is low value here:

1. Only chunks below `stream_all_min()` are touched, so the 16K/32K rows of section 2 would not move. The only lines that could are `chat first token` (0.46 s) and the small cold prompts we already have (`1028 read in 1720 ms = 597.7 tok/s`).
2. It is not output-identical: "`STRATA_PREFILL_CPU_SHARE=0` turns it off: the output is then the 0.1.40.3 bytes", and the default-on note carries "mean KL against the share off about 0.004".
3. It competes with the same pool that does the decode CPU experts, on a box where that pool is already oversubscribed (section 6).

Memory: no new resident copy expected — the pool is borrowed during a prompt, when it is idle.

If tried anyway: `"STRATA_PREFILL_CPU_SHARE": "auto"` on its own (leave everything else), same bench, and read only `chat first token` and the 4K row.
