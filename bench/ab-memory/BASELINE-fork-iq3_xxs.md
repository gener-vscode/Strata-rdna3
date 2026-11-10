# Fork vs upstream: memory A/B (Qwen Flash Next, UD-IQ3_XXS, one 7900 XT)

Status: the fork side is measured. The upstream side has not run yet.
Measured on 2026-11-09, 19:49 → 20:08 HKT, on `7900xt`, engine started by `run-iq3_xxs.sh` under `strata.service`.

Files in this folder:

| file | what it is |
|---|---|
| `snapshot.sh` | takes one memory snapshot of a running serve; run it on both sides |
| `compare.sh` | puts two snapshots' key blocks side by side with the difference |
| `upstream-iq3_xxs.json` | our IQ3_XXS config rewritten for `/home/tommy/repo/Strata` (same args, same env, upstream paths) |
| `snapshots/fork-20261109T120829Z.txt` / `.keys` | the fork baseline |

---

## 1. What the fork costs (measured)

From `snapshots/fork-20261109T120829Z.txt`:

| thing | value |
|---|---|
| system RAM | 46.43 GiB total, **4.67 GiB available**, 140 MiB in swap |
| engine process (`strata-host`, pid 20482) | **RSS 38.47 GiB**, peak since start (VmHWM) 38.72 GiB, VmSize 105.08 GiB (that includes the VRAM it maps), 43 threads, 0 swapped |
| engine private dirty pages | 37.85 GiB (smaps: Private_Dirty / Anonymous) |
| `strata-vision` | RSS 0.94 GiB |
| `serve/server.py` (python) | RSS 0.21 GiB |
| GPU VRAM | **19.88 GiB used of 19.98 GiB** (~105 MiB free), GTT used 33 MiB of 23.2 GiB |
| the whole service, last exit | systemd: "45.3G memory peak, 3.3G memory swap peak" |

The engine's own accounting for the same start (`logs/rdna3-iq1_m.log`, newest `engine started` segment — the file name is stale, `run-iq3_xxs.sh` writes the IQ3_XXS run into it):

```
expert cache auto: 13.79 GiB free, 512 MiB reserved (+105 MiB for the draft head) -> 6079 slots
expert cache 8468 slots, 13.70 GiB of VRAM
FileExpertSource: RAM budget 37.00 GiB: 16422 of the 26.78 GiB of experts the GPU cache does not hold, by profile rank
FileExpertSource: the prompt path's lend region: 6041 of its 6041 slots keep their experts in RAM too (9.73 GiB of the budget's remaining 10.74 GiB)
FileExpertSource: allocating 36.50 GiB page-locked cache complement
FileExpertSource: mapped pinned cache complement ready: resident 36.50 GiB, pinned 36.50 GiB in 86 s
strata generate: resident RAM mode: 36.50 GiB of experts in RAM (page-locked), 8468 in the GPU cache; adaptive swaps exchange them with the GPU cache (no file reads)
strata: prefill plan inputs: 40.0 GiB experts, 13.2 GiB in the GPU caches, 36.5 GiB RAM copy (6044 lend slots kept), file tier 0.0 GiB; 5.5 GiB available for the page cache
strata serve: 438 MiB of VRAM free with everything loaded
strata serve: WARNING: only 438 MiB of VRAM free at the start of this request (below 512 MiB): ... the driver can page GPU memory to system RAM (#2065)
```

Later in the same log, with `--conversation-cache-mib 0`: `conversation cache: parked 72552 tokens ... parked=1 bytes=1127749196` (1.08 GiB parked). Not the main term, but worth watching in the A/B.

## 2. The term that dominates

`--resident-budget-gib 37` in `rdna3/configs/iq3_xxs-1gpu.json` (the only other fork config with it is `iq2_xs-1gpu.json`). It makes the engine copy **36.50 GiB** of experts into page-locked RAM at start and keep them there. That is 38.47 GiB of the 41 GiB the machine is using.

Upstream understands the same flag (`Strata/src/program/generate.cpp:3751`), so this is not a fork-only feature. What is unknown is what upstream actually ran with: `Strata/run-iq3_xxs.sh` points at `Strata/strata-iq3_xxs.json`, and that file is not in the upstream tree today. So the A/B has to decide, not infer.

Second term to test, same log: VRAM ends at 105–438 MiB free, below our own `--vram-reserve-mib 512`. The engine itself warns that at that point amdgpu can page GPU memory into system RAM (#2065). Paged GPU memory shows up as host RSS, so part of the 38.47 GiB may be VRAM spill rather than experts.

## 3. Arms to run

Keep everything else fixed: same model files, same pack (`Strata-data/packs/iq3_xxs`), same tokenizer, same MTP dir, one GPU, `--parallel 1`, no API key, same three prompts, one restart per arm.

| arm | run | question it answers |
|---|---|---|
| A | fork, as it is now | done, `snapshots/fork-*` |
| B | upstream + `bench/ab-memory/upstream-iq3_xxs.json` (same flags, `--resident-budget-gib 37` kept) | is the difference the code or the config? |
| C | upstream without `--resident-budget-gib` | what upstream normally costs |
| D | fork without `--resident-budget-gib` | the flag's cost on our side |
| E | fork with `--vram-reserve-mib 1024` | whether the VRAM-full paging path is adding host RAM |

Copy the mirror config where upstream's own runner looks for it:

```sh
cp bench/ab-memory/upstream-iq3_xxs.json /home/tommy/repo/Strata/strata-iq3_xxs.json
```

Notes so both sides really match:
- the draft vocab file is ours only (`Strata-rdna3/rdna3/draft_vocab_zh60k.bin`); the mirror config points at that path, so both engines read the same bytes.
- `--expert-profile` uses each tree's own `data/expert-profile.bin`; both are 196632 bytes, same file.
- our tuning file `tools/hip/gfx1100-hipblaslt-100200.txt` exists in both trees. The runtime hipBLASLt is 100202 and both runs print "version mismatch ... using hipBLASEx", so neither gets the tuned table.

## 4. Measuring each arm

```sh
# idle, right after "resident RAM mode" / "everything loaded"
bash bench/ab-memory/snapshot.sh --label fork-upstream-B --repo /home/tommy/repo/Strata \
     --log logs/<upstream log>.log --note "arm B idle" --out bench/ab-memory/snapshots

# the same arm after the prompts, with 5 samples 60 s apart
bash bench/ab-memory/snapshot.sh --label fork-upstream-B-after --repo /home/tommy/repo/Strata \
     --log logs/<upstream log>.log --samples 5 --interval 60 --out bench/ab-memory/snapshots

bash bench/ab-memory/compare.sh bench/ab-memory/snapshots/fork-*.keys bench/ab-memory/snapshots/fork-upstream-B-*.keys
```

Read the compare output in this order:

1. `log_ram_budget`, `log_resident_gib`, `log_expert_cache`, `log_lend_region` — if upstream prints a `file tier` line instead of `resident RAM mode`, the gap is the flag and not the code.
2. `strata-host_rss_kB` and `strata-host_hwm_kB`.
3. `vram_used_kB` against `vram_total_kB`, plus the engine's "MiB of VRAM free" line.
4. `mem_available_kB`, `swap_used_kB`, `python_rss_kB`, `strata-vision_rss_kB`.

## 5. Fork vs upstream, from reading both trees (unconfirmed static analysis)

Not measured; findings from reading code, so treat them as leads for the arms above.

- Upstream has `--ram-keep-gib` / `STRATA_RAM_KEEP_GIB`, and it raises the headroom of the explicit RAM modes to at least that value (`Strata/src/program/generate.cpp:3779-3788`). Our tree has no `--ram-keep-gib` at all (0 hits in `src/`), so our resident sizing only has its own default headroom unless `STRATA_RESIDENT_HEADROOM_GIB` is set. A different headroom is a different resident copy size.
- Upstream-only sizing knobs that could change RAM: `--vram-elastic`, `--vram-segment-mib`, `--vram-reserve-later-mib`, `--kv-resident`, `--mmap-experts`, `--resident-experts`, `--resident-cpu-experts`, `--expert-cache-per-layer`, `--prompt-cache*`, `--conversation-cache-min-free-mib` / `-min-tokens` / `-park-gain`, and the `STRATA_DEFAULTS=026` master switch (`include/strata/core/defaults_026.hpp`, which covers the PLE residency policy `STRATA_PLE_AUTO_RAM`).
- 17 of the 45 `STRATA_*` variables in our config appear nowhere in upstream `src/` or `include/`, so they do nothing there: `STRATA_RDNA_MMVQ_WAVE`, `STRATA_PEER_TRANSPORT`, `STRATA_PREFILL_MMQ_TILE_ROWS`, `STRATA_GR_RDNA`, `STRATA_GR_RDNA_Q8`, `STRATA_RDNA_Q6K`, `STRATA_GR_RDNA_A8`, `STRATA_COMBINE_CPU`, `STRATA_WAIT_FUSE`, `STRATA_ROUTE_PUBLISH`, `STRATA_GR_INJ_UP`, `STRATA_GR_FUSED`, `STRATA_GDN_CHUNK_GDV`, `STRATA_PA_KLDS`, `STRATA_PF_GROUP_RES`, `STRATA_TOPK_SPLIT_MIN`, `STRATA_ENGINE_NICE`. Most are speed switches; `STRATA_PEER_TRANSPORT`, `STRATA_COMBINE_CPU`, `STRATA_TOPK_SPLIT_MIN` and `STRATA_KV_HOST_DMA` are the ones that could move buffers. All 25 engine flags in the config are understood by both parsers.
- Our tree has `src/core/arena_shm.cpp` (`STRATA_ARENA_SHM`: the expert arena kept in shared memory across engine starts) and upstream does not. It is off in this config and `/dev/shm` holds only `rocm_smi_renderD128`, so it is not what we are seeing now — but any arm that sets it shows the arena as RAM use that outlives the engine.
- The engines are different builds: ours md5 `fb975936515c`, 47,363,408 bytes, dated 2026-11-08; upstream md5 `a1620aa7bde9`, 57,054,160 bytes, dated 2026-11-07. Both `engine/BUILD.json` claim version 0.1.57 and the same `src` hash, so the provenance recorded in our `BUILD.json` is not trustworthy.
- The two trees are not an ancestor pair: ours is `ce61f3b0` (`feat/consolidation`), the upstream tree is `f41e3db1` (`v0.1.40.1-4782-gf41e3db1`), and neither repo can resolve the other's HEAD commit. `src/core/expert_source.cpp` differs by 658 changed lines.
- The upstream copy of `expert_source.cpp` keeps the same resident-budget comments and rules as ours in the lines around `resident-budget-gib`, so a budget-driven 36.50 GiB pinned copy is expected in arm B too. Arm B is the arm that decides whether the extra RAM is the config or the code.

## 6. Not tested

No measurement was made on the upstream engine. Nothing here says the fork leaks or double-counts; it says the fork pins 36.50 GiB and leaves the card with ~100 MiB free. Arm B, C and E are what decide between "the config is different" and "the code is different".
