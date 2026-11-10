# The IQ2_XS run: same fork, same 8192 chunk, third data point

Snapshot `snapshots/fork-iq2xs-8192-20261109T145759Z.*`, log `logs/rdna3-iq2_xs.log` (engine started 22:53:44), same engine binary `fb975936515c`. Model `Qwen3.8-Flash-Next-UD-IQ2_XS` (39.4 GiB of experts), `--max-context 184000`, `--conversation-cache-mib 1536 --conversation-cache-slots 2`, `STRATA_PREFILL_AUTO_MAX=8192`, `STRATA_RESIDENT_PIN=0`, `--resident-budget-gib 37`, `--vram-reserve-mib 512`.

## 1. Memory

| | IQ3_XXS, chunk 32768 | IQ3_XXS, chunk 8192 | **IQ2_XS, chunk 8192** |
|---|---|---|---|
| GPU expert cache | 8468 slots / 13.70 GiB | 8468 slots / 13.70 GiB | 7600 slots / 12.18 GiB |
| experts outside the cache | 26.26 GiB | 26.26 GiB | 27.20 GiB (16976; "the rest are read from the files") |
| lend region kept in RAM | 6041 slots / 9.73 GiB | 1777 slots / 2.88 GiB | 2519 slots / 4.04 GiB |
| resident complement | 35.99 GiB | 29.14 GiB | **31.24 GiB** (pageable, pinned 0.00, 54 s) |
| engine RSS | 38.47 GiB | 31.35 GiB | **33.44 GiB** |
| engine VmHWM | 38.72 GiB | 32.06 GiB | 33.51 GiB |
| `MemAvailable` | 4.67 GiB | 11.81 GiB | **9.56 GiB** |
| VRAM used / free | 19.88 / 414 MiB | 19.91 / 414 MiB | 19.90 / **444 MiB** |
| GTT used | 33 MiB | 25 MiB | 21 MiB |
| swap in use | 140 MiB | 165 MiB | 159 MiB |
| `strata-vision` / python | 0.94 / 0.21 | 0.94 / 0.21 | 0.94 / 0.21 |

The complement again adds up exactly: 27.20 + 4.04 = 31.24 GiB. So the same rule is at work on a second model, and with the chunk at 8192 the loan is 4.04 GiB instead of the 9.73 GiB the 32768 chunk took.

## 2. Why this run sits 2.09 GiB above the IQ3_XXS 8192 run

Not the experts, and not the chunk:

- `--conversation-cache-mib 1536 --conversation-cache-slots 2` is on here and off in the IQ3_XXS config. One conversation really is parked: `parked=1 bytes=1580789976` = **1.47 GiB**.
- Four more times it tried and refused: `conversation cache: skip parking (snapshot 1560 MiB / 1593 / 1769 / 1812 MiB exceeds available budget)`. The parked entry plus the KV/window overhead for `--max-context 184000` (against 128000 there) covers most of the 2.09 GiB.

RSS was flat over 40 s at three samples (35,079,780 kB every time, HWM unchanged) while `MemAvailable` drifted slightly up. Nothing is growing.

## 3. Speed lines this run produced (real traffic, not the bench suite)

```
prompt 88422 tokens = 0 reused + 88422 read in 59662 ms (1482.0 tok/s), 1095 generated in 15899 ms (68.9 tok/s)
prompt 92206 tokens = 83277 reused + 8929  read in  8007 ms (1115.1 tok/s), 1175 generated in 17204 ms (68.3 tok/s)
```

A 88K-token cold prompt at 1482 tok/s and decode 68–69 tok/s, with the card at 444 MiB free. Put beside the IQ3_XXS 8192-arm bench (32K at 1773–1796 tok/s, decode 68.8), the decode speed is the same and the big-prompt prefill is lower — but these are different models and different prompt lengths, so do not read a chunk effect into it.

## 4. The one thing this arm proves about the VRAM side

Changing the chunk did not free the card: 414 MiB → 444 MiB. The GPU cache simply grew to fill it (12.18 GiB here, 13.70 there). The card is full either way and `#2065` still warns on every request. The only knobs that move that number are `--vram-reserve-mib` (upstream suggests 640) or `--max-context`, and that is still untested here.

## 5. Still unmeasured

- A same-prompts bench at 32768 for either model, so "the 8192 arm is not slower" rests on log lines with unequal prompt lengths and cache states.
- `--vram-reserve-mib 640/1024` on this model, where the engine itself now suggests 640.
- Whether `--conversation-cache-mib 1536` is worth its 1.47 GiB on a machine with 9.5 GiB free; four out of five park attempts were refused for lack of budget, which hints the setting is already tight.
