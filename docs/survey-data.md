# Survey: the data and document layer, numbers and writers

What the four siblings duplicate in their document stores, node tables, maps, metadata sidecars,
number handling, writers and edit tooling, and what a shared FormatCore component for each would
look like. Read-only survey of the code at: TomlBeef `cd799f0`, KdlBeef `84f2bc2`, XmlBeef `d1ee13e`,
JsonBeef `7959c3f` (all clean). Paths start at the repository name (https://github.com/mdsitton/<Name>); `T/`, `K/`, `X/`, `J/` stand
for `TomlBeef/src/TomlBeef/`, `KdlBeef/src/KdlBeef/`, `XmlBeef/src/XmlBeef/`, `JsonBeef/src/JsonBeef/`.
Reader-side topics (cursors, UTF-8, scanning, errors) are in `survey-input.md`; typed mapping and test
tooling in `survey-typed-and-tooling.md`.

## 0. Summary

- **Lineage.** TomlBeef came first (objects in a `BumpAllocator` arena), KdlBeef introduced the node
  table with `uint32` IDs and 16-byte handles, XmlBeef copied KdlBeef's model and improved the memory
  side (chunked `XmlTextArena`, `XmlStack`, kept source, lazy positions, `Compact`), JsonBeef copied
  XmlBeef's (`JsonTextArena`, `JsonStack` are textual copies) and pushed the record to 40 bytes and
  the numbers furthest. The newest copy is usually the best tested, but each also diverged a little.
- **Identical modulo names today** (safe to share first): the text arena (X/J), the inlined growable
  array (X/J), the tree link primitives (K/X; J a packed variant), subtree removal walk (K/X/J), the
  side-table helpers that follow moved entries (K/X), `ReadFileBytes`/`BeginRead`/`EndRead` (K/X/J),
  the lazy line index (X/J), the public `*SourceRange` struct (all four), Clinger's fast path (T/K/J),
  the descendants iterator (K/X).
- **Same idea, different code** (share after a design pass): hash indexes and hashing (T/J/X: three
  hashes, three seeding policies), PreserveStyle capture (three mechanisms), dirty marks (four flag
  enums), shortest-double layouts (T/K/J), arbitrary-radix big integers (K/J), compaction (X only),
  mutate/fuzz harnesses (X/J committed, K ad hoc, T none).
- **Performance risk** is low for moves that keep type boundaries (Beef emits one object file per type
  and the siblings build without LTO, so a type moved to another project inlines exactly as before;
  confirm in `beef-sharing-experiments.md`). The risk is in new abstractions over hot records (generic
  link accessors, a shared record layout); those need the instruction-count gate.
- **Two latent issues found**: TomlBeef parses slow-path floats with `Double.Parse(digits)`
  (`T/TomlParser.Values.bf:898`), which uses `NumberFormatInfo.CurrentInfo` (corlib `Double.bf:191`,
  a culture initialized from the user's locale), where KdlBeef and XmlBeef pass their own format and
  JsonBeef calls `[Friend]Parse` with `'.'`;
  TomlBeef's `TomlEntryMap` hash is unseeded (`T/TomlEntryMap.bf:241`), where JsonBeef seeds per
  process against hash flooding. A shared number parser and a shared seeded hash remove both.

## 1. Document stores and arenas

| Repo | Where | Lines | Distinguishing features |
|---|---|---:|---|
| TomlBeef | `T/TomlDocumentStore.bf:10` (`PoolRecyclingAllocator` :16) | 134 | `BumpAllocator(.Allow)` subclass whose pools go to a cache kept across `Reset` (page faults were 40% of parse time); also allocates `TomlTable`/`TomlArray` objects (destructors recorded), `NewKey`/`NewString` copy bytes as `StringView`; `ReleasePoolCache` (public `ReleaseCachedMemory`, `T/TomlDocument.bf:134`); `mSuppressAutoDirty` lives here |
| TomlBeef | `T/TomlTextArena.bf:10` | 46 | Metadata text: 16 KiB `String` blocks, large text gets its own block; **empty text gets a non-null pointer** (null = "absent" in comment sets) |
| KdlBeef | `K/KdlDocumentStore.bf:9` | 97 | Copy of TomlBeef's allocator (comment says so), text only (no destructors needed, still `.Allow`); `OwnValue` copies a `KdlValue`'s views (format-specific) |
| XmlBeef | `X/XmlTextArena.bf:11`, `X/XmlDocumentStore.bf:14` | 111 + 48 | Chunked byte arena, chunks never move, `Reset` keeps every chunk (no allocator rebuild: measured on 17,000 small SVGs), doubling 4 KiB→1 MiB, `Release`, `ReservedBytes`, `FilledBytes`; store adds a first-chunk size (exact size when compacting) |
| JsonBeef | `J/JsonTextArena.bf:11` | 96 | XmlTextArena minus `FilledBytes` ("ported from XmlBeef"); `ReadFile` reads the file straight into it (`J/JsonDocument.bf:353`, one copy) |
| XmlBeef / JsonBeef | `X/XmlStack.bf:9`, `J/JsonStack.bf:9` | 121 / 123 | Growable value array with inlined `Add`/`PopBack`/indexer (corlib `List.Add` is not inlined); X has `GrowUninitialized`, J has `Capacity`/`Ptr`; KdlBeef uses corlib `List<T>` for its tables |

Arena strings: every sibling hands out arena text as `StringView` (`NewText`, `NewKey`, `Copy`), never
`String` objects (TomlBeef's architecture §4 records why: `String` payloads allowed mutation behind the
dirty tracking). XmlBeef and JsonBeef also **keep one copy of the input** in the arena and store views
into it when nothing was decoded (`X/XmlDocument.bf:813` `Own`, `J/JsonDocument.bf:589` `TextRef`);
KdlBeef copies every string; TomlBeef copies every string and token.

Compaction: only XmlBeef (`X/XmlDocument.Compact.bf:37` `MemoryUsage`, :77 `Compact`, :189
`Clear(releaseMemory)`): live nodes renumbered in preorder, attributes made contiguous, side tables
remapped, live text copied into an exact-size store with the kept source moved as one block so views
into it stay valid. JsonBeef has `Release()` (`J/JsonDocument.bf:170`), TomlBeef `ReleaseCachedMemory`,
KdlBeef nothing (its review notes that long-lived mutation retains text, `KdlBeef/docs/review.md:313`).

**Differences that matter.** (1) BumpAllocator vs chunk arena: the chunk arena resets in O(1) and wins
on many small documents; BumpAllocator is needed only where objects with destructors live in the
arena (TomlBeef's tables and arrays). (2) Empty-text pointer contract: TomlTextArena guarantees a
non-null pointer; XmlTextArena returns the literal `""` (also non-null, but by accident). (3) Alignment:
the chunk arena is unaligned bytes; fine for text only.

**Shared design.**

```bf
namespace FormatCore;

/// Plain bytes in chunks that never move; Reset keeps the chunks.
internal class TextArena
{
	public this(int firstChunkBytes = 4096);
	[Inline] public char8* Alloc(int size);
	/// A copy; an empty copy still has a non-null pointer (callers may use null for "absent").
	public StringView Copy(StringView text);
	public void Reset();
	public void Release();
	public int ReservedBytes { get; }
	public int FilledBytes { get; }
}

/// BumpAllocator whose pools are recycled across Reset (objects with destructors: TomlBeef).
internal class RecyclingBumpAllocator : BumpAllocator { /* AllocPool/FreePool over a kept cache */ }

/// The document's copy of its input and the rule "a view into it is kept, anything else is copied".
internal struct KeptSource
{
	public void Set(StringView owned);
	[Inline] public bool Contains(StringView text);
	[Inline] public StringView Own(StringView text, TextArena arena);
	[Inline] public int32 OffsetOf(StringView text);
}

/// XmlStack/JsonStack merged (Add, AddDefault, GrowUninitialized, PopBack, Back, Ptr, Span,
/// Reserve, TrimExcess, ReservedBytes).
internal class GrowList<T> where T : struct { … }
```

Format-specific stays in the siblings: `KdlDocumentStore.OwnValue`, the TOML store's table/array
factories and `mSuppressAutoDirty`.

**Effort** S (arena, list) + S (KeptSource). **Risk**: performance none if the code moves as is (same
type boundaries); KdlBeef switching from `BumpAllocator` and corlib `List` to these is a measured
change (expected faster on small documents). API none (all internal). **Core tests**: chunk reuse after
Reset (no allocation once grown), oversized allocation, Release, Filled/Reserved accounting, non-null
empty copy, GrowList growth/TrimExcess/GrowUninitialized(0) at capacity. **Sibling proof**: XmlBeef
`XmlCompactTests` and `XmlTester -memory`, JsonBeef `test-json-fuzz.sh` and `bench/instructions.sh`,
TomlBeef `TomlLifetimeTests` (`ReleaseCachedMemory_KeepsCurrentContent`, pool count), KdlBeef
`KdlTester -bench` (document read MB/s).

## 2. Node tables and handles

| Repo | Record | Bytes | Links and counts | Slot 0 | Builder |
|---|---|---:|---|---|---|
| KdlBeef | `K/KdlDocument.bf:28` `KdlNodeRecord` in `List<>` | ~72 | parent, first, last, next, prev `uint32`; `mChildCount`; entry start/count/capacity | hidden root holding top-level nodes | `Build` :351, stack of open IDs; `LinkLastChild` :490 |
| XmlBeef | `X/XmlDocument.bf:59` `XmlNodeRecord` in `XmlStack<>` | ~56 | same five links + `mChildCount`; attribute start/count | the document node (a live node) | `Build<CMode>` :530, const generic per metadata mode; reads the core's fields directly |
| JsonBeef | `J/JsonDocument.bf:28` `JsonNodeRecord` in `JsonStack<>` | 40 | parent, first, next, prev; **last child and count packed into the 64-bit payload** of containers | unused, root is 1 | `Build<TCursor>` :411 plus the fast build (`J/JsonDocument.Fast.bf`), preorder |
| TomlBeef | objects: `TomlTable` (`TomlEntryMap` of `TomlTableSlot`), `TomlArray`, `TomlValue` union | slot 56, value 40 | owner references; per-container `TomlContainerMetadataContext` for node IDs | — | parser + `TomlPathResolver` |

Mutation primitives (table side):

| Operation | KdlBeef | XmlBeef | JsonBeef |
|---|---|---|---|
| Link last / before / after | `K/KdlDocument.bf:490`, `K/KdlDocument.Mutation.bf:24`, :41 | `X/XmlDocument.bf:848`, `X/XmlDocument.Mutation.bf:15`, :32 (identical to K) | `J/JsonDocument.bf:638` `AppendChild`, `J/JsonDocument.Mutation.bf:115` `LinkBefore(parent, id, before)` (packed counts) |
| Unlink | `K/KdlDocument.Mutation.bf:51` | `X/XmlDocument.Mutation.bf:42` (identical) | `J/JsonDocument.bf:653` |
| Remove subtree (mark `Removed`, slots kept) | `K/...Mutation.bf:71` | `X/...Mutation.bf:169` (+ style marks, root/DOCTYPE bookkeeping) | `J/...Mutation.bf:79`, :94 (same walk) |
| Self-or-ancestor (refuse moves into own subtree) | `K/...Mutation.bf:94` (stops at 0) | `X/...Mutation.bf:200` (0 may be the ancestor) | — (no move API; `CopyDetached`/`Adopt` in `J/JsonPatch.bf:374`, :452) |
| Liveness / stale view | `IsLive` `K/KdlDocument.bf:458`, `CheckView` :467 | `X/XmlDocument.bf:822`, :830 | `IsLive` `J/JsonDocument.bf:189`; enumerators check generation only |

Handles and views: `KdlNode` (`K/KdlNode.bf:43`), `XmlNode` (`X/XmlNode.bf:39`), `JsonNode`
(`J/JsonNode.bf:40`) are the same 16-byte struct (document, ID, generation; `IsValid`, `Of(doc, id)`
returning the default handle for 0, `Record` that fails fatally on a stale handle). `KdlNodeId`,
`XmlNodeId`, `JsonNodeId` are the same `uint32` wrapper. Views: `KdlNodeList` (:267),
`KdlNamedNodes`/`KdlDescendants` (`K/KdlNode.Lookup.bf:201`, :270), `XmlNodeList`/`XmlElementList`
(`X/XmlNode.bf:242`, :322), `XmlDescendants` (`X/XmlNode.Lookup.bf:261`; the K iterator plus
namespace filtering), `JsonNodeList`/`JsonMemberList` (`J/JsonNode.bf:334`, :384; no descendants).
Every enumerator reads the next link before returning the current node, so removal during the loop is
safe. The document writers walk the same links without recursion (`K/KdlDocument.bf:521`,
`X/XmlDocument.Write.bf:123`, `J/JsonDocument.Write.bf:87`).

**Differences that matter.** (1) Slot 0: a hidden root (K), a real document node (X), nothing (J);
algorithms that stop "at 0" differ (`IsSelfOrAncestor`). (2) JSON's packed last-child/count keeps the
record at 40 bytes; a uniform links block would cost it 8 bytes per node (its status notes record size
as a memory-traffic lever). (3) KdlBeef measured that keeping a node's fields in one record beats
parallel arrays (`KdlBeef/docs/architecture.md` §4), and that a packed 48-byte entry record was slower
than the 72-byte one: a shared layout must not be imposed. (4) TomlBeef has no node table: its tree
is public objects (`TomlTable`, `TomlArray`), and a move to IDs would be a rewrite of its public API.

**Shared design: generic algorithms over each format's own record**, not a shared record.

```bf
namespace FormatCore;

/// What a node record exposes to the tree algorithms (implemented by KdlNodeRecord etc.; JsonNodeRecord
/// implements LastChild/ChildCount over its packed payload).
internal interface ITreeRecord
{
	uint32 Parent { get; set; }
	uint32 FirstChild { get; set; }
	uint32 LastChild { get; set; }
	uint32 Next { get; set; }
	uint32 Prev { get; set; }
	int32 ChildCount { get; set; }
	bool IsRemoved { get; }
	void MarkRemoved() mut;
}

/// Link operations on a node table; TRoot says whether slot 0 is a real container (K, X) or none (J).
internal static class Tree<TRecord, TRoot> where TRecord : struct, ITreeRecord where TRoot : const bool
{
	[Inline] public static void LinkLast(TRecord* nodes, uint32 parent, uint32 child);
	public static void LinkBefore(TRecord* nodes, uint32 sibling, uint32 child);
	public static void LinkAfter(TRecord* nodes, uint32 sibling, uint32 child);
	public static void Unlink(TRecord* nodes, uint32 id);
	public static void MarkRemovedSubtree(TRecord* nodes, uint32 top);
	public static bool IsSelfOrAncestor(TRecord* nodes, uint32 ancestor, uint32 id);
	/// The node after `id` in preorder within `root`'s subtree (0 at its end); `enter` visits children.
	[Inline] public static uint32 NextPreorder(TRecord* nodes, uint32 root, uint32 id, bool enter);
	public static void LiveOrder(TRecord* nodes, uint32 root, List<uint32> order);   // for Compact
}

/// Walk with enter/leave steps, for the writers (close tags, `}`) without recursion.
internal struct PreorderWalk<TRecord> where TRecord : struct, ITreeRecord
{
	public bool Next(TRecord* nodes, out uint32 id, out bool leaving) mut;
}

/// Enumerator cores the public view types wrap (no allocation, generation captured).
internal struct ChildCursor<TRecord> …        // next link read before returning
internal struct DescendantCursor<TRecord, TFilter> where TFilter : struct, INodeFilter …
```

Public handle and list types stay in each sibling (different names, properties and doc comments; Beef
has no struct inheritance): they wrap the cursors as fields, which costs nothing once inlined.
`GenerationStamp` (generation bump, `CheckView` message) can be a small shared struct embedded in each
document. **Not** a generic `TreeDocument<TRecord>` base class: a public `KdlDocument` deriving from a
FormatCore generic would put FormatCore in every sibling's public type hierarchy and needs the record
type to be public.

**Effort** M (tree ops + cursors + porting three siblings). **Risk**: performance medium, since these
run per node on the build path (`LinkLast`) and per step in every walk; an interface property on a
struct generic must monomorphize and inline (prototype in `experiments/` and count instructions on
X/J's `bench/instructions.sh` before porting). The fallback, if property setters on interface-
constrained structs do not inline, is a concrete `TreeLinks` field block plus a JSON-specific packed
variant. API none. **Core tests**: a randomized model test (link/unlink/move/remove sequences checked
against a naive parent+children-list model, for both `TRoot` values and for a packed record),
preorder equivalence with a recursive walk, removal invalidation. **Sibling proof**:
`KdlMutationTests`/`KdlReviewTests`, `XmlMutationTests`/`XmlReviewTests` and `test-roundtrip.sh` with
`-mutate`, `JsonDocumentTests`/`JsonPatchTests` and `test-json-fuzz.sh` (SetValue copies); document-read
instruction counts unchanged within noise.

## 3. Ordered maps, indexes and interning

| Repo | Where | Lines | What it is |
|---|---|---:|---|
| TomlBeef | `T/TomlEntryMap.bf:22` | 268 | A table's entries in insertion order (`TomlTableSlot`: key view, value, node ID); linear scan up to 8; past that an open-addressing index (power of two, ≤ half full, slot = entry+1 and 32-bit hash), `FindOrAdd` in one probe, rebuild on remove/rename; word-at-a-time hash with a splitmix64 finalizer, **unseeded**; duplicates are errors (TOML) |
| JsonBeef | `J/JsonMemberIndex.bf:11` | 124 | Per-object index for objects over 16 members, created on first lookup (`J/JsonDocument.bf:696`), kept in `Dictionary<uint32, JsonMemberIndex>` by object ID, dropped on any member change; slot = `hash << 32 | memberId`; **seeded per process** (time and address through splitmix64); a name maps to its last member; also answers duplicate checks while building |
| XmlBeef | `X/XmlNameTable.bf:41` | 375 | Interning: entries in an `XmlStack`, slots `hash << 32 | id`, **seeded per table**, text in an `XmlTextArena`; 256-entry direct-mapped recent-name cache (first byte, last byte, length); four predefined names at fixed IDs survive `Clear`; cached QName split and validity (XML-specific) |
| KdlBeef | `K/KdlNode.Lookup.bf` (scan from the end) | — | No index: properties are scanned from the last entry (last duplicate wins); measured 28–64 ns for 4–16 properties, an index would pay only past ~30 (`KdlBeef/docs/status.md`) |
| Typed writers | `K/KdlBind.bf:173` `KdlKeyIndex`, `X/XmlMap.bf:200` `XmlMapWriter`, `J/JsonBind.Node.bf:67` `JsonMemberWriter` | — | One pattern for dictionaries written in place: index existing entries by key once (last duplicate kept, earlier removed), mark used, append new, remove unused at `Finish`; uses corlib `Dictionary`/`HashSet` (typed-mapping survey) |

Duplicate policies: JSON has `JsonDuplicateNames` (KeepAll, Error, LastWins, FirstWins) applied while
building (`J/JsonDocument.bf:461`); KDL keeps all and the last wins on lookup and in canonical output;
XML duplicates are well-formedness errors checked on name IDs in the reader (pairwise up to 16, a set
above); TOML duplicates are errors and merges have their own conflict policy. These are format rules;
only the index that answers "is this key here, and which is last" is shared.

**Differences that matter.** Three hashes of the same shape (overlapping word loads, multiply mixing)
with three seeding policies; TOML's unseeded hash is reachable from untrusted input. Index ownership
differs: embedded struct (T), side dictionary by object (J), whole-document table (X). Entry
identity: position+1 (T), node ID (J), interned ID (X).

**Shared design.**

```bf
namespace FormatCore;

internal static class ByteHash
{
	/// Word-at-a-time hash (XmlNameTable's: overlapping loads, never past the end, high-half finish).
	[Inline] public static uint32 Hash(char8* ptr, int length, uint64 seed);
	/// A seed per table from a process seed (time, address) and a counter.
	public static uint64 NewSeed();
}

/// Resolves an index slot's ID to its key, so the index stores no keys.
internal interface IKeySource { StringView KeyOf(uint32 id); }

/// Open addressing over IDs: slots `hash << 32 | id`, power of two, at most half full, linear probe;
/// a probe that misses reads no key.
internal struct OpenIdIndex : IDisposable
{
	public uint32 Find<TKeys>(TKeys keys, StringView key, uint32 hash) where TKeys : IKeySource;
	public uint32 FindOrInsert<TKeys>(TKeys keys, StringView key, uint32 hash, uint32 newId, out bool added) mut …;
	public void Set<TKeys>(TKeys keys, StringView key, uint32 hash, uint32 id) mut …;   // replace (last wins)
	public void Rebuild<TKeys>(TKeys keys, Span<uint32> ids) mut …;
	public void Clear() mut;
}

/// Ordered entries with a scan-then-index policy (TomlEntryMap generalized: the slot type is the
/// format's; the threshold is a const generic).
internal struct OrderedMap<TSlot, TLimit> where TSlot : struct, IKeyedSlot where TLimit : const int …

/// String interning with stable text and a recent-name cache (XmlNameTable minus QName logic).
internal class InternTable { public uint32 Intern(StringView text); public uint32 InternCached(StringView text);
	public uint32 Find(StringView text); public StringView this[uint32 id] { get; } public void Clear(); public void Release(); }
```

XmlBeef keeps `XmlNameTable` as a wrapper (QName split, predefined names, `XmlNameId`). KdlBeef needs
nothing now (no index pays); `InternTable` would serve it if property keys were interned later.

**Effort** M. **Risk**: XmlNameTable's `Intern`/`InternCached` are on the start-tag hot path (inlined
into the reader); the shared version must keep the slot-hash-first probe and the inlining. Changing
TOML's hash changes iteration-independent behavior only (index order is internal). **Core tests**:
collisions forced by a fixed seed, growth at half full, last-wins `Set`, rebuild after removals,
predefined-entry survival across `Clear`, a seeded-hash distribution check. **Sibling proof**: TomlBeef
`TomlReadTests`/`TomlMutationApiTests` and its lookup benchmark (~70 ns); JsonBeef duplicate-policy
tests in `JsonDocumentTests` and the fuzz script; XmlBeef `XmlReaderTests` (duplicate attributes,
namespaces) and instruction counts on svg-icons/records (name-heavy).

## 4. Metadata sidecars: positions and PreserveStyle

| Repo | Positions | PreserveStyle mechanism | Dirty marks |
|---|---|---|---|
| TomlBeef | `T/TomlMetadata.bf:138` `TomlPackedRange` (line, column, offset, length, **source index** for merged documents) in `TomlDocumentMetadata.mRanges` by `TomlNodeId` (:550) | Copies of original tokens and comments in `TomlTextArena`; parsed format records (`TomlIntegerFormat`, `TomlFloatFormat`, date/time, array/table layout) in pools; comment sets; inferred `TomlDocumentStyle`; **not** byte-exact by design (functional equivalence) | `TomlDirtyFlags` :22 (Value, Children, Style) per node style; root flags separate |
| KdlBeef | `K/KdlDocument.bf:57` `KdlRangeRecord` per node ID and entry index, located while reading (`RangeAt` :439) | **Slices**: the reader partitions the source into one slice per event (`SourceText`/`SourceStart` + landmarks); `K/KdlDocument.Style.bf` copies the pieces into the store as views (`KdlNodeStyle` :30: leading, head prefix, name, before children, block end, tail; `KdlEntryStyle` :49); works from a stream without keeping the source | `KdlStyleFlags` :8 per node/entry (`MarkNode` :72, `MarkEntry` :79), no ancestor propagation (the writer visits every node) |
| XmlBeef | `X/XmlDocument.bf:90` `XmlRangeRecord` by node ID and attribute index; from memory **offsets only, line -1**, located on request through a lazy line-start index (`LocateInSource` :735); streams locate while reading | **Offsets into the kept source** (`XmlNodeStyle` `X/XmlDocument.Style.bf:35`: lead, start, end, name end, attributes end, start-tag end, inner tail, end-tag start; `XmlAttributeStyle` :53); a stream is read whole first; entity sharing groups | `XmlStyleFlags` :8; `MarkNode` :201 + `MarkChanged` :210 propagate `SubtreeDirty` to ancestors, stopping at one already marked; `MarkNeighbors` for shared groups |
| JsonBeef | `J/JsonDocument.Positions.bf:47` `JsonRangeRecord` (value and **member name** ranges, **int64 offsets**); lazy line index :69 (X's algorithm) | Offsets into the kept source (`JsonNodeStyle` `J/JsonDocument.Style.bf:29`: lead, token, name end, value start/end, comma, after, inner, close, first token); `FinishStyle` finds commas after the read; layout detection (indent unit, colon text, newline, multi-line) | `JsonStyleFlags` :8; `Mark` :339 propagates `SubtreeDirty` like X; `MarkNew` :361 |

Public range types: `TomlSourceRange` (`T/TomlMetadata.bf:100`), `KdlSourceRange.bf`,
`XmlSourceRange.bf`, `JsonSourceRange` (`J/JsonDocument.Positions.bf:8`) are the same struct (source
view, line, column, offset, length, `ToString` as `source:line:column`); only the doc comments on the
length differ. Per-item side tables that follow entries/attributes when they move: `SideCopy`,
`SideClear`, `SideRemove` are identical in `K/KdlDocument.Mutation.bf:113` and
`X/XmlDocument.Mutation.bf:282` ("a table is in use when it is not empty, items added since the read
have default records"). Style tables grow on access in all three (`NodeStyle(id)`, `StyleOf(id)`).

**Differences that matter.** (1) Three PreserveStyle mechanisms: copied slices (K: stream-friendly,
memory proportional to the source anyway), offsets into a kept source (X, J: smaller records, unchanged
subtrees written as one range, but streams are read whole), tokens and formats (T: regenerates layout,
not byte-exact; the only one with a style API that sets formats in code). (2) Ancestor propagation
exists only where the writer copies unchanged subtrees as one range (X, J). (3) JSON keeps two ranges
per node and 64-bit offsets; the others 32-bit. (4) TOML ranges carry a source index (merges).

**Shared design: the mechanisms, not the records.**

```bf
namespace FormatCore;

/// The public range (all four are this struct); siblings keep their names with
/// `public typealias KdlSourceRange = FormatCore.SourceRange;` if the author accepts a FormatCore type
/// in their public signatures, else they keep their own copy and only the internals are shared.
public struct SourceRange { public StringView mSource; public int mLine, mColumn, mOffset, mLength; … }

/// One stored range; line 0: none; line -1: offsets only, located on request.
internal struct RangeRecord { public int32 mLine, mColumn, mOffset, mLength; }

/// Line starts of a kept source built on first request; binary search; columns in code points; a
/// leading BOM takes no column; an offset on a CRLF's LF is on the line the CRLF ends.
internal struct LineIndex<TNewlines> : IDisposable where TNewlines : INewlineRule
{
	public void Locate(StringView source, int offset, out int line, out int column) mut;
}

/// A side table by ID or item index: empty = unused; grows with default (or initializer) records;
/// follows item moves (the K/X SideCopy/SideClear/SideRemove).
internal struct SideTable<T> : IDisposable where T : struct
{
	[Inline] public bool InUse { get; }
	public ref T At(int index) mut;          // grows
	public void Copy(int from, int to, int count, int itemCount) mut;
	public void ClearAt(int at, int itemCount) mut;
	public void RemoveAt(int at, int end, int itemCount) mut;
	public void Remap(Span<uint32> newIndexOf) mut;   // Compact
}

/// Dirty marking: set flags on a node and SubtreeDirty on its ancestors up to one already marked.
internal static class Marks<TRecord, TStyle> where TRecord : struct, ITreeRecord where TStyle : struct, IStyleFlags
{
	public static void MarkUp(TRecord* nodes, ref SideTable<TStyle> styles, uint32 id, uint16 flags, uint16 subtreeDirty);
}

/// Layout of new content inferred from the source: newline kind, indentation unit, IsIndentation.
internal struct LayoutHints { public StringView mNewLine; public StringView mIndentUnit; … }
```

The format records (`KdlNodeStyle`, `XmlNodeStyle`, `JsonNodeStyle`, TOML's formats and comment
sets), their capture code and the preserving writers stay in the siblings: they encode each grammar's
pieces. The common flag bits (Captured, LeadingDirty, NameDirty, ValueDirty, ChildrenDirty,
SubtreeDirty) can be documented as a convention, but Beef enums cannot be extended, so each sibling
keeps its enum and passes the bit values.

**Effort** S (SourceRange, RangeRecord, LineIndex, SideTable) + M (marks, layout hints). **Risk**: none
on reads without metadata (side tables stay empty); PreserveStyle reads are less hot. API: the public
`SourceRange` typealias is the only visible change. **Core tests**: `LineIndex` against a naive scan
for each newline rule (LF, CR, CRLF; KDL's NEL/FF/VT/LS/PS), the CRLF-boundary rule, BOM, offset past
the end; `SideTable` following random move/insert/remove sequences of an item table. **Sibling proof**:
`XmlPositionsTests`, `KdlLimitsAndPositionsTests`, JsonBeef positions tests in `JsonDocumentTests`,
TomlBeef `TomlPreserveStyleMetadataTests`; the roundtrip scripts (K, X, J byte for byte, with mutate).

## 5. Numbers

| Repo | Parsing | Formatting |
|---|---|---|
| TomlBeef | `TryParsePlainInteger` `T/TomlParser.Values.bf:556` (1–18 digits, no leading zero); `TryParsePlainFloat` :586 (Clinger, exponent ±22); slow path strips underscores into a scoped `String` and calls `Double.Parse(digits)` (:898, culture-dependent decimal separator) | `TomlWriter.bf:205` canonical float (`"R"` + `.0`, `-0.0`, `inf`/`nan`); `T/TomlWriter.Formats.bf:11` `WriteIntegerWithFormat` (base 2/8/16, digit case, min digits, underscore grouping), :120 `WriteFloatWithFormat`, :204 `AppendRoundTripScientific` (moves the point of the `R` digits), exponent case/sign/width, `PadFractionDigits`; date/time formats |
| KdlBeef | `TryParsePlainNumber` `K/KdlReader.Values.bf:244` (T's two in one pass over the integer part; KDL allows leading zeros); slow path strips underscores on the stack, `double.Parse(digits, KdlChar.sNumberFormat)` :224; `MakeInteger` int64 or `BigInteger` lexeme | `K/KdlCanonical.bf:276` float lexeme canonicalization (no `_`/`+`, `E±`), :322 `AppendIntegerLexeme` (any radix → decimal, base-2^32 limbs, divide by 10^9), :410 `AppendDouble` (round-trip digits, `.0`, `E+`) |
| JsonBeef | `J/JsonNumber.bf:49` `ParseDouble`: `TryParsePlainDouble` :91 → `TryClinger` :144 (**extended**: exponents past 22 when the scaled mantissa stays exact) → corlib fast_float via `double.[Friend]Parse` (no culture, no compares); `ParseFloat` binary32 directly; `TryParseInt64`/`UInt64` :180; classification `Integer/UInteger/Float/BigInteger/NonFinite`; reader gathers the mantissa during its one scan, 8 digits at a time (`JsonChar.ParseEightDigits`) | `AppendDouble` :297 from zmij digits (`[Friend]ToString_RoundTripFast`) laid out by `AppendLayout` :360: `Plain` and `EcmaScript` (RFC 8785); `AppendFloat` (binary32 shortest); `AppendHexAsDecimal` :234 (base-10^9 limbs); exact decimal of a double for `ValueEquals` (`J/JsonPatch.bf:606`) |
| XmlBeef | `XmlValueParser` `X/XmlNode.Lookup.bf:376`: XML Schema lexical forms (whitespace, `INF`, `NaN`, `1`/`0` booleans), then `double.Parse(s, sNumberFormat)` | none beyond text (values are strings) |

Verified: JsonBeef's number code passes the parse-number-fxx corpus bit for bit (1,414,116 numbers, f64
and f32) and 100,000 RFC 8785 lines (`JsonBeef/docs/status.md`); KdlBeef has a bit-identity test of its
fast path against `Double.Parse`. TomlBeef's and KdlBeef's fast paths are the same code (KdlBeef says
"TomlBeef's ... with KDL's grammar"); JsonBeef's is the generalization.

**Shared design.** Grammar checks stay in the readers (each format validates its token); FormatCore
converts validated pieces and lays out results.

```bf
namespace FormatCore;

internal static class DecimalParse
{
	/// ±mantissa × 10^exponent when exact (JsonBeef's TryClinger, with the >22 extension).
	[Inline] public static bool TryClinger(uint64 mantissa, int exponent, bool negative, out double value);
	/// One-pass `[sign]digits[.digits][(e|E)[sign]digits]` without underscores: an int64 (≤18 digits)
	/// or a Clinger double; false for anything else. TLeadingZeros: KDL allows them, TOML/JSON not.
	[Inline] public static bool TryParsePlain<TLeadingZeros, TPlus>(StringView token, out PlainNumber number) …;
	/// Correctly rounded, culture-free (corlib fast_float through [Friend]); underscores stripped on the
	/// stack first when `separator` is given.
	public static bool ParseDouble(StringView unsignedDigits, bool negative, out double value);
	public static bool ParseFloat32(StringView unsignedDigits, bool negative, out float value);
	[Inline] public static uint64 ParseEightDigits(uint64 word);
	/// Decimal magnitude with overflow: int64, uint64 or big.
	public static IntegerClass ClassifyDecimal(char8* digits, int count, bool negative, out uint64 magnitude);
}

internal static class ShortestDouble
{
	/// zmij's shortest round-trip digits and the decimal point position (value = 0.d1d2… × 10^point).
	public static int Digits(double value, char8* digits, out int point);
	public static int Digits(float value, char8* digits, out int point);
	/// Layouts: EcmaScript (RFC 8785), JsonPlain, ExponentStyle (KDL canonical `E+`, TOML's captured
	/// case/sign/width), AlwaysFraction (`.0`), Scientific (TOML's notation).
	public static void Append(String output, double value, in FloatLayout layout);
}

internal static class BigDecimal
{
	/// Digits in radix 2, 8, 10 or 16 (underscores skipped) as decimal text, linear for radix 10.
	public static void AppendRadixAsDecimal(String output, StringView digits, uint32 radix, bool negative);
	/// The exact decimal expansion of a double (JsonBeef's ValueEquals).
	public static void AppendExact(String output, double value);
}

/// Integer text in a base with digit case, minimum digits and underscore grouping (TOML's format,
/// wanted by KdlBeef's open item P5).
internal struct IntegerLayout { public uint8 mBase; public bool mUppercase; public uint8 mMinDigits, mGroupSize; }
internal static class IntegerText { public static void Append(String output, int64 value, IntegerLayout layout); }
```

Not shared: each grammar's validation and messages, JSON's `NonFinite`/JSON5 hex handling, XML Schema
lexical forms (they would call `DecimalParse.ParseDouble` underneath), **TOML date/time**
(`T/TomlDateTime.bf`, `T/TomlParser.DateTime.bf`, date/time writer formats: no other sibling has the
type; revisit only if XmlBeef's typed mapping adds `xs:dateTime`).

**Effort** M. **Risk**: performance low if the hot entry points stay `[Inline]` and the readers keep
gathering mantissas in their own scans (JsonBeef's reader passes mantissa and exponent, not text);
correctness gated by corpora. KdlBeef's `numbers` input is its weakest benchmark (146 MB/s; the time
is in the float path), so measure it. **Core tests**: JsonBeef's fxx corpus and RFC 8785 file run
against the core directly (move JsonTester's `-fxx`/`-es6` drivers), Clinger vs `[Friend]Parse` on
random mantissa/exponent pairs, radix conversion against a naive big-number implementation, layout
golden tables per style. **Sibling proof**: `test-json-numbers.sh`, KdlBeef's suite (canonical float
and big-integer forms) and its float bit-identity test, TomlBeef `test-toml.sh`, `test-roundtrip.sh`
and `TomlStyleApiTests` (formats).

## 6. Writers and escaping

| Repo | Canonical / plain writer | Preserving writer | Escaping | Output |
|---|---|---|---|---|
| TomlBeef | `T/TomlWriter.bf` (three-phase table order, linear-output rules, shared header-path buffer) | `T/TomlWriter.Preserving.bf:11` (recursive over tables; per-node formats, comments, blank lines, indentation by column) | `WriteBasicString` `T/TomlWriter.bf:264` (per char; `\e` on 1.1); literal-string preference | caller `String`; `WriteFile` builds the whole string (I3 deferred) |
| KdlBeef | `K/KdlDocument.bf:521` (link walk, 4 spaces, properties sorted and deduplicated) and `K/KdlCanonical.bf` from events | `WritePreserving` `K/KdlDocument.Style.bf:178` (concatenate pieces, regenerate dirty; indentation unit from source) | `AppendQuoted` `K/KdlCanonical.bf:223` (plain runs, short escapes, `\u{…}` for banned code points); bare identifiers | caller `String` |
| XmlBeef | `WriteCanonical` `X/XmlDocument.Write.bf:95`, `WriteElementTree` :123 (link walk, optional indent of element-only content); `XmlCanonical` suite form | `WritePreserving` `X/XmlDocument.Style.bf:265` | `AppendTextEscaped` :444 (context-aware `]]>`), `AppendAttributeEscaped` :476/:483, suite-form `AppendEscaped` `X/XmlCanonical.bf:189` | caller `String`; `WriteBytes` through `XmlEncoder` (`X/XmlEncoder.bf:7`: UTF-16/32, Latin-1, ASCII, single-byte tables; unencodable policies) |
| JsonBeef | `JsonWriter` `J/JsonWriter.bf` (streaming, compact or indented, first error recorded and later calls no-ops) driven by `WriteTree` `J/JsonDocument.Write.bf:87`; JCS with UTF-16 member order :176/:246 | `WritePreserving` in `J/JsonDocument.Style.bf` | `AppendEscaped` `J/JsonWriter.bf:511` (8 bytes at a time, options: non-ASCII, HTML, line separators, WTF-8 surrogates back to escapes) | caller `String`; `WriteFile` |

**Common shape**: every writer appends to a caller-provided `String`, walks the links without
recursion (except TomlBeef's table recursion), escapes by "copy the plain run, then the escape", and
indents with a unit repeated per depth (`AppendIndent` in X/K, `IndentText` in JSON options, column
counts in TOML). The escape sets and canonical rules are format law and differ in every case.

**Shared design (small).** `PreorderWalk` (§2) for the walks; an `EscapeWriter` helper that takes a
stop-byte set (SWAR from the character layer: bytes below 0x20, given ASCII bytes, ≥ 0x80) and a
per-format escape callback as a generic struct parameter, so TOML's per-char `WriteBasicString` and
KDL's `AppendQuoted` gain JsonBeef's word-at-a-time plain-run scan; `HexText.AppendUnicodeEscape`
variants (`\uXXXX` with surrogate pairs, `\u{X}`, `&#N;`/`&#xN;`); `AppendIndent(output, unit, depth)`.
Keep `JsonWriter`, the canonical forms (JCS ordering, XML suite form, KDL canonical, TOML canonical),
and `XmlEncoder` in their siblings; `XmlEncoder` moves only together with XmlBeef's decoders if the
input survey moves encodings into FormatCore. A shared output-sink abstraction is not worth it until a
sibling builds a streaming writer (TomlBeef's I3 analysis applies to all four).

**Effort** S–M. **Risk**: escaping is per byte on write paths that are measured (JSON compact write,
KDL canonical write MB/s); a generic callback must inline. **Core tests**: the run scanner against a
byte-by-byte reference with random bytes, escape sets per format as golden tables. **Sibling proof**:
nativejson byte-for-byte rewrite and RFC 8785 vectors (J), KDL suite canonical outputs, XML rewrite
mode and SVG fixed point, TOML encoder suite (`test-encoder.sh`, `test-official-toml.sh`).

## 7. Mutation and edit infrastructure

- **Equality short-circuits**: setters skip equal values so PreserveStyle nodes stay clean (TomlBeef
  `IsSemanticallyEqualTo`, XmlBeef's `XmlValueWriter` "changes nothing when the value is the same",
  JsonBeef typed writes compare values). A convention, not code.
- **Dirty tracking**: §4. **Edit dependencies** (XmlBeef's table in its architecture §4: ATTLIST
  defaults, DOCTYPE removal, namespace scope, entity groups) are XML-specific.
- **Transactions**: JsonBeef `Checkpoint` (`J/JsonPatch.bf:337`: copy records and style slots, count
  append-only tables, restore on failure, generation unchanged) and TomlBeef's merge into a temporary
  store. Generic over a node table plus side tables it would be ~100 lines; share only once a second
  format needs patching.
- **Compaction**: §1. A generic `Compact` over `GrowList<TRecord>` + `Tree.LiveOrder` + ID remap +
  `RangeTable` (below) + `SideTable.Remap` + a "move text" hook would give KdlBeef and JsonBeef
  XmlBeef's `Compact`/`MemoryUsage` for little code.
- **Entry/attribute tables**: KDL entries and XML attributes are one document-wide table with a
  (start, count) range per node; appending grows in place when the range is last, else moves it to the
  end leaving a hole (`K/KdlDocument.Mutation.bf:144`, KDL adds a capacity; `X/XmlDocument.Mutation.bf:313`),
  removal shifts within the range (:177, :335), side tables follow. Shared as
  `RangeTable<TItem>` (`Append(ref ItemRange, TItem)`, `RemoveAt(ref ItemRange, int)`,
  `Span(ItemRange)`, move callbacks for side tables), effort S.
- **Harnesses**:

| Repo | Where | What |
|---|---|---|
| XmlBeef | `XmlBeef/XmlTester/src/Mutate.bf:11` | `-mutate SEED`: 8 random well-formedness-keeping edits of a PreserveStyle document, `WriteBytes` in its encoding, re-read without metadata, compare suite forms; prints the edit log and both forms on failure |
| XmlBeef | `XmlBeef/XmlTester/src/Fuzz.bf:12` | Byte mutations (delete run, insert a markup token from a dictionary, duplicate a slice, replace a byte) for collect-errors; memory vs 16-byte stream must agree |
| JsonBeef | `JsonBeef/JsonTester/src/Mutate.bf:11` | 1–8 random edits, write, re-read plain, compare canonical |
| JsonBeef | `JsonBeef/JsonTester/src/Fuzz.bf:17` | Character mutations (interesting ASCII, random byte, UTF-8 lead/continuation), then agreement across fast build, reader, 1-byte stream, push reader, collect-errors, SkipValue, lenient modes, JSON5, SetValue copy + ValueEquals + Patch; `Sweep` over chunk sizes 1–31 |
| KdlBeef | — | "random valid mutations ... all round-trip" and collect-errors fuzzing are reported in its docs but no harness is committed |
| TomlBeef | — | none |

**Shared design**: a separate test-support project, `FormatCore.Testing` (not linked into release
libraries), with `TextMutator` (the union of XmlBeef's byte operations and JsonBeef's character
classes; a token dictionary per format), `EditRun` (seeded `Random`, N edits through a format-supplied
`IEditTarget { void Collect(List<…>); void Apply(Random, String log); }`, write, re-read plain, compare
canonical text, print log/written/expected/actual), and an `AgreementCheck` that runs named read modes
and reports the first disagreement; plus one bash driver for "every input × seeds × rounds" with
`SEEDS`/`ROUNDS` like the existing scripts. **Effort** M (driver) + S per sibling. **Risk** none at
run time. It is the safety net for every other migration here and gives KdlBeef and TomlBeef a
committed mutate/fuzz harness.

## 8. What should not be shared

- Public types: `KdlNode`/`XmlNode`/`JsonNode`, their IDs, lists and enumerators, documents and their
  config structs (names, doc comments and semantics differ; the siblings' public API is theirs). Share
  the cursors and checks inside them.
- Record layouts (`KdlNodeRecord`, `XmlNodeRecord`, the 40-byte `JsonNodeRecord`, `KdlEntryRecord`,
  `XmlAttributeRecord`) and value unions (`KdlValue`, `TomlValue`): each is measured for its format.
- TomlBeef's object model (`TomlTable`, `TomlArray`, `TomlEntryMap` slots, path resolver, merge): it
  is public API; it can use the shared arena, hash/index and numbers, not the node table.
- Grammars, number classification rules, escape sets, canonical forms (JCS, XML suite form, KDL
  canonical, TOML canonical), duplicate-name policies, XML namespaces/DTD/edit dependencies, QName
  logic, JSON Pointer/Patch, TOML date/time, `JsonWriter`, PreserveStyle capture and writers.
- `XmlEncoder` (unless encodings move with the decoders).

## 9. Prioritized list (most duplicated × least risk first)

| # | Component | Copies today | Effort | Risk | First users |
|---|---|---|---|---|---|
| 1 | `TextArena`, `GrowList<T>`, `KeptSource` | X=J identical, K/T variants | S | Low | X, J (drop-in), then K (measured) |
| 2 | Read shell: `ReadFileBytes`/`ReadStreamBytes` with a size budget, `BeginRead`/`EndRead` helpers, collected-error text kept in the arena | K, X, J near-identical (`K/KdlDocument.bf:319`, `X/XmlDocument.bf:481`/:494, `J/JsonDocument.bf:338`) | S | Low (error types: return a small failure struct, the sibling builds its error) | K, X, J |
| 3 | Positions: `SourceRange`, `RangeRecord`, `LineIndex<TNewlines>`, `SideTable<T>` | 4 public structs, 2 line indexes, 2 side-table helpers | S | Low | X, J, K; TOML's ranges later |
| 4 | `FormatCore.Testing` mutate/fuzz/agreement harness | X, J (K, T missing) | M | None at run time | K, T first (new coverage), then X, J |
| 5 | Numbers: `DecimalParse`, `ShortestDouble`, `BigDecimal`, `IntegerText` | 3 Clinger paths, 2 radix converters, 3 float layouts | M | Low–medium (gated by fxx/es6 corpora) | J (source), T (fixes culture dependence), K |
| 6 | Tree algorithms and cursors (`Tree<TRecord, TRoot>`, `PreorderWalk`, cursors) | K=X identical, J variant | M | Medium (hot; prototype + instruction counts) | K, X, then J |
| 7 | Hashing and indexes (`ByteHash`, `OpenIdIndex`, `OrderedMap`, `InternTable`) | 3 hashes, 3 indexes | M | Medium (XmlNameTable hot path) | T (seeding fix), J, then X |
| 8 | `RangeTable<TItem>` for entries/attributes + generic `Compact` | K, X (Compact X only) | M | Low–medium | K, J gain Compact |
| 9 | Style helpers: `Marks.MarkUp`, `LayoutHints`, escape run writer | X, J (marks); all (escapes) | S–M | Low–medium | X, J; K, T escapes |

## 10. Open questions

1. Do Beef interface property setters (`set mut`) on struct generics specialize and inline like
   direct field access? §2 and §3 depend on it; the fallback is a concrete links block (costing JSON
   8 bytes per record) or comptime-generated accessors. To answer in `experiments/`.
2. Is "one object file per type, no LTO" accurate for the siblings' Release builds, so that moving a
   type to FormatCore never changes inlining? (`beef-sharing-experiments.md`.)
3. FormatCore's building blocks as `internal` (siblings add `using internal FormatCore;`, which Beef
   allows across projects, and so can any user) or `public` in a `FormatCore.Impl`-style namespace?
   Either way no sibling public signature may name them.
4. Public `SourceRange` through `typealias` (one type, sibling names kept) or four copies? It is the
   only shared type that would surface in the siblings' public API.
5. One PreserveStyle source model? KdlBeef's copied slices support streaming PreserveStyle; XmlBeef
   and JsonBeef keep the source and store offsets (they read streams whole first). Converging KDL on
   offsets would simplify and shrink its style records; converging X/J on slices would bound memory
   for streamed PreserveStyle. Or keep both and share only side tables and marks.
6. Should KdlBeef move its tables from corlib `List<T>` to `GrowList<T>` (XmlBeef measured
   `List.Add` not inlining) and from `BumpAllocator` to `TextArena`? Both are expected wins; both
   need its benchmark.
7. Slot-0 semantics: keep three conventions as a const generic, or converge (a hidden or document
   record at 0 for all)? JSON's root at 1 is public (`JsonNodeId.Value`).
8. Offsets: JSON stores int64 offsets in positions, the others int32 (inputs over 2 GiB). One width
   for `RangeRecord`?
9. Hash seeding policy: per table from a process seed (XmlBeef) for all, including TOML?
10. EndRead semantics differ slightly: KdlBeef keeps the partial document whenever `CollectErrors` is
    on (even after an I/O error with no collected errors), XmlBeef and JsonBeef only when errors were
    collected. Which is intended?
11. TomlBeef's slow-path `Double.Parse(digits)` depends on the current culture's decimal separator,
    and corlib initializes the current culture from the user's default locale
    (`Beef/BeefLibs/corlib/src/Globalization/CultureInfo.bf:196`); whether that yields a separator
    other than `.` on Linux is unverified (a test under `LANG=de_DE.UTF-8` would tell). Its siblings
    pin the separator explicitly. Fix in TomlBeef now, or with the shared parser?
