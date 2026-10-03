# AGENTS.md

## Notes for coding agents

- This repository is a Beef language project: **FormatCore**, the shared core library of four
  format libraries by the same author — TomlBeef (`~/development/TomlBeef`), KdlBeef
  (`~/development/KdlBeef`), XmlBeef (`~/development/XmlBeef`) and JsonBeef (`~/development/JsonBeef`).
  It holds what they duplicate (input cursors, UTF-8 and scanning, encodings, errors and diagnostics,
  limits, arenas and node tables, numbers, the typed-mapping generator framework, test and benchmark
  tooling); `docs/plan.md` says what moves here, in which order, and how each sibling migrates.
- **The siblings are this library's users, and they are hot code.** Every change here is measured in
  the siblings (instructions per input byte, e.g. XmlBeef's `bench/instructions.sh`) before and after;
  a shared component must specialize and inline exactly as the copy it replaces
  (`docs/beef-sharing-experiments.md` has the rules for generics, `[Inline]`, constant tables and
  comptime across projects).
- **Never edit a sibling repository from a FormatCore session** unless the author asks for that
  migration step: other sessions work in them. Migration steps are planned in `docs/plan.md` and
  done in the sibling, one sibling at a time.
- **The shared rules, gotchas and conventions** below (between the `FormatCore:agents-common` markers)
  are `docs/agents-common.md`, which `tools/sync.sh` also writes into each sibling's AGENTS.md: edit
  that file, never the region, then `bash tools/sync.sh .` (and each sibling's sync in its migration
  step).
- Beef `String` stores UTF-8 data and is mutable. Prefer `StringView` for borrowed string inputs.
- Beef uses manual and scope-based memory management. There is no tracing garbage collector.
- This project currently targets Linux64 first; Windows is verified with the Proton-hosted Beef
  (`~/development/beef-proton/bin/beefbuild-win`), as in TomlBeef.
- Preferred CLI tool: `beefbuild` on Linux, `BeefBuild` on Windows. Use from `PATH`.
- Start with `docs/plan.md` (the plan and handoff), the surveys of what the siblings duplicate
  (`docs/survey-input.md`, `docs/survey-data.md`, `docs/survey-typed-and-tooling.md`),
  `docs/beef-sharing-experiments.md` (how Beef behaves across project boundaries, measured) and
  `docs/status.md` (current state, verification baseline, open items). Keep `status.md` current:
  remove finished items and update the baseline when test counts change. Durable design notes go in
  `docs/architecture.md` once the implementation has a design worth recording; `docs/plan.md` is the
  starting plan and is updated as phases complete, not duplicated.

## Critical rules

- **Verify Beef source/project changes.** After modifying `.bf`, `BeefProj.toml`, or workspace files, run the tests in **both** Debug and Release: `beefbuild -test` and `beefbuild -test -config=TestRelease` (they run FormatCore's, FormatCore.Testing's and ToyTests' `[Test]`s, selected by `ConfigSelections` in `BeefSpace.toml`). Debug catches runtime-check and allocator issues; Release catches optimizer-dependent bugs. Also `bash ./test-leaks.sh`, `bash ./test-codegen.sh` and `bash tests/registry/run.sh` (typed mapping), `bash tools/sync.sh . --check`, and the Windows tests (`bash ./win-test.sh`) before committing. A change to a component a sibling already uses is verified in that sibling too: its full verification (its AGENTS.md) and its instruction counts before and after. Report results. For docs-only edits, no build is required. If verification cannot be run, say why.
- The rest of the critical rules are the shared ones below.

<!-- FormatCore:agents-common begin -->
## Shared rules (FormatCore)

This block is FormatCore's `docs/agents-common.md`, written into each repository's AGENTS.md by
`tools/sync.sh` between the `FormatCore:agents-common` markers: change it in FormatCore, then sync
(`bash <FormatCore>/tools/sync.sh <repo>`); `--check` fails when a copy drifted.

- **Do not use scripts or bash commands to edit code.** Use the provided `edit` or `write` tools directly. Violating this will result in a work stoppage.
- **Always use `edit` for changes to existing files**, never `write` unless creating a new file or doing a complete rewrite.
- **When using `edit` with multiple changes** in the same file, merge nearby changes into a single edit call with multiple entries in the `edits` array.
- **Do not include large unchanged regions** in `edits[].oldText`. Keep it as small as possible while still being unique.
- **NEVER REVERT CODE USING GIT OR ANY VERSION CONTROL.** Do not use `git checkout`, `git revert`, `git reset`, or any similar command that discards or rolls back code changes. This destroys work and context. If you think a revert is needed, **end your turn and ask for explicit permission first.**
- **Never add `Co-Authored-By` or any other attribution trailer to commit messages.**
- **Use US English spellings** in code, comments and documentation (neighbor, color, behavior).
- **Commit as Matthew Sitton <matthewsitton@gmail.com>**: `git -c user.name="Matthew Sitton" -c user.email="matthewsitton@gmail.com" commit ...` (the global git identity can differ).
- **Windows is verified**, not deferred: the `[Test]`s run under the Proton-hosted Windows Beef
  (`~/development/beef-proton/bin/beefbuild-win`) in Test and TestRelease (`bash ./win-test.sh`)
  before committing.
- **Benchmarks do not wait for a quiet machine** (this machine never is): a benchmark's `run.sh` samples until each run converges and repeats processes until enough agree within ±10% (`bench/compare/measure.sh`, from FormatCore's bench-kit), marking a cell that never settles `~`. Run it as it is, whatever the load; report the load average and the `~` cells with the figures, and rerun (`ONLY=...`) cells that did not settle before drawing conclusions from them. A cell past its time limit is DNF, not waited out. Small changes are compared with `bench/instructions.sh` (user-space instructions per input byte), which the load does not disturb.
- **Run shell scripts with bash** (`bash ./script.sh`): the interactive shell is not bash, and unquoted variables do not word-split.
- **Disk space is limited**: check `df -h ~` before large builds or downloads.

## Beef Language Gotchas

These are non-obvious Beef behaviors discovered through debugging (in TomlBeef and its siblings). Violating these will cause crashes, leaks, or silent failures.

### Memory & lifetime

- **`scope` works for class types** — `scope Document()`, `scope List<T>()` all work fine. The object lives for the enclosing scope.
- **`scope List<String>()` does NOT delete String elements.** The list's internal buffer is freed but contained `String`/class instances leak. Use `defer { ClearAndDeleteItems!(list); }` for scope-allocated lists of owned items.
- **Field initializers with `~ delete _` require an explicit constructor.** Beef's generated default constructor does NOT run field initializers when `~ delete _` is present. Always write `public this() { mField = new Type(); }` explicitly.
- **`~ delete _` is preferred** over manual `~this()` methods for field-level cleanup.
- **`DeleteContainerAndDisposeItems!`, `ClearAndDeleteItems!`, `DeleteDictionaryAndKeys!`** are built-in mixins for container cleanup. Use them instead of manual loops.
- **`defer` on a mixin requires a block wrapper**: `defer { ClearAndDeleteItems!(x); }` — NOT `defer ClearAndDeleteItems!(x);`
- **`defer` runs in LIFO order.** For `defer SomeCall(arg)`, `arg` and `this` are evaluated immediately; for `defer { ... }`, captured variables are read when the scope exits. So `defer File.Delete(path).IgnoreError();` deletes the file *now* (the call is the receiver of the deferred `IgnoreError`): write `defer { File.Delete(path).IgnoreError(); }`.
- **`delete` on value types (enums, structs) is a no-op.** Types without `~this()` (which structs can't have) need explicit `.Dispose()`.

### String formatting

- **`$"...{var}..."` interpolation** is for string literals (`scope $"key={key}"`). Variable names are captured from scope.
- **`AppendF("...{}...", arg)` / `AppendF("...{0}...", arg)`** use positional placeholders. Do NOT use `{variable}` syntax in `AppendF` — it compiles but crashes at runtime.
- **Do not mutate string literals.** `String s = "literal"; s.Append(...)` attempts to mutate read-only literal storage. Use `scope String()..Append(...)` or `scope $"..."`.
- **`StringView.Substring(pos)` and `Substring(pos, length)`** exist. Prefer them over raw `StringView(&ptr[offset], length)`.
- **`Console.WriteLine($"{x}")` allocates nothing**: `WriteLine(StringView fmt, params Object[])` exists, so the interpolation becomes a format call. A `$"..."` passed to a method without such an overload (`list.Add($"...")`) creates a heap String; use `scope $"..."` there.

### Switch & pattern matching

- **`switch` does NOT fall through in Beef.** Each case breaks automatically. `fallthrough;` needed to continue into the next case.
- **`switch` on `Result<T, E>`**: `case .Ok(let val):` and `case .Err(let e):`
- **`if (X case .Err(let e))`** is preferred over `switch` for simple error checks. But it does NOT bind the success value — for `.Ok(let val)` extraction, use `switch` or a temporary variable.
- **A variable declared inside a condition cannot be used after a `||` that might skip it.** `if (!TryGetArray(let a) || a.Count != 3)` is fine, but `if (!a.TryGetFloat(0, let x) || !a.TryGetFloat(1, let y)) return; use(x, y);` fails with "Conditional short-circuiting may skip variable initialization". Declare the variables first and pass them with `out`, split the checks into separate `if`s, or `switch` on a tuple of results.
- **There is no `case A or B` pattern.** Compare explicitly.
- **Enum switches without `default:` warn on non-exhaustiveness** — useful for catching new enum variants.

### Test framework

- **`[Test]` methods must be static.**
- **`beefbuild -test`** auto-discovers `[Test]` methods. No configuration needed. It runs the tests of the **first project listed** in the workspace's `[Projects]`, and of another project only when the test config selects that project's Test config: `ConfigSelections = {Other = {Config = "Test"}}` under `[Configs.Test.<platform>]` and `[Configs.TestRelease.<platform>]` (FormatCore's `BeefSpace.toml`; Beef's own `IDEHelper/Tests` workspace does the same).
- **Test assertions produce virtually no console output.** Debug test failures in a console app first, then port to `[Test]` once proven.
- **`[Test(ShouldFail=true)]`** marks an expected failure. If the test passes, the framework reports "Test should have failed but didn't" as an error.
- **A segfault in a test is never acceptable.** `ShouldFail` is for assertion failures, not crashes.

### File I/O

- **`File.ReadAllText` strips exactly one BOM** via StreamReader. Use `File.ReadAll` with `List<uint8>` for raw bytes when BOM-preservation matters (a format may allow a BOM only first, or use it to detect the encoding).
- **`File.ReadAll` requires `using System.Collections;`** for `List<uint8>`.
- **`entry.GetFilePath(.. scope .())`** — the `.. scope .()` syntax creates a scope-allocated out parameter.

### Type system

- **`StringView` cannot be null.** Passing `null` where `StringView` is expected creates a default/empty StringView.
- **`char8` vs `int` comparisons** need explicit `(uint8)` casts when comparing with hex literals like `0xEF`.
- **Shadowed variable warnings (BF4200)** — reusing a name like `e` in nested `case .Err(let e)` produces warnings. Use unique names.
- **`out` and `var` are mutually exclusive in parameter position.** Write `out existingVar` for a pre-existing variable, or `var newVar` to declare inline. `out var x` does **not** compile. A variable declared with `let` (also `let x` in an `out` position) is read-only: it cannot be passed as `out` again; declare it with `var` when it is reused.
- **Reserved identifiers include `box`.** Do not use `box` as a local/parameter/field name.
- **Prefer Beef primitive aliases** (`int32`, `uint8`, `float`, `bool`) over wrapper type names such as `System.Int32`.
- **Wrapping arithmetic** (hashes) uses `&*`, `&+`.

#### Special type references

- **`Self`**, **`SelfBase`**, **`SelfOuter`**, **`var`**, **`let`**, and the **`.` (dot type)** expected-type shorthand (`return .Err(...)`, `(.)floatVal`) work as in TomlBeef.

### Comptime

- **`[Comptime]` code may enumerate `Type.TypeDeclarations`** (not `Type.Types`), read attributes with `GetCustomAttribute<T>()` on declarations, types and fields (`GetCustomAttributes<T>()` for repeated ones), and emit code with `Compiler.EmitTypeBody` / `EmitAddInterface`. `Runtime.FatalError` in comptime code becomes a build error. See TomlBeef's `TomlSerializerCodeGen.bf`.
- **An `IComptimeTypeApply` runs during the type's initialization**: looking at a field type that specializes a generic over the type itself (`List<Node>` in `Node`) there is a data cycle ("OnCompile const evaluation creates a data dependency during TypeInit"), and in a larger project it crashed the compiler outright. Emit only signatures then, and the bodies as `System.Compiler.Mixin(SomeGen.Body(typeof(T), ...))`: the mixin runs when the method is compiled, when every type is complete (JsonBeef's `JsonSerializerCodeGen.Emit`). `Compiler.Mixin` is a statement, not an expression: a property returns through a mixed-in `return ...;`.
- **A generic constraint on an interface that comptime adds** (`where T : IJsonSerializable` with a `[JsonObject]` type) can fail with "must implement" when the type argument is written out (`F<MyType>(...)`); let it be inferred from an argument (`F(myObject, ...)`).
- **"Current project" in `TypeDeclaration.DeclaredInCurrent`/`DeclaredInDependency`** is the project of the comptime evaluation's entry point (the format library's attribute in `ApplyToType`), never the user's: a user's declarations seen through `AlwaysVisible` disappear once a second project depends on the format library. Do user-relative lookups in a `[Comptime]` method emitted into the user's type and run through `Compiler.Mixin` (FormatCore's `docs/beef-sharing-experiments.md` Q3).
- **Never emit an `[OnCompile]` method from `ApplyToType`**: BeefBuild crashes (exit 139).
- **Comptime static fields do not persist** between evaluations (each `ApplyToType` and each `Compiler.Mixin` starts afresh): pass state explicitly or emit it.

### Lambdas

- **A lambda that outlives a block must not capture the block's locals.** `op = scope:: () => Use(kind);` with `kind` declared inside an inner `{ }` (or a `case` block) reads a dead stack slot once the block ends: the values silently change. Declare captured locals at the lambda's own scope, and capture by value with `[=]`.

### Windows Debug

- **The Windows Debug runtime checks for leaks when the process exits** and stops it with a breakpoint (`Test process exited with error code: 2147483651`, 0x80000003) after every test has passed. LeakSanitizer on Linux can miss such a leak (a stale pointer keeps it "reachable"). Find it by marking tests `[Test(Ignore=true)]` in halves.

### Console & debugging

- **`Console.Out.Flush()`** is often needed to see output before a crash. Console output is buffered.
- **`beefbuild -run -args ...`** runs the startup project with arguments (everything after `-args` is passed through).

## Doc Comment Style

Public API surface uses `///` documentation comments with Doxygen-style tags, placed directly above the declaration (above attributes). Required: `@brief` first when a summary is wanted, `@param` for every parameter, `@return` for every non-void method. `@brief` alone is enough for constants, fields and trivial getters. Do not use C# XML tags.

## Beef Language Conventions

- `using` directives at the top: `System*` first, then dependencies, then project namespaces.
- Members are private by default; be explicit with `public` on API surface. `internal` requires `using internal <namespace>;` even within the same namespace (and in every file that touches FormatCore's internal building blocks: `using internal FormatCore;`).
- Struct methods that modify fields are marked `mut` after the signature; `set mut` for property setters.
- Use `Result<T, E>` with the library's parse error for fallible operations; propagate with `Try!` or `if (X case .Err(let e)) return .Err(e);`. There are no exceptions.
- `String` owned and mutable, `StringView` borrowed; never store a `StringView` in a long-lived object unless the backing storage is owned; prefer APIs that append into caller-provided `String` buffers; never return a `scope String`.
- Prefer `scope` for temporaries, `new` + `delete`/`defer delete` or `~ delete _` fields for owned objects.
- Beef rejects comparing `uint8` with a char literal: text is handled as `char8*`/`char8`, with `(uint8)` casts only where hex values are compared.

## Naming Conventions

| Kind | Convention | Example |
|------|-----------|---------|
| Types | PascalCase | `ByteCursor`, `NodeTable` |
| Methods/functions | PascalCase | `Parse`, `TryGetString` |
| Fields (public) | camelCase | `maxInputBytes` |
| Fields (private) | `m` + PascalCase | `mNodes`, `mRootNodes` |
| Fields (static/private) | `s` + PascalCase | `sScratchBuffer` |
| Constants / enum values | PascalCase | `DefaultMaxInputBytes`, `Ok` |
<!-- FormatCore:agents-common end -->

## Debugging with lldb/gdb

Beef compiles to native code via LLVM and emits DWARF debug info on Linux. Both lldb and gdb work.

```bash
lldb --batch -o run -o bt ./build/Debug_Linux64/<Project>/<Project>
gdb -batch -ex run -ex bt ./build/Debug_Linux64/<Project>/<Project>
```

Frame #0 is the crash point. Mangled names map to files (`bf::FormatCore::ByteCursor::ScanRun` → `ByteCursor.bf`). "Unhandled error in result" means a `Result` holding `.Err` was discarded. Release builds strip debug info; debug against `build/Debug_Linux64/...`.

## Code Organization

- Each public type normally gets its own file; small helper types may share a file when that improves cohesion.
- Library sources in `src/FormatCore/`, tests in `src/FormatCore/tests/`; the testing and benchmark
  helpers (`FormatCore.Testing`, a separate project the siblings' testers depend on, never their
  libraries) in `Testing/src/`, tests in `Testing/src/tests/`; cross-project experiments in
  `experiments/<name>/` (each its own workspace); shared scripts in `tools/` and `bench-kit/`, vendored
  into the siblings by `tools/sync.sh` (`tools/vendored.txt` lists them).
- Do not enumerate `src/` in `BeefProj.toml`.

## Build and Test Conventions

- `beefbuild -help` is the source of truth for CLI flags.
- `beefbuild -test` / `beefbuild -test -config=TestRelease` run the `[Test]` methods of every test
  project the workspace selects.
- `bash ./test-leaks.sh` runs the `[Test]`s under LeakSanitizer; `bash ./win-test.sh` runs them on
  Windows (Test and TestRelease).
- Performance is measured as user-space instructions (`perf stat -e instructions:u`) on fixed
  iteration counts, which the machine's load does not disturb; wall time only through the siblings'
  benchmark rule. Profile with `perf record`.

## References

- The four siblings, each with `docs/architecture.md` and `docs/status.md`: `~/development/TomlBeef`,
  `~/development/KdlBeef`, `~/development/XmlBeef`, `~/development/JsonBeef`
- Official Beef documentation: `https://www.beeflang.org/docs/`; docs source `~/development/Beef_website`
- Beef language and tool source: `~/development/Beef`
- TomlBeef (design and code to port): `~/development/TomlBeef`, especially `docs/architecture.md`
