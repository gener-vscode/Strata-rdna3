#!/usr/bin/env bash
# bench/ab-memory/snapshot.sh - one memory snapshot of a running Strata serve.
#
# Run the SAME script on both sides of the A/B (fork and upstream); it takes whatever repo it is pointed at,
# so the two snapshots are comparable line for line.  A KEY=<value> block is written too, for the diff.
#
#   bench/ab-memory/snapshot.sh --label fork \
#       --repo /home/tommy/repo/Strata-rdna3 --log logs/rdna3-iq1_m.log
#   bench/ab-memory/snapshot.sh --label upstream \
#       --repo /home/tommy/repo/Strata --log logs/strata-iq3_xxs.log
#
# Optional: --samples N --interval S (watch growth), --note "text" (what moment this is), --out DIR.
set -u

label="run"; repo="$(pwd)"; log=""; out="$(pwd)/bench/ab-memory/snapshots"; samples=1; interval=30; note=""
while [ $# -gt 0 ]; do
    case "$1" in
        --label)    label="$2"; shift 2 ;;
        --repo)     repo="$2"; shift 2 ;;
        --log)      log="$2"; shift 2 ;;
        --out)      out="$2"; shift 2 ;;
        --samples)  samples="$2"; shift 2 ;;
        --interval) interval="$2"; shift 2 ;;
        --note)     note="$2"; shift 2 ;;
        -h|--help)  sed -n '1,20p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

ts=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$out"
txt="$out/$label-$ts.txt"
keys="$out/$label-$ts.keys"

# no log given: newest log in the repo that mentions an engine start
if [ -z "$log" ]; then
    log=$(ls -t "$repo"/logs/*.log 2>/dev/null | while read -r f; do grep -qa 'engine started' "$f" && { echo "$f"; break; }; done)
fi

engine_pid=$(pgrep -f 'engine/strata --serve' 2>/dev/null | tail -1)
vision_pid=$(pgrep -f 'engine/strata-vision' 2>/dev/null | tail -1)
serve_pid=$(pgrep -f 'serve/server.py' 2>/dev/null | tail -1)

# ---------------------------------------------------------------- report body
{
echo "################ Strata memory snapshot ################"
echo "label        : $label"
echo "note         : $note"
echo "taken_utc    : $ts"
echo "repo         : $repo"
echo "hostname     : $(hostname)"
echo "kernel       : $(uname -r)"
echo "git rev      : $(git -C "$repo" rev-parse HEAD 2>/dev/null)"
echo "git describe : $(git -C "$repo" describe --tags 2>/dev/null)"
echo "git dirty    : $(git -C "$repo" status --porcelain 2>/dev/null | tr '\n' ';')"
echo
echo "---- engine build ----"
cat "$repo/engine/BUILD.json" 2>/dev/null
echo "engine bytes : $(stat -c %s "$repo/engine/strata" 2>/dev/null)"
echo "engine md5   : $(md5sum "$repo/engine/strata" 2>/dev/null | cut -c1-32)"
echo
echo "---- host RAM / swap ----"
grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree)' /proc/meminfo
free -h | sed 's/^/free: /'
swapon --show 2>/dev/null | sed 's/^/swap: /'
echo
echo "---- GPU (amdgpu sysfs, every card) ----"
for d in /sys/class/drm/card*/device; do
    [ -e "$d/mem_info_vram_total" ] || continue
    vtotal=$(cat "$d/mem_info_vram_total"); vused=$(cat "$d/mem_info_vram_used")
    gtotal=$(cat "$d/mem_info_gtt_total" 2>/dev/null || echo 0); gused=$(cat "$d/mem_info_gtt_used" 2>/dev/null || echo 0)
    busy=$(cat "$d/device_busy_percent" 2>/dev/null || echo '?')
        echo "$(basename "$(dirname "$d")") vram_used_GiB=$(awk -v v="$vused" 'BEGIN{printf "%.2f", v/1073741824}') vram_total_GiB=$(awk -v v="$vtotal" 'BEGIN{printf "%.2f", v/1073741824}') gtt_used_MiB=$(awk -v v="$gused" 'BEGIN{printf "%.2f", v/1048576}') busy=${busy}%"
done
echo
echo "---- processes (what the OS really charges to RAM) ----"
printf "%-22s %8s %10s %10s %10s %10s %8s\n" PROCESS PID "RSS(GiB)" "VmPeak" "VmHWM" "VmSwap" Threads
for p in "$engine_pid" "$serve_pid" "$vision_pid"; do
    [ -n "$p" ] || continue
    name=$(cat /proc/$p/comm 2>/dev/null)
    rss=$(awk '/^VmRSS:/{print $2}' /proc/$p/status 2>/dev/null)
    peak=$(awk '/^VmPeak:/{print $2}' /proc/$p/status 2>/dev/null)
    hwm=$(awk '/^VmHWM:/{print $2}' /proc/$p/status 2>/dev/null)
    swp=$(awk '/^VmSwap:/{print $2}' /proc/$p/status 2>/dev/null)
    th=$(awk '/^Threads:/{print $2}' /proc/$p/status 2>/dev/null)
    printf "%-22s %8s %10s %10s %10s %10s %8s\n" "$name" "$p" \
        "$(awk -v v="$rss" 'BEGIN{printf "%.2f", v/1048576}')" "$peak" "$hwm" "$swp" "$th"
done
echo
echo "engine smaps_rollup:"
[ -n "$engine_pid" ] && grep -E '^(Rss|Pss|Pss_Dirty|Private_Dirty|Anonymous|Swap|Locked|LazyFree):' /proc/$engine_pid/smaps_rollup 2>/dev/null | sed 's/^/  /'
echo "gpu-visible pages of the engine (VSZ, includes the VRAM it maps):"
[ -n "$engine_pid" ] && awk '/^VmSize|^VmData/{print "  "$0}' /proc/$engine_pid/status 2>/dev/null
echo
echo "---- engine command line ----"
[ -n "$engine_pid" ] && tr '\0' ' ' < /proc/$engine_pid/cmdline && echo
echo "---- engine env (STRATA_/HSA_/HIP_/GPU_) ----"
[ -n "$engine_pid" ] && tr '\0' '\n' < /proc/$engine_pid/environ 2>/dev/null | grep -E '^(STRATA_|HSA_|HIP_|GPU_|ROCM)' | sort | sed 's/^/  /'
echo
echo "---- systemd unit peak (what the whole service cost) ----"
journalctl -u strata --no-pager 2>/dev/null | grep -a 'memory peak' | tail -3 | sed 's/^/  /'
echo
echo "---- engine's own memory decisions (latest 'engine started' segment) ----"
if [ -n "$log" ] && [ -f "$log" ]; then
    echo "  log: $log"
    S=$(grep -an 'engine started' "$log" 2>/dev/null | tail -1 | cut -d: -f1)
    if [ -n "$S" ]; then
        tail -n +$S "$log" | grep -aiE 'RAM budget|page-locked|resident|lend region|expert cache|VRAM|GiB available|prefill plan|stager ring|verify: window|mtp: |conversation cache|parked=|WARNING|file tier I/O|really free' \
            | grep -av 'done:' | tail -40 | sed 's/^/  /'
    else
        echo "  (no 'engine started' line in this log)"
    fi
else
    echo "  (no log found; pass --log)"
fi
} | tee "$txt"

# ---------------------------------------------------------------- key=value block (for the diff)
{
echo "label=$label"
echo "note=$note"
echo "git_rev=$(git -C "$repo" rev-parse --short HEAD 2>/dev/null)"
echo "engine_md5=$(md5sum "$repo/engine/strata" 2>/dev/null | cut -c1-12)"
echo "mem_total_kB=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
echo "mem_available_kB=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)"
echo "swap_used_kB=$(awk '/^SwapTotal/{t=$2} /^SwapFree/{f=$2} END{print t-f}' /proc/meminfo)"
i=0
for d in /sys/class/drm/card*/device; do
    [ -e "$d/mem_info_vram_used" ] || continue
    i=$((i+1))
    echo "vram_used_kB[$i]=$(( $(cat "$d/mem_info_vram_used") / 1024 ))"
    echo "vram_total_kB[$i]=$(( $(cat "$d/mem_info_vram_total") / 1024 ))"
    echo "gtt_used_kB[$i]=$(( $(cat "$d/mem_info_gtt_used" 2>/dev/null || echo 0) / 1024 ))"
done
for p in "$engine_pid" "$serve_pid" "$vision_pid"; do
    [ -n "$p" ] || continue
    n=$(cat /proc/$p/comm 2>/dev/null)
    echo "${n}_rss_kB=$(awk '/^VmRSS:/{print $2}' /proc/$p/status 2>/dev/null)"
    echo "${n}_hwm_kB=$(awk '/^VmHWM:/{print $2}' /proc/$p/status 2>/dev/null)"
    echo "${n}_swap_kB=$(awk '/^VmSwap:/{print $2}' /proc/$p/status 2>/dev/null)"
done
if [ -n "$log" ] && [ -f "$log" ]; then
    S=$(grep -an 'engine started' "$log" 2>/dev/null | tail -1 | cut -d: -f1)
    if [ -n "$S" ]; then
        seg=$(tail -n +$S "$log")
        echo "log_resident_gib=$(echo "$seg" | grep -a -oE 'resident [0-9.]+ GiB, pinned [0-9.]+ GiB' | tail -1)"
        echo "log_ram_budget=$(echo "$seg" | grep -a -oE 'RAM budget [0-9.]+ GiB' | tail -1)"
        echo "log_expert_cache=$(echo "$seg" | grep -a -oE 'expert cache [0-9]+ slots, [0-9.]+ GiB of VRAM' | tail -1)"
        echo "log_lend_region=$(echo "$seg" | grep -a -oE 'lend region: [0-9]+ of its [0-9]+ slots[^|]{0,80}' | tail -1)"
        echo "log_vram_free_at_start=$(echo "$seg" | grep -a -oE '[0-9]+ MiB of VRAM free with everything loaded' | tail -1)"
        echo "log_conversation_parked_bytes=$(echo "$seg" | grep -a -oE 'parked=[0-9]+ bytes=[0-9]+' | tail -1)"
        echo "log_prefill_plan=$(echo "$seg" | grep -a -oE 'prefill plan inputs: [^\n]{0,200}' | tail -1)"
    fi
fi
} > "$keys"

# more samples? keep watching the same processes
s=1
while [ "$s" -lt "$samples" ]; do
    s=$((s+1)); sleep "$interval"
    echo "---- sample $s ($(date -u +%H:%M:%S)Z) ----" | tee -a "$txt"
    for p in $(pgrep -f 'engine/strata --serve' 2>/dev/null) $(pgrep -f 'serve/server.py' 2>/dev/null) $(pgrep -f 'engine/strata-vision' 2>/dev/null); do
        printf "  %-20s rss=%s kB  hwm=%s kB  swap=%s kB\n" "$(cat /proc/$p/comm 2>/dev/null)" \
            "$(awk '/^VmRSS:/{print $2}' /proc/$p/status 2>/dev/null)" \
            "$(awk '/^VmHWM:/{print $2}' /proc/$p/status 2>/dev/null)" \
            "$(awk '/^VmSwap:/{print $2}' /proc/$p/status 2>/dev/null)" | tee -a "$txt"
    done
    echo "  MemAvailable=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo) kB" | tee -a "$txt"
done

echo
echo "saved: $txt"
echo "keys : $keys"
