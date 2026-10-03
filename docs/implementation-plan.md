# Implementation plan: managed ConsoleHost and retained graphical surface

Date: 2026-10-01. This is a proposed implementation sequence, not a capability receipt. [ROADMAP.md](../ROADMAP.md) remains the only status ledger. [The managed UI work order](work-managed-ui.md) defines detailed contracts and gates.

## Outcome and release boundary

Deliver an installed Android APK that opens a managed retained interface, offers two independent PowerShell console sessions and a graphical pane, accepts real keyboard/IME input, runs commands asynchronously, and provides profile repair without clearing storage. Console cells belong to console content only. Graphical applications and services can use the runtime host without constructing a console.

Release is complete only when [R1-R9](../ROADMAP.md#release-apk-preview-finish-line) have same-artifact evidence. Complete terminal emulation, native Edit hosting, Windows presentation and general desktop features are later capabilities. A sub-20-MB APK is a measured target, not a substitute for correctness or an established final size.

## Engineering rules

- PowerShell authors the application and build. SMA handles control-plane events, composition decisions and shell behavior. Repeated parser, buffer, layout, hit-testing, glyph/span and drawing submission paths are explicitly lowered to managed IL or a separately admitted shader/native gate.
- Fixed code is emitted at build time through the existing persisted expression-tree/IL producer. Device-dependent metrics may specialize validated code at runtime; do not defer fixed code to startup. Arbitrary scriptblocks are not automatically persistable methods.
- Reuse pinned Microsoft runtime/SMA facilities and Android platform graphics. No Roslyn, Xamarin, XAML, WebView or new third-party managed UI/parser package. Each dependency needs a named requirement, immutable provenance, digest and measured cost.
- Use Android hardware Canvas for this preview. The shared retained scene owns its state; the platform owns rasterization and presentation buffers. Damage schedules work; submitted hardware frames cover the complete surface. No timer-driven redraw or polling loop.
- Build and package only through setup.ps1. Preserve the single-script release build and existing public step IDs. Generated output stays in the confirmed build write plan. Never import local donor assemblies or uncommitted external code as product input.
- Keep the frozen CellCanvas script unchanged. Its compatibility gates are separate. Preserve gates 2a-2d while refactoring the host, including the established main-thread profile contract.
- Treat pointers, callbacks, JNI references and buffers as owned resources with bounded access and generation/lifetime rules. Catch failures at managed callback boundaries. Recovery handles recoverable startup failures; it does not contain native faults or repair a currently blocked UI thread.
- All acceptance checks listed here are planned implementation work. Build self-checks and device receipts accompany their gate; this document itself executes no tests.

## Baseline to preserve

The console reference implements transcript streams, progress, command-entry/history, width/reflow, packed frames and a reference ring; its declared 63 vectors have prior receipts. These do not establish full terminal-screen semantics or lowered cross-thread synchronization.

The x86-64 hardware Canvas diagnostic has a receipt. Production managed bindings/callbacks and physical-backend hardware presenter receipts remain open. The screen probe executes commands synchronously and is not the production session adapter.

The retained 104-image diagnostic APK is 18,244,452 bytes. Markdown (MarkdownRender, Markdig) entered with that build: Utility cannot be imported without it (step 2.8). Newtonsoft has been in the payload since `cf8e501` and is reached on every engine start (below). The System.Text.Json group entered with the command assemblies in `74038fa`. Step 2 replaces all three; each ships until its own sub-step passes. Historical sizes and receipts must remain labeled with their own artifact.

## Implementation sequence

### 1. Freeze the capability and ownership contracts

**Maps to:** P0, R1-R4. **Inputs:** pinned runtime/SMA/platform metadata, current console reference and work order.

Write the supported command manifest with aliases, providers, formatting, initialization and explicit Android exclusions. Define pane, scene, text-input and session ownership before emission. State message bounds, resource limits, offset units and stale-generation handling. Scope each graphical primitive by the initial console/settings/profile-repair workload.

Planned entrypoint: `scripts/ConsoleHost.ps1`, containing typed composition/emission definitions during development. Keep `modules/Console.psm1` as the reference. Keep diagnostic Profile fixtures separate. The runtime host, graphical controls and basic recovery must load without SMA; introduce assembly boundaries only where necessary to enforce that closure.

**Exit:** reviewed typed contracts, command manifest, dependency map and lowering/measurement table. Reference port inputs are admitted from immutable source with licenses and digests; local mockups remain observations until admitted.

### 2. Repair payload admission and reduce the payload

**Maps to:** command payload repair, R1. **Depends on:** 1.

Three third-party assembly groups serve a small surface:

| Group | Store size | Surface used |
| --- | ---: | --- |
| Newtonsoft.Json | ~701 KiB | SMA `PSConfiguration.cs` only (29 lines; `JObject`, `JProperty`, `JToken`, `JsonSerializer`, `JsonSerializerSettings`, `JsonTextReader`, `JsonTextWriter`, `TypeNameHandling`; `Add`, `Deserialize`, `Property`, `Remove`, `ToObject`, `TryGetValue`, `WriteTo`), plus Utility `JsonObject.cs`, `ConvertToJsonCommand.cs` and `InvokeRestMethodCommand.Common.cs` |
| System.Text.Json, System.IO.Pipelines, System.Text.Encodings.Web | ~827 KiB | Utility `TestJsonCommand.cs` and `WebRequestPSCmdlet.Common.cs` (error formatting) |
| Microsoft.PowerShell.MarkdownRender, Markdig.Signed | ~510 KiB | Utility's Markdown cmdlets |

Source: PowerShell `1481b98f0079f979f658e49a7281024cc754049b`. Newtonsoft is reached on every engine start: the `ExperimentalFeature` type initializer calls `PowerShellConfig.Instance.GetExperimentalFeatures()` (`ExperimentalFeature.cs:136`), whose constructor creates a Newtonsoft `JsonSerializer` (`PSConfiguration.cs:99`).

Replace them with PowerShell-authored code; nothing is written in C#. The same review covers the rest of the payload.

#### Payload review, 2026-10-01

Static metadata of the committed 102-image payload (Newtonsoft included) and the two Markdown images, read from the pinned packages (SHA-512 checked against `lib/manifest.json`), with every facade forward resolved to its implementing assembly and reachability computed from SMA, the three command assemblies and CoreLib. Sizes are estimates: IL-only bytes (metadata, IL bodies, resources) and their deflated size, from the arm64 runtime pack. The method is within 2% of measured store sizes (Newtonsoft 703,407 estimated vs 717,736; the System.Text.Json group 836,320 vs 846,848). This is not a traced run; device probe logs remain the proof.

| Group | Images | Why it ships today | Store | APK |
| --- | --- | --- | ---: | ---: |
| A. Unreferenced | System.Net.WebClient, System.Configuration.ConfigurationManager, System.CodeDom, System.Diagnostics.EventLog, System.Security.Cryptography.ProtectedData, System.Drawing | No payload image references them, directly or through a forwarder. SMA names CodeDom and EventLog only as strings in format data; ProtectedData only in Windows code. In the payload since `cf8e501`. `netstandard` stays: the shipped Unix MMI image and MarkdownRender reference it (an emulator run without it failed in `PSVersionInfo`'s type initializer). | ~206 KB | ~77 KB |
| B. JSON and telemetry | Newtonsoft.Json, System.Text.Json, System.IO.Pipelines, System.Text.Encodings.Web, Microsoft.ApplicationInsights, and the System and System.Xml.Linq facades only these use | The table above; ApplicationInsights: SMA references 11 types and 16 members, although the host opts telemetry out | ~1,949 KB | ~738 KB |
| C. Type identity only | System.Data.Common, System.Transactions.Local (only Data.Common uses it), Microsoft.Management.Infrastructure | SMA's adapter selection tests `obj is CimInstance`, `DataRowView`, `DataRow` (`MshObject.cs:439-449`); the JIT resolves those types to compile it. On the device no object is ever one of them, and MMI's native `libmi` is not shipped, so CIM cannot run. | ~1,350 KB | ~496 KB |
| D1. Legacy code pages | System.Text.Encoding.CodePages | One call at engine start: `Encoding.RegisterProvider(CodePagesEncodingProvider.Instance)` (`AutomationEngine.cs:21`) | ~699 KB | ~499 KB |
| D2. Mail | System.Net.Mail, System.Net.Requests, System.Net.WebHeaderCollection | `Send-MailMessage`; SMA also binds `MailAddress` in the `[mailaddress]` accelerator (`TypeResolver.cs:806`) and CliXml rehydration (`serialization.cs:6693`, `:7315`), so excluding the cmdlet alone removes nothing | ~353 KB | ~155 KB |
| D3. Ping | System.Net.Ping | `Test-Connection` (Management) only | ~42 KB | ~21 KB |
| E. C# runtime binder | Microsoft.CSharp | C# `dynamic` in SMA and Utility: tab completion (19 sites), `Format-Hex`, DSC resource search, `MiscOps.cs`, `enum` value arithmetic (`PSType.cs:1196`). Surface: `Binder.GetMember`, `InvokeMember`, `InvokeConstructor`, `GetIndex`, `Convert`, `BinaryOperation`, `UnaryOperation`, `CSharpArgumentInfo.Create`. Not Roslyn; Roslyn is absent. | ~290 KB | ~129 KB |
| Kept: web stack | System.Net.Http, System.Net.Quic, System.IO.Compression.Brotli | Web cmdlets; decided with HTTPS acceptance | (~854 KB) | (~344 KB) |

A through E total ~4,890 KB of store and ~2,116 KB of APK per architecture, since all of it is IL; Markdown (2.8) adds ~510 KiB of store and ~209 KB of APK (measured with the 104-image build). Estimated APKs after every cut: x86-64 ~15.9 MB (from 18.24 MB), arm32 ~14.9 MB (from 17.23 MB); arm64 needs a current build first. What remains is PowerShell itself: SMA ~13.7 MB of store, CoreLib ~5.6 MB, Private.Xml ~3.0 MB. Trimming methods inside Microsoft's assemblies is not proposed.

#### Cut order

Lowest risk first; the metadata retarget is proven on references with no behavior before it carries behavior. An assembly leaves the payload only at its own sub-step; until then it ships. Each sub-step ends with a build and the startup/liveness receipt on each backend, and records its store and APK delta; a backend without a device stays open for that sub-step.

1. **Remove group A.** Assembly-order and manifest change only. Proof: `-TraceAssemblyProbe` over startup and the declared command workload requests none of them.
2. **Declared command set.** The session exposes exactly the step 1 command manifest, preserving cmdlet/alias/provider contracts, module identity and module initialization; `Send-MailMessage`, `Test-Connection` and the web cmdlets follow that manifest. Microsoft's JSON and Markdown cmdlets stay until 2.5 and 2.8 replace them. Constraint for later exits: `Import-Module -Assembly` enumerates `ExportedTypes` (`InitialSessionState.cs:5567`), which loads every public type, and `ConvertFromMarkdownCommand._conversionType` is a MarkdownRender enum, so loading Utility needs MarkdownRender for that class's layout. The admission mechanism (generated entries, or a 2.3 placeholder for that enum) is chosen when the first such exit needs it.
3. **Metadata retarget, on placeholder types (group C).** The IL-only re-emit (`setup.ps1` `Test-ReadyToRunImage` and its re-emitter) gains a metadata edit: an AssemblyRef and the TypeRefs under it point to an assembly emitted for this project. First use: the `DataRow`, `DataRowView`, `DataTable` family and the CIM types become empty sealed types that are never instantiated, so the adapter tests stay false and `[ciminstance]`-style accelerators resolve to types no object has. The build reads every patched image back and fails if a retargeted AssemblyRef remains or a retargeted member does not resolve. Exit: Data.Common, Transactions.Local and MMI leave the payload.
4. **Telemetry (ApplicationInsights).** Retarget its 11 types and 16 members to inert implementations; the host's opt-out stays. Exit: ApplicationInsights leaves the payload.
5. **JSON core and commands.** A JSON reader/writer authored in PowerShell, its repeated parse/write paths lowered to IL, built on CoreLib's `SearchValues`, `Utf8Parser`/`Utf8Formatter`, `Utf8` and `Rune` (public in the pinned CoreLib) and `BigInteger` from the shipped `System.Runtime.Numerics`. `ConvertFrom-Json`, `ConvertTo-Json` and `Test-Json` as advanced functions under Microsoft's names, producing objects through SMA's own PSObject APIs. Microsoft's cmdlets on the PC are the oracle, never a producer: vectors cover number typing (`Int32`/`Int64`/`Decimal`/`Double`/`BigInteger`), date conversion, `-AsHashtable`, `-Depth` and its truncation warning, duplicate and case-colliding keys, escaping, `-Compress`, enums and error records. Differences are fixed or recorded. Exit: the System.Text.Json group leaves the payload unless the web cmdlets are admitted.
6. **Configuration (Newtonsoft).** The project's JSON assembly (for example `Dev.MansfieldPlumbing.Pwsh.Json`) implements exactly the types and members `PSConfiguration.cs` reaches, backed by the JSON core; SMA's `Newtonsoft.Json` references are retargeted to it. Reads and writes of `powershell.config.json` at both scopes match the oracle. No assembly carries Newtonsoft's identity. Exit: Newtonsoft leaves the payload.
7. **C# runtime binder (Microsoft.CSharp).** The eight factory members are implemented on the standard `System.Dynamic` binders in the shipped System.Linq.Expressions and retargeted. PSObject operands keep binding through SMA's own meta-objects; CLR operands use reflection with C# numeric promotion for the integral and floating types the sites reach. Oracle vectors cover every listed site, including `enum` definitions with explicit, implicit and maximum values. Exit: Microsoft.CSharp leaves the payload.
8. **Markdown commands.** `ConvertFrom-Markdown`, `Show-Markdown` and the Markdown option commands as advanced functions rendering to VT through the console's renderer, scoped by a declared Markdown subset and checked against the oracle for that subset. Utility admission no longer needs MarkdownRender (see 2.2). Exit: MarkdownRender and Markdig leave the payload, and `netstandard` with them (its other referencer, MMI, left at 2.3).
9. **Scope decisions, each with its own receipt.** D1: if the command manifest declares legacy code pages unsupported, retarget `CodePagesEncodingProvider.Instance` to a provider that supplies none; `-Encoding` with a Windows code page then fails as on a runtime without the provider. D2: removing Mail requires a placeholder `MailAddress`, which changes the `[mailaddress]` accelerator and CliXml rehydration; keep it unless that change is accepted. D3: Ping leaves with `Test-Connection`. Web cmdlets: owned implementations, or Microsoft's admitted with their JSON and HTTP dependencies justified in the inventory.

**Compatibility stand-ins.** Legacy .NET types that ordinary scripts still create directly get project-emitted implementations on the current APIs instead of shipping their original assemblies. They live in one project assembly built by `setup.ps1`'s existing persisted-emission path, separate from the gate 2e compatibility assembly (which alone may use `Android.*`/`Java.*` names). First entry: `System.Net.WebClient` (removed at 2.1), covering `DownloadString`, `DownloadFile`, `DownloadData`, `UploadString` and `UploadData` on `HttpClient`, with a vector per method checked against the real type on the PC. Members not implemented fail as missing rather than pretending to work. Resolution trace (PowerShell `149ab5cd`): a type name found in SMA's CoreCLR type catalog first loads its framework assembly; a `FileNotFoundException` there returns null (`CorePsAssemblyLoadContext.cs:185-202`), and resolution then searches every PowerShell-visible assembly, meaning the default load context and assemblies loaded from bytes or files (`ClrFacade.cs:47-75`, `TypeResolver.cs:365-384`). The stand-in therefore resolves when the host loads it at startup, provided the missing framework assembly fails with `FileNotFoundException`; any other exception propagates. That exception type under the store's declining probe is confirmed on a device before relying on it.

Decide retained IL/type/resource closure before reducing assemblies. Account for signatures, inheritance, generics, custom attributes, exception handlers, reflection and initialization. Removals are individual decisions with receipts, not bulk deletions.

**Exit:** the candidate loads SMA and the declared command set with none of the removed groups, behavior compared against the pinned Microsoft implementation, and exact-artifact startup/liveness receipts on all three backends. Record emitted assembly sizes, compressed APK and store deltas. Failure keeps the candidate unproved; do not reuse the older artifact's success claim.

### 3. Complete hardware presenter evidence

**Maps to:** P1, R7. **Depends on:** a buildable candidate from 2 and admitted platform sources from 1.

Replay hardware acquisition, acceleration identity, pixels, clipping, input-triggered redraw, idle behavior, resize and window destruction/recreation. Finish x86-64 (emulator), arm64 (physical device) and arm32 receipts before the next runtime layer is called portable. Unavailable hardware leaves that backend gate open; independent source/design work may continue.

**Exit:** same candidate passes each backend's hardware presenter workload, process-liveness and crash checks. Record acquisition/submission costs as diagnostic baselines, not production performance claims.

### 4. Emit the platform foundation and first frame

**Maps to:** P2, R2/R3. **Depends on:** 1-3.

Use PersistedAssemblyBuilder, the existing expression kit and Add-PersistedMethod verification. Emit JNI/NDK bindings and managed UnmanagedCallersOnly callbacks; cache binding IDs and drawing resources. Replace diagnostic script callbacks for production lifecycle/input/drawing. Define activity generation, window ownership and synchronous teardown; reject stale work.

Register callbacks, return from activity creation and present a basic frame before SMA admission. UI state and drawing submission initially remain on the declared Android thread; blocking command work will have separate worker ownership. A thread touching JNI obtains its own environment through JavaVM. Handle Java exceptions and release local/global references explicitly.

**Exit:** basic graphical controls and status remain usable with controlled missing/failing SMA admission. Window loss and recreation do not touch stale resources. Gates 2a-2d remain intact on each backend.

### 5. Implement retained scene and pane composition

**Maps to:** P3, R3. **Depends on:** 4.

Retain stable nodes with parent/ordered children, logical bounds, visibility, clip, transform, opacity and resources. Lower scene traversal, bounded measure/arrange and hit testing. Start with row/column/overlay layouts, a scroll container, text, buttons and tab chrome. Add paths/images only to the scoped contract; do not build a CSS engine or window manager.

Define focus, pointer capture, popup/menu ordering and pane-contributed action IDs. Accumulate damage and coalesce frame requests. A console frame is one content node; ordinary controls use proportional text and logical coordinates. Inactive panes retain state without unconditional redraw.

**Exit:** create/switch/close two console placeholders and a functional graphical pane; bounds, clipping, focus and retained state behave correctly across resize and lifecycle changes. Measure lowered traversal/submission and idle redraw counts.

### 6. Lower the existing console model

**Maps to:** P3, R3/R4. **Depends on:** 4-5.

Persist the named cell/style/width/transcript/editor/progress/reflow/composition/diff methods. Preserve the reference API where useful, with adapters for the graphical scene. Keep the 63-vector scope distinct from new capabilities. Persistent parser state must survive write boundaries; byte transports also need persistent decoding.

Define frame buffer limits, slot ownership and release/acquire ordering for cross-thread publication. Introduce concurrency only where the producer/consumer contract needs it; plain reference reads/writes are not sufficient evidence. Preserve scroll, selection, copy/paste, pinch, keyboard, pointer and touchpad behavior with explicit coordinate/offset conversions.

**Exit:** reference and emitted implementations pass the admitted vectors and meaningful lowering/chunk-boundary cases; console pixels and gestures work in the retained host. Record composition/reflow/draw costs without interpreted per-cell submission.

### 7. Connect real PowerShell sessions

**Maps to:** P4, R4/R5. **Depends on:** 2, 5-6.

Give each session a worker-owned runspace and pipeline lifecycle. Use version-matched PSHost and stream APIs; validate input before submission. Provide normal formatting, all diagnostic streams, progress, prompt generation, cancellation and bounded interactive-read protocols. Preserve objects until the explicit formatting boundary; do not flatten every result with ToString.

Send bounded events back through the host's blocking/woken event path. Tag events with session/generation IDs. Specify process-global directory/environment effects, reentrancy and session shutdown. Retire the probe's synchronous command execution path from product startup.

**Exit:** actual console commands return output and the next prompt; cancellation, failure, progress and interactive reads leave the UI responsive. Two sessions preserve independent state. Record queue bounds and input-to-visible-output timing.

### 8. Emit the fixed Android bridge and complete text input

**Maps to:** P5, R4/R5. **Depends on:** 4-7; source-scoping may proceed earlier.

Emit the fixed NativeActivity subclass and auxiliary non-drawing input view, keeping NativeContentView. Implement committed/composing text, selection, deletion, nested batch edits, editor actions and required state notifications. Map the focused editor to InputConnection without duplicate hardware/native key delivery. Handle density, font scaling, system bars, cutouts and IME layout changes.

Load the pinned crypto library from Java with the app class loader and admit its required runtime DEX. Forward document results/new intents and safe-start entry. Independently check emitted DEX/signatures/manifest/JNI registration. Scope accessibility forwarders and semantic node/actions against pinned source rather than inventing a generic Java framework.

**Exit:** real phone text input and clipboard work in the console and graphical text control; hash/TLS representatives run after established initialization. Lifecycle/input and same-artifact command-family receipts pass on all backends. Recoverable initialization failures become UI state; native aborts remain process failures.

### 9. Add essential settings and bounded profile editor

**Maps to:** P3/P6, R3/R6. **Depends on:** 5, 8.

Implement a typed settings hierarchy and adaptive navigation with shared theme tokens. Separate application appearance from terminal font/palette. Preview a working copy; Save validates and atomically persists, Discard restores prior state. Minimum controls: labels, buttons/actions, choice/toggle controls, text fields, swatches and scrolling.

Implement profile text editing with selection, undo/redo, find, UTF-8 load/save and dirty-document handling. Lower repeated document/navigation/layout paths. Use SMA tokens, AST/errors and completion when available. Basic editing must still work without SMA. Microsoft Edit is an algorithm reference, not a commitment to duplicate its entire editor or allocator.

**Exit:** appearance changes and Save/Discard are coherent; a malformed profile can be opened and repaired using the shared graphical surface and real text input. Measure editor behavior at declared document limits.

### 10. Integrate recovery and document storage

**Maps to:** P6, R2/R6. **Depends on:** 4, 8-9.

Write a durable startup-attempt marker before the application profile, clearing it only at a host-observed success point. An incomplete attempt or deliberate safe-start bypasses the profile. Preserve the established main-thread profile contract: a hung profile requires force-stop/relaunch; the marker supplies recovery on that launch. No automatic retry loop or implied fault containment.

Provide profile-free repair session when SMA works and built-in view/copy/export/replace/rollback actions when it does not. Stage replacements, retain previous bytes, validate bounds/encoding/syntax as applicable and promote atomically. Use Android document APIs for selected storage; interruption or picker cancellation must not corrupt the active profile. Diagnostics record relevant stage/error/position without automatically exporting private contents.

**Exit:** missing/malformed/throwing/hanging profiles, failed SMA admission, interrupted startup/import, cancellation and rollback all leave a demonstrated path forward without storage reset.

### 11. Integrate the release graph and installed assets

**Maps to:** P7, R2/R3/R8. **Depends on:** proven emission contracts from 4-10.

After development behind setup.ps1, introduce a ManagedUi node using an unused numeric ID, depending on Select/4; Store/5 depends on ManagedUi. Existing public step IDs stay stable. Selection must stop producing those same UI images. Publish emitted images, identities/hashes and contracts in BuildContext, then validate closure/order before store emission.

Fold developed emitter functions into setup.ps1 for release. Ship default startup independent of a private profile. Pin fonts/icons/licenses and assets; prove clean installation and signed upgrade preserving data. Optional debuggable PC deployment/repair stays explicit and separate from release manifest behavior.

**Exit:** one build script and one producer per artifact; clean installation needs no injected script. Emitted UI artifacts pass metadata/IL/store checks. The release manifest is non-debuggable, and upgrade/recovery retains private data.

### 12. Produce the APK and public evidence bundle

**Maps to:** P8, R1-R9. **Depends on:** 1-11.

Run the declared acceptance workload from the release APK: filesystem/object formatting, JSON both ways, secure strings, hash, HTTPS, progress, failure and cancellation; UI/IME/graphical-pane/recovery/lifecycle cases. Use the same ABI-inclusive APK on all claimed backends. Record process liveness/crash results and cold-start/first-frame/idle/input-latency/size measurements with conditions.

Build reproducibly through setup.ps1 from a clean checkout with pinned inputs and the permanent signing identity. Record revision, options, hashes, notices and SBOM. Run the existing build verification/self-tests and independent oracles at their declared boundaries. README, roadmap checkboxes and release notes must match receipts; scans include wording, secrets/private data, keys and generated output. Publish once the package is complete and reviewed.

**Exit:** every R1-R9 item links to the release artifact or its evidence. This is the APK finish line.

## Subsequent capabilities

1. Addressed terminal model with primary/alternate screens, cursor/save state, wrapping/margins, erase/insert/delete and declared modes; input encoding and capability/color/cursor replies. Keep it separate from transcript reflow. Publish a protocol matrix and prove actual TUIs.
2. Optional native session ABI for create/run/input/output/resize/cancel/destroy and versioned host services. Investigate Microsoft Edit at the audit's pinned revision as an Android .so session; adapt process/global/terminal assumptions. Determine native producer/admission policy in its own project first. Deliver code through installation and prove prompt restoration/liveness. In-process native faults share Pwsh's crash fate; a PTY/process adapter is an alternative, not mandatory for callback hosting.
3. Task/session management pane using stable selection, hierarchy, contributed actions and owned lifecycle events. Broader Android process access is a separately gated platform capability.
4. Admit optional text-parser/diagnostic scripts by immutable source/digest and opt-in bundling; define transport before packaging PC/device wrappers. No donor registry or compiled assembly becomes an implicit dependency.
5. Windows hardware presenter for the same shared contracts, then independently measured 3D/remoting/video or other rendering backends. None is a prerequisite for the Android APK preview.

## Source of design rules

Microsoft: [portable VT boundary](https://learn.microsoft.com/en-us/windows/console/classic-vs-vt), [VT behavior](https://learn.microsoft.com/en-us/windows/console/console-virtual-terminal-sequences), [retained scene semantics](https://learn.microsoft.com/en-us/windows/win32/learnwin32/retained-mode-versus-immediate-mode), [visual composition](https://learn.microsoft.com/en-us/windows/win32/directcomp/basic-concepts), [Terminal appearance](https://learn.microsoft.com/en-us/windows/terminal/customize-settings/appearance).

Google: [hardware Surface contract](https://developer.android.com/reference/android/view/Surface#lockHardwareCanvas()), [JNI lifetime/threading](https://developer.android.com/ndk/guides/jni-tips), [NativeActivity callbacks](https://developer.android.com/ndk/reference/struct/a-native-activity-callbacks), [InputConnection](https://developer.android.com/reference/android/view/inputmethod/InputConnection), [insets](https://developer.android.com/reference/android/view/WindowInsets.Type), [custom accessibility](https://developer.android.com/guide/topics/ui/accessibility/views/custom-views).

Documentation informs requirements; pinned source, independent verification and hardware receipts establish implementation claims. A phase does not pass merely because the emitter and its reader agree.

## Optional device signals

Broader optional commands and ADB follow [their separate work order](work-optional-scripts.md): explicit bundle selection, scripts shipped in the signed APK and resolved by name from `PATH` (`PWSH_USER_SCRIPTS` before `PWSH_APP_SCRIPTS`, no registration), direct device services, and separate ADB protocol/transport/CLI contracts. Convenience aliases go in Profile.ps1 with Set-Alias (for example adb -> Invoke-Adb). Nothing is loaded at startup, so a failed profile or a broken script leaves the shipped commands and recovery available. Start with parsers and device readers/actions. Windows USB ADB already has a PowerShell prototype; Android USB host and wireless pairing require their own admission and receipts. O0-O4 do not extend R1-R9.

Morse and V.21 follow [their dedicated work order](work-device-signals.md): direct torch binding, corrected codec/timing, event-driven light receive, managed DSP and lossless AAudio capture/playback. Console commands precede optional retained panes. This port does not extend the APK preview release requirements.

