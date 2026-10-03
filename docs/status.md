# FormatCore status

Last reviewed: 2026-10-03.

## Verification baseline

| Check | Expected result |
|-------|-----------------|
| `beefbuild -test` (Debug checks) | 27/27 pass |
| `beefbuild -test -config=TestRelease` (Release settings) | 27/27 pass |
| `bash ./test-leaks.sh` | PASS: no leaks detected |
| `bash ./win-test.sh` (Test and TestRelease under Proton) | 27/27 pass in both |
| `bash tools/sync.sh . --check` | PASS: the root's vendored scripts match `tools/` |
| `experiments/*/run.sh`, `experiments/hotloop/measure.sh`, `experiments/buildcost.sh`, `bash experiments/deps/setup.sh run` | The results in `docs/beef-sharing-experiments.md` |

## Feature status

| Area | State |
|------|-------|
| Research: surveys, cross-project experiments | Done (`docs/`, `experiments/`) |
| Phase 0 tooling: `tools/test-leaks.sh`, `win-test.sh`, `test-codegen.sh`, `sync.sh` (+ `--check`) | Done in FormatCore; siblings not synced yet (their `sync.sh --check` fails until they are) |
| Phase 1 primitives: `Swar`, `Bytes16`, `Utf8`, `Hex`, `ITextPolicy`, `ParseError<TKind>`, `Diagnostic<TKind>`, `ErrorPolicy`, `Limits`, `LineIndex`, `RangeRecord`, `TextArena`, `KeptSource`, `GrowList`, `BitStack`, `DecodeBuffer` | Done (`architecture.md` §2-5) |
| Phase 2 cursors: `IInputCursor`, `ByteCursor<TText>`, `BufferedStreamCursor<TText>`, `LineCounter<TText>`, `InputStart`, `Scan.Until<TStops>` | Done |
| Everything else | Planned: `docs/plan.md` §6 |

## Open items

| ID | Item | Size |
|----|------|------|
| P0 | Phase 0 rest: `FormatCore.Testing` (`Measure`), bench-kit, shared AGENTS block; syncing the siblings | M |
| M | Sibling migrations (plan §5), one sibling and one component at a time, with the author's go-ahead | — |
| B | Sibling bugs (`plan.md` §2.3): fixed in FormatCore's components as they land; fixed in each sibling when it migrates (or earlier, if the author asks) | S each |
| Q | Open questions for the author (`plan.md` §9); Q7 (UTF-8 wording) now decided by default for JSON's wording, `architecture.md` §2 | — |
