# Survey: typed mapping and tooling across the siblings

Scope: what of TomlBeef, KdlBeef, XmlBeef and JsonBeef's compile-time typed mapping (part A) and of
their test, tester, benchmark and agent tooling (part B) can move into FormatCore, and how. Read-only
survey of the four repositories as of 2026-10-03 (TomlBeef `cd799f0`; the others at their HEADs of that
day). Paths start at the repository name (https://github.com/mdsitton/<Name>). "T/K/X/J" abbreviate the four siblings.

---

## Part A. Compile-time typed mapping

### A1. Inventory

| Sibling | Generator (comptime) | Plan stage | Runtime bind | Attributes / interfaces | Entry points | Total |
|---|---|---|---|---|---|---|
| TomlBeef | `TomlSerializerCodeGen.bf` 588 | inline in `Emit` (no plan object) | `TomlBind.bf` 438 | `TomlObjectAttribute.bf` 116, `ITomlSerializable.bf` 28, `ITomlConverter.bf` 156 | `TomlSerializer.bf` 100 + document `Deserialize`/`Serialize` | 1,426 |
| KdlBeef | `KdlSerializerCodeGen.bf` 1,323 | same file: `FieldPlan` :157, `PlanField` :184, `ScanChain` :275 | `KdlBind.bf` 940 | `KdlObjectAttribute.bf` 159, `IKdlSerializable.bf` 93 | `KdlSerializer.bf` 105 | 2,620 |
| XmlBeef | `XmlSerializerCodeGen.bf` 775 | `XmlSerializerPlan.bf` 809 (`FieldPlan` :53, `PlanField` :113, `PlanMap` :237, `ScanChain` :327) | `XmlBind.bf` 1,093 (+ `XmlMap.bf` 423) | `XmlObjectAttribute.bf` 318 | `XmlSerializer.bf` 120 | 3,115 (+423) |
| JsonBeef | `JsonSerializerCodeGen.bf` 1,078 | `JsonSerializerPlan.bf` 467 (`ValueSpec` :34, `FieldPlan` :54, `TypePlan` :71, `PlanType` :89, `Spec` :176) | `JsonBind.bf` 645, `JsonBind.Node.bf` 405 | `JsonObjectAttribute.bf` 247 (interfaces inside) | `JsonSerializer.bf` 237 | 3,079 |

Lineage (each architecture.md says so): TOML's `[TomlObject]` (2026-09, prototype, `TomlBeef/docs/architecture.md` §8a)
→ KDL adds roles and `ScanChain`/`PlanField` (`KdlBeef/docs/architecture.md` §6) → XML splits the plan into its own
file (review A03) and adds namespaces, maps, `Strict`, `ShowGenerated` (`XmlBeef/docs/architecture.md` §6) → JSON
replaces the flat plan with a recursive `ValueSpec`, a `TypePlan`, and defers planning to method-compile time
(`JsonBeef/docs/architecture.md` §5). Last generator commits: T 2026-09-30, K 2026-09-30, X 2026-10-01, J 2026-10-02.
Typed-mapping tests: `TomlSerializerTests.bf` 973 lines, `KdlSerializerTests.bf` 420, `XmlObjectTests.bf` 458,
`JsonObjectTests.bf` 727; build-failure fixtures only in XmlBeef (`tests/codegen/src/Fixtures.bf`, 19 fixtures).

### A2. Generation model

| | TOML | KDL | XML | JSON |
|---|---|---|---|---|
| Hook | `IComptimeTypeApply.ApplyToType` → `Emit(type, Naming, Key)` (`TomlObjectAttribute.bf:50`) | same, `Emit(type, Naming, Name)` (`KdlObjectAttribute.bf:61`) | same, `Emit(type, Naming, Name, Namespace, Strict, ShowGenerated)` (`XmlObjectAttribute.bf:69`) | same, `Emit(type, this)`: the whole attribute (`JsonObjectAttribute.bf:78`) |
| When bodies are planned | type-init time, full text via `Compiler.EmitTypeBody` (`TomlSerializerCodeGen.bf:125-127`) | type-init time (`KdlSerializerCodeGen.bf:151-153`); `[KdlChildren]` dispatch deferred: `Compiler.Mixin(KdlSerializerCodeGen.ChildrenDispatch(...))` (:915) | type-init (`XmlSerializerCodeGen.bf:135-137`); `ChildrenDispatch` (:538) and `MapDispatch` (:670) deferred | **all bodies deferred**: shells whose body is `Compiler.Mixin(JsonSerializerCodeGen.Body(typeof(T), n))` (`JsonSerializerCodeGen.bf:103-105`, `Body` :121). Type-init planning made self-referencing types (`List<Node> children`) a cycle that crashed the compiler |
| Generated members | `static TomlKey`, `static TomlKeyAliases`, `TomlRead(TomlTable, ITypedAllocator)`, `TomlWrite(TomlTable)` | `KdlNodeName`, `KdlRead(KdlNode, alloc)`, `KdlWrite(KdlNode)`, `sKdlClaimed`, virtual `KdlClaimedChildNames`, `KdlArgumentsStart` | `XmlElementName`, `XmlElementNamespace`, `XmlRead(XmlNode, alloc)`, `XmlWrite(XmlNode)`, claimed-name properties, `XmlGeneratedSource` | `JsonRead(JsonReader, alloc)`, `JsonWrite(JsonWriter)`, `JsonWrite(JsonNode)`, `JsonGeneratedSource` |
| Inheritance | `new` hides base, `base.TomlRead` first (:51-52, :74-78) | `new` + base first; claims over chain, virtual claimed names | as KDL | `virtual`/`override`; **one method covers the whole chain** (a reader cannot hand the object to a base midway) (:95-97) |
| Plan object | none: per-field locals then `EmitRead`/`EmitWrite` | `FieldPlan` (flat: `mType/mKind/mConverter` + one level of `mElement*`) | `FieldPlan` (flat + key/map fields) | `ValueSpec` recursive (List/Dictionary/Nullable to any depth) + `FieldPlan` + `TypePlan` |
| Emit style | `String` + `AppendF`, fixed `_` locals | same | same | `Emitter` class (:37): code buffer, unique `Local()` names, error-path stack (`PathPart`, `Wrap`) |
| Debug output | none | none | `ShowGenerated` (:156) | `ShowGenerated` (:106-112, re-plans all three bodies) |

### A3. Member classification (`Kind`)

| Kind | T `CodeGen:17` | K `CodeGen:16` | X `Plan:12` | J `Plan:13` |
|---|---|---|---|---|
| Bool, Integer, Float, String, Enum (simple, `!IsUnion`) | yes | yes | yes | yes |
| char8/16/32 → Unsupported | yes | yes | yes | yes |
| Format scalars | 4 TOML date/time types | — | — | — |
| Object (`[XObject]`) | attribute only | attribute only | attribute only | attribute **or hand-written `IJsonSerializable`** |
| List<T> | 1 level (lists of lists rejected, `IsSupported` :172) | any depth (content rule) | 1 level | any depth |
| Dictionary<K,V> keys | String only (`DictionaryValue` :189 tests arg 0) | String, integer, enum | String, integer, enum (`KeyKind` :622) | String, integer, enum (`KeyKind` :399, byte-identical to X) |
| `T?` (Nullable) | no (status.md O9 open) | no | no | yes |
| Converter (registered / `UseConverter`) | yes | yes, leaves of containers | yes, leaves | yes, innermost value |
| Order: scalars → registered converter → enum → object → List → Dictionary | same | same | same | same (`Classify`: T :133, K :412, X :560, J :262; J takes List/Dict/Nullable first in `Spec` :176) |

Roles (format-specific by nature): TOML none (everything is a key). KDL `Role` (`CodeGen:33`): Property, Argument,
ChildValue, Arguments, ChildArguments, ChildObject, ChildObjects, Children, ChildContent. XML `Role` (`Plan:29`):
Attribute, Element, Text, AttributeList, ElementList, ChildObject, ChildObjects, Children, Map (+ 5 `XmlMapStyle`s).
JSON none (members only), plus discriminator polymorphism.

### A4. Naming, attributes, validation

| | TOML | KDL | XML | JSON |
|---|---|---|---|---|
| Naming enum | `TomlKeyNaming` {AsDeclared, SnakeCase, KebabCase, CamelCase} | `KdlNaming` {**KebabCase** (default), AsDeclared, SnakeCase, CamelCase} | `XmlNaming` {AsDeclared, CamelCase, KebabCase, SnakeCase, Lower} | `JsonNaming` {AsDeclared, CamelCase, PascalCase, SnakeCase, KebabCase} |
| Enum case names | as declared (`CaseList` T:314) | through naming (K:627) | through the declaring type's naming (`CaseNaming` X:233) | through the field's naming; or `EnumsAsNumbers` |
| Type attribute members | `Naming`, `Key` (dotted home path) | `Naming`, `Name` | `Naming`, `Name`, `Namespace`, `Strict`, `ShowGenerated` | `Naming`, `Strict`, `OmitNulls`, `EnumsAsNumbers`, `Discriminator`, `TypeName`, `ShowGenerated` |
| Field attributes | `TomlName`, `TomlAlias` (also on types), `TomlIgnore`, `TomlRequired`, `TomlUseConverter` | + `KdlArgument(n)`, `KdlArguments`, `KdlChild`, `KdlChildren` | + `XmlName(…, Namespace)`, `XmlAttribute`, `XmlElement`, `XmlText`, `XmlArray(Name, Item)`, `XmlMap(Style, Key, Entry, Value, Wrapped)`, `XmlChildren` | `JsonName`, `JsonAlias`, `JsonIgnore`, `JsonRequired`, `JsonUseConverter` |
| Name check | control chars (in `AppendLiteral`) | control chars | XML local-name grammar (`CheckName` X:475) | control chars (`CheckName` J:251) |
| Collision checks | none | `ScanChain` K:275: argument indexes, one `[KdlArguments]`/`[KdlChildren]`, one role per field, property vs child name spaces | `ScanChain` X:327: attributes vs elements with namespace overlap (`ElementClaimsOverlap` :537), one text, one catch-all | `PlanType` J:89: one member namespace incl. aliases and the discriminator |
| Abstract / polymorphism | — | `[KdlChildren]` dispatch by node name over `ChildTypes` (`Type.TypeDeclarations`) | `[XmlChildren]` and TypedEntries maps, same `ChildTypes` (4-line diff from K: the attribute type) | `Discriminator`, `SubTypes` J:330 (same scan); abstract without discriminator is a build error |
| Build errors | `Runtime.FatalError("[TomlObject] Owner.field: …")` | `Fail`/`FailType` → `"[KdlObject] …"` | same, `"[XmlObject] …"` | same, `"[JsonObject] …"` |

All four default to `AsDeclared` except KDL (kebab, the KDL convention). Every library's word splitter is the same
algorithm (acronym-aware: `HTTPPort` → `http_port`).

### A5. Drift between the copied helpers

Extracted each comptime helper and diffed (`diff -w`, changed lines). Everything not listed is a 0-2 line difference
that is only the attribute type or the `[XObject]` message prefix.

| Helper | Copies (lines) | Drift |
|---|---|---|
| `ApplyNaming` | T:238 30, K:547 29, X:781 29, J:436 32 | Same splitter. J adds PascalCase, X adds Lower (no separator), K/T use `naming != .CamelCase` for the separator test; J/X test Kebab/Snake explicitly. **J's is the superset; X's `Lower` is missing from J.** |
| `AppendLiteral` | T:271, K:578, X:162 (18 each), J:1029 21 | J escapes `\n\t\r` and has `escapeAll` (for `ShowGenerated` source); others stop the build on any control char. X's `ShowGenerated` copes another way. |
| `IntegerRange` | T:292, K:599, X:183, J:1053 (20 each) | T: 64-bit unsigned min `"0"`; K/X/J: `int64.MinValue` for every 64-bit type, safe only because `IsUInt64` routes uint64 elsewhere. Latent bug if a caller forgets. |
| `FindRegisteredConverter` | T:202 20, K:474, X:700, J:415 (17) | attribute type and message only |
| `ListElement`, `DictionaryValue`, `DictionaryKey`, `KeyKind` | 10/10/10/13 each | 0 (T's `DictionaryValue` restricts keys to String) |
| `IsSerialized`, `Fail`, `FailType` | 5 each (K, X, J; T inlines) | attribute type / prefix |
| `NewExpr` (allocator) | 5 each | J swapped parameter order (`args` defaulted) |
| `CaseList` | T, K, X (12) | T ignores naming |
| `ChildTypes` / `SubTypes` | K:494, X:720 (22), J:330 (20) | attribute type; J excludes the base itself |
| Ownership emitters | T `EmitDeleteValue` :426, K/X `EmitReplaceList` (K:796, X:407), J `NeedsDelete`/`EmitDelete`/`EmitClearItems` (:693-757) | J's is the general (recursive) one |

Duplicated format-independent comptime code: about **250 lines per sibling** (helpers above + the scalar half of
`Classify` + `IsSupported`-type checks), ~1,000 lines across the four, plus ~60-80 lines of identical attribute
structs (`Name`, `Alias`, `Ignore`, `Required`, `Converter(typeof(T))`, `UseConverter(typeof(C))`) each.

### A6. Runtime side

| Concern | T | K | X | J |
|---|---|---|---|---|
| Value lookup | `TomlBind.Read*(table, key, required, …)` → `Result<bool, E>` | `KdlBind.Find*` → `KdlValueRef`, then `To*` | `XmlBind.Find*` → `XmlValueRef`, then `To*` | token stream: `JsonBind.Read*(reader, …)` → `bool`, error parked in `reader.mBindError` (no large `Result` on the hot path) |
| Integer range | `ReadInteger(.., min, max)` T:38 "`{v} is outside the range {min} to {max}`" | `ToInteger` K:741 same text; `ToUInt64` via big-int text K:762 | `ToInteger` X:537 | `ReadInteger` J:357 "`The number … is out of the field's range (… to …)`" |
| Located errors | table/array `MakeError` (Positions forced by `TomlSerializer.WithPositions`) | `KdlBind.MakeError` K:474; `KdlSerializer.WithPositions` | `XmlBind.MakeError` X:323; lazy line index | JSON Pointer path built on the way out (`AtMember`/`AtIndex` J:76-87) |
| Update in place, by position | `WriteItem`/`ItemTable`/`TrimArray` T:362-400 | `KdlArgumentCursor` :304, `KdlChildCursor` :368, `KdlFreeChildCursor` :416 | `XmlChildCursor` :210, `XmlFreeChildCursor` :260 | `JsonArrayCursor` (Node :25) |
| Update in place, by key | `WriteTableAt`, `RenameAlias` T:327 | `KdlKeyIndex` :173 (`Finish` removes absent keys), `Rename*Alias` | `XmlMapWriter`, `Rename*Alias` | `JsonMemberWriter` (Node :67), `RenameAlias` (Node :272) |
| Allocator | `ITypedAllocator _alloc`, `new:_alloc` through the same `NewExpr` text, in all four; allocator-owned objects are never deleted on re-read |

The runtime helpers share *contracts* (absent keeps the value, null creates and owns, required → located
MissingValue, write unchanged values not at all, alias renamed on write, leftovers trimmed) and *message texts*, not
code: each binds to its own node model, and J's binds to a token stream for speed (its typed track is a benchmark
column, `JsonBeef/docs/status.md` P6T). Sharing comptime code costs nothing at run time; sharing runtime bind code
would put an abstraction on hot paths.

### A7. Core versus format-specific

| Format-independent (move to FormatCore) | Format-specific (stays) |
|---|---|
| Walking the `[XObject]` chain base-most first, `IsSerialized` | Roles and their attributes (KDL arguments/children, XML attribute/element/text/map, JSON discriminator) |
| Classification of scalars, enums, objects, `List`, `Dictionary`, `Nullable`, converters into a recursive `ValueSpec`; key kinds | Format scalars (TOML date/times) as a hook; which nestings a format allows |
| Naming policies and the word splitter; enum case lists | Name grammar checks (XML local name), name spaces/places of claims |
| Name/alias/ignore/required attribute plumbing; per-level naming | Namespaces (XML), home key paths (TOML `Key`) |
| Claim table with "mapped by both A and B" messages; place + overlap rule supplied by the format | Overlap rules (XML namespace wildcard) |
| Converter registry lookup over `Type.TypeDeclarations`, duplicate-registration error; concrete subtype enumeration | Converter interfaces' signatures (`ITomlConverter`, `IKdlConverter`, …) |
| `Runtime.FatalError` formatting (`[Prefix] Owner.field: message`) | Emit templates: lookups, conversions, writes, cursors |
| Emitted-code helpers: string literal, integer ranges, `new:_alloc` expression, enum switch generators, recursive delete/clear of owned values, unique locals, `ShowGenerated` text | Runtime bind libraries |
| Deferred-body driver (`Compiler.Mixin(Body(typeof(T), part))`) and base/override modifiers | Entry points (`XSerializer`), document integration |

### A8. Proposed FormatCore design

Namespace `FormatCore.Mapping`, all `[Comptime]` except `Naming` (also usable at run time, e.g. by tools).

1. **Naming** — `public enum NamingPolicy { AsDeclared, CamelCase, PascalCase, SnakeCase, KebabCase, Lower }` and
   `Naming.Apply(StringView, NamingPolicy, String)`. Format enums can stay as public API for now (map 1:1) or be
   replaced (pre-1.0, breaking changes are acceptable): the format attribute keeps `Naming`, typed `NamingPolicy`.
   KDL keeps its kebab default by giving its attribute a default.
2. **ValueSpec / MemberPlan / TypePlan** — J's three classes generalized:
   `ValueSpec { Type, ValueKind, Converter, Item, KeyType, KeyKind, FormatTag }`,
   `MemberPlan { FieldInfo, Level, Name, Aliases, Required, Spec, Slot, Naming, Role (int, format enum cast) }`,
   `TypePlan { Levels, Members, Slots }`. `ValueKind` adds `FormatScalar` (TOML date/times, a converter-free format
   type identified by the format's classifier).
3. **Format descriptor** — a struct implementing a static interface, used as a generic argument so comptime calls
   are direct:
   ```beef
   interface IMappingFormat
   {
       static StringView Prefix { get; }                        // "[XmlObject]"
       static bool IsObject(Type type);                         // has [XmlObject] (or J: hand-written interface)
       static void Attributes(Type level, ref LevelOptions o);  // naming, strict, … from the level's attribute
       static void FieldOverrides(FieldInfo f, MemberPlan p);   // reads XName/XAlias/XRequired/XUseConverter
       static int ClassifyFormatScalar(Type type);              // -1, or a FormatTag
       static Type RegisteredConverter(TypeDeclaration d);      // the target of d's [XConverter], or null
       static void AssignRole(MemberPlan p, TypePlan t);        // roles + role checks (Fail)
       static void Claims(MemberPlan p, ClaimSet claims);       // places/names; overlap rule on ClaimSet
       static bool Allows(ValueSpec s, out StringView why);     // T: no lists of lists; X: map shapes
   }
   ```
   `Planner<TFormat>.Plan(Type) → TypePlan` does chain walking, naming, spec building, converter lookup,
   collisions, all errors. Formats keep their emitters but take `TypePlan`/`MemberPlan`.
4. **Shared attributes (optional, later)** — FormatCore `[SerialName]`, `[SerialIgnore]`, `[SerialAlias]`,
   `[SerialRequired]` honored by every format, with the format's own attribute winning. Pays off for a type mapped
   to several formats at once (a config read from TOML and written as JSON). Names must not collide with BJSON's
   `[JsonObject]`/`[JsonIgnore]` (the JsonBeef bench links BJSON and JsonBeef in one project) or corlib.
5. **Emission kit** — `CodeWriter` (J's `Emitter`: buffer, indentation, `Local(prefix)`, error-path hook),
   `Literal.Append(code, text, escapeAll)` (J's), `IntegerRange(type, min, max, maxBits)` (T's "0" fix kept;
   format passes the widest integer it reads), `NewExpr`, `EnumEmit.NameToCase/CaseToName/CaseList(naming)`,
   `Ownership.EmitDelete/EmitClearItems/NeedsDelete` (J's), `Generated.MethodModifiers(type, isObject)`
   (`new`/`virtual`/`override`/`mut`), `Generated.SourceText` for `ShowGenerated`.
6. **Driver** — adopt J's deferred model everywhere: `ApplyToType` emits only signatures (+ interface), bodies are
   `Compiler.Mixin(Fmt.CodeGen.Body(typeof(T), part))`. Fixes the self-reference crash for T/K/X too, and lets
   dispatch tables see subtypes. Cost: J re-plans per body (3×, plus ShowGenerated); cache plans per type in a
   comptime `static Dictionary<Type, TypePlan>` if comptime statics persist (question Q6).

Lines removed per sibling: ~250-400 comptime (helpers + planner skeleton); KDL and XML's `ScanChain` partly (claim
bookkeeping ~80 lines each). Emitters (~60% of each generator) stay. TOML gains J's nesting and `T?` almost for free
in planning (O9 in `TomlBeef/docs/status.md`) but still needs emit templates.

### A9. Cross-project comptime: what is known, what to test

Known working today (one hop: library generator, user project applies it):
- Attribute defined in a library, `IComptimeTypeApply` applied in another project: `XmlBeef/tests/codegen` (project
  `Fixtures` depends on XmlBeef), `TomlBeef/bench/compare/beef/src/Typed.bf`, `JsonBeef/bench/compare/beef/src/JsonBeefTyped.bf`.
- Emitted user code calling the library's public `[Comptime]` method through `Compiler.Mixin(...)`: J's bodies,
  K/X's dispatch — in those same user projects.
- `Type.TypeDeclarations` filtered by `DeclaredInCurrent || DeclaredInDependency || AlwaysVisible` sees converters
  declared in the user project and its dependencies.
- `Runtime.FatalError` from comptime surfaces as a build error (`test-codegen.sh` greps it).

Questions for the cross-project experiments (two hops: FormatCore → format library → user project):

| # | Question | Why it matters |
|---|---|---|
| Q1 | Can a format library's `ApplyToType`/`[Comptime]` method call FormatCore's `[Comptime]` methods, and can those call `Compiler.EmitTypeBody`/`EmitAddInterface` on the user's type? | the whole design |
| Q2 | Inside FormatCore code, what are `DeclaredInCurrent`/`DeclaredInDependency` relative to: the user's project (type being compiled), the format library, or FormatCore? | converter registry and subtype lookup moved into FormatCore must still see user-project declarations |
| Q3 | Generic comptime methods over attribute types: `HasCustomAttribute<TAttr>()` / `GetCustomAttribute<TAttr>()` with `TAttr` a generic parameter; and static-interface dispatch `TFormat.AssignRole(...)` at comptime | `Planner<TFormat>` without boxing or reflection |
| Q4 | Comptime class instances (`new MemberPlan`) allocated in FormatCore and used/freed by the format library; interface dispatch on them | plans crossing the boundary |
| Q5 | FormatCore attributes (`[SerialName]`) read by the format library from user fields; attribute structs with `String` members across projects | shared attributes |
| Q6 | Do static fields mutated during comptime persist across `Compiler.Mixin` evaluations (plan cache), and are they reset on incremental rebuilds? | 3× re-planning cost |
| Q7 | Incremental rebuild: does editing FormatCore's comptime code re-run generation in the user project? (stale generated code risk) | developer loop, CI |
| Q8 | Are `[Comptime]` methods of a dependency kept out of the runtime binary (size), and does a non-`[Comptime]` helper (Naming) used at both times work? | binary size, dual use |
| Q9 | Does the build error from `Runtime.FatalError` raised two frames into FormatCore still point at the user's type/attribute? | error UX, fixture greps |
| Q10 | Same on Windows (the Windows BeefBuild under Proton) | the siblings verify Windows |
| Q11 | `[XObject]` on a generic type (`class Box<T>`): is `ApplyToType` run per specialization? (untested in all four) | scope of the planner |

### A10. Tests the core needs

1. Runtime `[Test]`s for `Naming.Apply` (table of `HTTPPort`, `Utf8Name`, `_x`, `ABC`, digits; every policy) and
   `Literal.Append`.
2. A **toy format** inside FormatCore's test workspace (`TestMap`: fields to a `Dictionary<String, Variant>`), with a
   `[TestMapObject]` attribute built on the framework: `[Test]`s of what its generated code does, and
   `ShowGenerated`-style golden text of plans (a probe attribute that emits `static StringView PlanDump`), so
   planning is tested without any real format.
3. **Build-failure fixtures**: generalize XmlBeef's `test-codegen.sh` (44 lines; `// FIXTURE <name>: <text>` +
   `-define=FIXTURE_<name>`, one build per fixture) into a FormatCore script taking the workspace and fixtures file;
   FormatCore's own fixtures cover the shared checks (unsupported type, duplicate names/aliases, two converters,
   inheritance collision, bad dictionary key); each sibling keeps fixtures for its roles. TOML, KDL and JSON have
   none today.
4. A three-project fixture workspace (FormatCore → ToyFormat lib → user) that locks Q1-Q5 answers as regression
   tests.
5. Each sibling's existing typed tests unchanged as the migration's acceptance (plus Debug and TestRelease).

### A11. Effort, risks, order

| Stage | Content | Effort | Risk |
|---|---|---|---|
| A-1 | Naming + literal + type helpers + converter/subtype lookup + integer range + ownership/enum emitters, as static comptime helpers parameterized by attribute type / prefix | 1-2 days + 0.5 day per sibling | low (Q1-Q3) |
| A-2 | `ValueSpec`/`MemberPlan`/`TypePlan` + `Planner<TFormat>` + `ClaimSet`; toy format and fixtures | 3-5 days | medium: KDL/XML `ScanChain` subtleties (argument index across levels, namespace overlap), message texts that fixtures grep |
| A-3 | Deferred-body driver for T/K/X, `ShowGenerated` for T/K, plan cache | 2-3 days | medium: inheritance switches from `new` to the J model only if wanted (K/X rely on per-level methods + virtual claims) |
| A-4 | Shared field attributes | 1 day after Q5 | naming clashes; semantics when both apply |

Risks: compile-time cost (comptime is interpreted; a generic planner adds calls, measure the bench projects' build
time); error message drift breaking `test-codegen.sh` expectations (keep texts); two-hop comptime may simply not work
(fallback: FormatCore ships the helpers as source the siblings include, a `Shared/` directory referenced by
`BeefProj.toml` paths — loses one-copy maintenance only in packaging, not in source); active sessions in XmlBeef and
JsonBeef (migrate those last, coordinate).

Order: A-1 in FormatCore with tests → KdlBeef (stable, roles, no sessions) → TomlBeef (simplest; picks up nesting/`T?`
later) → XmlBeef → JsonBeef (source of the design; when its session is idle) → A-2 per sibling in the same order → A-3.

---

## Part B. Tooling

Dates are last commits (`git log -1 --format=%ci -- path`); "drift N" is `diff a b | grep -c '^[<>]'`.

### B1. Test scripts

Shape shared by all: `#!/bin/bash`; `BIN="${BIN:-./build/Debug_Linux64/<X>Tester/<X>Tester}"` (Release through `BIN=`);
the same "`ERROR: $BIN not found or not executable. Build first with: beefbuild`" text; suite-present check;
`tmpdir=$(mktemp -d); trap … EXIT`; `LOGFILE=test-<name>.log`; `timeout N "$BIN" …` per case with exit 0 accept,
1 reject, else crash; summary then `FAIL: see $LOGFILE`/`PASS`. No script uses `set -e`; only
`TomlBeef/test-official-toml.sh:14` (`set -u`) and `XmlBeef/test-codegen.sh:6` (`set -uo pipefail`) set options.

| Script | T | K | X | J | Shared? |
|---|---|---|---|---|---|
| `test-leaks.sh` (LSan over `beefbuild -test -config=TestRelease`, `leak:BeefBuild` suppression) | 64 | 64 | 64 | 64 | **byte-identical ×4** (md5 `f68bd1c7…`) |
| `test-roundtrip.sh` | 144 (semantic JSON via `json-compare.py`) | 58 (`-preserve`, `-stream 16`) | 140 (`-roundtrip`, stream, `-mutate`) | 95 (`-preserve -echo`, stream, `-mutate`) | K/X/J same design, no shared code; T–X drift ≈ 280 |
| Suite runner | `test-toml.sh` 116, `test-encoder.sh` 115, `test-official-toml.sh` 62 | `test-kdl-spec.sh` 148 | `test-xml-conformance.sh` 269, `test-svg-corpus.sh` 114 | `test-json-suite.sh` 463, `-corpus` 139, `-lines` 83, `-numbers` 37 | skeleton shared: `MODES`, golden first-stderr-line `tests/errors/<id>.err` + `UPDATE_GOLDEN` (K :75-86, X :175-183, J), X's expected-failures + `UPDATE_EXPECTED` |
| Fuzz / collect | — | — | `test-collect.sh` 91 | `test-json-fuzz.sh` 42 | loop shape only |
| Codegen fixtures | — | — | `test-codegen.sh` 44 | — | generalizable (A10) |
| Suite fetch | committed fixtures | `tests/fetch-spec.sh` 20 | `tests/fetch-suites.sh` 98 | `tests/fetch-suites.sh` 222 | X/J identical `is_current()` (`.pinned`) and sha256 verify |

Parameters a shared roundtrip driver needs: `BIN`, an input list (`path<TAB>flags`, which X and J already build in
`$tmpdir/inputs`), echo command template, stream flag, mutate template or none, default `SEEDS`, timeout, the exit
codes that mean "rejected, not crashed" (X: 3/4), log name. A suite-runner library needs: BIN/suite defaults and
messages, mode→flags table, golden compare + `UPDATE_GOLDEN`, expected-failures + `UPDATE_EXPECTED`, crash and timeout
classification, PASS/FAIL footer. Case selection and oracles (`json-compare.py`, `expected_kdl`,
`tests/xmlconf/manifest.py`, `tests/tools/json-canonical.py`) stay per repo.

### B2. Tester CLIs

| | TomlTester | KdlTester | XmlTester | JsonTester |
|---|---|---|---|---|
| Files (lines) | Program 277, TomlTestJson 286, JsonToToml 162 | Program 434, TypedUi 211 | Program 265, Bench 316, Fuzz 133, Mutate 212, Memory 94, Osm 117 | Program 473, Bench 176, Fuzz 343, Mutate 143, Canonical 290, Numbers 241, Push 100, TrickleStream 45 |
| Options | `for`/`if` chain, Program.bf:34-78 | :83-89, subcommands :32-65 | :93-127, `-bench` :51, `-memory` :76 | :86-188, subcommands :59-65 |
| stdin | `Console.In.ReadToEnd` :99 | `ReadStdin(String)` :417 (64 KiB, keeps BOM) | `ReadStdin(List<uint8>)` :248 (4 KiB) | files only |
| Bench rule | `Measure` :227, `Measurement` :211 | :361/372, `PrintResult` :409 ("TomlTester's Measure") | `Bench.bf:262/273`, `PrintResult` :310 ("KdlTester's") | rough best-of (Bench.bf:134-148); real one in `bench/compare/beef` |

`Measure` is one function in **six copies** (three testers + `bench/compare/beef/src/Program.bf` of T :59, X :39,
J :61), identical after stripping namespace qualifiers: warm up ≥ 1 s, time single runs, stop when n ≥ minSamples and
≥ 60% of samples lie within ±10% of the median (converged) or at n = 1000 / 10 s (capped); prints
`{ms:F3} ms/op {MB/s:F1} MB/s (n=N, converged|capped)`. Format-independent too: X's `ReadInputs`/`CollectFiles`/
`ReadOne` (Bench.bf:227-260, file or sorted recursive directory), `CodePoints` :165, the two `ReadStdin`s.

Not copies: X vs J `Bench.bf` drift 386, `Fuzz.bf` 406, `Mutate.bf` 291. Fuzz shares a skeleton (seeded `Random`,
byte operators — delete/insert token/duplicate/replace — over a format token alphabet: X `sInserts` 28 entries, J
`cInteresting` + 5 character classes; rounds loop; disagreement report), J adds a 3-way `Agree()` :107 and the 1-31
byte stream `Sweep()` :298. Mutate shares only the outer loop (collect nodes, N seeded edits with a log, preserving
write, re-read, compare canonical). `Memory.bf` is X-only document slot accounting, not allocation counting; peak RSS
exists only as J's `bench/compare/c/maxrss.c` (45, `wait4`).

### B3. Benchmark infrastructure (`bench/compare/`)

| File | T | K | X | J | Newest / most capable |
|---|---|---|---|---|---|
| `c/bench.h` | 167 (09-29) | 107 (09-29) | 240 (09-30) | 235 (10-02) | `measure()` byte-identical in K/X/J, same constants in T (`BENCH_WARMUP_NS 1e9`, `MAX_NS 10e9`, `MAX_SAMPLES 1000`, `WINDOW 0.10`, `MAJORITY 0.6`). Extras: T lookup driver :91-167; X directory inputs, UTF-16 counts; J simdjson 64-byte padding, `.ndjson` batches, `check_add`/`print_check`, `usage()`. Drift vs J: T 208, K 150, X 207 |
| `run.sh` | 126 | 112 | 267 | 482 (10-02) | J: `settle()`/`cell()` inline :216/:245, ±10% converged-only, `MAX_RUNS=9`, peak RSS, `TRACKS` |
| process repeats | median of 3 (`repeated()` :89) | median of 3 (`cell()` :55) | `measure.sh` 49: `settle()` ±5%, ≤ 9, `~` | inline, ±10%, ≤ 9, `~` | two implementations of one idea, different tolerances |
| `merge.sh` (`ONLY=` partial reruns, `merge_into` re-exec with `MERGE_CHILD=1`) | 55 | **none** (`ONLY` filters, no merge :73-77) | 55 | 60 (10-02) | J superset except T's `saved_row`; drift T–X 22, T–J 41, X–J 26 |
| `bench/instructions.sh` (`perf stat -e instructions:u` on `-bench-loop`) | — | — | 40 | 70 | J (`EVENT=cycles`, `MODES`) |
| `plot.py` | 785 | 486 | 449 | 492 | lineage T→K→X→J in docstrings; `esc`/`text`/`FONT` identical ×4; `style`/`write_svg` identical K/X; `split`/`listing` identical K/X/J; drift 477-955 |
| `build.sh` / `fetch.sh` | 73 / 47 | 68 / 51 | 102 / 103 | 159 / 136 | `want()`/`step()` identical ×4; Zig block (`ZIG_VERSION=0.16.0`) identical ×4; `fetch()` identical K/X/J |
| `gen-inputs.py`, typed scripts, `reference.py` | 139, `typed.sh` 79 | 152, `typed.sh` 65 | 490, `run-typed.sh` 82 | 395, `reference.py` 178 | format-specific |
| other | `beef.sh` 71, `lookup.sh` 92, `modes.sh` 45, `update-tomlbeef.sh` 57 | | | | T-only |
| vendored | `beef/src/beefy/StructuredData.bf` 2,790 + `DisposeProxy.bf` 46 | | | same files | identical copies in T and J |

Load policy drift: X (`run.sh:39/267`, `run-typed.sh:24/82`) and J (`run.sh:52/479`) print `/proc/loadavg` and never
wait ("this machine never is" quiet, J and FormatCore AGENTS.md); **T's `update-tomlbeef.sh:15-16` refuses at load > 2
unless `FORCE=1`**. Harness languages: T 9 (beef c cpp cs go java js rust zig), K 10 (no beef dir, + knus, python),
X 10, J 12 (+ lua, perl).

### B4. Windows and AGENTS.md

- The Windows wrapper (a local Proton setup, not a published repository): `beefbuild-win` 39 lines (Proton's wine,
  `WINEPREFIX=$ROOT/prefix`, pre-started `wineserver`, `-workspace=Z:<PWD>`), `bin/pwsh-win` 37, the prefix,
  downloads, smoke checks. K/X/J AGENTS.md (K:10-11, X:11-12, J:11-12) and status baselines (K :15 79/79, X :18
  256/256, J :17 281/281) use it; **TomlBeef's AGENTS.md:8 and architecture.md:11 still call Windows deferred**, and its
  status has no Windows row. All five `BeefSpace.toml` carry the four `[Configs.*.Win64]` (`Toolset = "LLVM"`) blocks.
  No repo has a script around it: it is run by hand, twice (Test, TestRelease).
- AGENTS.md: T 415 (09-29, the long original), K 166, X 171, J 185, FormatCore 184 (J's copy; its first bullet still
  says "a JSON (RFC 8259) parser and writer" and points at `docs/plan.md`). K/X/J are a compressed rewrite of T: 99
  non-blank lines verbatim in K, X and J, 59 in all four; the rest differ by type/file name substitution (gotcha
  examples, lldb paths, `Result<T, XParseError>`). Rules that drifted: benchmark bullet (X cites `measure.sh` ±5%, J
  ±10%), "run scripts with bash" and "disk space" only in J/FormatCore, Comptime gotchas (K 94-97, J 100-105),
  Lambdas and Windows Debug (exit 2147483651 = leak) only in J.
- `docs/status.md` baselines: same `| Check | Expected result |` table and row order everywhere (`beefbuild -test`,
  TestRelease, suites Debug then `BIN=` Release, leaks, Windows, fetch, bench). Counts: T 324, K 79, X 256, J 281.

### B5. What FormatCore can hold

| Item | Form | Per-repo parameters | Lines saved | Effort | Notes |
|---|---|---|---|---|---|
| `tools/test-leaks.sh` | script called with the sibling's workspace (`-workspace=`), or copied by a sync script | none (`CONFIG`, `LSAN_LIB` env exist) | 192 | 0.5 h | trivial |
| `tools/test-lib.sh` (sourced) | bash library: BIN check, tmpdir/trap, log, timeout/crash classes, golden + expected-failures, MODES, footer | modes table, flags | ~40-80 per runner | 1-2 days | refactor each runner; keep its output text |
| `tools/test-roundtrip.sh` | generic driver over `path<TAB>flags` | see B1 | ~150 | 1 day | T keeps its semantic roundtrip separately |
| `tools/test-codegen.sh` | X's script with `WS`/fixtures as arguments | workspace, fixtures file | 44 per adopter | 1 h | also used by FormatCore's toy format |
| `tools/win-test.sh` | wraps `beefbuild-win -test` and `-config=TestRelease`, reports both | workspace | new | 1 h | closes T's Windows gap |
| `FormatCore.Bench` (Beef, test/bench helper project, not in the core lib) | `Measure`, `Measurement`, `PrintResult`, `ReadInputs`, `ReadStdin` | none | ~6 × 60 | 1 day | testers and bench harnesses depend on it; keeps the rule in one place |
| `FormatCore.Fuzz` (same helper project) | seeded byte mutator with token alphabet, rounds/report loop | alphabet, compare delegate | ~80 ×2 | 1 day | X/J only today |
| `bench-kit/c/bench-core.h` + per-format `check.h` | timing core, `print_result`, file/directory/ndjson/padding readers | check struct | ~70 ×4 | 0.5 day | harnesses include by relative path or a fetched copy |
| `bench-kit/measure.sh` | one `settle()` (tolerance, converged-only, max runs as variables), `maxrss.c` | tolerance | ~50 ×4 | 0.5 day | unify X ±5% and J ±10% (decide one) |
| `bench-kit/merge.sh` | J's + T's `saved_row` | none | ~55 ×3 | 1 h | gives K `ONLY=` merges |
| `bench-kit/instructions.sh` | J's | tester, inputs, modes | ~40 ×2 | 1 h | |
| `bench-kit/fetch-lib.sh`, `build-lib.sh` | `fetch()`, Zig block, `want`/`step`, `is_current`, sha256 | library lists stay | ~40 ×4 | 0.5 day | |
| `bench-kit/svgplot.py` | `esc`, `text`, `style`, `write_svg`, `split`, `listing`, results.md parser | panels, labels, baselines | ~150 ×4 | 1-2 days | largest Python duplication |
| `AGENTS.md` shared block | `docs/agents-common.md` in FormatCore, siblings keep header/footer and either include a pointer or a synced copy | repo header, start-with docs, build/test, references | ~100 ×4 | 0.5 day | agents read only the repo's AGENTS.md: a synced copy (script that rewrites a marked region) is safer than a pointer; fix T's Windows line, X's ±5% rule |

Stays per repo: suite selection, manifests, oracles, golden files, expected-failure lists; tester flag vocabulary and
format code (`TomlTestJson`, `JsonToToml`, `Canonical`, `Numbers`, `Push`, `TrickleStream`, `Osm`, `TypedUi`, `Memory`,
`Mutate` edits); `gen-inputs.py`, `reference.py`, harness sources per language, run.sh library tables and tracks, plot
panels; T's lookup/modes/typed scripts; status tables (schema can be standardized).

How siblings would reach shared scripts: vendored copies refreshed by `tools/sync.sh` with a header naming the source
commit, since a reference into another repository breaks for anyone cloning one repo alone. Beef code reaches
FormatCore as a package (Git) dependency. Vendored copies drift (today's problem) unless a check
(`tools/sync.sh --check`) runs in each sibling's verification baseline. Recommend: Beef helpers as a dependency,
scripts vendored with a check.

Risks: changing benchmark scripts changes published numbers' method (rerun baselines after the switch, one sibling
at a time); the load-policy conflict needs a decision; X and J have active sessions touching run.sh and testers.

Order: (1) test-leaks + win-test + codegen script, (2) AGENTS.md common block (fix T's drift), (3) `FormatCore.Bench`
`Measure` (6 copies), (4) bench-kit merge/measure/instructions, (5) bench.h core, (6) test-lib and roundtrip driver,
(7) plot primitives, (8) fuzz helpers. Siblings migrate T and K first, X and J when their sessions are idle.

---

## Prioritized list

1. **Tooling quick wins**: `tools/test-leaks.sh` (4 identical copies), `tools/test-codegen.sh`, `tools/win-test.sh`; fix
   TomlBeef's stale Windows note. Hours.
2. **Comptime helpers (A-1)** in FormatCore with runtime and fixture tests; migrate K then T. Blocked only on Q1-Q3.
3. **AGENTS.md common block** with a sync check; settle the benchmark load/tolerance rule (T refuses at load > 2, X
   ±5%, J ±10%).
4. **`FormatCore.Bench` Beef helpers** (`Measure` ×6) and **bench-kit** (`merge.sh`, `measure.sh`, `instructions.sh`,
   `bench-core.h`).
5. **Planner (A-2)**: `ValueSpec`/`MemberPlan`/`TypePlan`/`ClaimSet` + toy format + cross-project fixture workspace.
6. **Deferred-body driver (A-3)** for T/K/X (fixes the self-reference compile crash class), `ShowGenerated` everywhere.
7. Test-script library and roundtrip driver; plot primitives; fuzz helpers.
8. Shared field attributes (A-4), after Q5 and a naming decision.

## Open questions

- Q1-Q11 above (A9), for the cross-project experiments; Q2 (what "current project" means for `Type.TypeDeclarations`
  inside FormatCore) and Q3 (generic attribute parameters at comptime) decide between a framework and a helper kit.
- Inheritance model: adopt J's whole-chain virtual methods everywhere, or keep T/K/X's per-level `new` methods with
  virtual claim lists? The planner supports both; the emitters differ.
- Enum case naming: as declared (T), through the type's naming (K, X) or the field's (J)? One rule for the shared
  `EnumEmit`.
- One `NamingPolicy` replacing the four enums (breaking, allowed pre-1.0), with KDL's kebab default kept?
- Should TOML adopt the shared nesting (`List<List<T>>`, `T?`, integer/enum dictionary keys), closing its O9?
- Shared runtime bind messages ("outside the range"): adopt one text, or leave each format's (J's names the number's
  text and uses JSON Pointer paths)?
- Scripts by path versus vendored with a check; Beef helpers as a separate `FormatCore.Testing` project so the core
  library carries no bench code?
- Benchmark rule: one tolerance (±5% or ±10%), converged-only, and the load policy, before sharing `measure.sh`.
- K has no `merge.sh` and no beef harness directory: adopt the shared ones when bench-kit lands?
