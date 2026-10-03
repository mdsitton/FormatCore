#!/bin/bash
# Vendors FormatCore's shared scripts and files (tools/vendored.txt) into a repository, each with a
# header line naming its source, and writes FormatCore's shared AGENTS.md block (docs/agents-common.md)
# into the marked region of the repository's AGENTS.md, so the four format libraries run the same copies
# and follow the same rules; --check reports copies that differ from FormatCore's (run it in each
# repository's verification so they cannot drift again).
# Usage: bash tools/sync.sh <repository> [--check]
#   bash tools/sync.sh <repository>           write the copies and the AGENTS.md region
#   bash tools/sync.sh <repository> --check   exit 1 if a copy or the region is missing or differs
# The region is the lines between `<!-- FormatCore:agents-common begin -->` and
# `<!-- FormatCore:agents-common end -->` in AGENTS.md: add the two markers once (where the shared rules
# belong, replacing the repository's own copy of them); the sync never adds them by itself.
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
BEGIN='<!-- FormatCore:agents-common begin -->'
END='<!-- FormatCore:agents-common end -->'
BLOCK="$CORE/docs/agents-common.md"

# The comment that starts a header line in a file of this name
comment_of() { # path
	case "$1" in
	*.c | *.h | *.cpp | *.hpp) echo "//" ;;
	*) echo "#" ;;
	esac
}

# The copy: the source with a header line, after its #! line if it has one, else first
render() { # source
	local header
	header="$(comment_of "$1") Vendored from FormatCore ${1#"$CORE"/} by tools/sync.sh: edit it there, then sync."
	if head -n 1 "$1" | grep -q '^#!'; then
		head -n 1 "$1"
		echo "$header"
		tail -n +2 "$1"
	else
		echo "$header"
		cat "$1"
	fi
}

# The copy without its header line, to compare with the source whatever commit wrote it
strip() { # file
	awk 'NR <= 2 && !dropped && /Vendored from FormatCore .* by tools\/sync\.sh/ { dropped = 1; next } { print }' "$1"
}

# The lines of AGENTS.md between the markers (nothing if there are none)
region() { # agents-file
	awk -v b="$BEGIN" -v e="$END" '$0 == e { inside = 0 } inside { print } $0 == b { inside = 1 }' "$1"
}

# Whether AGENTS.md has both markers, in order
has_region() { # agents-file
	awk -v b="$BEGIN" -v e="$END" '$0 == b { seen = 1 } $0 == e && seen { found = 1 } END { exit !found }' "$1"
}

# AGENTS.md with the region replaced by the block
write_region() { # agents-file
	local tmp
	tmp=$(mktemp)
	awk -v b="$BEGIN" -v e="$END" -v block="$BLOCK" '
		$0 == b { print; while ((getline line < block) > 0) print line; skip = 1; next }
		$0 == e { skip = 0 }
		!skip { print }' "$1" > "$tmp"
	# Copied over, not moved: the file keeps its mode
	cat "$tmp" > "$1"
	rm -f "$tmp"
}

drift=0
count=0
while IFS=$'\t' read -r source dest condition; do
	[[ -z "$source" || "$source" == \#* ]] && continue
	if [ "$condition" != always ] && [ ! -e "$TARGET/$condition" ]; then
		continue
	fi
	count=$((count + 1))
	# FormatCore synced into itself: a file vendored to its own path is the source
	if [ "$TARGET/$dest" -ef "$CORE/$source" ]; then
		continue
	fi
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
	mkdir -p "$(dirname "$TARGET/$dest")"
	render "$CORE/$source" > "$TARGET/$dest"
	if [[ "$dest" == *.sh ]] && head -n 1 "$CORE/$source" | grep -q '^#!'; then
		chmod +x "$TARGET/$dest"
	fi
	echo "wrote $dest (FormatCore $commit)"
done < "$CORE/tools/vendored.txt"

# The shared AGENTS.md block
agents="$TARGET/AGENTS.md"
if [ -f "$agents" ]; then
	count=$((count + 1))
	if ! has_region "$agents"; then
		echo "missing: the FormatCore:agents-common region of AGENTS.md (add the begin and end markers)"
		[ $CHECK -eq 1 ] && drift=1
	elif [ $CHECK -eq 1 ]; then
		if ! diff -q <(region "$agents") "$BLOCK" > /dev/null; then
			echo "differs: the FormatCore:agents-common region of AGENTS.md (from docs/agents-common.md)"
			drift=1
		fi
	else
		write_region "$agents"
		echo "wrote the FormatCore:agents-common region of AGENTS.md (FormatCore $commit)"
	fi
fi

if [ $CHECK -eq 1 ]; then
	if [ $drift -ne 0 ]; then
		echo "FAIL: vendored copies differ from FormatCore's (bash <FormatCore>/tools/sync.sh $1)"
		exit 1
	fi
	echo "PASS: $count vendored files match FormatCore"
fi
