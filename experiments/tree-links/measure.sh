#!/bin/bash
# User-space instructions per node of each mode: two runs that differ by five passes over the
# 1,048,576-node table, so startup and the table's set-up cancel out.
# Usage: bash measure.sh [binary] [modes...]   (beefbuild -config=Release, or -config=ReleaseNoLTO, first)
set -uo pipefail
cd "$(dirname "$0")"
BIN=${1:-./build/Release_Linux64/App/App}
shift || true
modes=("$@")
[ ${#modes[@]} -eq 0 ] && modes=(build-direct build-tree build-packed-direct build-packed-tree walk-direct walk-tree walk-packed-direct walk-packed-tree)
nodes=$((1 << 20))
count() {
	perf stat -x, -e instructions:u "$BIN" "$1" "$2" 2>&1 > /dev/null | grep instructions | cut -d, -f1
}
for mode in "${modes[@]}"; do
	one=$(count "$mode" 1)
	six=$(count "$mode" 6)
	awk -v m="$mode" -v a="$one" -v b="$six" -v n="$nodes" 'BEGIN { printf "%-20s %7.3f\n", m, (b - a) / 5 / n }'
done
