# Why the fork's resident copy is 35.99 GiB and upstream's is 30.38 GiB

Same model, same pack, same `--resident-budget-gib 37`, same `STRATA_RESIDENT_PIN=0` (the fork's config now carries it too, `rdna3/configs/iq3_xxs-1gpu.json:118`), so pinning is **not** the cause. The engine's own lines add up to the answer.

## 1. The arithmetic, from the two logs

```
fork      logs/rdna3-iq3_xxs.log (22:13 run)
  expert cache auto: 14.31 GiB free, 512 MiB reserved (+105 MiB for the draft head) -> 6317 slots
  expert cache 8468 slots, 13.70 GiB of VRAM
  RAM budget 37.00 GiB: 16108 of the 26.26 GiB of experts the GPU cache does not hold
  the prompt path's lend region: 6041 of its 6041 slots keep their experts in RAM too (9.73 GiB of the budget's remaining 10.74 GiB)
  allocating 35.99 GiB pageable resident cache complement          <- 26.26 + 9.73
  prefill plan: chunk 32768, ring 192 ; prompt chunk auto: 32768 tokens, a 192-slot ring
  the prompt path borrows 6041 CUDA0 cache slots (9.73 GiB)

upstream  strata-iq3_xxs.log (20:42 run)
  expert cache auto: 13.89 GiB free, 512 MiB reserved (+184 MiB draft head, +256 MiB for what is allocated after the cache) -> 5971 slots
  expert cache 8016 slots, 12.95 GiB of VRAM
  RAM budget 37.00 GiB: 16560 of the 27.01 GiB of experts the GPU cache does not hold
  the prompt path's lend region: 2097 of its 2097 slots keep their experts in RAM too (3.37 GiB of the budget's remaining 9.99 GiB)
  allocating 30.38 GiB pageable resident cache complement          <- 27.01 + 3.37
  prefill plan: chunk 8192, ring 96 ; prompt chunk auto: 8192 tokens, a 96-slot ring
  the prompt path borrows 2126 CUDA0 cache slots (3.46 GiB)
```

Resident complement = (the experts the GPU cache does not hold) + (the prompt path's lend region, kept in RAM too).

| term | fork | upstream | difference |
|---|---|---|---|
| experts outside the GPU cache | 26.26 GiB | 27.01 GiB | −0.75 GiB |
| lend region kept in RAM | **9.73 GiB** (6041 slots) | **3.37 GiB** (2097 slots) | **+6.36 GiB** |
| complement | **35.99 GiB** | **30.38 GiB** | **+5.61 GiB** |
| measured engine RSS | 38.47 GiB | 32.47 GiB | +6.00 GiB |

So 6.36 of the 6.00 GiB is the lend region, partly paid back by 0.75 GiB (the fork's GPU cache is 0.75 GiB bigger, so 0.75 GiB less has to sit in RAM).

## 2. Why the lend region is three times bigger

The lend region is the cache slots the **prompt path** borrows for its chunk buffers, and the bytes it borrows grow with the chunk. The fork runs 32768-token chunks; upstream runs 8192-token chunks.

The chunk is set by the config's env, not by the model:

```
rdna3/configs/iq3_xxs-1gpu.json:78    "STRATA_PREFILL_AUTO_MAX": "32768"
rdna3/configs/iq3_xxs-1gpu.json:112   "STRATA_PREFILL_RING": "192"
```

`strata-iq3_xxs.json` has neither. Both trees read the variable the same way:

- fork `src/program/generate.cpp:2681-2685`, upstream `src/program/generate.cpp:3546-3550`:
  `auto:N` **or `STRATA_PREFILL_AUTO_MAX`** lifts the `--prefill auto` ceiling above 8192. Without it the default stays 8192.
- upstream can only lift a *bare* `--prefill auto` by itself, and only on RDNA4: `src/program/generate.cpp:3890-3935` (`prefill_auto_bare` + `gfx12_chunk_ceiling` + `gfx_arch_is_gfx12`). A 7900 XT is gfx1100, so upstream stays at 8192 on this card. The fork reaches 32768 because its config names it, and `prefill_auto_bare` is false for a named ceiling in both trees.

And every borrowed slot costs RAM in resident mode: `src/core/expert_source.cpp` (fork 3566-3599, upstream 3632-3665) keeps "the prompt path's lend region … in RAM too" while a budget allows, i.e. the complement includes the loan. Upstream's own comment says the same thing (`generate.cpp:9775-9782`, #2090): "every lent slot's expert is read from the RAM side during the read … that copy also holds the lent slots' experts", with the measured example "3,907 slots / 6.38 GiB against 2,068 / 3.37 GiB" for 16384 against 8192 — the same doubling shape we see here at 32768.

Both trees also have the RAM guard that steps the chunk down (32768 → 16384 → 8192) when the RAM free at that moment does not cover the extra loan plus 6 GiB (fork `generate.cpp:8072-8098`, upstream `9775-9805`). Upstream never needed it here (it was already at 8192). On the fork, at 32768 the loan fitted inside the 37 GiB budget (9.73 of the remaining 10.74 GiB), so the guard left it alone.

## 3. The secondary difference, and it is real code, not config

The two engines reserve different VRAM before filling the expert cache:

```
fork:      512 MiB reserved (+105 MiB for the draft head)
upstream:  512 MiB reserved (+184 MiB for the draft head, +256 MiB for what is allocated after the cache)
```

The fork does not reserve room for what is allocated after the cache, so its cache lands at 8468 slots / 13.70 GiB and the card ends at **414 MiB free** — below its own `--vram-reserve-mib 512` — and the engine prints the #2065 warning that the driver then pages GPU memory into system RAM. Upstream ends at **714 MiB free** with 8016 slots and no warning. The fork's extra GPU cache is what pays for 0.75 GiB of the RAM difference, but it buys it with a card that has no room left.

## 4. The one-variable test that settles it

On the fork, with everything else untouched:

```json
"STRATA_PREFILL_AUTO_MAX": "8192"      // was 32768
```

Expected from the arithmetic above: the loan falls to roughly 2100 slots / 3.4 GiB, the complement to about 27 GiB + 3.4 GiB ≈ 30.5 GiB, engine RSS to about 32–33 GiB, and VRAM free rises well above the 512 MiB reserve. If it does, the memory gap is `--prefill auto` reaching 32768-token chunks in this fork's configs, and prefill speed is what that 6 GiB was bought with.

Then the speed half of the question: a 32768-token prompt in 1 chunk against 8192 in 4 chunks. Run `bench.sh` or the same prompt set with both values and keep the ms/token numbers; the config should say which side wins, in writing.

Other configs carry the same pair (`rdna3/configs/`: iq1_m, iq2_xs, iq3, iq3-2gpu, iq4-1gpu, iq4-2gpu all `AUTO_MAX 32768` with `RING 192` or `384`), so a decision here applies to all of them.
