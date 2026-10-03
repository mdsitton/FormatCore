#!/bin/bash
# The converter-registry regression (plan.md §2.3 bug 1): builds and runs App in a workspace where the
# format library (ToyFormat) has three dependents, and checks that the framework's lookups, which run in
# the mixin stage under a [Comptime] entry in the user's type, find exactly the converters of the user's
# project and its dependencies: App's and UserLib's, never OtherLib's. The "at apply" lines show what the
# siblings' old lookup (inside ApplyToType, through AlwaysVisible) finds in the same workspace.
# Usage: bash tests/registry/run.sh [config]      (default: Debug)
set -uo pipefail
cd "$(dirname "$0")"
CONFIG="${1:-Debug}"
if ! build=$(beefbuild -config="$CONFIG" 2>&1); then
	echo "$build" | grep -E "ERROR|Fatal" | head -20
	echo "FAIL: the registry workspace did not build"
	exit 1
fi
output=$("./build/${CONFIG}_Linux64/App/App" 2>&1)
echo "$output"
expected=(
	"App.Station now: Local=FahrenheitToy Outside=CelsiusToy Inside=none "
	"UserLib.Reading now: Outside=CelsiusToy Inside=none "
	'App.Station written: {"Local":"70F","Outside":"21C","Inside":{"Value":294}}'
)
failed=0
for line in "${expected[@]}"; do
	if ! grep -qxF -- "$line" <<< "$output"; then
		echo "missing: $line"
		failed=1
	fi
done
if [ $failed -ne 0 ]; then
	echo "FAIL"
	exit 1
fi
echo "PASS: the mixin-stage lookups see the user's project and its dependencies only"
