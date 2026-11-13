# Should the chunk go to 20480 or 24576? — the log already answers it

## 1. The engine already tried ~23K, and it did not go well

Every IQ2_XS run that had `STRATA_PREFILL_AUTO_MAX=32768` printed the same shape (`logs/rdna3-iq2_xs.log` lines 46-65, 327-346, 459-478, 802-821, 984-1003, 1105-1125):

```
FileExpertSource: the prompt path's lend region: 6252 of its 6532 slots keep their experts in RAM too
                  (10.04 GiB of the budget's remaining 10.04 GiB)
strata generate: WARNING: a prompt chunk of 32768 tokens lends 6532 cache slots to the prompt path,
                 but only 6252 of their experts fit in RAM: the others are read from the files
strata serve: prompt chunk auto: 23296 tokens, a 192-slot ring
strata serve: the prompt path borrows 6532 CUDA0 cache slots (10.48 GiB)
```

Three things to read out of that:

1. **The RAM guard stepped 32768 down to 23296 / 23040 / 22784** — so 20-24K is not a new setting, it is where this box already lands when asked for 32K.
2. **The loan saturates at ~90 % of the cache** (`kAutoLendPct`, `generate.cpp:8038-8045`): 6397-6532 slots no matter whether the chunk is 22784 or 32768. Past ~20K, a bigger chunk buys **no extra loan** — it just asks for a chunk the guard will cut.
3. **The budget was already over**: "only 6252 of their experts fit in RAM: the others are read from the files". Complement would be 27.77 + 10.3 ≈ **38.1 GiB against a 37 GiB budget**.

And one run in that arm stopped itself:

```
line 1051: no progress for 60 s during a request (reading the prompt (batched): layer 44 of the prompt
           chunk from token 8344) - stopping the engine so the request can be retried
line 1052: stall report (engine 0.1.49.1): stage "reading the prompt (batched): layer 44 ... " for 61 s
```

## 2. Where 20K and 24K sit against the measured arms

| chunk | lend region | complement | engine RSS (idle) | `MemAvailable` |
|---|---|---|---|---|
| 8192 | 2520 slots / 4.03 GiB | 31.81 GiB | 34.02 GiB | 9.02 GiB |
| **16384 (current best)** | 4692 / 7.53 GiB | 35.31 GiB | 37.71 GiB | 5.40 GiB → **3.95 after bench** |
| ~23K (what 32768 gave) | 6397–6532 / 10.26–10.48 GiB | **≈ 38.1 GiB (over budget)** | not snapshotted | — |
| 20480 | interpolates ≈ 5900 slots / 9.4 GiB | ≈ 37.2 GiB | — | — |
| 24576 | saturates ≈ 6500 slots / 10.4 GiB | ≈ 38.1 GiB | — | — |

The 37 GiB budget is the wall, and both 20480 and 24576 are at or past it. Past the wall the lend region's experts stop being RAM-resident and start being read from disk during the prompt — which is slower than the smaller chunk that fit.

Also relevant, from `journalctl -u strata`: the service that ended at 11:11:02 reported **`43.5G memory peak, 5.5G memory swap peak`**. Swap was already being used before any chunk increase.

## 3. The step function: what a bigger chunk actually buys

A chunk at or above `stream_all_min` (1024) streams every non-cached expert **once per chunk**, so the cost is the number of chunks (`generate.cpp:718-721`):

| prompt length | 8192 | 16384 | 20480 | 24576 | 32768 |
|---|---|---|---|---|---|
| 32K | 4 | **2** | 2 | 2 | 1 |
| 40K | 5 | 3 | 2 | 2 | 2 |
| 64K | 8 | **4** | 4 | **3** | 2 |
| 88K | 11 | 6 | 5 | **4** | 3 |
| 124K | 16 | 8 | 7 | 6 | 4 |

- **For prompts up to ~32K, 20480 and 24576 buy nothing** — still 2 chunks, same as 16384. Pure RAM cost.
- 24576 only helps from about 40K tokens up (64K: 4 chunks → 3, i.e. ~25 % less expert streaming).
- The one jump that matters at 32K is a single 32768 chunk, and this box cannot fund it.

## 4. Recommendation, split into the two questions it used to mix

Two separate things decide this, and they have different answers.

**(a) Does a bigger chunk help this workload? Yes, clearly.** The real prompts in this log are 88,422 / 92,206 / 108,211 / 124,241 tokens, and live sessions run past 140K. At those lengths the chunk count is the whole cost:

| prompt | 16384 | 20480 | 24576 | 32768 |
|---|---|---|---|---|
| 88K | 6 | 5 | **4** | 3 |
| 124K | 8 | 7 | **6** | 4 |
| 142K | 9 | 7 | **6** | 5 |

24576 is 9 → 6 chunks at 142K, about a third less expert streaming. So "only if your traffic is ≥ 40K" was met all along; that clause was never the reason to hesitate.

**(b) Can the box pay for it? Barely, and only if something else gives up its RAM.** At ~23K the engine needed 10.48 GiB of loan and found 10.04 GiB of budget left, so it kept 6252 of 6532 slots resident and let 280 slots (~0.44 GiB) fall to the files. That is the near-miss, and the whole run sits on top of it:

| | 16384 arm | ~23K |
|---|---|---|
| complement | 35.31 GiB | ≈ 38.1 GiB (**+2.8 GiB**) |
| + parked conversation | 1.69 GiB | 1.69 GiB |
| + vision + python | 1.15 GiB | 1.15 GiB |
| `MemAvailable` left, after a bench | 3.95 GiB | **≈ 1.1 – 2.6 GiB** |

1-2.6 GiB of slack on a 46 GiB box is how swap happens, and a 5.5 GiB swap peak is already on record for this service. So the hesitation was about (b), not (a).

**To make 24576 affordable, free the room first, in this order:**

1. `--conversation-cache-mib 2048 → 512` — gives back the 1.69 GiB parked entry. This alone covers the 0.44 GiB near-miss with room to spare.
2. `--max-context 224000 → 160000` if you do not genuinely need 224K — trims the window and KV buffers.
3. Then set `STRATA_PREFILL_AUTO_MAX=24576` and read the two lines in §5.

Do not raise `--resident-budget-gib` to fund it: that knob is the wall itself, and raising it just moves the shortfall from "read from files" to "no RAM left".

Note also that 20480 and 24576 will probably land in the same place: the 32768-ceiling runs settled at 23296 / 23040 / 22784, so asking for 24576 gets you ~23K, which is the state whose outcome is already in the log.

### The two log lines that decide it, whatever you set

```
the prompt path's lend region: N of its M slots keep their experts in RAM too   # want N == M
WARNING: a prompt chunk of ... lends ... but only N of their experts fit in RAM  # if this appears, roll back
```

`N == M` means the loan is RAM-resident and the chunk is affordable. `N < M` means you are reading experts off disk mid-prompt, and the chunk should come down.

## 5. Not measured

No snapshot or bench exists at 20480 or 24576; the ~23K numbers above are the engine's own accounting lines from the 32768-ceiling runs, not a snapshotted arm. The stall at line 1051 is one event in one run and its cause is not proven — it is reported as evidence against, not proof.
