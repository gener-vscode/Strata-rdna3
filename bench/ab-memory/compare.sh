#!/usr/bin/env bash
# bench/ab-memory/compare.sh - put two snapshot.sh key files side by side.
#
#   bench/ab-memory/compare.sh bench/ab-memory/snapshots/fork-*.keys bench/ab-memory/snapshots/upstream-*.keys
#
# Every key is printed as: key  A  B  B-A  (values in kB unless the key carries its own text).
set -u
[ $# -eq 2 ] || { echo "usage: compare.sh <a.keys> <b.keys>" >&2; exit 2; }
A="$1"; B="$2"

awk '
function num(v){ gsub(/[^0-9.]/,"",v); return v+0 }
NR==FNR { a[$1]=substr($0, index($0,"=")+1); order[++n]=$1; next }
{ b[$1]=substr($0, index($0,"=")+1) }
END {
    printf "%-34s %14s %14s %12s\n", "KEY", "A", "B", "B-A"
    for (i=1;i<=n;i++){ k=order[i]; show(k, a[k], b[k]) }
    for (k in b){ found=0; for (i=1;i<=n;i++) if (order[i]==k) found=1; if (!found){ show(k, "-", b[k]) } }
}
function show(k, x, y) {
    if (x ~ /^[0-9]+$/ && y ~ /^[0-9]+$/) {
        d = y - x
        printf "%-34s %14s %14s %12s  (%.2f GiB vs %.2f GiB)\n", k, x, y, (d>=0?"+":"") d, x/1048576, y/1048576
    } else {
        printf "%-34s %14s | %s\n", k, x, y
    }
}
' "$A" "$B"
