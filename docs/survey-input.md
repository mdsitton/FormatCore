# Survey: the input and diagnostics layer

What the four siblings do to get bytes in, check them, locate them and report errors about them, and
what FormatCore should take over. Read at TomlBeef `cd799f0`, KdlBeef `84f2bc2`, XmlBeef `d1ee13e`,
JsonBeef `7959c3f` (TomlBeef's stale `.kilo/worktrees/` copies are ignored). Numbers are covered by
another survey; this one covers them only where they touch the cursor.

## 0. Findings in brief

- **Two cursor generations.** TomlBeef has the first one: a peek/advance cursor (`ITomlCursor`) with
  nested marks and a spill string. KdlBeef reshaped it into a **window** (`data[offset]` for
  `windowStart <= offset < end`, absolute offsets, `Begin`/`Fill`/`Locate`), and XmlBeef and JsonBeef
  copied that design and improved it. The three window cursors are the same code with renamed
  identifiers, apart from about six deliberate changes (§1.2). JsonBeef has the newest version,
  XmlBeef's adds transcoding, and KdlBeef's has the oldest line counter.
- **Pieces that are already byte-identical after renaming:** the stream-state class
  (Kdl/Xml/Json), `Fill`'s retention and MaxTokenBytes logic, `SetWindow`, `SetError`,
  `CompleteSequencesEnd`, the SWAR primitives (`ZeroBytes`, `BytesEqual`, `BytesBelowSpace`,
  `BytesBelow0E`, `CountHighBits`, `Load64/32`, `EqualBytes`), `CountCodePoints`, `NewlineLength`
  (LF/CR/CRLF), `XmlLineCounter`≡`JsonLineCounter`, the per-thread error carrier (four copies),
  `*SourceRange` (four), `XmlDiagnostic`≡`JsonDiagnostic`, `XmlStack`≈`JsonStack`,
  `HexDigitValue`/`Utf8SequenceLength`/`Decode`/`EncodeUtf8`/`AppendHex`/`AppendCodePointName`.
  Roughly 1,500 duplicated lines across the four repositories belong to this layer.
- **Format-specific parts:** the character policy (which code points are banned: KDL bidi and U+FEFF,
  XML non-`Char`, nothing extra for JSON or TOML), the newline set (KDL adds VT, FF, NEL, LS and PS),
  stop-byte sets, XML's declaration sniffing and entity frames, JSON's push cursor and its in-string
  UTF-8 check, TOML's mark/spill API, error-kind enums, and each format's recovery rules.
- **The biggest performance risk** is a shared `Grow` that no longer folds to `return false` for
  in-memory input. KdlBeef measured a 25% loss when it did not fold. Keep `Fill` as an inlined `false`
  on a generic struct cursor, and keep every hook generic (static interface methods or const generics),
  never virtual, on any path an `Avail` reaches.

## 1. Cursors

### 1.1 Implementations

| Repo | Type (file:line) | Lines | Distinguishing features |
|---|---|---|---|
| Toml | `ITomlCursor` (TomlCursor.bf:6), `TomlByteCursor` (:50) | 319 | Peek/advance API (`PeekByte`, `AdvanceByte` (CRLF as a unit), `Advance` (decodes UTF-8), `SkipWhitespace`, `ScanRun(stopMask, appendTo, maxAppend)`), nested `Mark`/`Slice`/`ReleaseMark`. Lines are tracked eagerly; the **column is computed on demand** (line start plus a one-entry cache, byte loop). `ScanRun` dispatches on a runtime `stopMask` to the SWAR `ScanTextRun` (:262) or to a table loop |
| Toml | `TomlBufferedStreamCursor` (TomlBufferedStreamCursor.bf:39), `TomlStreamState` (:7) | 535 | Fixed buffer (default 8 KiB, minimum 16) plus a **spill String** that holds `[mRetainStart, mBaseOffset)` while marks are held (`CompactForRefill` :359). Columns are counted per byte. `ValidateUtf8Bytes` (:445) is a per-byte state machine with line and column tracking. MaxTokenBytes is checked against the retained span (`CheckRetainedBytes`). Errors are flags on the state; the driver orders them afterwards (`TryGetStreamError`, TomlDocument.bf:347). The BOM is handled by the driver with `ResetPosition` |
| Kdl | `IKdlCursor`, `KdlLineCounter`, `KdlByteCursor`, `KdlBufferedStreamCursor` (KdlCursor.bf:12/42/74/178) | 401 | The first window cursor: `Begin(ref data, ref windowStart, ref end)`, `Fill(..., keep, pos, count)`, `TryGetInputError`/`HasInputError`, `Locate`, `LocatesOnlyForward`. The buffer doubles when one construct fills it, capped by MaxTokenBytes (a hard limit: the window ends `from + MaxTokenBytes`). Validation covers complete sequences only. **Line counter counts per code point** with KDL's newline set |
| Xml | `IXmlCursor`, `XmlLineCounter`, `XmlByteCursor` (XmlCursor.bf:11/48/150) | 241 | Kdl's interface plus `Encoding` and `BomOverridesDeclaration`. **SWAR line counter**: two words at a time while no byte is below 0x0E, then every LF and lone CR in a word at once; columns only on request, from a base that moves forward |
| Xml | `XmlBufferedStreamCursor`, `XmlStreamState` (XmlStreamCursor.bf:52/11) | 463 | Raw buffer plus decoded window (`XmlDecoder`). Detection on the first 4 KB (more while the declaration is incomplete). The **whole input is read** for a converter or the Windows-1252 fallback. `CheckWhole` gives memory-identical first errors when everything arrives in the first read. The buffer grows when fewer than 4 bytes are free (room for a code point) |
| Xml | core window: `Avail`/`AvailN`/`Grow`/`RebaseViews`/`At`/`StartsWith`/`SkipSpace`/`DecodeAt` (XmlReaderCore.bf:674–806), `InputWindow` (:56) | ~130 | `Grow` returns false inside entity frames, and before the buffer moves it calls `ResolvePositions` (locates open elements forward). `XmlReaderCoreBase` (:16) is a non-generic base class that holds the state, so `XmlReader` reads either core's fields alike |
| Json | `IJsonCursor`, `JsonLineCounter`, `JsonInputStart`, `JsonByteCursor` (JsonCursor.bf:12/47/144/167) | 234 | Xml's interface with `LocatesOnlyForward` replaced by `IsWhole`, plus `TakeStarved` (push input). **No up-front validation**: UTF-8 is checked in the string scan. `Locate` also guards `target < mLines.mLineStart` (an extra check XmlBeef lacks) |
| Json | `JsonBufferedStreamCursor`, `JsonStreamState` (JsonStreamCursor.bf:39/11) | 267 | Kdl's stream cursor with Xml's line counter. `mCapacity` is kept beside `mBuffer.Count`. `Validate` only clips at an input error |
| Json | `JsonPushCursor`, `JsonPushState` (JsonPushReader.bf:109/9) | ~180 | The window is everything fed and not yet dropped. `Fill` marks itself starved instead of failing, and the core snapshots and restores the token (`NextTokenPush`) |
| Json | core window: `Retain`/`Avail`/`AvailN`/`Grow`/`RebaseViews` (JsonReaderCore.bf:1650–1710), `KeepFrom` (:245) | ~70 | Adds `mHold` to the keep offset (a value being skipped or retained). `Retain` folds away when the cursor `IsWhole` |
| Kdl | core window (KdlReader.bf:1256–1382) | ~130 | `PeekAt`, `NewlineAt` and `SpaceAt` grow up to 3 bytes so that multi-byte newlines and spaces never split. `RebaseViews` covers `KdlValue` as well as views |

Readers are made generic the same way in all four repositories. The cursor is a struct, the core is
`XxxReaderCore<TCursor> where TCursor : IXxxCursor` (Toml: `TomlParserImpl<TCursor>`,
TomlParser.bf:8), and the public reader holds one core per cursor type and dispatches on a flag.
Calls on the interface are never virtual.

### 1.2 Differences that matter

1. **Retention model.** TOML holds nested marks and spills; the window cursors hold one `keep`
   offset per `Fill` call (`min(mRetain, mPos, pos)`, plus JSON's `mHold`) and grow the buffer
   instead of spilling. The window model needs no copy for a span longer than the buffer, its views
   stay contiguous, and it is better tested: every suite runs through a 16-byte (XML, KDL, JSON) or
   1-byte (JSON) stream buffer. TOML's spill costs an extra copy per long token.
2. **MaxTokenBytes semantics.** TOML only bounds the span its marks retain (default 0, checked before
   a refill and at `Slice`). The window cursors make it a hard limit on the construct plus lookahead:
   the initial buffer is at most the limit (KDL keeps a minimum of 4, XML and JSON 16), and the window
   ends at `from + MaxTokenBytes`. The limit's default is 0 in TOML, KDL and JSON, and 10,000,000 in
   XML.
3. **Line counting.**
   - KdlBeef: one code point at a time (`KdlLineCounter.AdvanceTo`).
   - XmlBeef and JsonBeef: SWAR (`AdvanceLines`, about 16 bytes per step on text without line
     breaks), with columns on request (`CountCodePoints`, 8 bytes per step).
   - TomlBeef: eager lines and an on-demand column with a byte loop in memory, and per-byte columns in
     streams.

   XmlBeef's review P02 measured the stream path falling from 2–5× to 1.1–1.3× the in-memory
   instruction count after the SWAR counter and forward-only locating went in.
4. **The CRLF rule at a drop point.** The KDL, XML and JSON stream cursors never drop the buffer just
   after a CR. XML and JSON define "an offset on the LF of a CRLF is on the line the CRLF ends";
   KdlBeef's `LineAndColumn` counts a split CRLF once, at the CR. TOML does not drop at all (it spills).
5. **Validation placement.** TOML, KDL and XML validate before the reader sees any bytes (the whole
   memory input, or each refill up to `CompleteSequencesEnd`). JSON validates only inside strings,
   because only strings may hold non-ASCII bytes, and calls the up-front `FindInvalid` only for
   mutation-API text. JSON's choice made errors come in document order: twitter went from 17.5 to
   15.3 instructions per byte.
6. **Encodings.** Only XML transcodes. JSON's `JsonInputStart.Check` rejects UTF-16 and UTF-32 by
   their BOM or zero-byte pattern. TOML and KDL treat everything as UTF-8 (anything else fails as
   invalid UTF-8).
7. **First-error parity between memory and stream input.** KDL and XML validate the whole first
   buffer in `Begin` (and XML calls `CheckWhole` when the stream ended inside the prefix). JSON gets
   parity for free because it validates in document order. TOML reports stream-level errors after the
   parse, in a fixed order (size, I/O, UTF-8).
8. **Views after a refill.** Each core lists its own views in `RebaseViews`. That list is
   format-specific state, but `Rebase(ref StringView, low, high, oldData)` is identical in all
   three.

### 1.3 Recommended shared design

All of this lives in `namespace FormatCore` as internal types (the formats see them through
`using internal FormatCore;`, or make them public if the formats live in other assemblies; see the
open questions).

```bf
/// The reader's view of the input: data[offset] for Base <= offset < End, absolute offsets.
struct InputWindow { public char8* mData; public int mBase; public int mPos; public int mEnd; public int mRetain; }

/// What a cursor reports about the input itself (I/O, encoding, size), kept with its own message copy.
enum InputErrorKind : uint8 { IoError, InvalidUtf8, InvalidChar /* policy-banned code point */,
	InvalidEncoding, UnsupportedEncoding, ResourceLimitExceeded }

class InputState          // was Kdl/Xml/JsonStreamState: buffer, raw buffer, error kind/message/position
{ public List<uint8> mBuffer; public bool mHasError; public InputErrorKind mErrorKind; public String mErrorMessage; ... }

interface IInputCursor
{
	Result<int, InputFailure> Begin(ref char8* data, ref int windowStart, ref int end) mut;
	bool Fill(ref char8* data, ref int windowStart, ref int end, int keep, int pos, int count) mut;
	bool HasInputError { get; }
	bool TryGetInputError(out InputError error);          // kind + message view + position
	bool Locate(int offset, out int line, out int column) mut;
	bool IsWhole { get; }                                 // JSON's; XML/KDL's LocatesOnlyForward == !IsWhole
	bool TakeStarved() mut;                               // push input; [Inline] false elsewhere
}

struct ByteCursor<TText> : IInputCursor where TText : ITextPolicy            // memory
struct BufferedStreamCursor<TText> : IInputCursor where TText : ITextPolicy  // Stream, growing window
struct PushCursor<TText> : IInputCursor where TText : ITextPolicy            // JSON's, if KDL/XML want push input
struct TranscodingStreamCursor<TText> : IInputCursor ...                       // XML's, decoder in front (§3)

/// Per-format, compile-time: the validation and newline policy. Static interface members (corlib's
/// IParseable pattern), so every call specializes and inlines.
interface ITextPolicy
{
	static bool ValidateUpFront { get; }           // false for JSON (validates inside strings)
	static int FindInvalid(char8* text, int from, int to, String message, out InputErrorKind kind, out int length);
	static int NewlineLength(char8* text, int pos, int end);   // LF/CR/CRLF, or KDL's set
	static uint64 WordMayHoldNewline(uint64 word);              // SWAR guard for LineCounter
	static int MaxNewlineBytes { get; }                         // 1 (CRLF handled) or 3 (KDL's LS/PS)
}

struct LineCounter<TText> where TText : ITextPolicy   // XmlLineCounter generalized
```

- **The BOM** is handled in `Begin` with a policy option: `AllowBom` (JSON's setting), accept one, or
  reject a second one (TOML's `ControlCharInDocument`; KDL and XML let the validator or grammar
  reject it). Offsets stay raw everywhere and lines and columns restart at 1:1, as all four do today.
- **The window helpers stay in each core at first.** `Avail`, `AvailN`, `Grow` and `RebaseViews` are
  about 40 lines per format, and their hooks differ (XML's entity frames and `ResolvePositions`,
  JSON's `mHold` and `Retain` folding, KDL's 3-byte lookahead). Share only `InputWindow` and a static
  `[Inline] Window.Rebase(ref StringView, ...)`. A shared generic base `WindowCore<TCursor, THooks>`
  with struct hooks can come in phase 2 if instruction counts show no change.
- **TOML migration** goes through an adapter rather than a parser rewrite (about 350 call sites,
  mostly `AdvanceByte` and `PeekByte`): `TomlWindowCursor : ITomlCursor` wraps an `InputWindow` and
  one shared cursor. `Mark` sets `mRetain` at the outermost mark, and `Slice` returns a window view
  (no spill: the window grows). Columns come from `LineCounter` on request. TOML then gets SWAR
  stream validation, KDL/XML's MaxTokenBytes semantics (a behavior change: the limit then also
  bounds lookahead) and memory-equal errors without the post-parse ordering trick.

**Effort:** cursors and line counter M (3–4 days, mostly tests). Migrating KDL, XML and JSON is S each
(names only); TOML's adapter is M.

**Risks:**
- A policy that does not inline: a static interface method in a generic is specialized, but check
  that `[Inline]` survives through a constraint.
- `ByteCursor.Fill` must stay `[Inline] false`, so that `Grow` folds.
- Hoisting `IsWhole` and `TakeStarved` out of hot loops must still happen.
- Static fields of generic types are duplicated per specialization (`sTextStop` in
  `XmlReaderCore<TCursor>` already exists twice). Put tables in non-generic classes.
- Before and after each migration, run `bench/instructions.sh` (XML and JSON: events, document,
  stream and stream4k columns). KDL and TOML have no such script yet; port it first.

### 1.4 Tests

**Core:**
- One test `Stream` that returns n bytes per read (1–31, JSON's sweep), plus a failing stream.
- Equal windows and errors from memory and stream for random inputs.
- MaxTokenBytes at, below and above the buffer size, including limits below 4 (KDL F5,
  `F5_TokenLimitsBelowFour`) and a limit independent of the buffer (`R5_TokenLimitIndependentOfTheBuffer`).
- MaxInputBytes, I/O error mid-sequence, a CRLF across a refill, a BOM split across reads, retention
  with nested keeps.

**Sibling proofs after migration:**
- XML: `test-xml-conformance.sh` in all 7 modes, `test-collect.sh`, and `XmlStreamTests`
  (`Stream_SameAsMemory`, `Stream_PositionsCountedByWords`, `Stream_ErrorsSameAsMemory`).
- KDL: `test-kdl-spec.sh` in its 4 modes, and `KdlStreamTests`.
- JSON: `test-json-suite.sh` in 11 modes and the `test-json-fuzz.sh` stream sweep.
- TOML: `TomlStreamTests` (`Stream_*CrossesBufferBoundary`, `Utf8_Stream*`,
  `Stream_MaxTokenBytes*`) and `test-official-toml.sh`.

## 2. Character classification and scanning

### 2.1 Implementations

| Concern | Toml | Kdl | Xml | Json |
|---|---|---|---|---|
| Whole-buffer UTF-8 | `ValidateUtf8`, `IsValidUtf8`, `LocateUtf8Error` (TomlChar.bf:201/217/260). The fast pass skips 8 ASCII bytes and tracks no position; the slow pass re-scans with line and column | `FindInvalid` (KdlChar.bf:335): 8-byte `IsPlainAsciiWord` (exact; bans DEL), then KDL bans | `FindInvalid` (XmlChar.bf:282): **32-byte** `IsPrintableAscii32`, then 8-byte, then XML `Char` | `FindInvalid` (JsonChar.bf:434): 32/8-byte ASCII-only, **Unicode table 3-7** (second-byte ranges); messages name the bytes; `ValidSequenceLength` (:519) from one 32-bit load; `MaximalSubpartLength` (:587) for replacement |
| Incremental UTF-8 | per-byte state machine in the stream cursor | `CompleteSequencesEnd` + `FindInvalid` per refill | same as Kdl | in the string scan (`ScanStringText`, JsonReaderCore.bf:1241) |
| Error offset of a bad continuation byte | at the continuation byte (`i + j`) | `i + j` | `i + j` | at the lead byte, `length` = span |
| SWAR primitives | inline in `ScanTextRun` | inline in `ScanQuotedText` (:85) | `XmlChar` helpers (`BytesEqual`, `BytesBelowSpace`, `BytesBelow0E`, `ZeroBytes`, `CountHighBits`, `Load64`) | the same plus `BytesAboveSpace`, `StringStops`, `NonSpaceBytes`, `FirstByte`, `AllDigits`, `ParseEightDigits`, SSE2 `JsonBytes16`/`JsonMask16` (`FirstStringStop16`, :206) |
| Stop scans | `ScanRun(stopMask)`; SWAR for comment and string classes | `ScanQuoted` + `ScanQuotedText` (stops `"`, `\`, <0x0E, 0xC2, 0xE2) | `ScanText` (`<&]\r`), `ScanUntil(a, b)`, `ScanValue(quote)` (XmlReaderCore.Text.bf:25/53, .Tags.bf:194) | `ScanStringRun` (16-byte SSE2, then 8-byte, then bytes; :1208), `SkipIndentation` (:1540) |
| 256-entry tables | `sScanClass` (bit classes; TomlChar.bf:23) | `sIdentifierByte`, `sQuotedStop` | `sNameByte`, `sTextStop` | `sByteClass` (dispatch, :81), `sHexValues` |
| How tables are built | **every one** by a `Build*()` static initializer at run time (none is comptime or a literal), except generated literals: `XmlEncodingTables` (`tools/gen-encoding-tables.py`) and `JsonIdentifierTables` (`gen-json5-tables.py`) | | | |
| Newlines | LF, CRLF (a bare CR is rejected by the parser but counted by the locator) | CR, LF, CRLF, VT, FF, NEL, LS, PS (`NewlineLength`, :163) | LF, CR, CRLF | LF, CR, CRLF (JSON5 treats LS and PS as whitespace but does not count them as lines) |
| Columns | code points, on demand (byte loop) | code points, per code point | code points, SWAR `CountCodePoints` | same as Xml |
| `LineAndColumn(input, offset)` | inside `LocateUtf8Error` | KdlChar.bf:513 (a split CRLF counted at the CR) | XmlChar.bf:536 (an offset on the LF is after the CR) | JsonChar.bf:665 (same as Xml) |

Every scan resumes where it stopped after a refill (`p = Scan(p); if (p < mEnd || !Grow(p,1)) return
p;`), never from the construct's start. The exception is JSON push input, which re-reads a token
after a `Feed` and guards long strings with `mScanFrom`. The "8 readable bytes past the window"
slack in the plans (XmlBeef plan.md:188, JsonBeef plan.md:143) was **never implemented**: every
scan has a byte tail loop. Beef exposes no trailing-zero count, so JSON's `FirstByte` uses a multiply.

### 2.2 Recommended shared design

- **`FormatCore.Swar`** (static, all `[Inline]`) takes the union of the XmlChar and JsonChar
  primitives above. **`FormatCore.Bytes16`/`Mask16`** takes JSON's SSE2 types (the `[Intrinsic]`
  operators). Literal arguments (`Swar.BytesEqual(w, (uint8)'<')`) constant-fold once inlined, exactly
  as today.
- **`FormatCore.Utf8`:** `SequenceLength`, `Decode`, `Encode(char8*)` and `Encode(String)` (XML and
  JSON's one `PrepareBuffer` call), `ValidSequenceLength`, `MaximalSubpartLength`,
  `CompleteSequencesEnd`, `CountCodePoints`, `StartsWithBom`, `HexDigitValue`, `Hex4`, `AppendHex`,
  `AppendCodePointName`, `AppendCharDescription` (JSON's version; XML's `Unexpected` does the same
  inline).
- **`Utf8.FindInvalid<TText>(text, from, to, message, out kind, out length)`.** The ASCII block test
  and the extra code-point ban come from the policy:
  - JSON and TOML: ASCII-only words.
  - XML: no C0 controls except tab, LF and CR.
  - KDL: XML's rule plus DEL, then bidi controls and U+FEFF.

  Use JSON's table 3-7 core (exact, cheaper) and XML's 32-byte step. **Messages and the
  continuation-byte offset are the risk:** the goldens in KDL (95), XML (951) and JSON (211+) and
  TOML's position tests (`Utf8_InvalidContinuationByteReportsContinuationPosition`) pin them.
  Either let the policy choose the wording and offset convention, or unify on JSON's wording and
  regenerate goldens (`UPDATE_GOLDEN=1`, review the diff).
- **Stop sets as static policy structs:**

  ```bf
  interface IStopSet { static uint64 Word(uint64 w); static bool Byte(uint8 b); }
  static class Scan
  {
  	[Inline] public static int Until<TStops>(char8* data, int p, int end) where TStops : IStopSet;   // 8-byte words, then bytes
  	[Inline] public static int Until16<TStops>(...) where TStops : IStopSet16;                       // SSE2 variant
  }
  // XmlBeef:  struct TextStops : IStopSet { [Inline] public static uint64 Word(uint64 w) => Swar.BytesEqual(w, '<') | ...; [Inline] public static bool Byte(uint8 b) => XmlTables.sTextStop[b]; }
  ```

  The refill-resume loop stays in the core because it needs `Grow`. TOML's runtime `stopMask`
  dispatch inside `ScanRun` becomes one specialization per stop class.
- **`ByteTable`**: a tiny helper (or `[Comptime]` builder) so tables are const data instead of static
  initializers. This is optional: today's static initialization costs one pass at startup and an
  indirection.

**Effort:** S for Swar, Utf8 and Scan; M for the validator (golden churn).

**Risks:**
- Each scan loop is tuned per format: XML keeps the window end in a local, JSON stores to `mPos` only
  when it leaves the loop, and KDL measured 25% from storing per byte. A shared `Scan.Until` must take
  pointers and ends as locals and return a position, never touch `this`.
- Do not merge TOML's `ScanTextRun` (which computes `extra1`/`extra2` at run time) into a
  runtime-parameter version for the others: constant masks would be lost.
- 16-byte SIMD paid for JSON strings but not for whitespace. Keep both widths as separate entry
  points, chosen per call site.

**Tests:**
- TOML's `ScanRun_WordAtATimeMatchesByteLoop`, generalized: every predicate and every `IStopSet`,
  every byte value at every position in a word, against the byte loop.
- The validator exhaustively over all 1–3-byte sequences and a 4-byte sample, truncation at every
  cut, against a reference decoder.
- `CompleteSequencesEnd` at every cut.
- `LineCounter` against naive `LineAndColumn` on random LF/CR/CRLF (and KDL newline) mixes at every
  offset and word alignment, including an offset on a CRLF's LF (XmlBeef `Positions_CrlfAtTheOffset`,
  JsonBeef `E119_CrLfIsOneLineBreak`).

### 2.3 Not to share

- Grammar-specific classes: TOML bare-key and bare-value classes, KDL `IsIdentifierChar`,
  `UnicodeSpaceLength` and multi-line dedent, XML `IsNameStartChar`, `IsNameChar` and `IsPubidChar`,
  JSON `ByteClass` dispatch, the JSON5 identifier tables, and number grammar (`AllDigits` and
  `ParseEightDigits` can live in Swar, but their use is the number survey's).
- XML's attribute-value and text normalization (CR handling in `ScanText`).
- JSON's whitespace heuristics (`SkipOneSpace` and `SkipIndentation` were measured on JSON shapes).
- KDL's `NewlineAt` and `SpaceAt`, which need 3-byte lookahead.

## 3. Encodings

### 3.1 What exists

| Repo | Pieces | Notes |
|---|---|---|
| Xml | `XmlEncodingDetector.Detect` (XmlEncodingDetector.bf:64) | BOMs (UTF-32's before UTF-16's), UCS-4 2143/3412 and EBCDIC and UTF-7 rejected, Appendix F `<?xm` patterns, then the declaration's `encoding=` (`DeclaredEncoding` :297, `Classify` :366 with a label table), conflicts (a UTF-8 BOM wins over an 8-bit declaration; a wide/narrow mismatch is an error), `mIncomplete` (prefix grows up to MaxTokenBytes) |
| Xml | `Prepare` (:202) | Memory: detect, then call the converter or apply the fallback, then transcode all at once into a worst-case buffer |
| Xml | `XmlDecoder` (:421) | Chunked decode for UTF-8 (copy), ASCII (strict), Latin-1, the table encodings, and UTF-16/32 LE/BE (`DecodeWide` :515: four ASCII units per 8-byte load into one 4-byte store; surrogates checked; a cut unit waits unless `final`); `MaxExpansion` |
| Xml | `XmlEncodingTables` (531 lines, generated, WHATWG indexes pinned by SHA-256), `XmlEncoder` (134, the reverse for `WriteBytes`), `XmlEncoding` (enum and fallback, converter delegate) | ~15 KB of tables |
| Json | `JsonChar.DetectWideEncoding` (:399), `JsonInputStart.Check` | Rejects UTF-16 and UTF-32 by BOM or by RFC 4627 §3 zero patterns, as `UnsupportedEncoding` ("transcode it first") |
| Toml, Kdl | none | UTF-8 only by spec; UTF-16 input fails as invalid UTF-8 at offset 0 |
| StrikeCore | `ParsingTools.cs DetectEncoding` (C#, the StrikeCore package) | Ported into XML's detector. Its heuristic (no BOM and invalid UTF-8 means Latin-1) became the opt-in `EncodingFallback.Windows1252` |

### 3.2 Recommendation

- **Shared (`FormatCore.Encoding`):** `TextEncoding` (the enum without XML wording), `Decoder` (as
  `XmlDecoder`), `Encoder`, `SingleByteTables` (generated: move `tools/gen-encoding-tables.py` into
  FormatCore), `Bom.Detect(prefix)` covering UTF-8/16/32 BOMs, UTF-7, and the zero-byte patterns
  (JSON's four-byte test is the format-free form; XML's `<?xm` tests become an XML-side refinement),
  and `TranscodingStreamCursor` (XML's raw-buffer half: `ReadRaw`, `ReadMore`, `CheckWhole`,
  `ReadWhole`).
- **XML only:** declaration sniffing, `Classify`'s label table (it may move with the tables), the
  conflict rules, `mIncomplete` probing, and the converter delegate type (or make it generic:
  `delegate bool EncodingConverter(StringView name, Span<uint8> input, String output)`).
- **What the others gain:**
  - JSON: an opt-in `JsonReadConfig.Encodings = .Utf16And32` (RFC 7159/4627 readers accepted them;
    RFC 8259 and I-JSON forbid them). It would keep rejecting by default, so the suites' `i_`
    UTF-16 cases stay rejected unless the option is on. Errors would need UTF-8-offset wording as in
    XML.
  - TOML and KDL: nothing by spec. A better error ("the input is UTF-16LE: TOML must be UTF-8") from
    `Bom.Detect` costs four byte compares at `Begin`, and is worth having.
  - Writers: `Encoder` for JSON's opt-in `WriteBytes` in UTF-16 only if asked for.

**Effort:** M (moving it is mechanical; making the stream cursor format-free means the declaration
hook has to come out of `Begin`).

**Risk:** XML's `Begin` interleaves detection with reading (it grows the prefix while the
declaration is incomplete). Expose a hook `TDetect.Detect(prefix, ...) -> Detection` on the
transcoding cursor (static, generic), not a delegate. Make sure the tables are not linked into
TOML/KDL/JSON binaries: keep them in a type that only `Decoder` touches.

**Tests:**
- XML's `Encodings_Detected`, `Encodings_Conflicts`, `Utf16_AsciiRunsMeetOtherCharacters`,
  `Stream_Encodings` and `R04_LateEncodingDeclarations`, ported against the bare decoder: every table
  byte both ways (decode, then encode), surrogate pairs split at every chunk boundary.
- `book-utf16` in XML's `instructions.sh` (43 → 11 instructions per byte must hold).

## 4. Errors and diagnostics

### 4.1 Implementations

| Piece | Toml | Kdl | Xml | Json |
|---|---|---|---|---|
| Carrier | `TomlParseError` (TomlError.bf:63) | `KdlParseError` (KdlError.bf:73) | `XmlParseError` (XmlError.bf:96) | `JsonParseError` (JsonError.bf:75) |
| Fields | kind, message, source, int32 line/col/offset/length | same | same | same plus **`mPath`** (JSON Pointer for typed binding, `PrependPath`), **int64 offset** |
| Per-thread buffers (`LazyTLS<String>`, `Store` with self-alias guard) | message, source | same | same | plus path |
| `At(kind, msg, input, offset)` locating | — (`Located(range)`) | yes | yes | yes |
| `Detach()` | — | yes | yes | **no** |
| `ToString` | `source:line:column: message` | same | same | `source:line:column: path: message` |
| Owned copy | — | — | `XmlDiagnostic` (XmlDiagnostic.bf) | `JsonDiagnostic` (= Xml plus path) |
| Source range | `TomlSourceRange` (TomlMetadata.bf:100) | `KdlSourceRange` | `XmlSourceRange` | `JsonSourceRange` (JsonDocument.Positions.bf) |
| Internal failure token | none: the parser returns the full error in each `Result` | `KdlFailure` (empty) + `Fail`/`FailAt` (KdlReader.bf:1448) | `XmlFailure` + `Fail` (entity-aware) | `JsonFailure` + `Fail` (:1717) |
| Input error precedence | post-parse `TryGetStreamError` (size, I/O, UTF-8) | `mInputFailed`: `Fail` substitutes the cursor's error | same | same |
| Collect-errors | none | `AfterError`/`Recover` (KdlReader.bf:396) | `AfterError` (XmlReaderCore.bf:345), `XmlReaderCore.Recovery.bf` (320) | `AfterError`/`Recover` (:1763) |
| Document error list | — | `mErrors` with text copied into the store (KdlDocument.bf:374) | same (XmlDocument.bf:553) | same, into the arena (JsonDocument.bf:125) |
| Lazy line index for memory-input positions | — | — | `mLineStarts` (int32, XmlDocument.bf:173) | `LocateInSource`/`mLineStarts` (JsonDocument.Positions.bf:69) |

Error-kind enums (`uint8`) share about ten members by meaning but not by name: `InvalidUtf8` (XML
calls it `InvalidEncoding`), `UnexpectedChar`, `UnexpectedEof` (JSON: `UnexpectedEndOfInput`; TOML
has none), `UnterminatedString`, `InvalidEscape`, `ResourceLimitExceeded` (TOML also has
`MaxDepthExceeded`), `IoError`, `UnsupportedEncoding`, `MissingValue` (TOML: `MissingKey`),
`WrongType` (JSON: `TypeMismatch`), `InvalidValue`.

Collect-errors shares this skeleton:
- `fatal = inputFailed || state == Start || kind ∈ {ResourceLimitExceeded, IoError, encoding kinds}`.
- `MaxErrors` (default 100, 0 = none) is counted per error.
- A progress guarantee: KDL and XML move one byte past an error at the same offset as the last; JSON
  moves to `last + 1` for an error at or before the last.
- Recovery never makes an error (it would overwrite the per-thread message), so it only asks
  `HasInputError`.

The resynchronization rules themselves are entirely format-specific.

### 4.2 Recommended shared design

```bf
/// The error carrier: one generic struct, each format names its specialization.
public struct ParseError<TKind> where TKind : struct   // TKind: the format's uint8 enum
{
	static LazyTLS<String> sMessageBuffer, sSourceBuffer, sPathBuffer;   // per specialization, as today per format
	public TKind mKind; public StringView mMessage, mSource, mPath;
	public int32 mLine, mColumn, mLength; public int64 mOffset;
	public this(TKind kind, StringView message, int line, int column, int64 offset, int length = 1);
	public static Self At(TKind kind, StringView message, StringView input, int offset, int length = 1);  // via LineAndColumn
	public void SetSource(StringView source) mut; public void PrependPath(StringView token, bool escape) mut;
	public void Detach() mut; public override void ToString(String s);   // source:line:column: [path: ]message
}
public typealias KdlParseError = FormatCore.ParseError<KdlErrorKind>;   // in KdlBeef, so user code is unchanged
public class Diagnostic<TKind> { ... }      // XmlDiagnostic/JsonDiagnostic
public struct SourceRange { ... }           // the four identical structs
struct ErrorPolicy { int mCount, mLastOffset; int mMax; bool ShouldStop(bool fatal) mut; int ProgressAnchor(int offset) mut; }
class LineIndex { void Build(char8* text, int length, bool bom); void Locate(int offset, out int line, out int column); }  // Xml/Json mLineStarts
```

- Path escaping is pluggable: a static `TPath.AppendToken`, or the format escapes the token before
  calling `PrependPath`. JSON uses JSON Pointer; TOML would use dotted keys; KDL and XML could use a
  node path.
- **Cursors report `InputErrorKind`** and each format maps it to its own kind in one switch (`static
  TKind MapInputKind(InputErrorKind)` on the format's policy). This keeps the enums public and
  format-worded.
- `Fail`, `FailAt` and the `mInputFailed` substitution are ~25 lines per core. Share them as a static
  generic helper taking `ref ParseError<TKind>`, the cursor and the source name.
- **The TOML change first:** move TomlParserImpl to the empty-failure pattern (KDL measured that
  copying the full error on every return cost time). The carrier's growth (path, int64 offset) then
  costs nothing on the hot path. Until then, TOML's `Result<T, TomlParseError>` grows from 56 to
  about 72 bytes.

**Effort:**
- Carrier, Diagnostic and SourceRange: S (with typealiases, user-facing names do not change; the
  user may accept API breaks, at least for TOML, before 1.0).
- ErrorPolicy and LineIndex: S.
- TOML empty-failure refactor: M.

**Risks:**
- Generic statics: each specialization has its own per-thread buffers, which keeps today's isolation
  between formats.
- Check that `typealias` of a generic struct works with `Try!`, `case .Err(let e)` and doc comments,
  and how the debugger shows the type.
- `int64` offsets change field types in public structs (`mOffset` is `int32` in TOML, KDL and XML).

**Tests:**
- Port the carrier's `Store` aliasing case (a message rebuilt from a previous error's view).
- `ToString` with and without source, line and path.
- `Detach`, then the next error: the old text survives.
- `Diagnostic` round trip.
- `LineIndex` against `LineAndColumn` (BOM, CRLF at the offset).

**Sibling proofs:**
- Every suite's golden messages (the formatting is in them).
- `Read_ReportsLocatedErrors` (TOML), `Errors_AreLocated` (KDL), `Errors_Located` and
  `Errors_ColumnsCountCodePoints` (XML), `E118`/`E120` (JSON), `Collect_*` (JSON), `Recovery_*` (XML),
  `KdlCollectErrorsTests`.

## 5. Resource limits and read configs

| Setting | TomlReadConfig (TomlDocument.bf:30) | KdlReadConfig (KdlReadConfig.bf) | XmlReadConfig | JsonReadConfig |
|---|---|---|---|---|
| SourceName | yes | yes | yes | yes |
| MetadataMode (None/Positions/PreserveStyle) | yes | yes | yes | yes |
| CollectErrors / MaxErrors (100) | — | yes | yes | yes |
| MaxDepth (0 = unlimited) | 256, kind `MaxDepthExceeded` | 256 | 256 | 1024 (bit stack, no recursion) |
| MaxInputBytes | 0 | 0 | 0 (before transcoding) | 0 |
| MaxStringBytes | 0 (values only) | 0 (every string) | `MaxTextBytes` 10M | 0 |
| MaxNodes | 0 | 0 | 0 (elements) | 0 (document only) |
| Per container | MaxArrayItems, MaxTableEntries | MaxEntriesPerNode | MaxAttributesPerElement 4096 | MaxMembers (document) |
| Format-only | MaxPathSegments | — | MaxNameBytes, MaxNamespaceBindings, MaxEntity{Depth,ExpansionBytes,Amplification}, EntityAmplificationThreshold | MaxNumberLength, Dialect, AllowBom, Comments, … |
| StreamBufferBytes (minimum 16) | default 8 KiB | 64 KiB | 64 KiB | 64 KiB |
| MaxTokenBytes | 0, stream-only, retained span | 0, hard limit | 10M, hard limit | 0, hard limit (also push) |
| Presets | — | — | `Huge` | `Default`, `Jsonc`, `Json5`, `Strict`, `Untrusted` |

**Enforcement:**
- **TOML** keeps the limits in a `TomlResourceLimitState` class (TomlResourceLimitState.bf, 83
  lines) with `Check*` methods that build located errors, shared by the parser and the resolver.
- **KDL, XML and JSON** check `mConfig.X > 0 && ... > mConfig.X` inline at the site and `Fail` with
  a message that names the setting. The byte limits are checked as the decoded value grows (TOML
  `ScanRun(maxAppend)`, KDL's budgets, XML `P03_TextLimitWhileDecoding`).
- **The cursor-level limits are the same in all four:** MaxInputBytes (memory: before validation,
  located 1:1:0; stream: counted per read), MaxTokenBytes and StreamBufferBytes.

**Recommendation:**
- Share `InputSettings { int MaxInputBytes, MaxTokenBytes, StreamBufferBytes; BomPolicy Bom; }`, built
  by each format from its config. Cursors take this, never the format's config.
- Share the defaulting rule (`StreamBufferBytes` 0 → 64 KiB, minimum 16, clamped to MaxTokenBytes)
  as one function. Align TOML's default (8 KiB) or keep it as a parameter.
- Share a `LimitCheck` helper (`[Inline] static bool Exceeds(int limit, int value) => limit > 0 &&
  value > limit;`) and a message formatter: "X exceeds MaxY (n)". Do not share a limits class:
  depth, node and container semantics differ per format (TOML counts tree depth across headers, KDL
  frames, XML elements, JSON bits), and the config structs are public API with format-specific
  documentation.
- Do not merge the configs into one struct. A common embedded struct would change every user's field
  access (`config.MaxDepth`).

**Effort:** S. **Risk:** low. Keep the checks inline at their sites (they sit on per-token paths).

## 6. Small shared helpers

| Helper | Where | Recommendation |
|---|---|---|
| `XmlStack<T>` (XmlStack.bf, 121 lines), `JsonStack<T>` (JsonStack.bf, 123) | Inlined `Add`, `PopBack` and indexer (corlib `List.Add` is not inlined; it showed in profiles). JSON adds `Capacity` and `Ptr` and clamps capacity ≥ 1; XML adds `GrowUninitialized` | `FormatCore.ValueStack<T>`, the union of both. **KDL's `List<Frame>` and TOML's lists on hot paths are candidates** (measure) |
| JSON bit stack (`mBits`, JsonReaderCore.bf:76, :845–884) | 1 bit per level, object or array | `BitStack` (S); KDL and XML have no binary container kind and do not need it |
| `JsonDecodeBuffer` (70 lines) | Raw-pointer decode target with out-of-line `Grow` and 16-byte slack `CopyRun`: strings.json went from 22.2 to 14.3 instructions per byte | `DecodeBuffer`; KDL (escaped strings, multi-line dedent), XML (references, attribute normalization) and TOML (basic strings) all append to `String`, so this is a candidate speedup for each (measure) |
| `TomlKeyPathBuffer` (47) | Reused `List<String>` segments | TOML-only today; generic enough to share as `SegmentBuffer` if typed binding or paths in other formats want it. Low priority |
| `HexDigitValue` (4 identical copies), `Hex4` (JSON, table) | | `Utf8`/`Hex` in FormatCore |
| `EqualBytes` (Xml = Json) | Word compares, overlapping at the end | `Swar.EqualBytes` |
| `Rebase(ref StringView, ...)` (3 copies) | | `Window.Rebase` |
| Stream-state error parts (`MakeError`) | 3 identical copies | `InputState` (§1.3) |

## 7. What must not be shared

- The grammars' scanners and dispatch: token classes, names, identifiers, number grammars, string
  escape decoders (escape sets differ), multi-line string rules, XML attribute normalization and
  entity frames (`InputWindow` save and restore around replacement text), JSON's fast document build.
- Each core's `RebaseViews` list and its retention discipline (where `mRetain` and `mHold` are set);
  the reader's invariants depend on them.
- Recovery and resynchronization (KDL skips to the node's terminator, XML to the tag, phantoms and
  closes, JSON to a value or member). Only `ErrorPolicy` is shared.
- XML's declaration sniffing, its encoding-conflict rules and the converter's semantics; JSON's push
  snapshot and restore (`NextTokenPush`).
- Error-kind enums and every message text not produced by shared code.
- TOML's resolver-side limit semantics (`TomlResourceLimitState`).

## 8. Prioritized list (most duplicated × least risk first)

1. **`Swar` + `Utf8` primitives + `Hex` + `AppendHex`/`AppendCodePointName`.** Identical in 3–4
   copies; pure functions; inline; no golden impact. S.
2. **`ParseError<TKind>` + typealiases, `Diagnostic<TKind>`, `SourceRange`.** Four copies; no hot
   path (KDL, XML and JSON already fail through empty tokens). S. Decide the `int64` offset and
   `mPath` questions first.
3. **`InputState`, `LineCounter<TText>` (Xml/Json version), `LineIndex`.** Identical in two or three
   copies; KDL gains the SWAR counter. S–M. Verify with XML and JSON `instructions.sh` (stream
   columns).
4. **`ByteCursor<TText>` + `BufferedStreamCursor<TText>`** (the KDL/JSON stream cursor, XML's line
   handling) with `InputSettings`. Three near-identical copies. M. Measure events, document and
   stream instructions per byte; Fill must still fold.
5. **`ValueStack<T>`, `BitStack`, `DecodeBuffer`, `Window.Rebase`.** S. Adopting them in KDL and TOML
   is a separate, measured change.
6. **`Utf8.FindInvalid<TText>`** with policies. Four variants; golden churn. M.
7. **`Scan.Until<TStops>` / `Until16`.** Moderate duplication; the highest performance sensitivity.
   M. Adopt one call site at a time under `instructions.sh`.
8. **Encoding: `Decoder`, `Encoder`, tables, `Bom.Detect`, `TranscodingStreamCursor`.** One user
   today (XML), plus an optional JSON feature. M.
9. **`ErrorPolicy`** (the collect-errors skeleton) and the shared `Fail` helper. S, but they touch
   recovery invariants that the fuzz scripts guard (`test-collect.sh`, `test-json-fuzz.sh`).
10. **TOML on the window cursor** (adapter plus the empty-failure refactor). The largest gain for
    TOML (SWAR stream validation, no spill, lazy stream columns) and the largest change. L.
11. **`PushCursor`** generalized, if KDL or XML want push input. Later.

## 9. Open questions

1. **Packaging:** are these types `public` in FormatCore (consumed as a Beef dependency, like BJSON in
   TomlTester) or `internal` with `using internal FormatCore;`? Beef's `internal` is per-namespace, so
   cross-project internal access needs testing. Struct cursors and policies used as generic arguments
   by another project must be accessible to it.
2. **Error offsets:** `int64` everywhere (JSON's choice, streams over 2 GiB) or `int32` (TOML, KDL and
   XML, a smaller carrier)? And should `mPath` be part of the shared carrier?
3. **UTF-8 error wording and offsets:** unify on JSON's byte-naming messages, lead-byte offset and
   maximal subparts (and regenerate the KDL and XML goldens and TOML's position tests), or keep a
   per-policy convention?
4. **TOML's MaxTokenBytes:** adopting the window cursor changes its meaning from "retained span" to
   "construct plus lookahead, a hard limit". Is that acceptable for TOML's documented behavior and
   tests (`Stream_MaxTokenBytesBoundsRetainedSpans`)?
5. **KDL's newline set in `LineCounter`:** a word guard of `BytesBelow0E | 0xC2 | 0xE2` lead bytes,
   or keep a separate counter? JSON5's LS and PS: should they count as lines for positions (they do
   not today)?
6. **Slack bytes past the window:** they would remove every scan tail loop, but memory input is the
   caller's buffer (cannot over-read) unless copied (XML and JSON documents already copy the source).
   Worth a dedicated measurement before designing for it.
7. **Intrinsics:** can FormatCore reach `cttz` or `pmovmskb` through `[Intrinsic]` (JSON found none)?
   It would simplify `FirstByte` and `FirstStringStop16`, and helps every format at once.
8. **Comptime tables:** convert the `Build*()` static initializers to `[Comptime]` or const tables?
   This saves startup work and an indirection; check that LLVM then sees constant data (it may allow
   folding small tables).
9. **Generic base for the window helpers** (`WindowCore<TCursor, THooks>`): worth it after the cursor
   move, or are ~40 lines per format cheaper than the risk to the inlining?
10. **JSON UTF-16/32 opt-in:** is it wanted, given that RFC 8259 and I-JSON forbid it? If not,
    FormatCore's encoding module stays XML's alone and moving it has low priority.
