# FormatCore status

Last reviewed: 2026-10-03.

## Verification baseline

| Check | Expected result |
|-------|-----------------|
| `beefbuild -test` (Debug checks) | FormatCore 70/70, FormatCore.Testing 5/5, ToyTests 7/7 |
| `beefbuild -test -config=TestRelease` (Release settings) | the same |
| `bash ./test-leaks.sh` | PASS: no leaks detected |
| `bash ./test-codegen.sh` | 13/13 fixtures as expected |
| `bash tests/registry/run.sh` | PASS (mixin-stage lookups see the user's project and its dependencies only) |
| `bash tools/test-number-corpus.sh` | fxx 1,414,285 lines and RFC 8785 100,000 lines, 0 mismatches (needs JsonBeef's fetched suites) |
| `bash ./win-test.sh` (Test and TestRelease under Proton) | the same counts as Linux, both configs |
| `bash tools/sync.sh . --check` | PASS |
| `experiments/*/run.sh`, `*/measure.sh`, `experiments/buildcost.sh`, `bash experiments/deps/setup.sh run` | The results in `docs/beef-sharing-experiments.md` (Q1-Q8), `architecture.md` §5 (tree-links) |

## Feature status

| Area | State |
|------|-------|
| Phase 0 tooling: `tools/` (test-leaks, win-test, test-codegen, test-lib, sync with `--check` and the AGENTS region), `FormatCore.Testing`, `bench-kit/`, `docs/agents-common.md` | Done in FormatCore; no sibling synced yet |
| Phase 1 primitives (`architecture.md` §2, §4, §5) | Done |
| Phase 2 cursors (§3), measured in `experiments/cursor-fold` | Done |
| Phase 3 numbers (§6); bug 2 fixed in `DecimalParse` | Done |
| Phase 4 typed mapping (§8); bugs 1 and 4 fixed in the framework | Done: framework, toy format, fixtures, registry workspace |
| Phase 5 document infrastructure (§5); bug 3 fixed in `ByteHash`/`OrderedMap` | Done except a generic `Compact` |
| Phase 6 encodings (§7) and testing helpers (§9) | Done except the items below |
| Phase 7 TomlBeef on the window cursor | Done for streams (TomlBeef `TomlWindowCursor`, 20-68% fewer instructions); memory input keeps TOML's span cursor after `ByteCursor`'s checks (the window measured 2-8% more there) |
| Sibling migrations (plan §5, `docs/migration.md`) | KdlBeef done (2026-10-03, its `e769dfc`..`57401fe`; equal or fewer instructions per byte in every mode; B1, B4 fixed). TomlBeef done (its `498f5dc`..`09041ef`; document -1% to -25%, streams -18% to -68%, write equal; B1, B2, B3 fixed; `migration.md` §9 "TomlBeef"). JsonBeef done (its `8a406f7`..`1ae6268`; every column equal or lower but canada's and floats' reads, at most +0.4%; write up to -7.4%; B1 (converters and subclasses) and B4 fixed; `migration.md` §9 "JsonBeef"). XmlBeef done (its `7d1086e`..final; every cell of events, document, stream and stream4k equal or lower than d1ee13e, streams -1.4% to -3.4%, typed osm -2.8%, book-utf16 13.15 through a 4 KiB stream; B1, B4, B5 fixed; `migration.md` §9 "XmlBeef"). All four siblings are on FormatCore (v0.1.2). After merging the branches, the KdlBeef write column had gained 0.2 instructions per byte from JsonBeef's inlined `ShortestDouble.Append`: `Append` is out of line again and `AppendInline` is the entry for a constant layout on a hot path (JsonBeef's writer); KdlBeef, TomlBeef and JsonBeef re-measured equal to their migration figures; and `PlainUtf8Text.IsPlainBlock` tests four words at once (XmlBeef's default block test had cost TomlBeef 0.1 per byte) |

## Bugs found in the siblings (fixed in FormatCore; each sibling gets the fix when it migrates)

| ID | Sibling | Bug | FormatCore |
|----|---------|-----|------------|
| B1 | all four generators | Converter/subtype lookups use `AlwaysVisible`: silently empty with a second dependent of the format library | `MappingDriver` + `Registry` (mixin stage); `tests/registry`. **Fixed in KdlBeef** (`aa49e58`, fixture `OkRegisteredConverter`, which the old generator fails), **TomlBeef** (its `1a2d9ff`, the same fixture), **XmlBeef** (`15a7b01`, the same fixture with the second project `Other`; the old generator fails it with 'does not support fields of type') and **JsonBeef** (`5ed8436`, fixtures `OkRegisteredConverter` and `OkPolymorphic`: the old generator lost the user's converters and subclasses) |
| B2 | TomlBeef `TomlParser.Values.bf:898` | Slow-path float parse follows the current culture's decimal separator (confirmed on Linux with a `,` culture) | `DecimalParse.ParseDouble`; `ParseDouble_IgnoresTheCurrentCulture`. **Fixed in TomlBeef** (its `0e09716`, `FloatsIgnoreTheCurrentCulture`) |
| B3 | TomlBeef `TomlEntryMap.bf:241` | Unseeded table hash (hash flooding) | `ByteHash` seeded per table, `OrderedMap`; `IndexTests`. **Fixed in TomlBeef** (its `86df468`, `TableIndexesAreSeededPerTable`) |
| B4 | KdlBeef, XmlBeef, JsonBeef generators | `IntegerRange` minimum for uint64 is `int64.MinValue` | `IntegerBounds`; `IntegerBounds_UInt64StartsAtZero`. **Fixed in KdlBeef** (`aa49e58`), **JsonBeef** (`5ed8436`) and **XmlBeef** (`15a7b01`) |
| B5 | XmlBeef `XmlNameTable` hash | 4-7 byte keys OR two overlapping words (`<< 24`): keys differing in their first and last bytes collide under every seed (found in phase 5) | `ByteHash` (`<< 32`); `ByteHash_UsesEveryByte`. **Fixed in XmlBeef** (`bbf26bc`, its name table hashes through `ByteHash`; `NameTable_HashUsesEveryByte`) |
| B6 | all four (allocator path of typed reads) | corlib's `BumpAllocator(DestructorHandlingKind)` constructor ignores its argument; under `.Allow` an object read through the allocator deletes bump-owned Strings (`free(): invalid pointer`). Not yet checked in the siblings | noted; the toy format sets `DestructorHandling` after construction |

## Open items

| ID | Item | Size |
|----|------|------|
| X | XmlBeef follow-ups: `ErrorPolicy` (XML's recovery progress rule differs), `RangeTable` (its ItemRange's capacity field is not in XmlNodeRecord), `InternTable` (XML state per name entry), the shared `Planner` (`migration.md` §9 "XmlBeef") | M |
| J | JsonBeef follow-ups: canada's and floats' reads stay +0.03-0.16 instructions per byte over 7959c3f (shared number paths, layout); `KeptSource` and `Marks` unused there (`migration.md` §9 "JsonBeef") | S |
| T | TomlBeef follow-ups: `ShortestDouble.Append` for the canonical float (20% more than corlib's text on float writes, inside the zmij call: find out why); the shared `Planner`/`ValueSpec` for its generator (nesting and `T?`, its O9); the window cursor for memory input (2-8% more, spread over the parser) | M |
| K | KdlBeef follow-ups that need FormatCore: `RangeTable`/`SideTable` adoption, the shared `Planner` for its generator, `bench/compare/run.sh` on the vendored `measure.sh`/`merge.sh` (its `status.md` item F) | M |
| C | Generic `Compact` (GrowList records + `Tree.LiveOrder` + `SideTable.Remap` + a text-move hook) for KdlBeef/JsonBeef | M |
| T | Phase 6 tooling rest: `svgplot.py`, fetch/build helpers, round-trip driver; `-bench-loop` in TomlTester before it adopts `instructions.sh` (KdlTester has it) | M |
| P4 | Typed mapping rest: polymorphic dispatch in the toy format, a shared ShowGenerated helper | S-M |
| Q | Open questions for the author (`plan.md` §9). Decided by default in this pass: Q5 tolerance ±10% (AGENTS.md's rule), Q6 int64 offsets in error carriers and int32 in `RangeRecord`, Q7 JsonBeef's UTF-8 wording (KDL/XML/TOML goldens change when they migrate), Q8 shared `Tree` over accessors (measured equal), Q10 enum case names follow the declaring level's naming | — |
