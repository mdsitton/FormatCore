# Migrating a sibling onto FormatCore

How each sibling replaces its copies with FormatCore's components. Every step follows plan.md §5:
in the sibling, one component at a time, its instruction counts before and after, its full
verification, a commit naming the FormatCore version. KdlBeef first, then TomlBeef; XmlBeef and
JsonBeef when their sessions are idle and the author agrees. Paths are relative to
`~/development`, at the commits the surveys read (plan.md §1).

## 0. Hooking FormatCore up

1. In the sibling's library `BeefProj.toml`: `FormatCore = {Git = "<one URL, the same in all four>",
   Version = "x.y"}` once FormatCore has a remote (plan.md §9 Q2); until then, and for local
   development always, list `FormatCore = {Path = "../FormatCore"}` in the sibling's
   `BeefSpace.toml` `[Projects]` and `FormatCore = "*"` in the library's dependencies.
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
