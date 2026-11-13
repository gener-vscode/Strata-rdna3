#!/bin/bash
# pack-q2_0.sh - write the one missing file of the UD-Q2_0 pack: experts.bin (rdna3/README.md, step 4).
#
# setup.py already made $DATA/packs/unsloth-ud-q2_0/{dense.bin, index.txt, native_experts.txt, tokenizer/,
# conversions.json, compat-bf16.json}. What it did NOT write is experts.bin - the single prepacked expert
# file rdna3/run.py insists on before it will start the setup (the measured setups read the experts from
# there with O_DIRECT, ~1.9 GiB/s, instead of out of the GGUF shards).
#
#   ./pack-q2_0.sh          # background with nohup, log -> pack-ud-q2_0-experts.log (like the iq1_m / iq2_xs runs)
#   ./pack-q2_0.sh --fg     # run in this terminal instead
#   ./pack-q2_0.sh --check  # preflight only: checks everything, writes nothing
#
# Re-running is safe. iq_pack.py keeps the layers already in experts.bin.tmp (experts.bin.tmp.json says how
# many layers are in it and which shards they were cut from) and continues at that layer; and a finished
# experts.bin whose sidecar names these same shards is not rewritten at all.
#
# RAM, read this before you start it while a model is serving. This box serves IQ2_XS: engine RSS ~40 GiB,
# VmLck 0 (pageable, not pinned), and the resident complement is what is left of the experts after the GPU
# cache. The packer reads 66 GB of GGUF through the page cache and holds ~2 GiB per layer (512 experts x a
# ~1.8 MB blob, plus the copy written out), so with little MemAvailable it can push the live engine's
# complement into swap and decode slows sharply. If the server matters, stop it first:
#     sudo systemctl stop strata            # the `ai-restart-r` alias writes the drop-in back
# --check prints what it thinks of the headroom. Disk: experts.bin is 34.79 GiB; dense.bin (1.43 GiB) and
# index.txt are rewritten first under temporary names, so keep ~38 GiB free.

set -u

REPO=/home/tommy/repo/Strata-rdna3
DATA=/home/tommy/repo/Strata-data
PACK=$DATA/packs/unsloth-ud-q2_0
SHARD=$DATA/models/unsloth-UD-Q2_0/Qwen3.8-Flash-Next-UD-Q2_0-00001-of-00003.gguf
PY=$REPO/.venv/bin/python
GGUF_PY=$REPO/third_party/llama.cpp/gguf-py
LOG=$REPO/pack-ud-q2_0-experts.log

FG=0
CHECK=0
for a in "$@"; do
    case "$a" in
        --fg)    FG=1 ;;
        --check) CHECK=1 ;;
        *) echo "unknown option: $a (only --fg and --check)" >&2; exit 2 ;;
    esac
done

fail() { echo "STOP: $*" >&2; exit 1; }

# ---- what experts.bin has to be, straight out of the pack's own completion marker
[ -f "$PACK/native_experts.txt" ] || fail "$PACK/native_experts.txt is missing: run setup.py first (rdna3/README.md step 3)"
TOTAL=$(head -n 1 "$PACK/native_experts.txt" | sed -n 's/.*total \([0-9]\+\).*/\1/p')
[ -n "${TOTAL:-}" ] || fail "cannot read the expert total from the header of $PACK/native_experts.txt"
GIB=$(awk -v b="$TOTAL" 'BEGIN { printf "%.2f", b / 1073741824 }')

echo "pack    : $PACK"
echo "shard 1 : $SHARD"
echo "experts : $TOTAL bytes ($GIB GiB, 48 layers)"
echo

# ---- preflight: everything that would waste an hour, checked before the first byte
[ -x "$PY" ]                    || fail "$PY is missing: run ./setup.sh --setup first"
[ -d "$GGUF_PY/gguf" ]          || fail "gguf-py is missing at $GGUF_PY (setup.py fetches llama.cpp into third_party/)"
for i in 1 2 3; do                      # the shard names are -0000N-of-0000M (five digits)
    f=${SHARD/-00001-of/-0000${i}-of}
    [ -f "$f" ]                 || fail "$f is missing; all three shards are read for the expert arena"
done
[ -f "$PACK/index.txt" ]        || fail "$PACK/index.txt is missing: the pack was never indexed"
[ -f "$PACK/tokenizer/vocab.json" ] || fail "$PACK/tokenizer/vocab.json is missing"

free_bytes=$(df -B1 --output=avail "$DATA" 2>/dev/null | tail -1 | tr -d ' ')
[ -n "${free_bytes:-}" ]        || fail "cannot read the free space on $DATA"
need_bytes=$(( TOTAL + 3 * 1024 * 1024 * 1024 ))    # experts.bin plus room for dense.bin.tmp and its rename
if [ "$free_bytes" -lt "$need_bytes" ]; then
    awk -v f="$free_bytes" -v n="$need_bytes" 'BEGIN { printf "STOP: %.1f GiB free on %s, this needs %.1f GiB\n", f/1073741824, "/home/tommy/repo/Strata-data", n/1073741824 }' >&2
    echo "      (experts.bin + dense.bin.tmp + the rename). Free some space and rerun." >&2
    exit 1
fi

avail_kb=$(awk '/MemAvailable/ { print $2 }' /proc/meminfo)
avail_gib=$(awk -v k="$avail_kb" 'BEGIN { printf "%.2f", k / 1048576 }')
echo "disk    : $(awk -v b="$free_bytes" 'BEGIN { printf "%.0f", b / 1073741824 }') GiB free   (need $GIB GiB + 3 GiB)"
echo "memory  : $avail_gib GiB available"

running=$(pgrep -f 'iq_pack\.py' | tr '\n' ' ')
[ -z "${running:-}" ] || fail "an iq_pack.py is already running (pid $running); wait for it or stop it"

if pgrep -f "packs/unsloth-ud-q2_0" > /dev/null 2>&1; then
    fail "an engine is already serving this pack; stop it before repacking it"
fi

serving=$(pgrep -f 'engine/strata --serve' | tr '\n' ' ')
if [ -n "${serving:-}" ]; then
    rss_kb=$(awk '/VmRSS/ { print $2 }' /proc/"$(echo $serving | cut -d' ' -f1)"/status 2>/dev/null)
    echo "note    : a model is serving (pid $serving, RSS $(awk -v k="${rss_kb:-0}" 'BEGIN { printf "%.1f", k / 1048576 }') GiB, pageable)."
    echo "          Packing now can push its resident complement into swap and slow decode."
    echo "          Stop it first if that matters: sudo systemctl stop strata"
    echo
    if [ "${avail_gib%.*}" -lt 3 ]; then
        echo "STOP: only $avail_gib GiB available. This box needs ~2 GiB per layer on top of that." >&2
        echo "      Stop the server (sudo systemctl stop strata) and rerun." >&2
        exit 1
    fi
fi

# ---- what the pack looks like now, so you know whether this run will write, resume or skip
part=$PACK/experts.bin.tmp
note=$PACK/experts.bin.tmp.json
echo
if [ -f "$PACK/experts.bin" ]; then
    have=$(stat -c %s "$PACK/experts.bin")
    if [ "$have" = "$TOTAL" ] && [ -f "$PACK/experts.bin.src.json" ]; then
        echo "experts.bin is already there ($have bytes) with its sidecar: iq_pack.py will check it against"
        echo "these shards and, if they match, print \"not rewritten\" and stop. Nothing to do."
    else
        echo "experts.bin is there but $have bytes, not $TOTAL, or its sidecar is gone:"
        echo "iq_pack.py will rewrite it from layer 0 (it will say so)."
    fi
elif [ -f "$part" ]; then
    echo "an interrupted run is in $part ($(stat -c %s "$part") bytes);"
    echo "iq_pack.py continues at the layer recorded in $(basename "$note") if that layer still matches the GGUF."
else
    echo "no experts.bin yet: writing all 48 layers from the shards."
fi
echo

if [ "$CHECK" = 1 ]; then
    echo "--check: nothing written. Run without --check to pack."
    exit 0
fi

export STRATA_GGUF_PY=$GGUF_PY
CMD=("$PY" "$REPO/tools/iq_pack.py" --gguf "$SHARD" --out "$PACK" --compat-bf16 --experts-bin)
echo "${CMD[*]}"

if [ "$FG" = 1 ]; then
    cd "$REPO" && exec "${CMD[@]}"
fi

cd "$REPO" || exit 1
nohup nice -n 19 ionice -c3 "${CMD[@]}" > "$LOG" 2>&1 &
pid=$!
echo
echo "packing in the background, pid $pid"
echo "  watch   : tail -f $LOG"
echo "  progress: cat $PACK/experts.bin.tmp.json      (layers written so far)"
echo "  stop    : kill $pid    (the finished layers are kept; rerun to continue)"
echo
echo "done when the log ends with: experts.bin: 48 layers, $GIB GiB"
echo "then start it:  .venv/bin/python rdna3/run.py iq2_0-1gpu --data $DATA --gpus 0 --host 0.0.0.0 --port 8080 --log $REPO/logs/rdna3-iq2_0.log"
