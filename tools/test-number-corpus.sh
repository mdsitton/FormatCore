#!/bin/bash
# The number corpora against FormatCore's DecimalParse and ShortestDouble: every parse-number-fxx line
# that is a decimal number must give its f64 and f32 bits; every RFC 8785 es6 line must be written as
# its expected text and read back. Runs NumberCorpusTests (TestRelease) with FORMATCORE_NUMBER_CORPUS set.
# Usage: bash tools/test-number-corpus.sh <corpus directory>
#   the directory holding parse-number-fxx and es6-numbers (JsonBeef's tests/suites, fetched there by
#   JsonBeef's tests/fetch-suites.sh)
set -uo pipefail
if [ $# -lt 1 ]; then
	echo "Usage: bash tools/test-number-corpus.sh <corpus directory> (JsonBeef's tests/suites)"
	exit 2
fi
CORPUS="$(cd "$1" 2>/dev/null && pwd)" || { echo "ERROR: $1 not found"; exit 1; }
cd "$(dirname "$0")/.."
if [ ! -d "$CORPUS/parse-number-fxx" ] || [ ! -d "$CORPUS/es6-numbers" ]; then
	echo "ERROR: $CORPUS has no parse-number-fxx or es6-numbers (JsonBeef: bash tests/fetch-suites.sh)"
	exit 1
fi
output=$(FORMATCORE_NUMBER_CORPUS="$CORPUS" beefbuild -test -config=TestRelease 2>&1)
status=$?
grep -E '^(fxx|es6)|mismatch|^Completed|ERROR' <<< "$output"
if [ $status -ne 0 ]; then
	echo "FAIL"
	exit 1
fi
echo "PASS"
