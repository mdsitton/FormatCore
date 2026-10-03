#!/bin/bash
# Build cost of the hot-loop experiment as two projects (hotloop: Core + App) and as one (hotloop-mono:
# the same sources in App): user-space instructions of beefbuild and its children (the linker) for a
# clean build and for a rebuild after touching one Core source file, plus wall time for reference.
# Usage: bash experiments/buildcost.sh [runs]
set -uo pipefail
cd "$(dirname "$0")"
runs=${1:-3}
measure() { # workspace config
	perf stat -x, -e instructions:u -e task-clock beefbuild -workspace="$1" -config="$2" 2>&1 > /dev/null |
		awk -F, '/instructions/ { i = $1 } /task-clock/ { t = $1 } END { printf "%8.2f Ginstr %7.0f ms-cpu", i / 1e9, t }'
}
for config in Debug Release; do
	for ws in hotloop hotloop-mono; do
		for ((r = 0; r < runs; r++)); do
			rm -rf "$ws/build/${config}_Linux64"
			start=$(date +%s.%N)
			clean=$(measure "$ws" "$config")
			wall=$(awk -v s="$start" -v e="$(date +%s.%N)" 'BEGIN { printf "%.1f", e - s }')
			touch hotloop/Core/src/CoreScan.bf
			incr=$(measure "$ws" "$config")
			printf '%-8s %-13s clean: %s (%ss wall)   touch CoreScan.bf: %s\n' "$config" "$ws" "$clean" "$wall" "$incr"
		done
	done
done
