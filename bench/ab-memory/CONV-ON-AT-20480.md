# Conversation cache ON (`2048` / `2`) with `--prefill 20480` — measured (2026-11-10 16:45)

`CONV-CACHE-SIZING.md` §7 said *"no arm with conversation cache ON has been measured against
this 20480-chunk config"*. That arm is now running, and this is its measurement.

Engine pid 236310, started **14:44:31**, engine `fb975936515c`, git `ce61f3b0`.
Snapshot `snapshots/iq2xs-20480-conv2048-on-20261110T084235Z.txt/.keys`, log `logs/rdna3-iq2_xs.log`.

## 1. First: the running process is not the config file

| | `--prefill` | conversation cache |
|---|---|---|
| **running** (pid 236310, boot 14:44:31) | **20480 explicit** | **2048 MiB / 2 slots** |
| **on disk** (`rdna3/configs/iq2_xs-1gpu.json`, mtime **14:48:46**) | **auto** | 2048 MiB / 2 slots |

The file was edited **4 minutes after** the engine started, so the editor and the box disagree.
The next restart will be **`auto` (this build picks 16384 on gfx1100) + parking on**, which is a
different arm from the one measured here — and the better one (§5).

## 2. The expert side is unchanged by parking — as the identity predicts

```
expert cache 7200 slots, 11.54 GiB of VRAM
FileExpertSource: 5778 of the prompt path's 5778 lendable slots keep their experts in RAM too
FileExpertSource: mapped pinned cache complement ready: resident 37.12 GiB, pinned 37.12 GiB in 92 s
FileExpertSource: 23.02 GiB really free for a 37.12 GiB page-locked complement: 35.66 GiB free
strata serve: 734 MiB of VRAM free with everything loaded
```

Identical to `EXPLICIT-20480-RESULT.md` §1 (7200 / 11.54 / 5778 / 37.12), and
`grep -cE 'WARNING|does not fit|only [0-9]+ of their experts'` since boot = **0**. Turning
parking on did not touch the complement; it is RAM *on top* of it.

## 3. The RAM bill for turning parking on

| | 20480, parking **off** | **20480, parking ON (now)** | Δ |
|---|---|---|---|
| complement (page-locked) | 37.12 GiB | 37.12 GiB | — |
| engine VmRSS | 39.57 GiB | **41.0 GiB** (42 955 360 kB) | **+1.4 GiB** |
| engine VmHWM | 39.59 GiB | **41.16 GiB** | +1.6 |
| **engine VmSwap** | 0 B | **40 MiB** | first time the engine itself is swapped |
| MemAvailable (idle) | 3.88 GiB | **2.8 GiB** | −1.1 |
| MemAvailable (snapshot samples 2/3) | — | 3.87 / 4.17 GiB | swings 1.4 GiB |
| system swap used | 1.19 GiB | **1.5 GiB** (vision 954 MiB, engine 39, python 70) | +0.3 |
| `Cached` | 0.78 GiB | 2.15 GiB | +1.4 |
| decode hit rate | 77.9 % | 69.2–83.5 % | same band |

So parking costs **about 1.4 GiB of RSS on top of the 37.12 GiB lock**, and it is the difference
between "engine never swaps" and "engine has 40 MiB in swap". Decode speed shows no visible
damage (hit rate is in the same 69–83 % band as every other arm).

## 4. What the engine actually did with a 2048 MiB budget: it mostly said no

Since boot: **35 refusals, 9 parks, 1 restore.** Two different gates refuse, and the second one
is the one that matters here.

**Gate 1 — the cache's own byte budget** (`generate.cpp:10161`, `make_room`):
```
conversation cache: skip parking (snapshot 2071 MiB exceeds available budget)
```

**Gate 2 — a live physical-RAM check I had not documented** (`generate.cpp:10168-10196`,
`include/strata/core/conversation_memory.hpp:82-85`):
```cpp
inline bool conversation_memory_admit(std::optional<uint64_t> available,
                                      uint64_t allocation, uint64_t floor) {
    return available && *available >= floor && allocation <= *available - floor;
}
// generate.cpp:10183-10190: sample /proc/meminfo, and if it fails, evict parked
// conversations (up to slots()) and re-read, before refusing.
```
```
conversation cache: skip parking (physical RAM admission; need 1997 MiB plus 2560 MiB floor,
                     4482 MiB available, source meminfo; evicted 0, 0 still parked)
conversation cache: evicted 1 parked conversation to admit this snapshot (766 MiB plus 2560 MiB floor)
conversation cache: no room beside the parked conversation this request starts with; taking it
                    instead of borrowing
```

**The rule is `MemAvailable ≥ snapshot + 2560 MiB`, checked against live meminfo at park time.**
With the complement locked at 37.12 GiB, MemAvailable sits between 2.8 and 4.5 GiB, so the gate
only opens for snapshots under ~0.3–1.9 GiB and only in the good moments. That is why it parked 9
times and refused 35. `evictions` climbed 4 → 6 → 8 → 10 while `parked` stayed at 1–2: it is
still paying the park cost and evicting its own work, exactly the waste `CONV-CACHE-SIZING.md`
§2 described — now with the engine's own admission gate as the reason.

**This is the good news, and it corrects §4/§5 of `CONV-CACHE-SIZING.md`.** That doc said asking
for 3072 MiB "would spend 3.0 of the 3.8 GiB available" and predicted the shape of the run that
hit `43.5G peak, 5.5G swap peak`. It does not: **the engine refuses rather than thrashing.** The
floor is enforced per park, from meminfo, not just in the auto-sizing formula. So an over-large
`--conversation-cache-mib` on this box is a waste, not a hazard.

## 5. Correction: snapshot cost is `~266 MiB + 14.3 KiB/token`, not a flat 16 KiB/token

Nine park lines from this arm (each `parked N tokens … snapshot_bytes`):

| tokens | snapshot | KiB/token |
|---|---|---|
| 19 296 | 504 MiB | 26.75 |
| 26 346 | 565 | 21.95 |
| 33 872 | 1005 | 30.40 ← outlier, `reused_kv_bytes` 87 MiB |
| 34 992 | 752 | 22.00 |
| 36 721 | 767 | 21.38 |
| 42 618 | 818 | 19.65 |
| 46 436 | 851 | 18.76 |
| 47 135 | 857 | 18.61 |
| 94 655 | 1604 | 17.36 |

Least squares over these nine: **`bytes ≈ 266 MiB + 14.28 KiB/token`**, which lands within 8 % on
seven of the nine. Density *falls* with length, so the flat 16.19 KiB/token in
`CONV-CACHE-SIZING.md` §2 (one 109 761-token sample) was right only at the long end. Re-derived
table against the live `2048 MiB` budget:

| parked | with the fit | vs 2048 MiB |
|---|---|---|
| 8 000 | 0.37 GiB | fits |
| 32 000 | 0.70 GiB | fits |
| 80 000 | **1.35 GiB** | fits (was estimated 1.23) |
| 128 000 | **2.00 GiB** | right on the ceiling |
| 224 000 | **3.31 GiB** | refused |

Two consequences: the byte budget stops you at about **128 K tokens**, not 97 K; and the fixed
266 MiB term is why short conversations look expensive per token.

## 6. Verdict

- **The box is not in trouble**: 0 warnings, complement unchanged at 37.12 GiB, `5778 of 5778`,
  decode hit rate unchanged. But RSS is 41.0 GiB, MemAvailable dips to 2.8 GiB, and the engine
  has 40 MiB in swap for the first time in this investigation.
- **Parking at 20480 is 35 refusals to 9 parks.** It is not earning its 1.4 GiB. The admission
  gate (`snapshot + 2560 MiB ≤ MemAvailable`) is the binding constraint, and the chunk is what
  pushed MemAvailable down to where that gate mostly closes.
- **The on-disk config (`--prefill auto` + parking 2048/2) is the arm to run.** `auto` gives back
  1.75 GiB of page-locked RAM (complement 37.12 → 35.31), which is precisely the headroom gate 2
  needs to open more often. That combination was never measured; it is the obvious next arm.
- **Add `--conversation-cache-min-tokens 8000`.** It is still absent from the config, so
  `min_tokens = 0` = park every conversation, and the short side requests are the ones spending
  slots and bytes (`CONV-CACHE-SIZING.md` §6).
- **Do not raise `--conversation-cache-mib` past 2048** at `--max-context 224000`: one 128 K-token
  conversation is already 2.00 GiB, and a second is 4 GiB the box does not have.

## 7. Still unmeasured

- Whether the engine's 40 MiB of swap grows. It was 0 B on every parking-off arm.
- Speed of `auto` + parking vs 20480 + parking, and vs either parking-off arm. No bench was run
  on this arm; §3's decode hit-rate band is the only speed evidence.
- Whether the single `restored 9665 tokens (checkpoint) in 78.1 ms` is representative — one
  restore in 22 hours of log is too few to say parking pays here.
