# FormatCore

The shared core of four [Beef](https://www.beeflang.org/) format libraries by the same author —
[TomlBeef](https://github.com/mdsitton/TomlBeef), KdlBeef, XmlBeef and JsonBeef: input cursors, UTF-8
and SWAR scanning, encodings, errors and diagnostics, arenas and node tables, numbers, the comptime
typed-mapping framework, and the test and benchmark tooling they currently each carry a copy of.

**Status: planning.** The plan and research are in `docs/`:

- [`docs/plan.md`](docs/plan.md) — what moves here, the design, the migration protocol, phases, open questions
- [`docs/survey-input.md`](docs/survey-input.md), [`docs/survey-data.md`](docs/survey-data.md),
  [`docs/survey-typed-and-tooling.md`](docs/survey-typed-and-tooling.md) — what the four libraries duplicate
- [`docs/beef-sharing-experiments.md`](docs/beef-sharing-experiments.md) — how Beef behaves across
  project boundaries, measured ([`experiments/`](experiments/))

## License

MIT (see `LICENSE`).
