#!/bin/bash
# pack-iq1_m.sh - write the UD-IQ1_M pack from scratch: the index, the tokenizer and experts.bin
# (rdna3/README.md, step 4).
#
# Same shape as pack-q2_0.sh, but the job is bigger. setup.py knows the Unsloth sizes UD-IQ4_XS,
# UD-Q4_K_XL, UD-Q5_K_XL, UD-Q6_K_XL and Q8_0, and it has NO entry for UD-IQ1_M, so for this model
# nothing was fetched and nothing was indexed: $DATA/models/unsloth-UD-IQ1_M/ and
# $DATA/packs/unsloth-ud-iq1_m/ are both absent. iq_pack.py therefore runs WITHOUT --base and writes
# the whole pack itself - dense.bin, index.txt, conversions.json, compat-bf16.json, tokenizer/,
# native_experts.txt - and then experts.bin, the file rdna3/run.py insists on before it will start a
# setup (the measured setups read the experts from there with O_DIRECT, ~1.9 GiB/s from a PCIe 4
# drive, instead of out of the GGUF shards).
#
# Get the GGUFs first, from unsloth/Qwen3.8-Flash-Next-GGUF, the UD-IQ1_M folder. Three shards,
# 68.0 GB; the byte counts are what the Hugging Face API reported for that folder on 2026-11-25.
# Put them, under those exact names, in $DATA/models/unsloth-UD-IQ1_M/:
#     Qwen3.8-Flash-Next-UD-IQ1_M-00001-of-00003.gguf    10946618
#     Qwen3.8-Flash-Next-UD-IQ1_M-00002-of-00003.gguf    39196009888
#     Qwen3.8-Flash-Next-UD-IQ1_M-00003-of-00003.gguf    28800138432
#
#   ./pack-iq1_m.sh          # background with nohup, log -> pack-ud-iq1_m-experts.log
#   ./pack-iq1_m.sh --fg     # run in this terminal instead
#   ./pack-iq1_m.sh --check  # preflight only: checks everything, writes nothing
#
# Re-running is safe. iq_pack.py keeps the layers already in experts.bin.tmp (experts.bin.tmp.json
# says how many layers are in it and which shards they were cut from) and continues at that layer; and
# a finished experts.bin whose sidecar experts.bin.src.json names these same shards is not rewritten
# at all. The pack's own completion marker is native_experts.txt, which iq_pack.py renames into place
# only when every layer is in (#172), so a stopped run leaves no half pack for a later setup to take
# as finished.
#
# RAM, read this before you start it while a model is serving. The engine's resident complement is
# what is left of the experts after the GPU cache, and it is pageable (VmLck 0), so it can be pushed
# out. The packer reads 68 GB of GGUF through the page cache and holds one layer's three projections
# plus the copy it writes out, so with little MemAvailable it can push the live engine's complement
# into swap and decode slows sharply. If the server matters, stop it first:
#     sudo systemctl stop strata            # the `ai-restart-r` alias writes the drop-in back
# --check prints what it thinks of the headroom, and the exact size of experts.bin is worked out from
# the GGUF headers before a single byte is written, so the disk figure is not a guess.

set -u

REPO=/home/tommy/repo/Strata-rdna3
DATA=/home/tommy/repo/Strata-data
PACK=$DATA/packs/unsloth-ud-iq1_m
SHARD=$DATA/models/unsloth-UD-IQ1_M/Qwen3.8-Flash-Next-UD-IQ1_M-00001-of-00003.gguf
PY=$REPO/.venv/bin/python
GGUF_PY=$REPO/third_party/llama.cpp/gguf-py
LOG=$REPO/pack-ud-iq1_m-experts.log

# published by unsloth/Qwen3.8-Flash-Next-GGUF, UD-IQ1_M/ (Hugging Face API, 2026-11-25)
S1_BYTES=10946618
S2_BYTES=39196009888
S3_BYTES=28800138432

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

# ---- the GGUFs come first, and there is no setup.py that will fetch them for this size
[ -x "$PY" ]                    || fail "$PY is missing: run ./setup.sh --setup first"
[ -d "$GGUF_PY/gguf" ]          || fail "gguf-py is missing at $GGUF_PY (setup.py fetches llama.cpp into third_party/)"
for i in 1 2 3; do                      # the shard names are -0000N-of-0000M (five digits)
    f=${SHARD/-00001-of/-0000${i}-of}
    if [ ! -f "$f" ]; then
        echo "STOP: $f is missing." >&2
        echo "      setup.py has no UD-IQ1_M size, so it cannot fetch this model: download the three" >&2
        echo "      shards of unsloth/Qwen3.8-Flash-Next-GGUF's UD-IQ1_M/ folder (68.0 GB) into" >&2
        echo "      $DATA/models/unsloth-UD-IQ1_M/ under their original names, then run this again." >&2
        exit 1
    fi
done

# the published sizes, checked as a warning: a re-quantized or fine-tuned checkpoint of the same
# geometry shares these shard names, so a mismatch is worth saying out loud but is not refused
for i in 1 2 3; do
    f=${SHARD/-00001-of/-0000${i}-of}
    want=$(eval "echo \$S${i}_BYTES")
    have=$(stat -c %s "$f")
    [ "$have" = "$want" ] || echo "note    : $(basename "$f") is $have bytes, the published shard is $want."
done

# ---- what experts.bin has to be: the pack's own marker when there is one, else the GGUF headers
# (iq_pack.expert_layout reads tensor infos only, never tensor data; on the UD-Q2_0 model it returns
# exactly the total its native_experts.txt records, 37355520000)
TOTAL=""
LAYERS=""
NEXPERT=""
SRC=""
if [ -f "$PACK/native_experts.txt" ]; then
    TOTAL=$(head -n 1 "$PACK/native_experts.txt" | sed -n 's/.*total \([0-9]\+\).*/\1/p')
    NEXPERT=$(head -n 1 "$PACK/native_experts.txt" | sed -n 's/.*n_expert \([0-9]\+\).*/\1/p')
    LAYERS=$(grep -vc '^#' "$PACK/native_experts.txt")
    [ -n "${TOTAL:-}" ] || fail "cannot read the expert total from the header of $PACK/native_experts.txt"
    SRC="$PACK/native_experts.txt"
else
    hdr=$("$PY" - "$SHARD" "$REPO/tools" <<'PY'
import pathlib, sys
sys.path.insert(0, sys.argv[2])
import iq_pack as P
try:
    got = P.expert_layout(P.Model(pathlib.Path(sys.argv[1])), pathlib.Path(sys.argv[1]))
except Exception as e:                                       # noqa: BLE001 - the message is the point
    print("cannot read the headers: " + str(e), file=sys.stderr)
    sys.exit(1)
if isinstance(got, str):                                     # a model iq_pack.py refuses to pack
    print(got, file=sys.stderr)
    sys.exit(1)
layout, text, n_expert, total = got
print(len(layout), n_expert, total)
PY
) || fail "cannot work the expert total out from the headers of $SHARD (see above)"
    read -r LAYERS NEXPERT TOTAL <<< "$hdr"
    [ -n "${TOTAL:-}" ] || fail "cannot work the expert total out from the headers of $SHARD (see above)"
    SRC="the GGUF headers (iq_pack.expert_layout, headers only)"
fi
GIB=$(awk -v b="$TOTAL" 'BEGIN { printf "%.2f", b / 1073741824 }')

echo "pack    : $PACK"
echo "shard 1 : $SHARD"
if [ -n "$LAYERS" ]; then
    echo "experts : $TOTAL bytes ($GIB GiB, $LAYERS layers, $NEXPERT experts per layer)"
else
    echo "experts : $TOTAL bytes ($GIB GiB, 48 layers)"
fi
echo "          (from $SRC)"
echo

# ---- preflight: everything that would waste an hour, checked before the first byte
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

if pgrep -f "packs/unsloth-ud-iq1_m" > /dev/null 2>&1; then
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
        echo "STOP: only $avail_gib GiB available. This box needs a layer's blobs on top of that." >&2
        echo "      Stop the server (sudo systemctl stop strata) and rerun." >&2
        exit 1
    fi
fi

# the GPU picture reader the iq1_m config asks for (vision.gpu true). rdna3/run.py refuses to start
# without it, so it is worth saying here that the pack is not the only thing that has to be there.
if [ -x "$REPO/engine/strata-vision-hip" ]; then
    echo "vision  : engine/strata-vision-hip is there (the GPU picture reader the config asks for)"
else
    echo "note    : engine/strata-vision-hip is missing: rdna3/run.py will refuse the setup even after"
    echo "          the pack is written, because rdna3/configs/iq1_m-1gpu.json sets vision.gpu true."
    echo "          Build it: setup.py --build --backend hip --vision gpu (it needs no model download)."
fi

# ---- what the pack looks like now, so you know whether this run will write, resume or skip
echo
part=$PACK/experts.bin.tmp
note=$PACK/experts.bin.tmp.json
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
elif [ -d "$PACK" ]; then
    echo "the pack folder exists but has no experts.bin yet; iq_pack.py writes the index and the tokenizer"
    echo "again (a few minutes, dense.bin.tmp and its rename) and then all the layers."
else
    echo "no pack yet: iq_pack.py writes dense.bin, index.txt, conversions.json, compat-bf16.json,"
    echo "tokenizer/, native_experts.txt and experts.bin from the shards."
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
echo "done when the log ends with: experts.bin: ${LAYERS:-48} layers, $GIB GiB"
echo "then start it:  ai-restart -c iq1_m   (or: .venv/bin/python rdna3/run.py iq1_m-1gpu --data $DATA --gpus 0 --host 0.0.0.0 --port 8080 --log $REPO/logs/rdna3-iq1_m.log)"
