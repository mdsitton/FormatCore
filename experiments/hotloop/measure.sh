#!/bin/bash
# User-space instructions per input byte of each hot-loop mode: two runs that differ by five passes over
# the 100 MiB buffer, so startup and buffer filling cancel out.
# Usage: bash measure.sh [binary] [modes...]   (beefbuild -config=Release first)
set -uo pipefail
cd "$(dirname "$0")"
BIN=${1:-./build/Release_Linux64/App/App}
shift || true
modes=("$@")
[ ${#modes[@]} -eq 0 ] && modes=(a-same a-type a-inline b d c c-inline c-mono c-mono-inline e-app e-const e-static e-static-inline e-static-table e-param e-param-inline)
bytes=$((100 * 1024 * 1024))
count() {
	perf stat -x, -e instructions:u "$BIN" "$1" "$2" 2>&1 > /dev/null | grep instructions | cut -d, -f1
}
for mode in "${modes[@]}"; do
	one=$(count "$mode" 1)
	six=$(count "$mode" 6)
	awk -v m="$mode" -v a="$one" -v b="$six" -v n="$bytes" 'BEGIN { printf "%-15s %6.3f\n", m, (b - a) / 5 / n }'
done
