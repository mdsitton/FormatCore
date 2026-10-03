# Migrating a sibling onto FormatCore

How each sibling replaces its copies with FormatCore's components. Every step follows plan.md §5:
in the sibling, one component at a time, its instruction counts before and after, its full
verification, a commit naming the FormatCore version. KdlBeef first, then TomlBeef; XmlBeef and
JsonBeef when their sessions are idle and the author agrees. Paths are relative to
`~/development`, at the commits the surveys read (plan.md §1).

## 0. Hooking FormatCore up

1. In the sibling's library `BeefProj.toml`: `corlib = "*"` and
   `FormatCore = {Git = "https://github.com/mdsitton/FormatCore.git", Version = "0.1"}`: **this exact
   URL string in all four** (locks and version pooling key on it). The SSH form
   (`git@github.com:mdsitton/FormatCore.git`) also resolves, but only for someone with a GitHub key;
   HTTPS works for every user of the public repository. Every workspace of the sibling lists
   `FormatCore = {Path = "../FormatCore"}` (relative to that workspace) in `[Projects]`, which
   overrides the Git spec for local work.
2. Files that use building blocks: `using FormatCore;` and `using internal FormatCore;`.
3. Vendor the scripts: `bash ../FormatCore/tools/sync.sh .` (writes `test-leaks.sh`, `win-test.sh`, and
   `test-codegen.sh` where `tests/codegen` exists); add `bash ../FormatCore/tools/sync.sh . --check`
   to the sibling's verification baseline in `docs/status.md`.

## 1. The text policy (first, everything else is generic over it)

Each sibling declares one struct implementing `ITextPolicy`, next to its char class:

| Sibling | ValidatesUpFront | Plain word / bans | Newlines |
|---|---|---|---|
| TomlBeef | true | `PlainUtf8Text` as is (TOML's control-character rules are grammar errors today; keep them there) | LF/CR/CRLF (`PlainUtf8Text`) |
| KdlBeef | true | ASCII 0x09-0x0D and 0x20-0x7E plain; bans 0x00-0x08, 0x0E-0x1F, DEL, bidi controls, U+FEFF (`KdlChar.IsDisallowed`, KdlChar.bf:324); `AppendBanned` keeps KdlChar's wording and the BOM message | KdlChar.NewlineLength (KdlChar.bf:163); `MayHoldNewline` = `BytesBelow0E | BytesEqual(0xC2) | BytesEqual(0xE2)`; `OnlyAsciiNewlines` false |
| XmlBeef | true | XmlChar's `IsPrintableAscii32`/`IsPlainAsciiWord` and `IsChar` (XmlChar.bf); `InvalidChar` maps to its `InvalidChar` kind | LF/CR/CRLF |
| JsonBeef | false (strings are checked in `ScanStringText`) | ASCII words | LF/CR/CRLF |

`src/FormatCore/tests/TestPolicies.bf` has a KDL-like and a JSON-like policy that the tests run.

## 2. Primitives (phase 1)

| FormatCore | Replaces |
|---|---|
| `Swar.*` | `XmlChar` (XmlChar.bf: Load64/32, BytesEqual, BytesBelowSpace, BytesBelow0E, CountHighBits, EqualBytes), `JsonChar` (JsonChar.bf: the same plus BytesAboveSpace, ZeroBytes, AllDigits, ParseEightDigits, NonSpaceBytes, FirstByte), KdlBeef's inline SWAR in `ScanQuotedText` (KdlReader.bf:85), TomlBeef's in `ScanTextRun` (TomlCursor.bf:262) |
| `Bytes16`, `Mask16` (+ `FirstSet`) | `JsonBytes16`, `JsonMask16`, `JsonChar.FirstStringStop16`'s readback (JsonChar.bf:6-48, :206) |
| `Utf8.SequenceLength/Decode/Encode/StartsWithBom/CountCodePoints/CompleteSequencesEnd/ValidSequenceLength/MaximalSubpartLength/FindNoncharacter` | the four char classes' copies (`Utf8SequenceLength`, `Decode`, `EncodeUtf8`, …) |
| `Utf8.FindInvalid<TText>` | `KdlChar.FindInvalid` (KdlChar.bf:335), `XmlChar.FindInvalid` (XmlChar.bf:282), `JsonChar.FindInvalid` (JsonChar.bf:434), TomlBeef's `ValidateUtf8`/`IsValidUtf8`/`LocateUtf8Error` (TomlChar.bf:201-260). **Changes messages and the continuation-byte offset for KDL, XML and TOML** (JsonBeef's wording and lead-byte offset): regenerate the KDL (95) and XML (951) goldens and TOML's position tests (`Utf8_InvalidContinuationByteReportsContinuationPosition`) in the same step, reviewing the diff |
| `Utf8.LineAndColumn<TText>` | `KdlChar.LineAndColumn` (KdlChar.bf:513; a split CRLF is now counted at the LF, XML/JSON's rule), `XmlChar.LineAndColumn`, `JsonChar.LineAndColumn` |
| `Hex.DigitValue/Digits4/Append/AppendCodePointName/AppendCharDescription` | `HexDigitValue` ×4, `JsonChar.Hex4`, `AppendHex`/`AppendCodePointName` ×2-3, `JsonChar.AppendCharDescription` |
| `InputStart.DetectWideEncoding/Check` | `JsonChar.DetectWideEncoding`, `JsonInputStart` (JsonCursor.bf:144); new for TOML and KDL (a UTF-16 file now reports "The input is UTF-16LE (TOML must be UTF-8)" instead of invalid UTF-8 at offset 0) |
| `ParseError<TKind>` via `public typealias XParseError = FormatCore.ParseError<XErrorKind>;` | `TomlParseError` (TomlError.bf:63), `KdlParseError` (KdlError.bf:73), `XmlParseError` (XmlError.bf:96), `JsonParseError` (JsonError.bf:75). `mOffset` becomes int64 for TOML/KDL/XML; JSON's `PrependPath(token, escape)` becomes the caller escaping `"/" + token` (JsonPointer.AppendToken) and passing the segment |
| `Diagnostic<TKind>` via typealias | `XmlDiagnostic`, `JsonDiagnostic` (KDL and TOML gain one) |
| `ErrorPolicy`, `Limits` | the `AfterError` skeletons (KdlReader.bf:396, XmlReaderCore.bf:345, JsonReaderCore.bf:1763) and recovery anchors; the inline `limit > 0 && value > limit` checks |
| `LineIndex<TText>` | `XmlDocument.mLineStarts`/`LocateInSource` (XmlDocument.bf:173, :735), `JsonDocument.LocateInSource` (JsonDocument.Positions.bf:69) |
| `GrowList<T>` | `XmlStack<T>`, `JsonStack<T>`; candidates in KdlBeef (its `List<>` tables) and TomlBeef, measured |
| `BitStack` | JsonReaderCore's `mBits` (JsonReaderCore.bf:76, :845-884) |
| `DecodeBuffer` | `JsonDecodeBuffer`; a candidate speedup for KDL, XML and TOML string decoding, measured |
| `TextArena`, `KeptSource` | `XmlTextArena`, `JsonTextArena`; XmlBeef's `Own` (XmlDocument.bf:813), JsonBeef's `TextRef` (JsonDocument.bf:589) |

## 3. Cursors (phase 2)

| FormatCore | Replaces |
|---|---|
| `IInputCursor` | `IKdlCursor`, `IXmlCursor`, `IJsonCursor`. `LocatesOnlyForward` becomes `!IsWhole`; `TryGetInputError` returns `InputError`, which the core maps to its kind (one switch) and copies into its own error |
| `ByteCursor<TText>` | `KdlByteCursor`, `JsonByteCursor` (XmlBeef's transcodes: it moves with the encodings module) |
| `BufferedStreamCursor<TText>` + `InputState` | `KdlBufferedStreamCursor` + `KdlStreamState`, `JsonBufferedStreamCursor` + `JsonStreamState`. Message change for KDL: "A token is longer than MaxTokenBytes (n)" (was "A token or entry is …"). KDL's minimum stream buffer becomes 16 bytes (was 4); the window still ends at `from + MaxTokenBytes`, so limits below 16 behave as before (`F5_TokenLimitsBelowFour`) |
| `LineCounter<TText>` | `KdlLineCounter` (KdlCursor.bf:42; KDL gains the word-at-a-time counter), `XmlLineCounter` (XmlCursor.bf:48), `JsonLineCounter` (JsonCursor.bf:47) |
| `InputSettings` | the cursor fields read from each read config (MaxInputBytes, MaxTokenBytes, StreamBufferBytes, AllowBom → `mBom`) |
| `Window.Rebase` | the three `Rebase(ref StringView, …)` copies (the reader's `RebaseViews` list stays) |
| `Scan.Until<TStops>` / `Until16` | candidate replacements for the stop scans, one call site at a time under `instructions.sh` (survey-input.md §2.2 risks) |

What stays in each sibling: the reader cores and their `Avail`/`Grow`/`RebaseViews`, push input
(`JsonPushCursor`), XmlBeef's transcoding stream cursor (until the encodings module lands), grammar
scanners, error kinds and every message not produced by shared code.

The proof for each step is the sibling's own: instruction counts (events, document, stream columns)
equal or better, its full verification, and its stream-versus-memory tests
(`KdlStreamTests`, `XmlStreamTests`, the JSON fuzz stream sweep).

## 4. Numbers (phase 3)

| FormatCore | Replaces |
|---|---|
| `DecimalParse.TryClinger`, `ParseDouble`, `ParseFloat32`, `TryParseInt64/UInt64`, `ClassifyInteger` | JsonBeef `JsonNumber.bf` (`TryClinger`, `TryParsePlainDouble`/`ParseDoubleSlow`, `ParseFloat`, `TryParseInt64/UInt64`, integer `Classify`) |
| `DecimalParse.TryParsePlain(.LeadingZerosAndPlus)`, `ParseDouble`, `TryParseRadix` | KdlBeef `KdlReader.Values.bf:244` `TryParsePlainNumber`, `:209` underscore stripping + `double.Parse`, the radix loops `:149-205` |
| `DecimalParse.TryParsePlain(.PlusSign)`, `ParseDouble` | TomlBeef `TomlParser.Values.bf:556/:586`, `ParseFloatToken` `:884-898` (**fixes B2**) |
| `ShortestDouble` (`.JsonPlain`, `.EcmaScript`, `.KdlCanonical`, `.TomlCanonical`, `FloatLayout.Scientific`) | JsonBeef `AppendDouble`/`AppendFloat`/`AppendLayout`; KdlBeef `KdlCanonical.bf:410`; TomlBeef `TomlWriter.bf:205`, `TomlWriter.Formats.bf:204` + `ReformatExponent` |
| `IntegerText`, `AppendGrouped` | TomlBeef `TomlWriter.Formats.bf:11`, `EmitGroupedDigits*` (`:375/:395/:501`) |
| `BigDecimal.AppendRadixAsDecimal`, `AppendExact` | KdlBeef `KdlCanonical.bf:322`; JsonBeef `AppendHexAsDecimal`, `JsonPatch.bf:590` |

Differences: `ParseDouble` returns false where JsonBeef called FatalError; `AppendExact` normalizes
trailing zeros into the power; non-finite values and TOML's `-0.0` stay with the format.

## 5. Typed mapping (phase 4)

| FormatCore.Mapping | Replaces (survey-typed-and-tooling.md A5) |
|---|---|
| `NamingPolicy`, `Naming.Apply` | `ApplyNaming` T:238, K:547, X:781, J:436 and the four naming enums (breaking for the attributes; KDL keeps its kebab default in its attribute) |
| `Literal`, `IntegerBounds` (**fixes B4**) | `AppendLiteral` T:271, K:578, X:162, J:1029; `IntegerRange` T:292, K:599, X:183, J:1053 |
| `Registry.FindConverter`, `Registry.SubTypes` through `MappingDriver` (**fixes B1**) | `FindRegisteredConverter` T:202, K:474, X:700, J:415; `ChildTypes`/`SubTypes` K:494, X:720, J:330 |
| `TypeShapes`, `Ownership`, `EnumEmit`, `CodeWriter` | `ListElement`/`DictionaryValue`/`DictionaryKey`/`KeyKind` ×4; T:426, K:796, X:407, J:693-757; J's `Emitter` (CodeGen:37) |
| `Planner<TFormat>`, `ClaimSet`, `IMappingFormat` | J's `PlanType`/`PlanField`/`Spec`/`Classify` (Plan:89/176/262); claim bookkeeping in K:275 and X:327 |

Each format keeps its attributes, roles, emit templates and runtime bind library. TOML, KDL and XML
move to body-time planning (no type-init emission) and JsonBeef's inheritance model; enum case names
follow the declaring level's naming (TOML wrote them as declared, KDL and XML used the enum type's
naming: their goldens may change).

## 6. Document infrastructure (phase 5)

| FormatCore | Replaces |
|---|---|
| `ReadShell` | KdlBeef `KdlDocument.bf:319`, XmlBeef `XmlDocument.bf:481/494`, JsonBeef `JsonDocument.bf:338-370` |
| `SideTable<T>` | KdlBeef `KdlDocument.Mutation.bf:113-139`, XmlBeef `XmlDocument.Mutation.bf:282-308` |
| `RangeTable<TItem>` | KdlBeef `AppendEntry`/`RemoveEntry` (`:144/:177`), XmlBeef `AppendAttribute`/`RemoveAttributeAt` (`:313/:335`) |
| `OrderedMap` (**fixes B3**) | TomlBeef `TomlEntryMap.bf` |
| `OpenIdIndex` | JsonBeef `JsonMemberIndex.bf` |
| `InternTable` (**fixes B5**) | XmlBeef `XmlNameTable.bf` (keeps a wrapper for QNames and `XmlNameId`) |
| `Tree`, `PreorderWalk` | KdlBeef `KdlDocument.bf:490`, `KdlDocument.Mutation.bf:24-104`; XmlBeef `XmlDocument.bf:848`, `XmlDocument.Mutation.bf:15-42/:169/:200`; JsonBeef `JsonDocument.bf:638/:653`, `JsonDocument.Mutation.bf:79-115` |
| `Marks` | XmlBeef `XmlDocument.Style.bf:201/210`, JsonBeef `JsonDocument.Style.bf:339` |

## 7. Encodings (phase 6, XmlBeef)

`XmlEncoding.bf`, `XmlEncodingTables.bf`, `XmlEncoder.bf` and its `tools/gen-encoding-tables.py` go
whole (typealiases keep the public names); from `XmlEncodingDetector.bf`, `XmlDecoder` (:421-635),
`Classify` (:366), `Prepare`/`CheckDeclarationLength`/`DecodeError`/`IsValidUtf8` (:191-266) and the
BOM/UTF-7/EBCDIC checks of `Detect` (:60-102); `XmlBufferedStreamCursor`/`XmlStreamState` and
`XmlByteCursor` become `TranscodingStreamCursor<XmlText, XmlDetector>` and
`TranscodingByteCursor<XmlText, XmlDetector>`. XML keeps an `XmlDetector : IEncodingDetector`
(declaration sniffing, conflicts, `<?xm` patterns) and its unencodable write policies. Message changes:
`windows-1252` lowercase in fallback messages, "A token is longer than MaxTokenBytes", and its error
kind mapping gains `InvalidEncoding`.

## 8. Tooling

`bash ../FormatCore/tools/sync.sh .` vendors `test-leaks.sh`, `win-test.sh`, `tools/test-lib.sh`,
`test-codegen.sh` (with `tests/codegen`) and the bench-kit files (with `bench/compare`), and writes
`docs/agents-common.md` into AGENTS.md between `<!-- FormatCore:agents-common begin -->` and `end`
(add the markers once, replacing the repo's copy of the shared rules; TomlBeef also fixes its stale
Windows line and drops the load refusal in `update-tomlbeef.sh`). Testers depend on
`FormatCore.Testing` and delete their `Measure`, `PrintResult`, `ReadInputs`, `ReadStdin`, fuzz
mutators and agreement code; `bench/instructions.conf` replaces each `instructions.sh` (TomlTester and
KdlTester first need `-bench-loop`).

## 9. KdlBeef: done (2026-10-03), and what it taught

KdlBeef moved in eight commits (`e769dfc`..`57401fe`): tooling and `-bench-loop`; the dependency,
`KdlText` and the UTF-8/hex helpers; `KdlParseError`/`KdlDiagnostic` typealiases; the cursors and line
counter; numbers and `ErrorPolicy`; `GrowList`, `TextArena`, `ReadShell`; `Tree`; the `[KdlObject]`
generator on `MappingDriver` with 14 build fixtures. Instructions per byte against 84f2bc2: events
-0.3% to -7%, document -1.6% to -7.8%, stream -3% to -34%, write equal (KdlBeef's `docs/status.md` has
the table). Its 79 tests, the spec suite in four modes, the round trips, leaks and Windows pass; no
golden changed. Skipped, recorded in its status: `RangeTable`/`SideTable` (its node record keeps
inline entry-range fields), the shared `Planner` (the generator keeps its own role planning and uses
FormatCore's driver, registry and helpers), `Limits.Exceeds` on hot counters.

Lessons for TomlBeef, XmlBeef and JsonBeef:

- **Measure every step, and expect ±1% from code layout.** Moving a component can change what LLVM
  inlines elsewhere with no change in the code itself. Each fix KdlBeef needed was found by
  comparing per-function `perf record -e instructions:u` profiles of the old and new Release builds
  (a scratch `git worktree` of the previous commit, with the workspace's FormatCore path made
  absolute, builds the old binary):
  - FormatCore's cursor and the 69-byte `ParseError` are larger than the siblings' (KDL's was 56 and
    49 bytes): declared before the reader core's hot fields they cost up to 1% (document reads).
    **Declare `mCursor` and `mError` last** in the core class.
  - FormatCore's number fast path made KDL's `ParseNumber` small enough for LLVM to inline it into
    `ReadValueToken`, which then stopped being inlined into `ReadValue`: stream reads +2-4%. An
    `[Inline]` on `ReadValueToken` (one caller) restored it.
  - **`Limits.Exceeds(max, ++count)` increments with no limit set** (its argument is evaluated before
    the call): +1% on a per-entry counter. Keep `max > 0 && ++count > max` for counters; `Exceeds` is
    for values without side effects.
  - The 69-byte error in `Result<Event, ParseError>` from `Next()` per event was suspected and ruled
    out (an empty-failure path measured no better).
- **`GrowList` now keeps a raw allocation** (an array object's header cost the writer 0.2%):
  `GrowList<T>` for node tables is a free win over corlib `List<T>` (document reads -0.2% to -1%).
- **`TextArena` beat the pool-recycling `BumpAllocator`** for document text: -1% to -3.4% on document
  reads. TomlBeef's store also holds objects with destructors (tables, arrays): only its text
  (`TomlTextArena`, comment text) is a direct candidate.
- **The line counter is the big stream win**: KDL counted per code point; FormatCore's SWAR counter
  made streams 9-34% cheaper. TomlBeef's stream cursor counts columns per byte today: expect the same.
- **UTF-8 messages**: KDL's goldens pinned no UTF-8 wording, so `FindInvalid`'s JSON wording changed
  nothing there. XmlBeef's 951 and TomlBeef's position tests may pin it: regenerate and review.
- **Typed mapping on the driver without the planner works** and fixes bug 1: emit signatures plus
  `MappingDriver.EmitEntry` in `ApplyToType`, make every body `MappingDriver.AppendBody`, filter
  `Type.TypeDeclarations` with `Registry.IsVisible` in the body stage. Two traps: a body that itself
  mixes in another library method (`Compiler.Mixin(Lib.Dispatch(...))`) is a new evaluation whose
  entry is the library: generate that code inline in the body instead; and per-type data that ApplyToType
  used to emit as a sized static array (`sKdlClaimed`) needs the registry too: emit
  `static T[] sX = X_() ~ delete _;` with `X_`'s body mixed in. The old generator fails
  KdlBeef's `OkRegisteredConverter` fixture (a converter in the user's project, a second project
  depending on the library); add that fixture to each sibling as its bug-1 regression.
- `box` is a reserved word in Beef (a fixture named a local `box` and failed to parse).

### TomlBeef: done (2026-10-03)

TomlBeef moved in ten commits (`498f5dc`..; its `docs/status.md` has the instruction-count table):
tooling and `-bench-loop`; the dependency and B2 (`DecimalParse.ParseDouble`); B3 (`TomlEntryMap` is
`OrderedMap<TomlTableSlot, const 8>`); UTF-8/hex helpers; `TomlParseError`/`TomlDiagnostic` typealiases
with the parser on an empty failure token; numbers; `TextArena` and `ReadShell`; `[TomlObject]` on
`MappingDriver` (B1; 10 build fixtures); streams on the window cursor (plan phase 7). Against `cd799f0`:
document -1% to -25% (arrays 179 → 134), preserve -2% to -12%, stream and stream1k -18% to -68%
(comments 30.7 → 9.9), write equal. Its 327 tests, the four suite scripts in Debug and Release, the
official toml-test suite, leaks and Windows pass.

Lessons for XmlBeef and JsonBeef:

- **Beef converts any struct to an empty struct implicitly.** An empty failure token
  (`struct TomlFailure {}`) made `.Err(TomlParseError(...))` compile and drop the error silently (the
  wrong error came out later: the kind of one, the message of another). Give the token a field (a
  `uint8`), so a missing `Raise` is a compile error. XmlBeef's and JsonBeef's `XmlFailure`/`JsonFailure`
  are empty structs today: check that nothing converts into them by accident.
- **TOML's full-error Results were the cost, not the error's size alone**: switching to the larger
  `ParseError` made document reads 4-13% slower until the parser failed with an empty token; then they
  were 6-25% faster than before the move.
- **`OrderedMap` needed `OpenIdIndex.RebuildDistinct`** (no key compares when rebuilding an index of
  distinct keys): without it, many small tables crossing the scan limit cost 2%.
- **Integer fast path first**: `DecimalParse.TryParsePlainInteger` before `TryParsePlain` (integers are
  the common bare value; the combined parse cost arrays/ints 1-2%).
- **`ShortestDouble.Append` cost 20% more than corlib's `ToString` on float-heavy writes**, with the
  extra instructions inside the zmij call itself (unexplained; same values, same output). TomlBeef keeps
  corlib's text for its canonical float. Measure it before JsonBeef or KdlBeef adopt it on a writer.
- **The window cursor over `ByteCursor` measured 2-8% more on TOML's document reads**, spread over the
  parser (no single function); TOML's memory input keeps its own span cursor after `ByteCursor.Begin`'s
  checks, and only streams read through the window (where it was 20-68% cheaper). For a sibling whose
  core already reads a window (KDL, XML, JSON) this does not apply.
- **Windows Debug**: two `scope $"..."` strings inside one `&&` in a loop failed a test there only;
  build such strings once per round.
- Column counts called per statement are short: count fewer than 32 bytes inline, longer spans with
  `Utf8.CountCodePoints` (a call per short column cost more than the old byte loop).

### JsonBeef: done (2026-10-03)

JsonBeef moved in eleven commits (`8a406f7`..the docs commit, against 7959c3f): tooling (vendored
scripts, bench-kit: `instructions.conf` with the typed and query columns through
`instructions_command`, `run.sh` on `measure.sh`'s `settle` and `merge.sh`'s `saved_table_cell`,
`c/bench.h` on `bench-core.h`); `JsonText` and the SWAR/UTF-8/hex helpers; the `JsonParseError` and
`JsonDiagnostic` typealiases; the cursors (`JsonPushCursor` implements `IInputCursor`); `GrowList`,
`TextArena`, `DecodeBuffer`; `BitStack`; `ReadShell` and `LineIndex`; `OpenIdIndex`; `Tree`; numbers;
the `[JsonObject]` generator on `FormatCore.Mapping` with 18 fixtures. Every column of
`bench/instructions.sh` (events, document, stream, write, typed, query, 16 inputs) is equal or lower
except canada's and floats' reads, +0.03 to +0.16 (at most 0.4%); write is up to 7.4% lower, a lookup in
a 2,000-member object 355 → 211 instructions. 281/281 tests, the suite in all modes, the fxx and RFC
8785 corpora, fuzz, round trips, leaks and Windows pass; no golden changed (one unit test's I/O
wording did: "Cannot read the file").

FormatCore changes it needed (branch `migrate-json`):
- `InputSettings.mUtf8Rule`: JsonBeef's goldens pin "(JSON must be UTF-8, RFC 8259 §8.1)".
- `BitStack.Set`/`Get` by level: the reader keeps its own depth (push input restores it).
- `ReadShell.ReadFileText` (a whole file into a `String`, the serializer's read).
- `Tree.AppendFresh(nodes, parent, child, ref childRecord)`: `LinkLastFresh`'s extra parent store cost
  JsonBeef's fast build 1-5% (its builders set the parent while filling the record).
- `DecimalParse`: a `separators` flag on `ParseDouble`/`ParseDoubleSlow`/`ParseFloat32`/
  `TryParseInt64`/`TryParseUInt64`/`ClassifyInteger` (inline dispatch: false is JsonBeef's plain loop,
  no underscore scan, no stack buffer: the buffer in the same function cost canada's read 2.5%), and the
  integer overflow check at the 20th digit only (it divided per digit).
- `ShortestDouble.Append` inlined, with the digits out of line (`Digits`) and the EcmaScript/Scientific
  layout inlined into the caller (`AppendDigits`), no `Append('0', 0)` calls: a caller with a constant
  layout gets the layout's tests folded. Out of line, the general layout cost JsonBeef's write 2.5%;
  inlined it beats JsonBeef's own layout code (floats 35.71 → 33.08).
- `ValueSpec.mEnumNumbers` (EnumsAsNumbers), so the generator uses the shared `ValueSpec` and
  `Ownership`.

Lessons for XmlBeef and TomlBeef (and anyone moving hot code):
- **Measure every call layer on a hot path, both ways.** The same shared function inlined or out of
  line moved canada's numbers ±1-2.5% in different directions per caller: the fast build wanted the slow
  float path inlined, the reader wanted it out of line (JsonBeef keeps an eight-line out-of-line corlib
  call for its reader, documented). Profiles at this precision (perf at 20k-instruction periods)
  attributed ±10% to the same function between runs: decide by `instructions.sh` counts only.
- **Pass constants to inlined shared code** (`ShortestDouble.Append(output, v, .JsonPlain)` per branch,
  not a runtime-chosen layout), the rule of beef-sharing-experiments.md Q1.
- **Bodies through the driver, and nothing mixed in from the library inside a body**: JsonBeef's
  discriminator dispatch was a nested `Compiler.Mixin(JsonSerializerCodeGen.TypeDispatch(...))`, which
  kept subclass lookups relative to JsonBeef (bug 1 for subtypes: `OkPolymorphic` fails with the old
  generator). Write such code inline in the body.
- **The generator's ShowGenerated property** goes through the entry too (a part number), or its
  planning would run with the library current.
- **Beef's parser stumbles on `>>` and `>>>` inside a skipped `#if` region**, comments included: a
  fixture file needs typealiases for nested generics and no such text in comments.
- `KeptSource` fits a document that stores views; one storing offsets (JsonBeef) has nothing to gain.
  `Marks` needs a `SideTable`, which grows with default records: style records with sentinel defaults
  (JsonBeef's -1s) keep their own ten-line mark loop.

### XmlBeef: done (2026-10-03)

XmlBeef moved in eleven commits from d1ee13e: tooling (vendored scripts, bench-kit with
`bench/instructions.conf`, the AGENTS region; `measure.sh`'s tolerance went from XmlBeef's ±5% to
±10%); the dependency, `XmlText` and the UTF-8/SWAR/hex helpers and validator (14 not-wf goldens
changed wording only: the encoded-surrogate and beyond-U+10FFFF messages now name the bytes, same
positions); `XmlParseError`/`XmlDiagnostic` typealiases; the encodings and cursors (`XmlEncoding`,
`XmlEncodingFallback`, `XmlEncodingConverter` typealiases, `XmlDetector : IEncodingDetector`, the
cursors as inlined adapters over the transcoding cursors, `XmlDecoder`/`XmlEncoder`/the tables and
their generator deleted); `XmlStack`/`XmlTextArena`/the line index; the name table's hash through
`ByteHash` (B5); the `[XmlObject]` generator on the driver (B1, B4; `XmlNaming` is `NamingPolicy`);
typed doubles through `DecimalParse`; `ReadShell` and `KeptSource`; `Tree`; `SideTable` and
`Marks.MarkChanged`; docs. Instructions per byte against d1ee13e: every cell of events, document,
stream and stream4k equal or lower (streams -1.4% to -3.4%, osm stream 36.02 → 35.13), typed osm
76.90 → 74.75, book-utf16 13.21 → 13.15 through a 4 KiB stream. 257 tests (one new: B5), the
conformance suite in seven modes, the SVG corpus, round trips with mutation, collect-errors fuzzing,
21 build fixtures (two new: `OkRegisteredConverter` with a second dependent project `Other`, which the
old generator fails, and `OkSelfReference`), leaks and Windows pass.

FormatCore changes this migration needed (all measured in XmlBeef):
- `ITextPolicy.IsPlainBlock` (a static member with a default body: existing policies are unchanged):
  FindInvalid's 32-byte step asks the policy. Four early-out IsPlainWord tests on text with newlines
  cost XmlBeef's SVG event passes 3% over its own combined test (all ASCII, then all ≥ 0x20, the
  controls only when one is below). Static interface members with default bodies work in Beef and
  specialize like the others.
- FindInvalid checks well-formed 2- and 3-byte sequences from one 32-bit load first.
- `Utf8.Encode(String)` writes each length in its own branch (sizing first, then branching again in the
  pointer version cost character references 0.3%).
- `[Inline]` on both transcoding cursors' constructors: XmlBeef's svg-icons input is thousands of small
  files, and an out-of-line constructor of the larger cursor cost its reads 0.8-1.3%.
- `LineIndex.Release`; `SideTable`'s indexer and `IsEmpty` (the document's many reads by index stay).

Not adopted (XmlBeef's status.md, item FC): `ErrorPolicy` (XML's recovery progress rule compares resume
points, and its MaxErrors test counts the coming error: invariants test-collect.sh guards),
`RangeTable` (its ranges carry a capacity XmlNodeRecord has no field for), `InternTable` (XML state per
entry, QName splits and predefined names, on the start-tag path; the hash and seed are FormatCore's),
the shared `Planner`.

Lessons:
- **Per-document setup counts on small-file inputs.** Anything a cursor constructs per read (settings,
  detection, the cursor struct copied into the core) shows on an input of many small documents only:
  keep constructors and the core's `Reset` inlined so the cursor is built in place.
- **A format's adapter over a FormatCore cursor costs nothing** when every member is `[Inline]`: XmlBeef
  kept `IXmlCursor` (XML errors, the encoding and BOM-override report) as thin structs over the
  transcoding cursors, and its reader core did not change.
- **Planning must move to the body stage, not just the bodies**: XmlBeef's ScanChain and PlanField
  reached the converter registry through Classify, so its claimed names and virtual claim properties
  became mixin parts too (static arrays from a field initializer whose method body is mixed in, as in
  KdlBeef).
- Error kinds: `InputErrorKind.InvalidEncoding` (decoding) and `InvalidUtf8` both map to XML's
  `InvalidEncoding`; `ByteOrderMark` cannot occur (XML skips the BOM).
