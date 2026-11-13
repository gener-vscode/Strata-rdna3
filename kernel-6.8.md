# GPU idle power old vs new disk — mechanism found: memory clock (MCLK)

## The confirmed difference

Your `amdgpu_pm_info` on the **old** disk vs the new disk's recorded values:

| | **OLD disk** `6.8.0-147` | **NEW disk** `7.0.0-43` |
|---|---|---|
| **MCLK (live)** | **96 MHz** | **1249 MHz** |
| average SoC | **18.00 W** | 60 W |
| SCLK | 0 MHz | — |
| VDDGFX | 54 mV | 55 mV |
| GPU temp | 45 °C | 56 °C |
| MEM Load | 6 % | 0 % |
| VCN | Powered down | Powered down |

**The memory clock never comes down on the new kernel.** It sits at the *top* DPM state (1249 MHz) at 0 % busy, while the old kernel drops it to the *bottom* state (96 MHz). GDDR6 idling at 1249 MHz instead of 96 MHz is exactly the ~40 W gap.

`pp_dpm_mclk` proves state 0 exists and is reachable on this kernel:
```
0: 96Mhz     <- where 6.8 parks at idle
1: 456Mhz
2: 772Mhz
3: 1249Mhz *  <- where 7.0.0-43 is stuck
```
⚠️ The `*` is **not** the live state — under `power_dpm_force_performance_level=auto` it marks the *max allowed* state. Proof: `pp_dpm_sclk` showed `2251Mhz *` while `amdgpu_pm_info` reported live `SCLK 0 MHz`. Only `amdgpu_pm_info` gives live clocks.

## Clock gating is NOT the difference
Old disk reports Fine **On**, Medium **On**, Medium-Grain mem Light Sleep **Off**, Coarse **Off** — essentially the same set the memory file recorded for the new disk. So gating is a red herring; MCLK is the variable.

## Correcting my own headline number
I reported "12–13 W". That was too optimistic — the old-disk floor is **not a single number**. Three runs, all `gpu_busy_percent = 0%`:

```
run 1: … 36 20 20 20 20 20 20 20 20 20 20 20 20 20 20   → 20 W
run 2: … 38 29 13 14 13 13 13 13 12 12                  → 12 W
run 3: … 41 25 25 25 25 25 25 25 25 25 25 25 25 25 25   → 25 W
```

So the honest figure is **12–25 W, with `amdgpu_pm_info` SoC = 18 W at MCLK 96 MHz**. The gap to the new disk's 58 W is still **~33–45 W**. (Run 3 followed my `pp_dpm_*` reads, which wake the GPU — discard the first ~5 samples always.)

## What is ruled out (identical on both boots)
`ppfeaturemask=0xffffffff` · `pcie_aspm=off` · `acpi_enforce_resources=lax` · `pcie_gen_cap=0x40000` · **2 displays, both `dpms=On`** · power cap 325 W / `cap_max` 333 W · model resident (97.8 % vs 98.1 % VRAM) · `strata.service` active at `busy 0 %` · **same Strata flags** (`--resident-experts`, `--expert-cache auto`, `--kv-resident 32768`, `--max-context 224000`) · **same repo commit `0bb2d71`**.

That kills hypotheses (1), (2) and (3) in the memory file. Only the kernel remains.

## Sharper next test — now with a falsifiable prediction
Boot the **old kernel on the new NVMe disk** (mirror of my original suggestion, which needs ~200 MB and mutates your control disk; this needs one package):
```
sudo apt install linux-image-6.8.0-147-generic
sudo grub-reboot "Advanced options for Ubuntu>Ubuntu, with Linux 6.8.0-147-generic" && sudo reboot
```
`grub-reboot` is required — `GRUB_TIMEOUT=0` + `STYLE=hidden` means no menu appears.

**Prediction:** `amdgpu_pm_info` MCLK drops to **96 MHz** and SoC to ~18 W. If it does, kernel confirmed. If MCLK stays 1249 MHz, the kernel is innocent and the NVMe root-disk side is implicated.

**30-second diagnostic that needs no reboot** (on the new boot — `pp_dpm_mclk` is read-only under `auto`, so force the level first):
```
sudo sh -c 'echo min_perf > /sys/class/drm/card1/device/power_dpm_force_performance_level'
sudo sh -c 'echo 0 > /sys/class/drm/card1/device/pp_dpm_mclk'
# read power1_average; then restore:
sudo sh -c 'echo auto > /sys/class/drm/card1/device/power_dpm_force_performance_level'
```
If power collapses toward ~18 W, that directly prices the MCLK pin. Note `min_perf` also caps SCLK, so this is a **diagnostic, not a fix** — restoring `auto` is essential.

## Not verified / open
- `SMC Feature Mask` = `0x0003ebb871ffffff` on the old disk; the new disk's value was never recorded — worth comparing.
- `--max-context 224000` on the new disk's state file (NVMe unmounted, needs root) — the one flag I couldn't confirm matches.
- `BootCurrent=0001` (NVMe ESP) while root is `/dev/sda2` — needs `sudo efibootmgr -v`.
- **No system changes were made** — read-only throughout.

Want me to write the confirmed mechanism, the 12–25 W range, and the three disk corrections (`nvme1n1`, not `nvme0n1`) into a new `.agents/memory/` entry? The current one still says 29 W and blames displays/`ppfeaturemask`.