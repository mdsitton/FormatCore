# Beef across project boundaries: experiments and rules

How Beef behaves when the code the four format libraries share moves into a separate library project
(FormatCore), measured with small workspaces under `experiments/`. Each section gives the experiment, the
measured result, the explanation from the compiler source, and the rule for FormatCore's design. The
summary table of rules and the blockers are at the end.

- Toolchain: BeefBuild 0.43.6, Linux64, LLVM codegen; Windows through the Windows BeefBuild under
  Proton (`beefbuild-win`). Source references are to the Beef source at `09e4aa68`
  (https://github.com/mdsitton/Beef, branch `fix/posix-spawn-workingdir`: upstream
  https://github.com/beefytech/Beef plus one fix); `IDEHelper/Compiler/` is abbreviated `C/`,
  `IDE/src/` as `IDE/`.
- Performance figures are user-space instructions (`perf stat -e instructions:u`), never time: two runs
  that differ by five passes over a 100 MiB buffer, so startup and buffer filling cancel out. They are
  deterministic: every rerun gave the same three digits.
- In the experiments, "Core" stands for FormatCore, "FormatLib" for a format library (XmlBeef etc.) and
  "App" for the end user's project. Run shell scripts with `bash`.

## Q1. Generics, `[Inline]` and constant tables across projects

**Experiment:** `experiments/hotloop` (projects Core and App) and `experiments/hotloop-mono` (the same
sources in one project, through symlinks). An 8-byte SWAR scan for `<`, `&` and bytes below 0x20 over a
100 MiB buffer with a stop every 61 bytes; each mode is a `[NoInline]` pass function in App so its loop
can be read with `objdump`. `bash experiments/hotloop/measure.sh [binary]` prints instructions per byte.
`ReleaseNoLTO` is a workspace config that is Release with `LTOType = "None"`.

| Mode | What | Release (ThinLTO) | ReleaseNoLTO |
|---|---|---:|---:|
| a-same | scan in the same App type as the loop | 3.571 | 3.807 |
| a-type | scan in another App type (ordinary method) | 3.571 | 4.137 |
| **b** | scan in Core (ordinary method), called from App | **3.571** | **4.137** |
| a-inline | App `[Inline]` wrapper around the body | 3.903 | 4.303 |
| **d** | Core `[Inline]` method, called from App | **3.903** | **4.303** |
| c-mono | App generic `AppReader<AppCursor>` (control) | 3.571 | 4.137 |
| **c** | Core generic `ReaderCore<TCursor> where TCursor : ICursor` on App struct `AppCursor` | **3.571** | **4.137** |
| c-mono-inline | App generic, cursor `Scan` is `[Inline]` | 3.903 | 4.303 |
| **c-inline** | Core generic, App cursor `Scan` is `[Inline]` | **3.903** | **4.303** |
| e-app | App-local scan, App `const uint8[256]` table in the byte loop (control) | 3.262 | 3.766 |
| e-const | Core generic method, stop bytes as `const` generic params (`ScanConst<const '<', const '&'>`) | 3.571 | 4.137 |
| e-static | Core `StopScanner<TStops> where TStops : IStopSet`: stop bytes and `IsStop` (const table) as App static interface members | 3.612 | 4.655 |
| e-static-inline | same, the App static members `[Inline]` | 3.480 | 3.915 |
| e-static-table | same as e-static, `IsStop` reading a `static` (mutable) table | 3.612 | 4.655 |
| e-param | Core ordinary method, stop bytes and table pointer as runtime arguments | 3.393 | 3.984 |
| e-param-inline | same, Core method `[Inline]` | 3.480 | 3.915 |

The single-project control (`hotloop-mono`) gives **the same number in every cell**, and its Release
and ReleaseNoLTO binaries have **byte-identical machine code** to the two-project build (normalized
`objdump -d` diff: only the file name line differs; `.text` 1,106,577 bytes in both Release builds).

Disassembly (Release): every mode compiles to the same word loop, all constants as immediates, no calls.
`ReaderCore<AppCursor>.CountStops` (Core generic, App cursor, App's ordinary `Scan`) is:

```
movabs $0x3c3c3c3c3c3c3c3c,%r8      ; '<' * ones, folded from the App cursor
movabs $0x2626262626262626,%r9      ; '&' * ones
movabs $0x202020202020201f,%r10
loop: mov (%rdi,%r11,1),%r14 ; xor ; xor ; sub ; sub ; and ; sub ; and ; or ; not ; test %rcx,%r15 ; je loop
```

The table-driven modes load the App table at a fixed address in the byte loop (`cmpb $0x0,0x2540c0(%r11)`),
including e-param, whose table and stop bytes are runtime arguments of a non-inline Core method: ThinLTO
inlined it and propagated the constants. Without LTO the picture is the one the column shows: b, c,
e-const and e-param `call` into Core once per stop, and e-static calls `AppStops.get__S1`,
`get__S2` per scan and `AppStops.IsStop` **per byte** of the byte loop (4.655); `[Inline]` on the App
static members removes all of it (e-static-inline, 3.915, no calls). Windows (Release, LLVM toolset)
links the same per-type objects (`Core_ReaderCore_App_AppCursor.obj`) with a ThinLTO cache, and the
PDB-located `PassGeneric` contains no calls and the folded immediates.

**Explanation.**
- The compilation unit is the whole workspace: one compiler pass sees every project, and every type
  gets **its own LLVM module** (`C/BfContext.cpp:153` `AssignModule`, one `BfModule` per type instance,
  `mProject` = the declaring type's project, lines 184-214). A specialization like
  `ReaderCore<App.AppCursor>` is a type of its own, compiled into `build/<cfg>/Core/Core_ReaderCore_App_AppCursor.o`
  (Core's directory, because `mTypeDef->mProject` of the generic definition is Core). The link line puts
  all projects' objects into one executable (`App.build.txt`); a BeefLib is not a separately compiled
  library.
- So the boundary that matters for inlining is the **type (module) boundary, not the project
  boundary**: a-type (another App type) costs exactly what b (a Core type) costs in both configurations.
- `[Inline]` methods are generated into the calling module whatever project declares them
  (`C/BfModule.cpp:14877-14920`, `ReferenceExternalMethodInstance` queues an `mInlineMethodWorkList`
  request for the caller's module and marks the function `alwaysinline`).
- Release defaults to ThinLTO on Linux and Windows and to **no LTO elsewhere** (macOS):
  `IDE/BuildOptions.bf:14-19` (`LTOType.GetDefaultFor`). The Release objects are LLVM bitcode, linked
  with `-flto=thin` and a `ltocache`; ThinLTO inlines across modules, which is why the ordinary-method
  modes equal the same-type mode under Release. A config whose name contains "Release" gets these
  defaults (`IDE/Workspace.bf:853`), so `TestRelease` does too.
- Generic interface calls on a struct type parameter are static calls on the specialized type (no
  boxing, no vtable); whether they are then inlined is the same module question as above.
- A module's codegen options come from its project (`C/BfModule.cpp:4160-4180`, `GetModuleOptions`),
  so per-project overrides of Core (SIMD, FMA, opt level) would also apply to `ReaderCore<AppType>`
  compiled for App. None of the four siblings sets any; FormatCore should not either.
- The `[Inline]` modes are 0.33 instructions/byte *worse* than the ordinary-method modes in both
  configurations and in both workspace layouts: forcing inlining in the front end gives LLVM a loop
  with one more `mov`/`lea` per word than the inliner's own choice. That is code shape, not the
  project split, but it means `[Inline]` is not free: measure it.
- Static interface members (`static bool IsStop(uint8 b);` in `IStopSet`, called as `TStops.IsStop`)
  and `const` generic parameters (`where S1 : const uint8`) both work across projects and constant-fold
  fully under ThinLTO.

**Rules.**
- Put a hot loop's generic in FormatCore freely: `Reader<TCursor> where TCursor : ICursor` specialized
  on a sibling's struct is the same machine code as the sibling's own copy.
- Mark every small method that a hot loop calls across a *type* boundary `[Inline]` (cursor `Scan`,
  static stop-set members, class-table lookups), whichever project it is in. ThinLTO covers it on
  Linux/Windows Release, but not Debug, not a build with LTO off, and not macOS Release.
- Hand a sibling's constants to FormatCore code as static interface members (`[Inline]`) of a struct
  type parameter, or as `const` generic parameters for scalars; both keep immediates and the constant
  table. Runtime parameters to a non-`[Inline]` FormatCore function only fold under LTO: avoid them on
  hot paths.
- Never rely on a project split to *prevent* inlining or to change codegen; never give FormatCore
  per-project codegen overrides.
- Verify each migrated hot path in the sibling with its instruction counts (and a `ReleaseNoLTO`-style
  config when a cross-type call is on the hot path); compare against the sibling's numbers before the
  move, not against the estimate here.

## Q2. `internal` across projects

**Experiment:** `experiments/internal` (Core, FormatLib depending on Core, App depending on FormatLib
only); `bash experiments/internal/run.sh` builds once per case.

| Case | Result |
|---|---|
| App uses Core's public API (App names only FormatLib) | OK: dependencies are transitive |
| Core's own `GenericHelper` uses `Shared.Internal` without `using internal Core;` in its file | **error**: even inside Core |
| App uses `Shared.Internal` without `using internal Core;` | error |
| App with `using internal Core;` uses `Shared.Internal` / `protected internal` member | OK / OK |
| App with `using internal Core;` uses `Core.Detail.DetailThing.Value` (internal, sub-namespace) | OK |
| App declares a variable of `internal class InternalType`, no `using internal` | error |
| App uses `InternalType.Value` or `Core.InternalType.Value` (static member through the internal type), no `using internal` | **OK** (not checked) |
| App `Shared.[Friend]sPrivate` (private) and `Shared.[Friend]Internal` | OK |
| App uses FormatLib's internal member with only `using internal Core;` | error |
| App generic `AppGeneric<T>` uses Core internal without `using internal` | error |
| FormatLib generic using Core internals (with `using internal Core;`), specialized on an App type | OK |

**Explanation.**
- `internal` has no project dimension at all. `CheckInternalProtection` (`C/BfModule.cpp:4128-4155`)
  passes when the *using file's* `using internal` set names the member's namespace (component-wise
  prefix, `BfAtomComposite::StartsWith`, `C/BfSystem.cpp:322`, so `using internal Core;` opens
  `Core.Detail`) or the type. The set is collected per file from `using internal` directives
  (`C/BfDefBuilder.cpp:2632-2636`) and resolved against the namespaces visible to the using project
  (`C/BfModuleTypeUtils.cpp:3663-3690`). Any project that can see FormatCore can open its internals.
- Inside a specialized generic type or method the check is skipped (`C/BfModule.cpp:4130-4134`): the
  unspecialized body was already checked where it was written, so a FormatLib generic keeps its access
  when App specializes it.
- `[Friend]` at the use site (`Type.[Friend]Member`) bypasses private, protected and internal
  (`C/BfModule.cpp:2925-2929` and `3062-3066`). corlib uses it itself (`Type.[Friend]Comptime_...`).
- An internal *type* is only checked where a type reference is resolved
  (`C/BfModuleTypeUtils.cpp:10389-10393`, and not for compiler-synthesized references); the
  `InternalType.Member` path does not hit it.
- Project visibility is transitive: BeefBuild flattens each project's dependency list recursively
  before handing it to the compiler (`IDE/IDEApp.bf:10821-10829` and `GetDependentProjectList` at
  12026). A user of XmlBeef sees FormatCore's public types without naming FormatCore.

There is no "friend assembly" or sibling-only visibility: `internal` is opt-in for any reader,
`[Friend]` opens everything, `protected internal` is `protected` or `internal`.

**Rules.**
- Use `internal` in FormatCore for "not supported API, may change": the siblings write
  `using internal FormatCore;` in the files that need it; end users who do the same are on their own.
- Never treat `internal` (or private) as a security or encapsulation boundary, and never make a
  sibling's correctness depend on users *not* reaching an internal.
- Every FormatCore file that touches FormatCore internals needs `using internal FormatCore;` too
  (the AGENTS.md gotcha holds across files of the same project).
- Prefer a sub-namespace (`FormatCore.Detail`) for implementation details that the siblings should
  not need either; it is a naming signal, not a barrier (`using internal FormatCore;` covers it).
- Do not depend on internal *types* being hidden: declare them `internal` for intent, but check
  member access, not type access.

## Q3. Comptime code generation across projects (FormatCore → format library → user project)

**Experiment:** `experiments/comptime`: Core (stand-in for FormatCore), FormatLib (depends on Core),
UserLib (depends on FormatLib), OtherLib (depends on FormatLib; unrelated to App), App (depends on
FormatLib and UserLib). FormatLib's `[XObject] : IComptimeTypeApply` forwards to `XCodeGen.Emit`,
which calls Core's generic `Planner<XFormat, XElementAttribute>.Plan(type, plans)`, which calls
`CoreChecks.CheckSupported` and fills `List<MemberPlan>` with Core-allocated objects; FormatLib
describes, visits and frees them, then `Compiler.EmitAddInterface`/`EmitTypeBody` on the App type.
Each project declares one `[Converter(typeof(int))]` class; Core's `CoreRegistry` lists them with
their `TypeDeclaration` flags. `bash experiments/comptime/run.sh` builds, runs and builds the
failure cases; `experiments/comptime-exclusive` reuses Core and FormatLib with a single dependent.

Output (Debug and Release, Linux and Windows identical), abridged:

```
type=App.Point format=X planner-v1 plans:[x=element(via XElementAttribute) why=attribute label=child ] visited=3 PlanCache.sPlans=1
  ProjectName@FormatLib=FormatLib ProjectName@Core=Core CallerProject@Core=App
  decls:[UserLib…{Dependent Sometimes} App…{Dependent Sometimes} FormatLib…{Cur Always Sometimes} Core…{Dep Always Sometimes} OtherLib…{Dependent Sometimes}]
type=App.Box<int> …   type=App.Box<float> …   type=UserLib.LibThing … CallerProject@Core=UserLib (same decl flags)
Core.CoreDirectAttribute.ApplyToType on App.Direct CallerType=App.Direct
  decls:[UserLib…{Dependent Sometimes} App…{Dependent Sometimes} FormatLib…{Dependent Always Sometimes} Core…{Cur Always Sometimes} OtherLib…{Dependent Sometimes}]
Mixin in App.Point (generated code: System.Compiler.Mixin(Core.CoreRegistry.DescribeAsCode())):   Core…{Cur …}  (as above, current = Core)
Mixin of an emitted App.Point entry ([Comptime] static String DeclsCode_() emitted into App.Point, then Compiler.Mixin(DeclsCode_())):
  decls:[UserLib…{Dep Always Sometimes} App…{Cur Always Sometimes} FormatLib…{Dep …} Core…{Dep …} OtherLib…{}]
Mixin of an emitted UserLib.LibThing entry:
  decls:[UserLib…{Cur …} App…{Dependent Always Sometimes} FormatLib…{Dep …} Core…{Dep …} OtherLib…{}]
comptime-exclusive (App is FormatLib's only dependent): App…{Dependent Always Sometimes}
```

Answers, by question (the survey's Q1-Q11 in `docs/survey-typed-and-tooling.md` included):

- **Attribute in Core applied in App** (`[CoreDirect]` with `IComptimeTypeApply`, `[CoreInit]` with
  `IOnTypeInit`): works. **Three-project chain** (survey Q1): FormatLib's `ApplyToType` calls Core's
  `[Comptime]` generic methods, which call `Compiler.EmitTypeBody`/`EmitAddInterface` on App's type:
  works. Build order needs nothing: the workspace is one compilation.
- **What is "current" for `TypeDeclaration.DeclaredInCurrent`/`DeclaredInDependency`** (survey Q2):
  the project of the type that declares the **entry point of the comptime evaluation**, never the
  project of the code making the query and never (unless the entry point is in it) the user's project.
  - In `[XObject]`'s `ApplyToType` the entry is FormatLib's attribute, so current = FormatLib, whether
    the `TypeDeclarations` loop runs in FormatLib or in Core (identical flags above).
  - For Core's own attribute, current = Core.
  - For generated code `Compiler.Mixin(Core.CoreRegistry.DescribeAsCode())`, the entry is Core's
    method: current = Core.
  - For a `[Comptime]` method **emitted into the user's type** and mixed in from there, current = the
    user's project (App, or UserLib for UserLib's type): App's and UserLib's converters are
    `Cur`/`Dep`, OtherLib's are not visible at all.
  - Source: `CeContext::GetReflectTypeDecl` takes `curProject` from
    `mCurModule->GetActiveTypeDef()->mProject` (`C/CeMachine.cpp:4122-4132`); the flags come from
    `BfProject::GetDependencyKind` (`C/BfSystem.cpp:1194-1227`) in `CreateTypeDeclData`
    (`C/BfModule.cpp:6797-6830`): `Dependency` → Dep + Always; a project depending on current →
    Dependent, plus Always only if *every other* project depending on current also depends on it
    (`Dependent_Exclusive`), else only Sometimes (`Dependent_Shared`).
  - Consequence for the existing siblings (read-only, not changed): XmlBeef's converter and subtype
    lookups (`XmlSerializerPlan.bf:703,728`; KdlBeef, JsonBeef, TomlBeef likewise) filter
    `DeclaredInCurrent || DeclaredInDependency || AlwaysVisible` from inside the attribute's
    `ApplyToType`, i.e. relative to XmlBeef. A user project's declarations pass only through
    `AlwaysVisible`, which holds only while the user project is the **only** project in the workspace
    depending on XmlBeef (`comptime-exclusive`). Add a second dependent (a test project, a user
    library using XmlBeef: here UserLib and OtherLib) and the user's converters become `Sometimes`:
    silently not found. And `Dependent` cannot tell the user's project from an unrelated one (App and
    OtherLib get identical flags).
  - `Compiler.CallerProject` and `Compiler.CallerType` at comptime are the type being processed
    (`App`, `App.Direct`) (`C/CeMachine.cpp:9076-9081`, `mCallerTypeInstance`); `Compiler.ProjectName`
    is the project of the code that names it (`C/BfModule.cpp:16150`). Neither changes the
    `TypeDeclarations` flags, and a `TypeDeclaration` does not expose its project.
- **Generic comptime over attribute types** (survey Q3): `field.HasCustomAttribute<TRoleAttr>()` and
  `field.GetCustomAttribute<TRoleAttr>()` with `TRoleAttr` a type parameter of a Core generic, supplied
  by FormatLib (`XElementAttribute`), work; reading the attribute's data generically goes through an
  interface constraint (`where TRoleAttr : Attribute, IRoleAttribute`, `roleAttr.Role`). **Static
  interface dispatch at comptime** works: `Planner<TFormat, …> where TFormat : IMappingFormat` calls
  `TFormat.AssignRole(field, role)` and `TFormat.FormatName`, implemented by FormatLib's `XFormat`.
- **Plans across the boundary** (survey Q4): `new MemberPlan()` in Core, virtual `Describe` and
  `IPlanVisitor` dispatch from FormatLib, `ClearAndDeleteItems!` in FormatLib: works.
- **Shared attributes** (survey Q5): Core's `[SerialName("why")]` (a `String` member) read by Core's
  planner from App's field: `why=attribute`. Works.
- **Static fields at comptime** (survey Q6): `PlanCache.sPlans` is 1 for every type: statics do not
  persist across evaluations. Each attribute application gets its own context
  (`C/BfModuleTypeUtils.cpp:2627-2629`), and `CeMachine::ReleaseContext` clears static fields and the
  heap (`C/CeMachine.cpp:11315-11327`); every `Compiler.Mixin` evaluation is a separate evaluation too.
  A plan cache across `ApplyToType` and the mixins is not possible: re-plan, or emit the plan into the
  type as data.
- **Incremental rebuild** (survey Q7): changing a `const` in Core's generic planner (`Version`) and,
  separately, the body of `MemberPlan.Describe`, then running `beefbuild` again regenerated App's and
  UserLib's code in both cases (the edit was seen in the output). Not stale.
- **Binary size** (survey Q8): Release: no symbol of `Planner`, `CoreRegistry`, `CoreChecks`,
  `MemberPlan`, `XCodeGen`, `XFormat` or the visitor (0 matches); `Core.Naming.Kebab`, used at comptime
  by FormatLib and at runtime by App, is in the binary once. Debug keeps `CoreRegistry`'s type data
  (it is named in emitted mixin code); nothing else.
- **Error location** (survey Q9): `Runtime.FatalError` two frames into Core
  (`ApplyToType` → `XCodeGen.Emit` → `Planner.Plan` → `CoreChecks.CheckSupported`) is reported at the
  user's attribute: `ERROR: Unable to comptime FormatLib.XObjectAttribute.ApplyToType(System.Type type)
  at line 36:1 in …/App/src/Program.bf  [XObject]`, followed by the message and the full comptime
  stack with file:line of each frame. A fixture grep on the message works.
- **Windows** (survey Q10): identical output through `beefbuild-win -run`.
- **Generic user types** (survey Q11): `[XObject] class Box<T>` gets `ApplyToType` once per
  specialization (`Box<int>` and `Box<float>` have their own plans) **and once for the unspecialized
  `Box<T>`**, whose field type is the generic parameter: the `FIXTURE_GENERIC_PARAM` case
  (`FatalError` on `field.FieldType.IsGenericParam`) stops the build at `[XObject]` on `Box`.
- **`GetFields` includes inherited fields, System.Object's too**: a class's list contains
  `mClassVData` (and `mDbgAllocInfo` in Debug). Its type differs by configuration: the planner saw a
  primitive in Debug and a pointer in Release, so an "unsupported field type" check passed in Debug and
  failed the Release build. Filter `field.DeclaringType` (the siblings already do).
- **Crash:** an `ApplyToType` that emits an `[OnCompile(.TypeInit), Comptime]` method into the user
  type (to re-enter comptime from the user's project) **crashes BeefBuild** (exit 139, segfault), even
  with a trivial body (`DEFER`, `DEFER DEFER_SIMPLE` in `run.sh`). The emitted `[Comptime]` method
  called through `Compiler.Mixin` (above) is the working form.

**Rules.**
- Build the typed-mapping framework as a shared generator in FormatCore: generic `[Comptime]` planners
  over the format (`TFormat : IMappingFormat`, static interface members) and the format's attribute
  types work across the chain. Keep each format's attribute (the `ApplyToType` entry point) in the
  format library.
- Never filter `Type.TypeDeclarations` from inside `ApplyToType` (or a FormatCore method it calls)
  expecting "current" to be the user's project. For lookups that must be relative to the user's
  project (converter registry, subtypes for `[XmlChildren]`-style dispatch), emit a `[Comptime]`
  method into the user's type and evaluate it with `Compiler.Mixin` from emitted code: there,
  `DeclaredInCurrent || DeclaredInDependency` is exactly "the user's project and what it depends on"
  (and excludes unrelated projects). Do not use `AlwaysVisible`/`DeclaredInDependent` to mean "the
  user's project".
- Report the siblings' current `AlwaysVisible` dependence as a latent bug (multi-dependent workspaces);
  fixing it is part of the migration, done in each sibling.
- Never keep state in static fields across comptime evaluations; pass it explicitly or emit it.
- Raise build errors with `Runtime.FatalError` anywhere in FormatCore's comptime code; the location is
  the user's attribute. Keep messages self-contained (type and member names), since fixtures grep them.
- Planners must handle generic-parameter field types (the unspecialized pass) without failing: emit
  generic code or defer the check to the specialization.
- Always skip fields whose `DeclaringType` is not the type being planned (or walk the base chain
  deliberately); never let `System.Object`'s fields into a plan.
- Never emit `[OnCompile]` methods from `ApplyToType` (compiler crash).
- Dual-use helpers (naming, literal escaping) are ordinary methods; comptime-only code is `[Comptime]`
  and costs nothing at runtime.

## Q4. Dependency mechanics: Path, Git, diamonds, locks, transitive dependencies

**Experiment:** `experiments/deps`. `bash experiments/deps/setup.sh run` creates a local bare
repository `remote/FormatCore.git` (Core in `/Core`; tags `v1.0.0`, `v1.1.0`, `v2.0.0` with
`CoreVersion.Value` 1, 2, 3, later `v1.2.0` = 12 on a branch), a library repository `remote/LibA.git`,
and workspaces where App depends on LibA and LibB, which depend on Core by
`{Git = "file://…/FormatCore.git?path=/Core", Version = …}`. App never names Core.

| Workspace | Constraints | Result |
|---|---|---|
| compat | LibA `"1.0"`, LibB `"1.1"` | one Core, `v1.1.0`, all three see Core 2; lock written |
| compat, after tagging `v1.2.0` | | still `v1.1.0` (lock kept) |
| compat, lock deleted | | re-resolved to `v1.2.0` (12) |
| conflict | LibA `"~1.0"` (<1.1), LibB `"2.0"` | **builds**, one Core `v2.0.0` (3), `WARNING: Project 'LibA' has version constraint '~1.0' for 'Core' which is not satisfied by selected version 'v2.0.0'` |
| nover | no `Version` | `Tag = ""`, hash of the default branch head |
| override | workspace lists `Core = {Path = "../remote/work/Core"}` | the local checkout wins for both libraries; no clone, no lock |
| gitchain | App → LibA by Git (`"1.0"`) → Core by Git | both resolved and **both locked in App's workspace lock** |

Lock file (`compat/BeefSpace_Lock.toml`):

```toml
[Locks.Core.Git]
URL = "file:///…/experiments/deps/remote/FormatCore.git?path=/Core"
Tag = "v1.1.0"
Hash = "e3313f7c3dcc5ae04f6db9d0751efad3ffe34f77"
```

**Explanation.**
- **Project names are the identity.** When a dependency is loaded, `IDEApp.AddProject`
  (`IDE/IDEApp.bf:3334-3350`) returns the workspace's existing project of that *name* if there is one;
  the dependency's Git URL or path is then ignored (only its version constraint is recorded). So a
  diamond yields one copy, and a workspace `[Projects]` entry overrides every library's Git spec.
- **Version choice:** constraints for the same URL are pooled (`PackMan.UpdateGitConstraint`,
  `IDE/util/PackMan.bf:629`); the highest tag matching **any** constraint wins
  (`IDE/util/PackMan.bf:718-770`), then a project whose constraint it violates gets a warning
  (`IDE/Project.bf:2432`), not an error. (The documentation's "satisfies the most constraints" is not
  what the code does.)
- **Locks** are per workspace, keyed by project name: `Lock.Git(url, tag, hash)`
  (`IDE/Workspace.bf:512-542`); a lock is used only if its URL equals the dependency's URL string
  (`IDE/util/PackMan.bf:435-437`). Clones are shared by commit hash in the managed cache
  (`GetClonePath`, `PackMan.bf:126`; for the Linux package `~/.config/beeflang/BeefManaged/<hash>`,
  `IDE/BeefConfig.bf:225-238`): gitchain reused compat's clone.
- **Transitive dependencies**: loading a project adds its dependencies (`IDE/Project.bf:2201-2209`),
  recursively; the compiler then gets the flattened list (Q2).

**Rules.**
- XmlBeef, JsonBeef, KdlBeef and TomlBeef each declare
  `FormatCore = {Git = "<FormatCore URL>", Version = "<major.minor>"}` in their library's
  `BeefProj.toml`. A consumer declares only the format library; FormatCore comes in transitively and is
  pinned in the consumer's `BeefSpace_Lock.toml`.
- Always use the **same URL string** in all four siblings (a different spelling of the same repository
  splits constraints and invalidates locks).
- Treat a FormatCore minor version as API-compatible: when two format libraries in one workspace
  constrain FormatCore differently, the highest matching tag is chosen for both, and an incompatible
  constraint is only a warning. Keep the siblings on the same FormatCore minor; do not rely on the
  constraint to protect a library.
- The siblings' workspaces use the Git dependency like any consumer; a FormatCore change reaches them
  as a new tag (delete the workspace's lock to pick it up).
- Tag FormatCore releases `vMAJOR.MINOR.PATCH`; an untagged dependency follows the default branch head.
- Never name a FormatCore project after anything a user might also call a project (the name is global
  in a workspace).

## Q5. Name collisions

**Experiment:** `experiments/names` (Core, LibX depending on Core, App depending on LibX);
`bash experiments/names/run.sh`.

| Case | Result |
|---|---|
| N1: `Core.Cursor` and `LibX.Cursor`, App has `using Core; using LibX;`, uses `Cursor` | error: `'Cursor' is an ambiguous reference between 'LibX.Cursor' and 'Core.Cursor'` |
| N2: `App.Cursor` (App's own namespace) and `using Core;` | **error: ambiguous** between `App.Cursor` and `Core.Cursor`: the own namespace does not win |
| N3: `Core.ObjectAttribute` and `LibX.ObjectAttribute`, `[Object]` with both `using`s | error: ambiguous |
| N4: Core's generator emits unqualified `Cursor.Id` into `App.Captured`; App has `App.Cursor` and `using Core;` | error in `$Emit$App:App.Captured`: ambiguous |
| N4_NOUSING: same, App has no `using Core;` | **compiles, binds to `App.Cursor`** (3, not Core's 1): silent capture |
| N5: generator emits `Core.Cursor.Id` into a type with a member named `Core` | error: `Type 'int' has no fields` |
| N5_GLOBAL: `global::Core.Cursor.Id` / a `global::Core.Cursor` field | `Identifier not found` / `Member name expected` |
| N7: App declares `namespace Core { struct Cursor {} }` | error: `The namespace 'Core' already has a definition for 'Cursor'` |

**Explanation.** Emitted code is parsed as part of the target type (`$Emit$App:App.Captured`) and
resolved with the target file's `using` directives and the target type's members in scope; names in
it mean what they would mean if the user had typed them there. Namespaces are global across all
projects of a workspace (N7). The parser knows `global::` (`C/BfReducer.cpp:5924`), but no form of it
resolved here.

**Rules.**
- Emitted code names everything fully qualified (`FormatCore.Detail.Reader`, `System.String`), as the
  siblings already do. Never emit an unqualified type or member name except the target's own members
  and generated locals with reserved-looking names (`_node`, `Gen_`).
- Choose a namespace that no user type plausibly has as a member name: `FormatCore` (not `Format`,
  `Core`, `Text`). Never put FormatCore types in `System` or in a sibling's namespace.
- Give FormatCore's public types distinctive names (`FormatCursor`, not `Cursor`); users import both
  FormatCore and a format library and their own namespace does not take precedence.
- Give attributes format-specific names in the format libraries (`[XmlObject]`, `[JsonObject]`), and
  FormatCore's shared attributes names no format library uses (`[SerialName]` only if no library has
  its own); a short-name clash is a hard ambiguity for every user importing both namespaces (BJSON's
  `[JsonObject]` and JsonBeef's are exactly N3).

## Q6. Build time and code size

**Experiment:** `bash experiments/buildcost.sh 3`: clean builds of `hotloop` (two projects) and
`hotloop-mono` (one project, same sources), user-space instructions of `beefbuild` and its children
(the linker), three runs each.

| Config | Two projects | One project |
|---|---|---|
| Debug, clean | 4.33-4.43 G instructions, 1.26-1.39 s CPU (0.7-0.8 s wall) | 4.33-4.37 G, 1.29-1.41 s CPU (0.8 s wall) |
| Release, clean | 14.97-15.01 G, 4.58-4.77 s CPU (1.8 s wall) | 14.97-15.06 G, 4.55-4.65 s CPU (1.8 s wall) |
| Rebuild after `touch` of a Core file (content unchanged) | 1.79-1.86 G | 1.79-1.86 G |

Release binary: 2,498,536 bytes (two projects) vs 2,498,568 (one); `.text`, `.data` and `.bss` equal,
machine code identical (Q1). ReleaseNoLTO: 1,922,856 vs 1,922,976, same.

**Explanation.** Beef compiles the workspace as one unit with one module per type (Q1); projects only
decide output directories and per-project settings. Splitting adds no compilation units and no link
steps (BeefLib objects are linked directly into the executable).

**Rule.** Split into projects for ownership and versioning only; there is no build-time or size cost
to minimize, and none to gain. Measure build cost only if FormatCore grows comptime work (comptime
runs per user type, Q3).

## Q7. Windows

`experiments/comptime` built and run with `beefbuild-win -run` (Debug, LLVM toolset): output identical
to Linux, including the three-project chain, the `TypeDeclarations` flags and the mixin forms.
`experiments/hotloop` built with `beefbuild-win -config=Release` (LLVM toolset, ThinLTO cache): the same
per-type objects (`Core_ReaderCore_App_AppCursor.obj`, …), correct results for modes b, c and e-static
under Wine, and `PassGeneric` (located through the PDB's `S_LPROC32`) contains no calls and the folded
`0x3c3c…`/`0x2626…` immediates. Instruction counts were not taken on Windows (Wine).

## Q8. FormatCore's cursors under a reader core

**Experiment:** `experiments/cursor-fold` (FormatCore by path, App with a reader core generic over
`IInputCursor` written as the siblings write theirs: the window in fields, `Scan.Until<TStops>` on
locals, `Grow` through `Fill`, resuming after a refill). The same stop-byte scan as Q1 over 100 MiB
(a stop every 61 bytes, no newlines); `bash experiments/cursor-fold/measure.sh [Release|ReleaseNoLTO]`.

| Mode | What | Release | ReleaseNoLTO |
|---|---|---:|---:|
| direct | the scan loop over a plain buffer (control) | 3.459 | 3.656 |
| memory | `ReaderCore<ByteCursor<UncheckedText>>` (no up-front validation) | 3.656 | 3.656 |
| validated | `ByteCursor<PlainUtf8Text>`: `FindInvalid` over the input in Begin, then the scan | 4.093 | 4.093 |
| validate | `Utf8.FindInvalid<PlainUtf8Text>` alone (ASCII input) | 0.438 | 0.438 |
| stream | `BufferedStreamCursor<UncheckedText>` over a MemoryStream, 64 KiB buffer | 6.728 | 6.729 |
| stream-validated | the same with up-front validation | 7.167 | 7.168 |

- The memory cursor's `Fill` folds: without LTO the cursor reader is the direct loop's 3.656 exactly;
  with ThinLTO the control's loop gets the 0.2-per-byte better shape (Q1's code-shape variance between
  functions, not a call: the core has none).
- Validation adds exactly its own cost (0.438 per byte on ASCII, the 32-byte plain-word step).
- The stream's extra ~3 per byte is the copy out of the MemoryStream plus the line counting of every
  dropped byte (16 bytes per step) and, because this input has no newline, a column count over the
  whole dropped region at each refill. Real text has short lines (the column base moves to the last
  line start). This is the siblings' design unchanged (JsonBeef's stream cursor), measured here only
  as a baseline for the sibling migrations, which compare against each sibling's own numbers.

## Summary of rules

| # | Do | Never |
|---|---|---|
| 1 | Put hot generics in FormatCore; specialize on sibling structs (identical code to a local copy) | Expect the project split to change codegen; give FormatCore per-project codegen overrides |
| 1 | `[Inline]` every small cross-*type* call on a hot path (cursor scan, static stop-set members) | Rely on ThinLTO for hot cross-type calls (absent in Debug, LTO-off and macOS Release) |
| 1 | Pass sibling constants as `[Inline]` static interface members of a struct type parameter, or `const` generic params | Pass hot constants/tables as runtime arguments to non-`[Inline]` FormatCore functions |
| 1 | Verify each migration with the sibling's instruction counts (and `[Inline]` both ways: it can cost 0.3 instr/byte) | Assume `[Inline]` is always a win |
| 2 | Use `internal` + `using internal FormatCore;` in the siblings for unsupported API; `FormatCore.Detail` for details | Treat `internal`, private or internal types as a boundary users cannot cross (`using internal`, `[Friend]`) |
| 3 | Shared comptime planners in FormatCore, generic over `TFormat : IMappingFormat` and the format's attribute types; entry attributes in the format library | Keep comptime state in statics; emit `[OnCompile]` methods from `ApplyToType` (compiler crash) |
| 3 | Do user-relative `TypeDeclarations` lookups in a `[Comptime]` method emitted into the user's type, run via `Compiler.Mixin`; filter `DeclaredInCurrent \|\| DeclaredInDependency` there | Filter `TypeDeclarations` inside `ApplyToType` assuming "current" is the user's project; use `AlwaysVisible`/`DeclaredInDependent` to find user declarations |
| 3 | Handle the unspecialized generic pass; skip fields not declared by the planned type | Let `System.Object`'s `mClassVData`/`mDbgAllocInfo` into plans |
| 3 | `Runtime.FatalError` with self-contained messages (located at the user's attribute) | |
| 4 | Siblings depend on `FormatCore = {Git = "<one URL>", Version = "x.y"}`; consumers name only the format library | Different URL spellings across siblings; relying on version constraints to stop an incompatible FormatCore (only a warning) |
| 4 | Release FormatCore changes as tags; siblings pick them up through the Git dependency | Editing the library's Git spec for local work |
| 5 | Emit fully qualified names; namespace `FormatCore`; distinctive type and attribute names | Unqualified names in emitted code (silent capture); short generic names (`Cursor`, `[Object]`) |
| 6 | Split projects for ownership and versioning | Merge or split projects for build time or size (no effect) |

## Blockers and open items

- **No blocker for moving hot code into FormatCore**: specialization, `[Inline]`, constant folding and
  ThinLTO behave identically across projects (Linux measured, Windows checked).
- **Typed-mapping registry semantics need a design change, not a workaround in FormatCore alone**:
  "current" in `TypeDeclarations` is the comptime entry point's project. The working form (an emitted
  `[Comptime]` method in the user type, mixed in from generated code) means converter and subtype
  lookups happen in the mixin stage, not during `ApplyToType` planning. If planning itself needs the
  user-relative registry, it has to move into that mixin stage. The siblings' current
  `AlwaysVisible`-based lookups fail silently in workspaces with two dependents of the format library.
- **BeefBuild crash** (exit 139) when `ApplyToType` emits an `[OnCompile]` method: reproducible with
  `bash experiments/comptime/run.sh` (`DEFER DEFER_SIMPLE`); worth reporting upstream. Avoided by the
  rule above.
- Version constraints do not protect a library (highest matching tag wins, conflicts warn): FormatCore
  needs a compatibility policy (the siblings move FormatCore minors together).
- Not measured: macOS (no LTO by default, so `[Inline]` matters more there), Windows instruction counts.
- The experiments' Git clones are in `~/.config/beeflang/BeefManaged/` (shared cache; deleting the
  hash directories there is safe).
