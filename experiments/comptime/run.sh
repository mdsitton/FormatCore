#!/bin/bash
# The comptime experiment: a normal Debug build and run, then the build-failure cases.
#   FIXTURE_POINTER        Runtime.FatalError two frames into Core: where is the error located?
#   FIXTURE_GENERIC_PARAM  is ApplyToType run on the unspecialized Box<T> too?
#   DEFER (+DEFER_SIMPLE)  ApplyToType emitting an [OnCompile(.TypeInit)] method: crashes BeefBuild 0.43.6
# Usage: bash run.sh
cd "$(dirname "$0")"
beefbuild 2>&1 | grep -A3 ERROR
./build/Debug_Linux64/App/App
for f in FIXTURE_POINTER FIXTURE_GENERIC_PARAM "DEFER" "DEFER DEFER_SIMPLE"; do
	defines=()
	for d in $f; do defines+=("-define=$d"); done
	echo "== $f"
	beefbuild "${defines[@]}" > build/fixture.log 2>&1
	echo "exit code $?"
	grep -A6 "ERROR" build/fixture.log | head -8
done
beefbuild > /dev/null 2>&1
