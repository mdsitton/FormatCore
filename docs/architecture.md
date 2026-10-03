# FormatCore architecture

The shared core of TomlBeef, KdlBeef, XmlBeef and JsonBeef. `docs/plan.md` says what moves here and in
which order; this file records the design as built. Each section names the sibling code it replaces.

## 1. Packaging and visibility

- One library project, `FormatCore` (`src/FormatCore/`), namespace `FormatCore` for the runtime
  building blocks (one namespace, not the plan's sub-namespaces: a sibling then needs one
  `using FormatCore;` and one `using internal FormatCore;`, and the type names are distinctive
  enough on their own). Folders group the sources: `Text/`, `Input/`, `Diagnostics/`, `Storage/`.
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
