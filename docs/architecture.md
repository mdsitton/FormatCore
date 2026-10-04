# FormatCore architecture

The shared core of TomlBeef, KdlBeef, XmlBeef and JsonBeef. `docs/plan.md` says what moves here and in
which order; this file records the design as built. Each section names the sibling code it replaces.

## 1. Packaging and visibility

- One library project, `FormatCore` (`src/FormatCore/`), namespace `FormatCore` for the runtime
  building blocks (one namespace, not the plan's sub-namespaces: a sibling then needs one
  `using FormatCore;` and one `using internal FormatCore;`, and the type names are distinctive
  enough on their own). Folders group the sources: `Text/`, `Input/`, `Diagnostics/`, `Storage/`.
- Other projects: `FormatCore.Testing` (`Testing/`, public test and benchmark helpers), and for the
  typed-mapping tests `ToyFormat` (`tests/toy`) and `ToyTests` (`tests/mapping`); the comptime
  framework is namespace `FormatCore.Mapping` (its names appear in emitted code, fully qualified).
- Building blocks are `internal` (siblings write `using internal FormatCore;`); that is a "not
  supported API" marker, not a wall (`beef-sharing-experiments.md` Q2). The types a sibling exposes
  under its own name through `typealias` are `public`: `ParseError<TKind>`, `Diagnostic<TKind>`.
- Every file that touches FormatCore internals has `using internal FormatCore;`, FormatCore's own
  included.
- Scripts live in `tools/` and are vendored into each repository by `tools/sync.sh` (with a header
  naming the source); `tools/sync.sh <repo> --check` fails on a copy that drifted. FormatCore vendors
  them into itself the same way (`test-leaks.sh`, `win-test.sh` at the root are copies).

## 2. Text: SWAR, UTF-8, policies (`Text/`)

- `Swar` (XmlChar ∪ JsonChar primitives), `Bytes16`/`Mask16` (JsonBeef's SSE2 lanes, with
  `Mask16.FirstSet`), `Hex` (digit values from a comptime table, `Digits4`, `AppendCodePointName`,
  `AppendCharDescription`), `Utf8` (sequence length, decode, encode to a pointer or a `String` in one
  buffer call, table 3-7 `ValidSequenceLength`, `MaximalSubpartLength`, `CompleteSequencesEnd`,
  `CountCodePoints`, `FindNoncharacter`, the naive `LineAndColumn<TText>`).
- **`ITextPolicy`** is a format's character rules as static interface members on a struct passed as
  a generic argument: whether input is validated up front (`ValidatesUpFront`: TOML, KDL, XML yes;
  JSON no, it checks strings while scanning), which plain words need no check, which ASCII bytes and
  code points are banned and how the ban is worded, the newline set (`NewlineLength`,
  `MayHoldNewline`, `OnlyAsciiNewlines`). `PlainUtf8Text` is the no-bans, LF/CR/CRLF policy (TOML's
  rules). The tests carry KDL-like and JSON-like policies; the real ones live in the siblings.
- **`Utf8.FindInvalid<TText>`** is JsonBeef's validator (table 3-7, errors at the lead byte with the
  length of the offending bytes, messages that name the bytes) with XmlBeef's 32-byte plain-word step
  and the policy's bans. KdlBeef and XmlBeef report a bad continuation byte at the continuation
  byte and in shorter words today; adopting this validator changes their golden messages (plan §9 Q7:
  the author decides, and the goldens are regenerated in that sibling's migration step).
- `Scan.Until<TStops>` / `Until16<TStops>` over `IStopSet` / `IStopSet16`: the scan takes the window as
  locals and returns a position; the refill loop stays in each reader core.

## 3. Input (`Input/`)

- `IInputCursor` is the window protocol of the three window cursors: `Begin`, `Fill(keep, pos,
  count)`, `TryGetInputError`, `HasInputError`, `Locate`, `IsWhole` (JsonBeef's; KDL and XML's
  `LocatesOnlyForward` is `!IsWhole`), `TakeStarved` (push input; `[Inline]` false elsewhere).
- Cursors report `InputError` (kind `InputErrorKind`, message in a per-thread buffer, line, column,
  64-bit offset, length); each format maps the kind to its own and builds its own error.
- `InputSettings` carries the cursor-level limits (MaxInputBytes, MaxTokenBytes, StreamBufferBytes),
  the BOM policy (skip one, or reject), whether UTF-16/32 input is reported as such (JsonBeef's
  detection, now available to TOML and KDL), and the format's name for that message.
- `ByteCursor<TText>`: memory; `Fill` is `[Inline] false`, so a reader's `Grow` folds away.
- `BufferedStreamCursor<TText>` is KdlBeef's and JsonBeef's stream cursor merged: validates each
  refill up to `CompleteSequencesEnd` when the policy validates up front (KDL, XML, TOML), else
  delivers every byte (JSON); grows the buffer for a long construct; MaxTokenBytes is a hard limit on
  the construct plus the reader's lookahead (`pos + count - min(keep, pos)`); never drops just after a
  CR; JsonBeef's two line counters (dropped bytes, forward locating).
- `LineCounter<TText>` is XmlBeef's SWAR counter, generic over the newline set: 16-byte skips while
  `MayHoldNewline` is zero, then a whole word's LF/CR at once when only ASCII newlines exist, else a
  byte at a time (KDL's NEL, LS, PS). Columns are counted on request from a moving base. An offset on
  the LF of a CRLF is on the line the CRLF ends (XmlBeef and JsonBeef's rule; KdlBeef counts a split
  CRLF at its CR: its migration adopts this rule).
- `InputStart`: wide-encoding detection (BOMs and RFC 4627 zero patterns) and the BOM check.
- `Window.Rebase` moves a view of the old window to the new one (three identical copies).

## 4. Diagnostics (`Diagnostics/`)

- `ParseError<TKind>` is the carrier of all four (kind, message, source, path, int32 line and column,
  **int64 offset**, int32 length; per-thread buffers per specialization, so formats do not overwrite
  each other's text; `At<TText>`, `SetSource`, `PrependPath` with the segment as given, `Detach`,
  `ToString` as `source:line:column: path: message`). Siblings keep their names:
  `public typealias KdlParseError = FormatCore.ParseError<KdlErrorKind>;`. `Diagnostic<TKind>` is the
  owning copy (XmlDiagnostic/JsonDiagnostic).
- `ErrorPolicy`: collect or stop, MaxErrors, and the recovery anchor that always moves forward.
  `Limits.Exceeds` and `Limits.AppendExceeded` ("X exceeds MaxY (n)").
- `LineIndex<TText>`: line starts of a kept source built on first request (XmlBeef/JsonBeef);
  `RangeRecord`: a stored range with line 0 = none, -1 = located on request.

## 5. Storage (`Storage/`)

- `GrowList<T>` (XmlStack ∪ JsonStack), `BitStack` (JsonBeef's nesting bits, beyond 64 levels in an
  array), `DecodeBuffer` (JsonDecodeBuffer), `TextArena` (XmlTextArena: chunks kept across `Reset`;
  an empty copy has a non-null pointer, TomlTextArena's contract), `KeptSource` (a document's copy of
  its input: views into it are kept, anything else is copied).
- Document infrastructure (phase 5, `Storage/`, `Document/`):
  - `ReadShell`: `ReadFileBytes`/`ReadStreamBytes` (the whole input within MaxInputBytes; a larger
    file fails from its size before reading, a growing one at the limit) and `ReadFileInto` (straight
    into a `TextArena`, JsonBeef's single copy). Failures are `InputError`s; the format maps the kind,
    names the source and clears its document.
  - `SideTable<T>` (per-item records beside an item table, in use when not empty, growing with
    defaults; `Copy`/`ClearAt`/`RemoveAt` follow item moves; `Remap` for compaction) and
    `RangeTable<TItem>` + `ItemRange` (KDL entries, XML attributes: appends grow in place when the
    range has room or ends the table, else the range moves to the end with doubled room; side tables
    follow through an `IItemMoves` struct).
  - `ByteHash`: word-at-a-time, overlapping loads, never past the end, **seeded per table**
    (`NewSeed`: time, an address, an atomic counter, splitmix64). Unlike XmlNameTable's, 4-7 byte keys
    put their two words side by side (`<< 32`): XmlNameTable's overlapping, ORed byte makes keys that
    differ in their first and last bytes equal under every seed (found here; XmlBeef's fix comes with
    its migration). `OpenIdIndex` (slots `hash << 32 | id`, at most half full, linear probe, keys read
    through `IKeySource` only on a hash match), `OrderedMap<TSlot, TLimit>` (TomlEntryMap: a scan up to
    `TLimit` entries, then a seeded index), `InternTable` (XmlNameTable without QNames: stable text,
    nonzero IDs, a recent-string cache, predefined strings surviving `Clear`).
  - `Tree<TRecord, TZeroIsNode>` over `ITreeRecord` (`[Inline]` accessors on each format's own record;
    `SetLastChildAndCount` so JsonBeef's packed record stores once; `LinkLastFresh` for zeroed new
    nodes): links, unlink, subtree removal, `IsSelfOrAncestor`, `NextPreorder`, `LiveOrder`;
    `PreorderWalk` gives enter and leave steps without recursion. `experiments/tree-links`: the same
    instructions per node as code on the fields in Release (5-link and packed records, builds and
    walks), +1.3% for the 5-link build without LTO. `Marks<TRecord, TStyle, TZeroIsNode>.MarkUp`:
    dirty bits with "changed below" propagated to the first marked ancestor.

## 6. Numbers (`Numbers/`)

- `DecimalParse`: `TryClinger` (JsonBeef's, exponents past 22 while the scaled mantissa stays exact),
  `TryParsePlain(token, PlainRules)` (TomlBeef's and KdlBeef's one-pass integer/float parse; leading
  zeros and `+` as rules that fold when inlined), `ParseDouble`/`ParseFloat32` (correctly rounded
  through corlib's parser via `[Friend]` with `.` pinned: **culture-independent**, TomlBeef's bug 2;
  underscores stripped on the stack; binary32 parsed directly), `TryParseInt64`/`TryParseUInt64`,
  `ClassifyInteger`, `TryParseRadix`. Grammar checks and messages stay in the readers; `ParseDouble`
  returns false for rejected text (JsonBeef's called FatalError).
- `FloatBits`; `ShortestDouble` (shortest round-trip digits laid out by `FloatLayout`: `Native`,
  `EcmaScript` and `Scientific` notations, the `.0` rule, exponent case, `+`, width; presets
  `JsonPlain`, `EcmaScript`, `KdlCanonical`, `TomlCanonical`, `Scientific(...)`; non-finite values are
  the format's to write); `IntegerText` (`IntegerLayout`: base, case, prefix, minimum digits,
  grouping); `BigDecimal` (radix 2/8/10/16 digits as decimal; the exact value of a double).
- `tools/test-number-corpus.sh` runs JsonBeef's parse-number-fxx (1,414,285 lines) and RFC 8785
  (100,000 lines) corpora against them: 0 mismatches.

## 7. Encodings (`Encoding/`)

- `TextEncoding` (public, for a format's `typealias`; XmlEncoding's cases, `Name`, `IsWide`,
  `IsSingleByte`, `FromLabel`), `EncodingFallback`, the `EncodingConverter` delegate. Labels are
  WHATWG's, except that ISO-8859-1 and US-ASCII keep their IANA meanings.
- `Decoder` (XmlDecoder: chunked; UTF-16/32 copy ASCII four units per 8-byte load; a unit cut at a
  piece's end waits unless `final`) and `Encoder` (XmlEncoder: stops at the first character it cannot
  write; what then is the format's policy).
- `SingleByteTables`, generated by `tools/gen-encoding-tables.py` (WHATWG indexes pinned by SHA-256;
  regenerated identical to XmlBeef's). Only Decoder and Encoder touch it: a Release binary that does
  not transcode has none of its symbols (checked on `experiments/cursor-fold`).
- Detection is a static generic hook, `IEncodingDetector`; `Bom.Detect`/`BomDetector` cover BOMs,
  UTF-7, EBCDIC, unusual UCS-4 orders and RFC 4627 zero patterns. XML supplies its own detector (the
  declaration), which may report the prefix incomplete (it then doubles, up to MaxTokenBytes).
  `Bom.DetectFirstCharacter`/`FirstCharacterDetector` (0.1.3, for YamlBeef) are YAML 1.2.2 §5.2's
  table: only the first character must be ASCII, so a one-character UTF-16 document, or `a中`, is found
  (Detect's four-byte patterns need two ASCII characters).
- `Transcoding.Prepare` (memory), `TranscodingByteCursor` and `TranscodingStreamCursor` implement
  `IInputCursor` with offsets in the UTF-8 text; decoding errors are `InputErrorKind.InvalidEncoding`.

## 8. Typed mapping (`Mapping/`, namespace `FormatCore.Mapping`)

- `NamingPolicy` (public, the union of the four enums) and `Naming.Apply` (acronym-aware), usable at
  compile time and run time.
- `Planner<TFormat>` over `IMappingFormat` (static members): walks the mapped levels base-most first,
  plans only the fields each level declares (no inherited or System.Object fields), names them,
  builds a recursive `ValueSpec` (List, Dictionary with String/integer/enum keys, Nullable,
  converters on the innermost value, format scalars, simple enums, objects), lets the format assign
  roles (`MemberPlan.mRole`, `mIndex`, `mTag`) and claim names through `ClaimSet` with its overlap
  rule, and stops the build through `MappingError` with self-contained `[Prefix] Owner.field: …`
  messages.
- Kit: `Literal`, `IntegerBounds` (**uint64's minimum is 0**: bug 4), `CodeWriter`, `EnumEmit` (case
  names follow the naming of the level that declares the field, JsonBeef's rule), `Ownership`.
- `MappingDriver`: `ApplyToType` emits signatures and a `[Comptime]` entry method into the user's
  type; every body is `Compiler.Mixin(<entry>(part))`. `Registry` lookups (converters, subtypes) run
  there, so "current" is the user's project: they see it and its dependencies, whatever else depends
  on the format library (**bug 1**; `tests/registry` proves it with three dependents, and shows the
  old in-`ApplyToType` lookup missing the user's converter in the same build). Planning at body time
  also removes the siblings' self-referencing-type crash class. Open generic types get stub bodies
  (their comptime methods cannot be evaluated); each specialization gets real code. Inheritance: one
  virtual method covers the chain, `override` below the base (JsonBeef's model). Build errors point at
  the generated entry in the user's type.
- Tests: the toy format (`tests/toy`, `tests/mapping`), 13 build-failure fixtures (`tests/codegen`,
  `test-codegen.sh`), the registry workspace (`tests/registry/run.sh`).

## 9. Testing and tooling (`Testing/`, `tools/`, `bench-kit/`)

- `FormatCore.Testing` (a project testers and harnesses depend on, never a library): `Bench.Measure`
  (`MeasureRule.Default`: 1 s warm-up; converged at `minSamples` with 60% within ±10% of the median;
  capped at 10 s or 1000 samples; the six copies' rule), `Inputs`, `ChunkStream`, `TextMutator`,
  `AgreementCheck`.
- `bench-kit/`: `merge.sh`, `measure.sh` (process repeats until runs agree within ±10%, `~` for cells
  that never settle: plan §9 Q5 decided by AGENTS.md's rule), `instructions.sh` (driven by a repo's
  `bench/instructions.conf`), `bench-core.h`, `maxrss.c`.
- `tools/vendored.txt` lists every vendored file with its condition; `tools/sync.sh` writes the copies
  with a header and `docs/agents-common.md` into the marked region of AGENTS.md; `--check` belongs in
  every repo's verification. `tools/test-lib.sh` is the suite-runner skeleton.
- One `beefbuild -test` runs every test project: the workspace's test configs select the others
  (`ConfigSelections`).
