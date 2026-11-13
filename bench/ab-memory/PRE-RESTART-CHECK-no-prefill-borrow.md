# Before restarting with `--no-prefill-borrow`: three things to know

Checked against the code in this tree. The flag is real and the parser knows it (`generate.cpp:2706`), but as the config stands it does not do what the experiment intends.

## 1. Blocking: `--no-prefill-borrow` + `--prefill auto` forces the chunk down to 2048

`src/program/generate.cpp:3271-3274`:

```cpp
if (o.prefill_auto && (o.no_prefill_borrow || o.expert_profile.empty())) {
    o.prefill_auto = false;       // nothing to lend from: the buffers are reserved for the session, so keep them small
    o.prefill_chunk = 2048;
}
```

So with `"--prefill", "auto"` (line 33) and `"--no-prefill-borrow"` (line 71):

- `--prefill auto` is **turned off**, and
- the chunk becomes **2048 tokens**, and
- `STRATA_PREFILL_AUTO_MAX=32768` (line 80) becomes **dead config** — nothing reads it once `prefill_auto` is false.

The run will therefore not be "no-borrow at a big chunk". It will be "no-borrow at 2048", which is the slowest chunk we have ever run on this box: the matched pair measured 8192 → 16384 at **+13.9 %** on 32K prompts, so 2048 is a long way down that curve (2048 on this model is unmeasured).

To keep a real chunk with no borrow, name the chunk instead of using `auto`:

```json
  "--prefill",
  "8192",
```

The forcing only happens on the `prefill_auto` branch.

## 2. `--resident-budget-gib 37` is gone, replaced by `--resident-experts`

The args now end with `--resident-experts` (line 70); there is no `--resident-budget-gib` anywhere in the file. `generate.cpp:2864-2872`:

```cpp
else if (a == "--resident-experts") {
    o.mmap_experts = o.resident_cpu_experts = o.resident_pin = o.resident_soft = true;
    o.resident_headroom = 4ull << 30;
    // A/B arms: STRATA_RESIDENT_PIN=0 keeps the copy pageable ...
    if (const char* v = std::getenv("STRATA_RESIDENT_PIN"); v != nullptr && std::string(v) == "0")
        o.resident_pin = false;
```

What that means here:

- `STRATA_RESIDENT_PIN=0` (line 120) **does** keep it pageable — that part is correct.
- budget 0 = **the whole complement**, not a 37 GiB budget (`generate.cpp:644`: "0 = the whole complement (--resident-experts)").
- `resident_soft = true` and 4 GiB headroom: if the complement does not fit it warns and falls back to plain mmap.
- This is a second variable changed at the same time, so the run is not comparable to `speed-iq2xs-8192` or `speed-iq2xs-16384`.

## 3. The prediction worth stating before you measure: no-borrow probably does not save RAM

In resident mode, **whatever the GPU expert cache does not hold lives in RAM.** The prompt path's buffers take VRAM either way:

| | where the prompt's `bytes_needed(chunk)` VRAM comes from | RAM consequence |
|---|---|---|
| borrow (default) | the cache's top slots | those slots' experts are duplicated in RAM (`+ lend region`) |
| `--no-prefill-borrow` | a session-long reserve withheld **from the cache** (`generate.cpp:4634, 8883`) | the cache is that much smaller, so the complement is that much **bigger** |

Reasoned from those comments, not measured: the two should roughly cancel. What no-borrow actually changes is that the reserve is fixed at the chunk size for the whole session, and the decode cache is permanently smaller — which costs decode hit rate.

The one case where it clearly wins on RAM is exactly the case §1 warns about: chunk forced to 2048 makes the reserve ~1 GiB instead of ~4 GiB, so RAM drops about 3 GiB — bought with prefill speed, not with the flag.

## 4. Other lines that moved since the last measured arm

| | `speed-iq2xs-8192` | `speed-iq2xs-16384` | config now |
|---|---|---|---|
| `--max-context` | 224000 | 224000 | 224000 |
| `--vram-reserve-mib` | 768 | 768 | **832** |
| `--pool-workers` | 8 | 8 | **7** |
| resident mode | `--resident-budget-gib 37` | same | **`--resident-experts`** |
| `--prefill` | auto, AUTO_MAX 8192 | auto, AUTO_MAX 16384 | **auto + `--no-prefill-borrow` → 2048** |
| `STRATA_PREFILL_CPU_SHARE` | 0 | 0 | 0 |

Four variables, so this run answers "what does this whole config cost", not "what does no-borrow cost".

## 5. Cleanest next arms, in the order that answers the most

1. **`--prefill 8192` + `--no-prefill-borrow`, everything else back to the 8192 arm** (`--resident-budget-gib 37`, `--vram-reserve-mib 768`, `--pool-workers 8`). One variable against `speed-iq2xs-8192`. This is the arm that tests the idea.
2. If (1) shows no RAM saving, stop pursuing no-borrow: the RAM is the complement, and the complement is `experts − cache`.
3. The VRAM side is still the open code question: ours reserves no room for post-cache allocations, upstream reserves `+256 MiB`. `--vram-reserve-mib 832` is the workaround; the engine asked for 832 itself at 224K context.
