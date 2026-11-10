# Conversation cache: what `--conversation-cache-slots 1` and `1536 MiB` really mean here

Asked 2026-11-10. The running arm has **both** at `0` (off). The question is the hypothetical:
is `slots 1` a waste (do you need ≥2 to get anything restored), and would `2 × 1536 MiB`
break the current setup?

Code read from this tree (`src/program/generate.cpp`, `include/strata/core/conversation_cache.hpp`),
costs measured from `logs/rdna3-iq2_xs.log`.

## 1. `--conversation-cache-mib` is a TOTAL byte budget, not per slot

```cpp
// generate.cpp:9993
strata::core::ConversationCache conversations(
    o.prompt_cache > 0 ? (size_t) o.conversation_cache_mib * 1024 * 1024 : 0,
    (size_t) o.conversation_cache_slots, o.conversation_cache_min_tokens);

// conversation_cache.hpp:210-212, 236, 246
ConversationCache(size_t budget, size_t slots, int64_t min_tokens = 0)
    : budget_(budget), slots_(slots), min_tokens_(min_tokens) {}
bool enabled() const { return budget_ != 0 && slots_ != 0; }
if (enabled() && candidate.bytes() <= budget_ - bytes_) reuse_ = std::move(candidate);
return enabled() && held <= budget_ && incoming <= budget_ - held && ...
```

So `budget_` is shared by every parked conversation; `slots_` is only a **count** cap. That
means:

- **`--conversation-cache-mib 1536 --conversation-cache-slots 2` does NOT mean 2 × 1536 MiB.**
  It means 1536 MiB shared between at most 2 conversations. To hold two snapshots you raise
  `mib`, not `slots`.
- `enabled()` needs **both** non-zero. The first draft of the config
  (`mib 1` / `slots 1536`) was technically enabled and completely useless: 1 MiB cannot hold a
  snapshot, so every `candidate.bytes() <= budget_ - bytes_` test fails.

## 2. What a parked snapshot actually costs (measured)

Every park line in this log, converted:

```
parked=1 bytes=1901558644 evictions=1   → 1.87 GiB
parked=1 bytes=1928875564 evictions=2   → 1.90 GiB
parked=1 bytes=1981760628 evictions=3   → 1.92 GiB
parked=1 bytes=2007268680 evictions=4   → 1.94 GiB
parked=1 bytes=2035914316 evictions=5   → 1.96 GiB
parked=1 bytes=2106036708 evictions=6   → 1.99 GiB
parked=1 bytes=1860742428 evictions=8   → 1.73 GiB
```

Plus the older pair: 109 761 tokens → 1 819 200 856 B = **1.69 GiB ≈ 16 KiB per token**.

Two things fall out:

1. **One snapshot of this conversation is 1.7–2.0 GiB.** A `1536 MiB` budget cannot hold it —
   the guard is `candidate.bytes() <= budget_ - bytes_`, i.e. 1.9 GiB ≤ 1.5 GiB → refused.
   The log proves it happened exactly that way: at 1536 MiB it parked **1.47 GiB once** and
   then **refused four more attempts** (snapshots 1560 / 1593 / 1769 / 1812 MiB over budget).
2. `evictions=1…8` climbing while `parked` stayed at 1 = the engine paid the park cost every
   turn and evicted its own work every turn. That is the real "waste", and it is a **byte**
   problem, not a slot-count problem.

Scale it to the new context: at ~16 KiB/token, a conversation that fills
`--max-context 224000` would want **~3.4 GiB per parked conversation**.

## 3. Is `slots 1` a waste?

Not structurally — but the engine default is 4 (`generate.cpp:826`) and the code comments say
why a small count hurts:

```
// generate.cpp:828-830  (--conversation-cache-min-tokens)
/// park only conversations of at least this many tokens.  Every parked conversation costs one of
/// conversation_cache_slots whatever its length, so without it a client that interleaves short side
/// requests with one long conversation evicts the long one (oldest first).
```

- A parked conversation occupies a slot **whatever its length**, so with 1 slot a single short
  side request evicts the long conversation you parked — which is precisely an agent harness.
  `--conversation-cache-min-tokens` exists to stop that; without it, `slots 1` is fragile.
- 1 slot is the floor for "park A, work on B, come back to A". Whether the switch-in restores
  before the switch-out parks (so the slot is free in time) I did **not** verify in code, so I
  will not claim it either way. The safe statement: **2 slots is what makes A↔B ping-pong
  safe; 1 slot only ever keeps one of them.**
- On this box the distinction is academic: at 1536 MiB the budget rejects the snapshot before
  the slot count ever matters.

## 4. Would 2 × 1536 MiB (i.e. `mib 3072`) break the current setup?

**Yes, it would take the box past the line.** Live numbers on the running
(`--prefill 20480`, `--max-context 224000`) arm:

| | now |
|---|---|
| MemAvailable | **3.80 GiB** |
| engine VmRSS / VmHWM | 39.62 / 39.73 GiB |
| engine VmSwap | 0 B |
| system swap used | 1.19 GiB |
| `Cached` (page cache) | **0.79 GiB** — already crushed by the pin pass |
| resident complement | 37.12 GiB **page-locked**, unreclaimable |

The engine's own rule for sizing this cache is `auto_conversation_cache_mib(available,
conversation_cache_min_free_mib)` with a **floor of 2560 MiB** (`generate.cpp:827`):

```
available 3.80 GiB − floor 2.50 GiB ≈ 1.3 GiB of usable budget
```

…which is **less than one snapshot (1.9 GiB)**. That is why the auto path prints
`conversation cache off: not enough free RAM to park conversations` on a box in this state,
and why the config correctly sets `0`.

Asking for 3072 MiB explicitly would spend 3.0 of the 3.8 GiB available, leaving ~0.8 GiB —
under the engine's own 2560 MiB floor, with the page cache already at 0.79 GiB and the
complement locked so nothing can be reclaimed. That is the shape of the run that logged
`43.5G memory peak, 5.5G memory swap peak` and a 60 s stall.

## 5. Verdict

- **Keep both at 0** on this box with `--prefill 20480`. There is no honest RAM for parking
  right now: 1.3 GiB usable vs 1.9 GiB per snapshot.
- `--conversation-cache-mib 1536 --conversation-cache-slots 1` is *safe* (it will simply
  refuse to park, and refuse loudly) but **useless for conversations of this size** — it is
  not a smaller cache, it is an off switch that still pays for the bookkeeping.
- If you want parking, buy the RAM first and then ask for enough of it:
  - drop the chunk to `--prefill auto` (gfx1100 picks 16384) → **+1.75 GiB** back
    (`EXPLICIT-20480-RESULT.md` §2);
  - then `--conversation-cache-mib 2048 --conversation-cache-slots 2 --conversation-cache-min-tokens 8000`
    holds **one** ~110 K-token conversation with the min-tokens guard protecting it from short
    side requests. Two parked conversations of this length would need ~4 GiB, which this box
    does not have while the complement is 37.12 GiB locked.

## 6. The exact scenario asked: `slots 2` + `mib 1536`, park 80 K, then a short side request

The deciding code is `make_room` (`conversation_cache.hpp:315-330`):

```cpp
while (!entries_.empty() && (entries_.size() >= slots_ || bytes_ > budget_ - held - incoming)) {
    // the oldest entry that does not hold a pinned shared prefix leaves; with only pinned ones left the new
    if (!evict_oldest()) return false;
}
```

and `put` refuses **before** evicting anything (`:422-426`):

```cpp
if (!enabled() || held > budget_ || n > budget_ - held) return false;   // make_room's refusal, first
```

Numbers: measured snapshot density is **16.19 KiB/token** (`1 819 200 856 B / 109 761 tokens`).

| parked | size | vs `mib 1536` (1.50 GiB) |
|---|---|---|
| 80 000 tok | **1.23 GiB** | fits, **271 MiB headroom** |
| 97 175 tok | 1.50 GiB | the budget ceiling |
| 128 000 tok | **1.98 GiB** | **cannot be parked at all** |

So for the asked sequence — park an 80 K conversation, interleave a `"hello, how are you"`:

1. The 80 K one parks: `entries_.size() = 1`, `bytes_ = 1.23 GiB`.
2. The short request finishes and is parked. `make_room` tests `entries_.size() >= slots_` → `1 >= 2` **false**, and `bytes_ > budget_ - incoming` → `1.23 > 1.50 − ε` **false**. **No eviction.**
3. Coming back to the 80 K conversation: its image is still there → **restorable.** ✅

**And this is the proof of the "at least 2 slots" claim**: with `slots 1`, step 2 hits
`entries_.size() >= slots_` → `1 >= 1` **true** → `evict_oldest()` takes the 80 K conversation
out, before you ever return to it. `min_tokens` defaults to **0 = park every conversation**
(`generate.cpp:831`), so nothing stops the short request from spending the slot.

Two things that still break it, independent of slot count:

- **The 80 K conversation re-parks every turn.** Each new snapshot must satisfy
  `n <= budget_ - held`; the log shows `evictions=1…8` climbing while `parked` stayed at 1 —
  it paid the park cost and evicted its own work every turn.
- **It grows.** Past ~97 K tokens its own snapshot exceeds 1536 MiB and `put` refuses it
  outright (not an eviction — it simply never parks). The 128 K case is already over the line.

The right guard is `--conversation-cache-min-tokens` (set above the short request's length,
e.g. 8000): then the side request never spends a slot and never competes for bytes, and
`slots 2` is genuinely enough for A↔B ping-pong.

## 7. Unverified / caveats

- The park-before-restore ordering at a conversation switch (point 3) was not read in code;
  the 1-vs-2 slot claim is stated as "1 keeps only one", not as "1 never restores".
- `16 KiB/token` is derived from two logged snapshots (109 761 tokens → 1.69 GiB) and the
  1.73–1.99 GiB band; it is not a formula from the source, and it may differ for a
  conversation whose layers reuse more (`reused_kv_bytes` was 0 in every line above).
- No arm with conversation cache ON has been measured against this 20480-chunk config.
