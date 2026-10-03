#!/bin/bash
# Vendors FormatCore's shared scripts (tools/vendored.txt) into a repository, each with a header line
# naming its source, so the four format libraries run the same copies; --check reports copies that
# differ from FormatCore's (run it in each repository's verification so they cannot drift again).
# Usage: bash tools/sync.sh <repository> [--check]
#   bash tools/sync.sh ../KdlBeef           write the copies
#   bash tools/sync.sh ../KdlBeef --check   exit 1 if a copy is missing or differs
set -uo pipefail
CORE="$(cd "$(dirname "$0")/.." && pwd)"
if [ $# -lt 1 ]; then
	echo "Usage: bash tools/sync.sh <repository> [--check]"
	exit 2
fi
TARGET="$(cd "$1" && pwd)" || exit 2
CHECK=0
if [ "${2:-}" = "--check" ]; then
	CHECK=1
fi
commit=$(git -C "$CORE" rev-parse --short HEAD 2>/dev/null || echo unknown)

# The copy: the source with a header after its first line (the #! line)
render() { # source
	head -n 1 "$1"
	echo "# Vendored from FormatCore ${1#"$CORE"/} by tools/sync.sh: edit it there, then sync."
	tail -n +2 "$1"
}

# The copy without its header line, to compare with the source whatever commit wrote it
strip() { # file
	head -n 1 "$1"
	tail -n +3 "$1"
}

drift=0
count=0
while IFS=$'\t' read -r source dest condition; do
	[[ -z "$source" || "$source" == \#* ]] && continue
	if [ "$condition" != always ] && [ ! -e "$TARGET/$condition" ]; then
		continue
	fi
	count=$((count + 1))
	if [ $CHECK -eq 1 ]; then
		if [ ! -f "$TARGET/$dest" ]; then
			echo "missing: $dest"
			drift=1
		elif ! diff -q <(strip "$TARGET/$dest") "$CORE/$source" > /dev/null; then
			echo "differs: $dest (from $source)"
			drift=1
		fi
		continue
	fi
	render "$CORE/$source" > "$TARGET/$dest"
	chmod +x "$TARGET/$dest"
	echo "wrote $dest (FormatCore $commit)"
done < "$CORE/tools/vendored.txt"

if [ $CHECK -eq 1 ]; then
	if [ $drift -ne 0 ]; then
		echo "FAIL: vendored copies differ from FormatCore's (bash <FormatCore>/tools/sync.sh $1)"
		exit 1
	fi
	echo "PASS: $count vendored files match FormatCore"
fi
