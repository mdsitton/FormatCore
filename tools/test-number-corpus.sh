#!/bin/bash
# The number corpora against FormatCore's DecimalParse and ShortestDouble: every parse-number-fxx line
# that is a decimal number must give its f64 and f32 bits; every RFC 8785 es6 line must be written as
# its expected text and read back. Runs NumberCorpusTests (TestRelease) with FORMATCORE_NUMBER_CORPUS set.
# Usage: bash tools/test-number-corpus.sh [corpus directory]
#   default: ../JsonBeef/tests/suites (fetched there by JsonBeef's tests/fetch-suites.sh)
set -uo pipefail
cd "$(dirname "$0")/.."
CORPUS="${1:-../JsonBeef/tests/suites}"
if [ ! -d "$CORPUS/parse-number-fxx" ] || [ ! -d "$CORPUS/es6-numbers" ]; then
	echo "ERROR: $CORPUS has no parse-number-fxx or es6-numbers (JsonBeef: bash tests/fetch-suites.sh)"
	exit 1
fi
CORPUS="$(cd "$CORPUS" && pwd)"
output=$(FORMATCORE_NUMBER_CORPUS="$CORPUS" beefbuild -test -config=TestRelease 2>&1)
status=$?
grep -E '^(fxx|es6)|mismatch|^Completed|ERROR' <<< "$output"
if [ $status -ne 0 ]; then
	echo "FAIL"
	exit 1
fi
echo "PASS"
