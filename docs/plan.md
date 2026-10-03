# FormatCore: plan and handoff

FormatCore is the shared core of the author's four Beef format libraries — TomlBeef, KdlBeef, XmlBeef
and JsonBeef (https://github.com/mdsitton/<Name>). Each was built from the previous one by copying and refining, so
about a third of each is the same machinery under four prefixes: input cursors, UTF-8 validation and
SWAR scanning, line counting and error location, error carriers and diagnostics, arenas and node
tables, positions and style sidecars, number parsing and formatting, the comptime typed-mapping
generator, and the test and benchmark tooling. The copies have drifted (bugs fixed in one and not the
others, features added to the newest only). FormatCore holds one copy of each, and the siblings move
onto it one component and one sibling at a time, each move proven by the sibling's own verification
and its instruction counts.

This is the handoff for the session that starts the implementation. Read with it:

- `docs/survey-input.md` — cursors, UTF-8 and scanning, encodings, errors and diagnostics, limits,
  small helpers: every copy with file:line, the differences, an API sketch, a prioritized list.
- `docs/survey-data.md` — arenas, node tables and handles, maps and interning, Positions and
  PreserveStyle, numbers, writers, mutation and fuzz infrastructure.
- `docs/survey-typed-and-tooling.md` — the four `[XObject]` generators and the test/bench tooling.
- `docs/beef-sharing-experiments.md` — how Beef behaves across project boundaries, measured
  (`experiments/`): the rules this plan builds on.
- `AGENTS.md`, and each sibling's `docs/architecture.md` and `docs/status.md`.

## 1. State

**2026-10-03, after the first implementation pass:** phases 0-6 are built in FormatCore (all but the
items `status.md` lists as open), each component with its own tests; no sibling has migrated yet.
`docs/architecture.md` is the design as built, `docs/migration.md` what each sibling replaces,
`docs/status.md` the verification baseline. The table below is the state when this plan was written.

| Path | What it is |
|---|---|
| `BeefSpace.toml`, `BeefProj.toml` | The `FormatCore` library project (`src/FormatCore/`), `TestRelease` and Windows (LLVM) configs |
| `src/FormatCore/FormatCoreVersion.bf`, `tests/SmokeTests.bf` | Placeholder; 1/1 tests pass |
| `experiments/` | Seven cross-project experiments (hot loop one- and two-project, internal, comptime chain, comptime "current project", dependencies with a local Git remote, names, build cost), each with its run script |
| `docs/` | The surveys, the experiments write-up, this plan, `status.md` |

The siblings at the time of the surveys: TomlBeef `cd799f0`, KdlBeef `84f2bc2`, XmlBeef `d1ee13e`,
JsonBeef `7959c3f` (XmlBeef and JsonBeef have active sessions).

## 2. What the research says

### 2.1 Sharing costs nothing at run time

`beef-sharing-experiments.md` Q1, Q6: a hot SWAR scan compiled as one project and as two (the scanner,
or a generic specialized on an App cursor, in the library) gives **byte-identical machine code and
identical instructions per byte** (3.571/byte Release; 4.137 with LTO off). Beef compiles one LLVM
module per *type*, so what matters for inlining is the type boundary, never the project; generics are
specialized where used; Release uses ThinLTO on Linux and Windows. Constants owned by the sibling
(stop-byte tables) fold in every form under ThinLTO; without LTO (Debug, macOS) only `[Inline]` keeps
cross-type hot calls inline. Clean-build time and binary size are unchanged.

### 2.2 What is duplicated

| Layer | Duplication | Source |
|---|---|---|
| Input | ~1,500 lines: the window cursor (memory and stream) in KdlBeef → XmlBeef → JsonBeef with ~6 deliberate differences; line counters, stream state, error structs, source ranges and byte helpers identical after renaming. TomlBeef has the older peek/advance cursor | `survey-input.md` |
| Data | Text arenas and stacks identical (X=J); tree links, handles, descendants iterators, side-table helpers identical (K=X; J a packed variant); the read shell in K, X, J; four identical `SourceRange` structs; three Clinger float paths | `survey-data.md` |
| Typed mapping | ~250 lines of comptime helpers in every generator (naming, literals, integer ranges, converter and subtype lookup, ownership emitters), drifted: JSON's is the most general (recursive `ValueSpec`, deferred bodies) | `survey-typed-and-tooling.md` A |
| Tooling | `test-leaks.sh` byte-identical ×4; the Beef `Measure` rule ×6; `bench.h` `measure()` ×4; `merge.sh` ×3 (KdlBeef lacks it); plot helpers ×4; ~100 lines of AGENTS.md ×4 | `survey-typed-and-tooling.md` B |

### 2.3 Bugs and drift found on the way

Real or latent defects in the siblings, independent of FormatCore (each to be fixed in its sibling,
by the author's say-so, or through the shared component that replaces it):

1. **All four generators**: converter registration looks up user declarations with
   `AlwaysVisible`, which only works while the user's project is the *only* project in the workspace
   depending on the format library. With a second dependent, user converters silently disappear
   (`beef-sharing-experiments.md` Q3, `experiments/comptime-exclusive`). The fix is to do
   user-relative `TypeDeclarations` lookups in a `[Comptime]` method emitted into the user's type and
   run through `Compiler.Mixin`, where "current" is the user's project.
2. **TomlBeef**: the slow-path float parse calls `Double.Parse(digits)`, which uses the current
   culture's decimal separator (corlib initializes it from the user's locale); the other three pin
   `.`. Likely wrong on a Windows machine with a comma locale.
3. **TomlBeef**: `TomlEntryMap`'s hash is unseeded (hash flooding on untrusted input); JsonBeef and
   XmlBeef seed.
4. **KdlBeef, XmlBeef, JsonBeef generators**: `IntegerRange`'s minimum for `uint64` is
   `int64.MinValue`, safe only because uint64 is routed separately.
5. Drift: naming policies differ (JSON adds PascalCase, XML adds Lower), enum case naming follows
   three different rules, only XmlBeef tests build-failure fixtures, only XmlBeef and JsonBeef have
   instruction-count scripts and committed fuzz/mutate harnesses, benchmark tolerance is ±5% (XmlBeef)
   vs ±10% (JsonBeef), and TomlBeef's update script still refuses to run above load 2 (the author's
   rule is now to benchmark under load).
6. BeefBuild crashes (exit 139) when an `ApplyToType` emits an `[OnCompile]` method
   (`experiments/comptime/run.sh`): avoid, and report upstream.

## 3. Requirements

| Requirement | Notes |
|---|---|
| **No sibling gets slower.** Every migration is measured with the sibling's instruction counts (before/after, all inputs and modes) and its full verification | `instructions.sh` must exist in all four first (TomlBeef and KdlBeef lack it) |
| **No sibling's public API changes for FormatCore's sake.** FormatCore types are building blocks behind each sibling's own public types | Except where a breaking improvement is wanted anyway (pre-1.0; e.g. one `NamingPolicy`) |
| **One sibling at a time, one component at a time**, each a separate commit in the sibling | XmlBeef and JsonBeef only when their sessions are idle and the author agrees |
| **Every FormatCore component has its own tests** (Debug, Release, leaks, Windows), independent of the siblings | Plus a toy format for the generator framework |
| **Fully qualified names in all emitted code**; distinctive type and attribute names | Q5: emitted code resolves with the user file's `using`s; BJSON's `[JsonObject]` shows the clash |
| **Format-specific code stays in the sibling** | Grammars, escape sets, stop-byte sets, canonical forms, error kinds, recovery rules, duplicate policies, public document/handle types, TOML dates, XML entities and declaration sniffing, JSON push input |

## 4. Design

### 4.1 Projects and packaging

- **`FormatCore`** (this repository's main project): the runtime and comptime building blocks,
  namespace `FormatCore` (sub-namespaces `FormatCore.Text`, `.Input`, `.Diagnostics`, `.Storage`,
  `.Numbers`, `.Mapping`). Building blocks are `internal`; siblings write `using internal
  FormatCore;` (Q2: `internal` has no project dimension, so this is a convention — users can opt in
  too — not a wall). Nothing in a sibling's public signatures names a FormatCore type.
- **`FormatCore.Testing`** (a second project in this repository, never a dependency of the libraries,
  only of the siblings' testers and bench harnesses): the benchmark `Measure` rule, input readers,
  the seeded fuzz mutator and agreement checks.
- **Scripts** in `tools/` (test-leaks, Windows tests, codegen fixtures, a sourced test-script
  library, a round-trip driver) and `bench-kit/` (`merge.sh`, `measure.sh`, `instructions.sh`,
  `bench-core.h`, fetch/build helpers, SVG plot primitives), **vendored** into each sibling by
  `tools/sync.sh`, with `tools/sync.sh --check` in each sibling's verification so copies cannot drift
  again.
- **AGENTS.md**: a shared block in `docs/agents-common.md`, written into a marked region of each
  sibling's AGENTS.md by the same sync script.
- **Dependency** (Q4): each sibling's library project declares
  `FormatCore = {Git = "<one URL, identical in all four>", Version = "x.y"}`; consumers name only
  the format library (Git dependencies are transitive and locked in the consumer's lock file). The
  siblings' own workspaces use the same Git dependency; a FormatCore change reaches them as a new tag. Version constraints only warn, so the policy is: all four siblings move across FormatCore minor
  versions together.

### 4.2 Components and their shared designs

The surveys give API sketches; the plan adopts them with these decisions:

- **Input** (`survey-input.md` §1–6): `Swar`, `Utf8` (`FindInvalid<TPolicy>` with per-format
  policies), `Hex`; `ByteCursor<TText>` and `BufferedStreamCursor<TText>` from the KDL/JSON window
  design with XmlBeef's line handling; `InputState`, `LineCounter<TText>` (the word-at-a-time version),
  `LineIndex`; `ValueStack<T>`, `BitStack`, `DecodeBuffer`. Every hook is a generic parameter on a
  struct type (never virtual) so the in-memory `Fill` still folds to `false` (KdlBeef measured 25%
  when it did not); stop-byte sets are `[Inline]` static members of a struct type parameter or const
  generics; small cross-type hot calls are `[Inline]` (Q1).
- **Diagnostics**: one `ParseError<TKind>` carrier (siblings keep their names through `typealias`
  and their kind enums), `Diagnostic<TKind>`, the collect-errors `ErrorPolicy` skeleton. Each
  sibling's public `SourceRange` stays its own struct over a shared internal record (§9 Q3).
- **Encodings**: XmlBeef's decoder, encoder, WHATWG single-byte tables, BOM detection and transcoding
  stream cursor move whole; XML's declaration handling stays in XmlBeef. Users: XmlBeef; TOML, KDL
  and JSON gain precise "this is UTF-16" errors (and JSON an opt-in reader if wanted, §9 Q7).
- **Storage** (`survey-data.md` §1–4): `TextArena`, `GrowList<T>`, `KeptSource`; the read shell
  (`ReadFileBytes`, `ReadStreamBytes` with a size budget, `BeginRead`/`EndRead`); `RangeRecord`,
  `SideTable<T>`; `Tree<TRecord, TRoot>` link algorithms, preorder walks and cursors over a
  sibling-owned record (prototype first: §9 Q8); `ByteHash` (seeded), `OpenIdIndex`, `OrderedMap`,
  `InternTable`; `RangeTable<TItem>` and a generic `Compact`; style marks and escape-run writers.
- **Numbers**: JsonBeef's extended Clinger path as `DecimalParse` (culture-independent, which fixes
  TomlBeef's bug 2), `ShortestDouble` (shortest round-trip digits with per-format layout),
  `IntegerText` (radix and grouping), `BigDecimal` for lexemes.
- **Typed mapping** (`survey-typed-and-tooling.md` A8): `NamingPolicy` (one enum for all four, the
  union of today's policies), `ValueSpec`/`MemberPlan`/`TypePlan`, `Planner<TFormat>` over an
  `IMappingFormat` static interface, `ClaimSet` with per-format overlap rules, an emission kit, and
  **JsonBeef's deferred-body driver everywhere** (signatures in `ApplyToType`, bodies through
  `Compiler.Mixin`), which also fixes the self-reference crash class for the other three. Converter
  and subtype registry lookups move into the mixin stage (fixes bug 1). Q3 proved the three-project
  chain works, including generic attribute parameters and static interface dispatch at comptime.
  Comptime state never lives in statics (they do not persist between evaluations).
- **Tooling**: §4.1.

## 5. Migration protocol (every component, every sibling)

1. FormatCore: the component with its own tests, green in Debug, Release, leaks and Windows; a FormatCore
   commit and tag.
2. In the sibling (a separate session or the author's go-ahead): record instruction counts on its
   inputs (`instructions.sh`, every mode); switch one component to FormatCore; full verification per
   its AGENTS.md; instruction counts again. Equal or better, or the move is reverted by a follow-up
   edit (never `git revert`) and the cause recorded here.
3. The sibling's commit names the FormatCore version; its `status.md` and `architecture.md` point to
   FormatCore for the moved part.

Order of siblings for each component: **KdlBeef first** (no active session, and it is the ancestor of
the window design), then **TomlBeef**, then XmlBeef and JsonBeef when idle.

## 6. Phases

**Phase 0 — Measurement and tooling.** `instructions.sh` for TomlBeef and KdlBeef (from JsonBeef's);
`tools/test-leaks.sh`, `tools/win-test.sh`, `tools/test-codegen.sh`, `tools/sync.sh`; the shared
AGENTS block (fixing TomlBeef's stale Windows note and load rule); `FormatCore.Testing` with `Measure`;
`bench-kit` (`merge.sh` gives KdlBeef `ONLY=` merges, `measure.sh` with one tolerance, §9 Q5).
Done when all four siblings run the vendored tools with `sync.sh --check` green.

**Phase 1 — Leaf primitives.** `Swar`, `Utf8` helpers, `Hex`, `ParseError<TKind>`, `Diagnostic`,
`RangeRecord`, `TextArena`, `GrowList`, `ValueStack`, `BitStack`, `DecodeBuffer`, `LineIndex`,
`LineCounter`, `InputState`. Migrate KdlBeef, then TomlBeef's applicable parts.

**Phase 2 — Cursors.** `ByteCursor<TText>`, `BufferedStreamCursor<TText>`, `Scan.Until<TStops>`.
KdlBeef first (it gains the SWAR line counter), then XmlBeef/JsonBeef when idle.

**Phase 3 — Numbers.** `DecimalParse`, `ShortestDouble`, `IntegerText`, `BigDecimal`, gated by
JsonBeef's fxx and ES6 corpora; TomlBeef first (fixes its culture bug), then KdlBeef.

**Phase 4 — Typed-mapping framework.** A-1 helpers and `NamingPolicy`; then the planner, `ClaimSet`,
the emission kit and the deferred-body driver with mixin-stage registry lookups; a toy format and
fixtures in FormatCore (XmlBeef's `test-codegen.sh` pattern, generalized), a three-project fixture
workspace locking the cross-project behavior. Migrate KdlBeef, TomlBeef, XmlBeef, JsonBeef (bug 1 is
fixed in each as it moves).

**Phase 5 — Document infrastructure.** Read shell, `SideTable`, `RangeTable`, `Compact`, hashing and
indexes (TomlBeef's seeding fix), then `Tree<TRecord, TRoot>` after a prototype shows equal
instruction counts, style marks and escape writers.

**Phase 6 — Encodings and testing helpers.** XmlBeef's encoding module; `FormatCore.Testing` fuzz and
mutate harnesses (KdlBeef and TomlBeef gain their first committed ones); the test-script library and
round-trip driver; plot primitives.

**Phase 7 — TomlBeef on the window cursor.** The largest single change (an adapter, then the
empty-failure refactor): SWAR stream validation, no spill, lazy stream columns for TOML. Its
`MaxTokenBytes` changes meaning (§9 Q4).

## 7. Testing

- FormatCore's own `[Test]`s per component (including the edge cases the siblings' tests already pin,
  ported), Debug and Release, LeakSanitizer, Windows.
- A toy format exercising the cursor, diagnostics and the generator framework end to end.
- The experiments stay as regression checks for the cross-project rules (`experiments/*/run.sh`).
- The real proof of each migration is the sibling's suite and instruction counts (§5).

## 8. Rules (from `beef-sharing-experiments.md`)

Hot generics in FormatCore, specialized on sibling structs; `[Inline]` small cross-type hot calls
(measure: it can cost ~0.3 instructions/byte); constants as `[Inline]` static interface members or
const generics, never runtime arguments to non-inline functions; no comptime state in statics; no
`[OnCompile]` emitted from `ApplyToType`; user-relative `TypeDeclarations` lookups only in a mixin
emitted into the user's type; handle the unspecialized generic pass and skip `System.Object`'s fields;
fully qualified names in emitted code; one Git URL for FormatCore in all four siblings.

## 9. Decisions and open questions

Decided in this plan (override any):

1. One library project plus a `FormatCore.Testing` project; scripts vendored with a sync check.
2. Building blocks `internal` with `using internal FormatCore;` in the siblings.
3. KdlBeef migrates first for every component; XmlBeef and JsonBeef only when idle, with the author's
   go-ahead.
4. JsonBeef's deferred-body generator model becomes the shared driver; one `NamingPolicy` enum
   (breaking for the siblings' attributes, allowed pre-1.0).
5. Benchmarks run under load (the author's rule): `measure.sh` repeats until processes agree, `~` for
   cells that never settle.

Open:

1. **Name**: `FormatCore` (namespace `FormatCore`) or a `<X>Beef` name like the siblings?
2. **Remote**: create `github.com/mdsitton/FormatCore` for the Git dependency (needed before any
   sibling depends on it by Git; local `Path` works until then)?
3. **Public `SourceRange`**: keep four public structs over a shared record (proposed), or one
   FormatCore type exposed through `typealias`?
4. **TomlBeef's `MaxTokenBytes`** changes meaning on the window cursor (a hard limit per construct
   instead of the retained span): acceptable?
5. **Benchmark tolerance**: ±5% (XmlBeef) or ±10% (JsonBeef) for the shared `measure.sh`?
6. **Error and position offsets**: `int64` everywhere (JsonBeef, streams over 2 GiB) or `int32`
   (smaller records)? Proposed: `int64` in error carriers (cold), `int32` in position records unless a
   sibling needs more.
7. **UTF-8 error messages**: unify on JsonBeef's wording and offsets (regenerating the KDL and XML
   goldens and TOML's position tests)? JSON UTF-16/32 opt-in reading: wanted?
8. **Tree links**: shared `Tree<TRecord, TRoot>` over interface property accessors (needs a prototype
   showing they inline like fields), or keep per-sibling link code and share only the algorithms?
9. **One PreserveStyle source model** (KdlBeef's copied slices vs XmlBeef/JsonBeef's kept source with
   offsets), or share only side tables and marks?
10. **Enum case naming rule** for the shared generator: as declared (TOML), the type's naming
    (KDL, XML), or the field's (JSON)?
11. **Fix the bugs of §2.3 now in each sibling**, or as each migrates?
