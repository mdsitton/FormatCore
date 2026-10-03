#!/bin/bash
# Builds App once per case (-define=CASE_<name>) and prints OK (with the program's output) or the error.
# Usage: bash run.sh
cd "$(dirname "$0")"
for c in NONE CORE_NO_USING NO_USING USING PROTINT SUBNS INTERNAL_TYPE INTERNAL_TYPE_QUALIFIED INTERNAL_TYPE_DECL INTERNAL_TYPE_USING FRIEND LIB_INTERNAL GENERIC_APP; do
	out=$(beefbuild -define=CASE_$c 2>&1)
	if echo "$out" | grep -q "ERROR:"; then
		echo "CASE_$c: FAIL: $(echo "$out" | grep ERROR: | sed "s/.*ERROR: //; s#$PWD/##" | head -2 | tr '\n' ' ')"
	else
		echo "CASE_$c: OK -> $(./build/Debug_Linux64/App/App)"
	fi
done
