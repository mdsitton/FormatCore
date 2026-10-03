#!/bin/bash
# Builds App once per case (-define=<name>) and prints OK (with the program's output) or the error.
# Usage: bash run.sh
cd "$(dirname "$0")"
for c in NONE N1_BOTH N2_OWN N3_ATTR N4_CAPTURE N4_NOUSING N5_SHADOW N5_GLOBAL "N5_GLOBAL N5_GLOBAL_FIELD" N7_SAME_FULL_NAME; do
	defines=()
	for d in $c; do defines+=("-define=$d"); done
	out=$(beefbuild "${defines[@]}" 2>&1)
	if echo "$out" | grep -q "ERROR:"; then
		echo "$c: FAIL: $(echo "$out" | grep -A1 ERROR: | grep -v '^--' | sed "s/.*ERROR: //; s#$PWD/##" | head -2 | tr '\n' ' ')"
	else
		echo "$c: OK -> $(./build/Debug_Linux64/App/App | tr '\n' ' ')"
	fi
done
