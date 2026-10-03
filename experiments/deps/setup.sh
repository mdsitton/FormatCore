#!/bin/bash
# Creates the dependency-mechanics experiment (everything it creates is git-ignored):
#   remote/FormatCore.git  a local bare repository standing in for FormatCore's remote; Core is in /Core.
#                          Tags v1.0.0, v1.1.0, v2.0.0 on main and v1.2.0 on branch v1x;
#                          Core.CoreVersion.Value is 1, 2, 3 and 12.
#   remote/LibA.git        a library repository whose LibA depends on Core by Git URL (tag v1.0.0).
# and these workspaces (App -> LibA, LibB; LibA, LibB -> Core by Git URL; App never names Core):
#   compat      LibA wants Core "1.0", LibB wants "1.1"           (both satisfiable)
#   conflict    LibA wants Core "~1.0" (<1.1), LibB wants "2.0"    (no common version)
#   override    as compat, but the workspace lists Core = {Path = "../remote/work/Core"}
#   nover       LibA and LibB give a Git URL and no Version
#   gitchain    App -> LibA by Git URL -> Core by Git URL (transitive Git dependencies)
# The v1.2.0 tag is added after the first compat build, to show the lock holding v1.1.0.
# Usage: bash setup.sh; then for each workspace: beefbuild -workspace=<name> and run
#   <name>/build/Debug_Linux64/App/App; the lock is <name>/BeefSpace_Lock.toml.
# Beef clones into its managed cache (~/.config/beeflang/BeefManaged/<commit> for the Linux package).
set -euo pipefail
cd "$(dirname "$0")"
HERE=$PWD
URL="file://$HERE/remote/FormatCore.git?path=/Core"
commit() { git -c user.name=exp -c user.email=exp@example.invalid commit -q "$@"; }

make_remote() {
	rm -rf remote
	mkdir -p remote/work/Core/src
	cd remote/work
	git init -q -b main .
	printf 'FileVersion = 1\n\n[Project]\nName = "Core"\nTargetType = "BeefLib"\n' > Core/BeefProj.toml
	version() { printf 'namespace Core;\n\npublic static class CoreVersion\n{\n\tpublic const int Value = %s;\n}\n' "$1" > Core/src/Version.bf; }
	version 1; git add -A; commit -m "Core 1.0.0"; git tag v1.0.0
	version 2; commit -am "Core 1.1.0"; git tag v1.1.0
	version 3; commit -am "Core 2.0.0"; git tag v2.0.0
	cd ..
	git clone -q --bare work FormatCore.git
	cd "$HERE"
}

add_v1_2() {
	cd remote/work
	git checkout -q -b v1x v1.1.0
	printf 'namespace Core;\n\npublic static class CoreVersion\n{\n\tpublic const int Value = 12;\n}\n' > Core/src/Version.bf
	commit -am "Core 1.2.0"; git tag v1.2.0
	git checkout -q main
	git push -q ../FormatCore.git v1x --tags
	cd "$HERE"
}

lib() { # dir name version-or-empty
	mkdir -p "$1/$2/src"
	local spec="{Git = \"$URL\"}"
	[ -n "$3" ] && spec="{Git = \"$URL\", Version = \"$3\"}"
	printf 'FileVersion = 1\n\n[Project]\nName = "%s"\nTargetType = "BeefLib"\n\n[Dependencies]\ncorlib = "*"\nCore = %s\n' "$2" "$spec" > "$1/$2/BeefProj.toml"
	printf 'namespace %s;\n\npublic static class Info\n{\n\tpublic static int CoreSeen => Core.CoreVersion.Value;\n}\n' "$2" > "$1/$2/src/$2.bf"
}

app() { # dir deps-toml-lines message-expression
	mkdir -p "$1/App/src"
	printf 'FileVersion = 1\n\n[Project]\nName = "App"\nStartupObject = "App.Program"\n\n# Core is never named here\n[Dependencies]\ncorlib = "*"\n%s\n' "$2" > "$1/App/BeefProj.toml"
	cat > "$1/App/src/Program.bf" <<-EOF
	using System;

	namespace App;

	class Program
	{
		public static void Main()
		{
			Console.WriteLine(scope \$"$3, App sees Core {Core.CoreVersion.Value}");
		}
	}
	EOF
}

workspace() { # dir versionA versionB [extra Projects line]
	rm -rf "$1"
	lib "$1" LibA "$2"
	lib "$1" LibB "$3"
	app "$1" $'LibA = "*"\nLibB = "*"' 'LibA sees Core {LibA.Info.CoreSeen}, LibB sees Core {LibB.Info.CoreSeen}'
	printf 'FileVersion = 1\n\n[Workspace]\nStartupProject = "App"\n\n[Projects]\nApp = {Path = "App"}\nLibA = {Path = "LibA"}\nLibB = {Path = "LibB"}\n%s\n' "${4:-}" > "$1/BeefSpace.toml"
}

make_remote
workspace compat "1.0" "1.1"
workspace conflict "~1.0" "2.0"
workspace override "1.0" "1.1" 'Core = {Path = "../remote/work/Core"}'
workspace nover "" ""

# LibA as its own Git repository (depending on Core by Git URL, "1.0")
rm -rf remote/libawork remote/LibA.git
lib remote/libawork LibA "1.0"
(cd remote/libawork && git init -q -b main . && git add -A && commit -m "LibA 1.0.0" && git tag v1.0.0)
git clone -q --bare remote/libawork remote/LibA.git
rm -rf gitchain
app gitchain "LibA = {Git = \"file://$HERE/remote/LibA.git?path=/LibA\", Version = \"1.0\"}" 'LibA sees Core {LibA.Info.CoreSeen}'
printf 'FileVersion = 1\n\n[Workspace]\nStartupProject = "App"\n\n[Projects]\nApp = {Path = "App"}\n' > gitchain/BeefSpace.toml

if [ "${1:-}" = "run" ]; then
	for w in compat conflict override nover; do
		echo "== $w"
		beefbuild -workspace=$w 2>&1 | grep -E "Git |WARNING|ERROR" || true
		[ -f $w/BeefSpace_Lock.toml ] && grep -E "Tag|Hash" $w/BeefSpace_Lock.toml
		$w/build/Debug_Linux64/App/App
	done
	echo "== compat after tagging v1.2.0 (lock kept)"
	add_v1_2
	beefbuild -workspace=compat 2>&1 | grep -E "Git |WARNING|ERROR" || true
	grep Tag compat/BeefSpace_Lock.toml; compat/build/Debug_Linux64/App/App
	echo "== compat with the lock deleted"
	rm compat/BeefSpace_Lock.toml
	beefbuild -workspace=compat 2>&1 | grep -E "Git |WARNING|ERROR" || true
	grep Tag compat/BeefSpace_Lock.toml; compat/build/Debug_Linux64/App/App
	echo "== gitchain"
	beefbuild -workspace=gitchain 2>&1 | grep -E "Git |WARNING|ERROR" || true
	cat gitchain/BeefSpace_Lock.toml; gitchain/build/Debug_Linux64/App/App
fi
