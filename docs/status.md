# FormatCore status

Last reviewed: 2026-10-03.

## Verification baseline

| Check | Expected result |
|-------|-----------------|
| `beefbuild -test` (Debug checks) | 1/1 pass (smoke test) |
| `beefbuild -test -config=TestRelease` (Release settings) | 1/1 pass |
| `experiments/*/run.sh`, `experiments/hotloop/measure.sh`, `experiments/buildcost.sh`, `bash experiments/deps/setup.sh run` | The results in `docs/beef-sharing-experiments.md` (cross-project codegen identical to one project; comptime chain works; the `[OnCompile]` crash reproduces) |

## Feature status

| Area | State |
|------|-------|
| Workspace | Done |
| Research: three surveys of the siblings, cross-project experiments | Done (`docs/`, `experiments/`) |
| Everything else | Planned: `docs/plan.md` §6 |

## Open items

| ID | Item | Size |
|----|------|------|
| P0 | Phase 0: measurement and tooling (`plan.md` §6) | M |
| B | Sibling bugs found by the surveys (`plan.md` §2.3), to fix in each sibling | S each |
| Q | Open questions for the author (`plan.md` §9) | — |
