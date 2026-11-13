# `--no-prefill-borrow` measured: it costs RAM, it does not save it

Clean arm, one flag changed against `speed-iq2xs-8192`. Same engine `fb975936515c`, same IQ2_XS, `--prefill 8192` (named, so not forced to 2048), `--resident-budget-gib 37`, `--vram-reserve-mib 768`, `--pool-workers 8`, `STRATA_RESIDENT_PIN=0`, `--max-context 224000`. Only `--no-prefill-borrow` added.

Snapshot `snapshots/iq2xs-noborrow-8192-20261110T031803Z.*`, engine started 11:11:05.

## 1. The result

| measured | borrow (8192, 23:5x) | **no-borrow (11:11)** | change |
|---|---|---|---|
| GPU expert cache | 7240 slots / 11.61 GiB | **3831 slots / 6.14 GiB** | **−5.47 GiB** |
| lend region kept in RAM | 2520 slots / 4.03 GiB | **none** | −4.03 GiB |
| experts outside the cache | 27.77 GiB | **33.24 GiB** | **+5.47 GiB** |
| resident complement | 31.81 GiB | **33.24 GiB** | **+1.43 GiB** |
| engine RSS (idle) | 34.02 GiB | **35.44 GiB** | **+1.42 GiB** |
| engine VmHWM | 34.09 GiB | 35.52 GiB | +1.43 GiB |
| `MemAvailable` | 9.02 GiB | **7.73 GiB** | −1.30 GiB |
| swap in use | 159 MiB | **284 MiB** | +125 MiB |
| VRAM used | 19.64 GiB | 18.13 GiB | −1.51 GiB |
| VRAM free, engine's line | 672 MiB | 2196 MiB | +1524 MiB |
| decode expert cache hit rate | 70–86 % (typ. 77–82) | **48.9 / 66.1 / 66.2 %** | **down** |

The lend region did vanish, exactly as the mechanism says it should:

```
borrow:     the prompt path's lend region: 2520 of its 2520 slots keep their experts in RAM too (4.03 GiB ...)
no-borrow:  (no lend region line at all)
```

But the complement went **up**, because the cache it replaced was bigger:

```
borrow:     expert cache 7240 slots, 11.61 GiB of VRAM
            RAM budget 37.00 GiB: 17336 of the 27.77 GiB of experts the GPU cache does not hold
            allocating 31.81 GiB pageable resident cache complement        <- 27.77 + 4.03

no-borrow:  expert cache auto: 12.48 GiB free, 768 MiB reserved (+125 MiB for the draft head) -> 3028 slots
            expert cache 3831 slots, 6.14 GiB of VRAM
            RAM budget 37.00 GiB: 20745 of the 33.24 GiB of experts the GPU cache does not hold
            allocating 33.24 GiB pageable resident cache complement        <- 33.24, no lend term
```

Arithmetic: the prompt path's session-long reserve took ~4 GiB of VRAM, and the auto cache sizing then gave back only 1.5 GiB of it as "free", so the cache lost 5.47 GiB and the RAM complement gained 5.47 GiB. The 4.03 GiB lend term that disappeared is paid for by 5.47 GiB that moved from VRAM into RAM. **Net +1.43 GiB RAM.**

## 2. Why it was always going to lose

Resident mode's rule: **whatever the GPU cache does not hold lives in RAM.** The prompt path's `bytes_needed(chunk)` bytes take VRAM either way — as a loan from the cache (and then the loaned slots' experts get a RAM copy) or as a session-long reserve (and then the cache is that much smaller, so that much more lives in RAM). The only difference is which side of the `experts = cache + RAM` identity pays, and a permanent reserve is worse than a loan because it is sized at the largest chunk and held for the whole session, while a loan is repaid and its experts come back.

## 3. The other cost, which is worse than the RAM

The cache halved, and decode felt it immediately:

```
no-borrow:  decode expert cache hit rate: 48.9 % (84212 hits / 172320 lookups)
            decode expert cache hit rate: 66.1 % (659881 / 998880)
            decode expert cache hit rate: 66.2 % (849826 / 1284480)
borrow:     ... 77.4 % / 80.4 % / 81.6 % / 82.3 % on comparable traffic

no-borrow:  the file tier reads through the file cache (... 6.1 GiB of experts read from the files)
no-borrow:  file tier I/O this request: the OS read 50325.4 MB from storage (849 major faults)
            for 6590.3 MB of expert reads
```

6.1 GiB of experts now sit in neither tier and are read from disk. Traffic is not identical between the two runs, so the hit-rate drop is directional — but a 11.61 → 6.14 GiB cache is a mechanical cause, not a coincidence.

## 4. Verdict

- **Do not use `--no-prefill-borrow` on this box.** +1.43 GiB RAM, +125 MiB swap, half the expert cache, hit rate down ~15 points, and real file reads appearing.
- The VRAM headroom it produced (2196 MiB free, no `#2065`) is available far cheaper from `--vram-reserve-mib`, which shrinks the cache by exactly the reserve instead of by the reserve plus the sizing knock-on.
- The best config so far stays the 16384 production arm: `--prefill auto` + `STRATA_PREFILL_AUTO_MAX=16384`, `--resident-budget-gib 37`, `--vram-reserve-mib 832` (the engine's own number at 224K context), `--pool-workers 7`.

## 5. What this arm did prove

It confirmed the mechanism from `WHY-CHUNK-COSTS-RAM.md` end to end: remove the lend region and the RAM complement's lend term goes to zero (31.81 → 27.77 GiB would have been the saving), and RAM is only higher because the same bytes were re-spent as a VRAM reserve that the cache had to fund. The lever on RAM is the **cache size**, and the only free way to change it is `--vram-reserve-mib` — not who holds the prompt buffers.

## 6. Not measured

No bench run on this arm (decode hit rate is from the traffic it served in its first minutes, not `strata_bench.py`). No `--vram-reserve-mib` sweep. No arm with `--no-prefill-borrow` and a small named chunk (e.g. 2048), which is what the engine forces on `auto` — that would shrink the reserve and is the only form of this flag that might pay.
