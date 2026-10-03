#!/bin/bash
# User-space instructions per input byte of a stop-byte scan through FormatCore's cursors, against the
# same scan over a plain buffer: two runs that differ by five passes over the 100 MiB input, so startup
# and buffer filling cancel out.
# Usage: bash measure.sh [config]   (default Release; also ReleaseNoLTO). Builds first.
set -uo pipefail
cd "$(dirname "$0")"
CONFIG=${1:-Release}
beefbuild -config="$CONFIG" > /dev/null || { echo "build failed"; exit 1; }
BIN=./build/${CONFIG}_Linux64/App/App
bytes=$((100 * 1024 * 1024))
count() {
	perf stat -x, -e instructions:u "$BIN" "$1" "$2" 2>&1 > /dev/null | grep instructions | cut -d, -f1
}
for mode in direct memory validated validate stream stream-validated; do
	one=$(count "$mode" 1)
	six=$(count "$mode" 6)
	awk -v m="$mode" -v a="$one" -v b="$six" -v n="$bytes" 'BEGIN { printf "%-8s %6.3f\n", m, (b - a) / 5 / n }'
done
