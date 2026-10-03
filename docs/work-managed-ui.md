# Work order: managed application UI and console preview

Planned 2026-10-01. `ROADMAP.md` is the implementation status ledger. This
document defines its P0-P8 gates; it records no new device proof.

## Shipping outcome

A newly installed APK presents a hardware-rendered retained interface with
tabbed PowerShell sessions. Commands execute away from Android's main thread;
output, errors, progress and completion return as events. The existing console
editing and gestures remain available. The same interface provides profile
repair when application startup fails, including export to user-selected
storage, replacement, rollback and diagnostics. `setup.ps1` builds the APK and
provides the optional Windows-PC development and repair workflow.

Pwsh remains an application runtime. The retained tab interface is the preview
application, and a terminal is one pane type. Graphical applications and
Android services do not inherit terminal cells, tabs, prompts or a renderer.

## Architecture and ownership

| Component | Owns | Dependency boundary |
| --- | --- | --- |
| Managed runtime host | Component lifetime, event routing, runspace admission, startup guard and recovery state | Can start without SMA, terminal state or graphical UI |
| Android bindings | NDK exports, JNI dispatch, window/input/looper operations and fixed Java forwarders | Platform mechanisms; no terminal or application policy |
| Managed retained UI | Layout, focus, hit regions, scene state, damage and tab controls | Activity-specific client of the host; ordinary coordinates, not cells |
| Managed console | VT/ANSI state, transcript, editor, selection, reflow and terminal draw commands | Pane content; optional to the retained UI and host |
| PowerShell session adapter | Pipeline invocation, host interaction, streams and completion | Attaches to the console; SMA references stay behind this boundary |
| Application scripts | Application behavior and composition | Use admitted platform capabilities; choose their UI or service shape |

Use separate emitted assemblies for platform, retained UI and console code
where that enforces these boundaries. The existing managed host remains the
runtime entry. Exact identities and dependency closure are fixed in P0 and P2;
the admission checks must prove that basic UI and repair paths load with SMA
unavailable. A metadata reference or static initializer must not defeat that
proof. Keep the existing separation between the host entry and methods that
reference SMA (`setup.ps1`, `New-ManagedHostAssemblyBytes`).

All code remains authored in PowerShell. During development, use a standalone
emitter `scripts/ConsoleHost.ps1`, invoked by `setup.ps1`; integrate
its functions into `setup.ps1` before release. Build and APK production always
run through `setup.ps1` and its step graph. The final build remains one script;
the APK contains the emitted assemblies and admitted application assets.

Use project-owned managed names for these components. Android.* and Java.*
managed names remain scoped to the separate frozen-workload compatibility
assembly; ordinary bindings use JNI class names as data, not Xamarin types.

## Execution constraints

- Keep the APK footprint measurable. Use the existing runtime and platform
  graphics APIs; admit a new assembly only for a named requirement that fails
  without it. Record compressed APK and uncompressed store deltas for each
  addition. Do not package the full optional command dependency closure or
  diagnostic fixtures as part of the UI implementation.
- The current Utility import required two Markdown assemblies, adding 209,033
  bytes to the signed x86-64 APK before the telemetry guard. Investigate
  build-generated command registration before treating those assemblies as
  permanent: preserve command, alias, provider and module-initializer behavior,
  and prove startup and the declared command set on devices. This is an open
  optimization, not an established replacement for binary module import.
- Production rasterization is hardware accelerated. Select Android hardware
  Canvas through owned JNI bindings for this preview. Skia is the platform
  implementation beneath that API; no direct private Skia ABI is assumed.
- Retained controls and terminal panes use the same hardware Canvas backend.
  The default diagnostic mode in `modules/AndroidCanvas.psm1` uses `Surface.lockCanvas`; those
  software-rendered receipts are evidence of probe correctness, not proof of
  the production rendering path.
  Its explicit `-Hardware` mode now has an [x86-64 probe receipt](receipt-hardware-canvas-x64.md);
  the production bindings/callbacks still require managed lowering.
- Obtain the surface from the NativeActivity window. Preserve
  `NativeContentView`; auxiliary text-input views attach with `addContentView`.
  There are no Xamarin, WebView, XAML or browser dependencies.
- Request frames only when damage or a platform redraw requires them. Hardware
  Canvas requires full surface coverage on every submitted frame; do not draw
  only changed cells into a newly acquired, unpreserved buffer. Retain scene
  state and reuse admitted resources, then render complete required coverage.
- Name the IL lowering target and measurement for each repeated path before
  implementing it: layout, cell composition, span merging, scene traversal,
  hit testing and JNI draw submission. No SMA dispatch per cell or draw op.
  Device-dependent metrics specialize code only when they become known.
- Native callbacks are owned managed `[UnmanagedCallersOnly]` entries. Bound
  callback state to its activity generation; catch failures at the boundary,
  including failures while reporting another error. No handwritten native
  callback stubs or new emitted machine-code algorithm enters this work.
- UI state belongs to the main looper. Producers publish typed events and
  signal its registered descriptor. No polling, timeout-based frame pump or
  script-block completion callback on an arbitrary worker thread.
- JNI environments are thread-local. Use the borrowed activity environment
  only on its owning thread; attach other threads through the VM when needed.
  Define local/global reference ownership, exception handling and teardown.

## Evidence and source inputs

The existing 63 console vectors and device receipts establish the current
PowerShell model and probe. They do not establish lowered-code equivalence,
hardware rendering, independent interactive sessions or the current command
payload. `scripts/CellCanvas.ps1` is frozen; do not edit it or borrow its
unconditional benchmark frame pump.

Read `modules/Console.psm1`, `modules/AndroidCanvas.psm1`,
`scripts/probes/console-screen/Profile.ps1`, `docs/console-reference.md`,
`docs/work-console-on-device.md`, `docs/host.md` and `docs/ui.md` first.

Design references (observations from working trees, not port inputs):

- A console design mockup: `src/App.tsx` separates tab controls from
  terminal, editor, files and settings content. Its retained configuration
  renderer is UI design evidence, not an Android implementation.
- QuickPS: `gallery/Desktop.ps1`, `src/Desktop.Windows.ps1`,
  `src/D2D.Windows.ps1` and `src/Composition.Windows.ps1` illustrate direct
  platform bindings, native controls, drawing and event dispatch.
- The predecessor Terminal project: `src/CanvasDemo.ps1` calls
  `SurfaceHolder.LockHardwareCanvas`; its canvas path is historical reference.
  It is not byte-identical to the frozen script in this repository.

For Windows Terminal, study the boundaries at commit
`2b5336c1fca1e53ceeaac09710a13c478938cc8d`:

| File | SHA-256 | Evidence |
| --- | --- | --- |
| `doc/ORGANIZATION.md` | `C62DAF9B3923356BF55C1D2BD9834889600C2A87DE84E42FE0C343A3751CFCA8` | Terminal core, control, application UI and renderer responsibilities |
| `src/cascadia/TerminalControl/ControlCore.h` | `6F43497A7A228729CF2B5B2EF1BD41708F68F3B57DF31F8A91B133F40EA5F6DD` | Connection, terminal and rendering separated from UX |
| `src/cascadia/TerminalApp/Tab.h` | `44B986D62B75568B993C68C4D10FD8E3DB7B890B2B68E39F483BACC7E098315C` | Tab owns pane content and focus; actual controls have Windows dependencies |
| `src/cascadia/TerminalApp/Pane.h` | `EF88905266CD6441A9C3AAA324C8BE3C61C1704A0CD169ED29EC556BEB28603A` | Pane layout and lifetime |

These are architecture references, not instructions to port Windows UI code or
replace the console's established parser specification. Existing console
conformance remains governed by `docs/console-reference.md`.

Admit any code port from a pushed immutable revision and pinned digest, into
this repository's own permitted location. Never build, modify or use
uncommitted content from the reference checkouts as product input. Resolve and
pin the reference vectors before running the lowered-model conformance gate;
the current test tool requires an external vector directory.

Android API behavior to trace before implementation includes
`Surface.lockHardwareCanvas`, `Canvas.isHardwareAccelerated`, drawing-state
and clipping operations, JNI, looper wakeup, input connections, document
providers, and activity callbacks. Use exact source revisions and hashes.
The public Surface contract requires full hardware-frame coverage:
[Surface API](https://developer.android.com/reference/android/view/Surface#lockHardwareCanvas()).
Document import/export follows the Storage Access Framework:
[document access](https://developer.android.com/training/data-storage/shared/documents-files).

## Gate order and receipts

Execute P0 through P8 in order. A runtime gate passes first on x86-64, then
arm64 and arm32 before work proceeds to the next runtime layer. Record the APK
and relevant emitted-assembly hashes, inputs, fixture identity, backend,
Android version, markers, observed result, post-result liveness and crash
evidence. Preserve gates 2a-2d; do not claim CellCanvas 2e/2f from these gates.

### P0: pin inputs and freeze the component contracts

Pin `jni.h` in `lib/manifest.json`, derive table slots and target layouts from
the admitted sources, and update the manifest digest in `setup.ps1`. Pin the
Android method/field and Java forwarder contracts needed by this plan. Resolve
the existing vector artifact's immutable origin and digest. Recheck runspace,
pipeline, callback and cancellation behavior against the shipped PowerShell
preview.4 sources; `docs/host.md` includes preview.5 traces that must not be
silently treated as version-matched evidence.

Define typed contracts for component lifetime, pane content, session events,
bounded queues, recovery actions and assembly admission. They must allow a
graphical pane without console state and a non-visual component without UI.
Inspect the 104-image diagnostic candidate on all three targets and retain its
startup results; cryptographic command execution waits for P5.

Exit: every implementation input has a pinned origin and integrity identity;
contracts and lowering targets are recorded; no unresolved ABI is guessed.

### P1: hardware Canvas through the owned bindings

Add a separate diagnostic fixture that acquires `Surface.lockHardwareCanvas`
on the NativeActivity surface, checks acceleration, selects RGBA8888, draws
complete frames and posts them. Do not mix software and hardware acquisition
paths on that surface. Cover text, rectangles, rounded rectangles, clipping
and nested drawing-state save/restore; use pinned font inputs.

An independent capture checks known colors, text bounds and clipping. Record
the renderer/backend identity as well as the acceleration flag: the flag alone
does not prove a physical GPU, and emulator software GPU emulation does not
satisfy the production rendering requirement. Check resize and window loss,
reference cleanup, idle behavior and absence of redraw loops.

Exit: hardware rendering receipts on all three backends, with no Xamarin;
acquisition and presentation timings recorded as the later lowering baseline.

### P2: managed host, bindings and first frame independent of SMA

Emit the platform bindings and managed callbacks into admitted IL-only
assemblies. Move window/input lifecycle handling out of script-block
delegates. The native host continues to start CoreCLR; managed code owns UI
callbacks and descriptor wakeups. Add the dedicated ManagedUi emission node
between Select and Store as specified below; verify store alignment,
dependency closure and identities through Step 6.

Install callbacks and return from activity creation. Draw the first hardware
frame before SMA work. Start the UI in an initializing state, then admit the
PowerShell adapter through a separately catchable entry. Preserve the existing
main-thread profile execution contract and `DefaultRunspace` restoration.
Changing profile affinity needs its own source trace and gate; it cannot be
used to change the frozen CellCanvas workload's contract.

Preserve case-insensitive profile discovery, ExternalScript invocation,
PSScriptRoot, the existing HadErrors rule and required runspace state. Retain
these as explicit regression cases rather than introducing another script
execution path during the host refactor.

Exit: a controlled absent/failing SMA adapter still leaves hardware rendering,
native input and built-in controls usable. Window recreation and teardown do
not invoke stale callbacks. Gates 2a-2d still pass on all three backends.

### P3: retained tabs and a lowered console pane

Lower the existing console model and frame operations, preserving their
contracts, using the existing persisted expression-tree/IL machinery for named
methods. This gate does not require a general PowerShell compiler. Replay all
63 admitted vectors and ring checks against both the
reference model and the emitted assembly. Add meaningful cases for lowering
boundaries rather than duplicating emitter implementation details.

Implement a retained root, tab strip, pane bounds, focus and hit regions in
ordinary UI coordinates. Initial controls: create, switch and close tabs,
status, and recovery/settings actions. Add a graphical pane containing text
and controls that never allocates console cells. Each console tab retains its
own transcript, editor, history, selection, scroll and zoom state.

Execute repeated layout, scene traversal, composition and draw submission in
lowered code. Keep the existing scroll/select/copy/paste, pinch, keyboard,
mouse and touchpad behavior, with visible tap controls for essential actions.
Lower repeated text-boundary conversion and editor work as needed; optional
SMA highlighting/completion cannot prevent basic editing or recovery.

Exit: two console panes and one graphical pane can be created, switched and
closed; inactive-pane state is preserved; controls remain outside cell
coordinates; hardware pixels and conformance pass on all three backends.

### P4: asynchronous PowerShell sessions

Give each console session its own worker runspace and pipeline owner. Define
working-directory behavior explicitly, since process current directory and
other statics are shared. UI requests carry session and lifetime generations;
events from closed/replaced sessions cannot affect a new pane.

Implement the host interaction the preview actually exposes: output formatting,
error/warning/verbose/debug/information streams, progress, prompt generation,
interactive reads and cancellation. Audit the version-matched PSHost contract
and state any intentionally unsupported operation. Parse and validate input
lengths/AST before invoking through pipeline APIs; do not use input-driven
`[scriptblock]::Create`, `Invoke-Expression` or runtime Add-Type compilation.
Document the intentional FullLanguage requirement and the trust boundary.

Managed stream and completion handlers publish ordered events to the looper;
they do not mutate UI or invoke script delegates from the worker. Bound output,
transcript and pending-input storage with explicit backpressure, cancellation
and overflow behavior. Do not silently drop errors or completion events.

Run SMA-dependent completion and highlighting off the UI callback path. Apply
results only to the matching session and editor revision; a delayed result
cannot replace newer input. A busy session does not block basic editing or
built-in repair controls.

Exit: two sessions keep independent variables/history; a long command in one
does not stop UI or the other session; streaming output appears before
completion; errors and progress have correct lifetime; cancellation and close
clean up correctly. No completion polling. Repeat on all three backends.

### P5: fixed Java bridge, text input and command payload

Emit the fixed NativeActivity subclass and text-input view. Load the pinned
Android crypto library from Java with the app class loader, including the
runtime's required crypto DEX. Emit and independently verify the owned DEX,
manifest references, method signatures and JNI registrations. No Xamarin
types, arbitrary Java subclassing or general peer-tracking system is added.

Route recoverable Java/library initialization errors into managed status and
inhibit dependent operations. A native abort during initialization remains a
process failure; the UI cannot catch it. Trace and gate this boundary explicitly.

Keep NativeContentView; add the non-drawing InputConnection view. Route
committed text, composition, deletion, selection and editor actions to the
focused session. Preserve Unicode scalar/UTF-16 boundaries. Handle IME insets,
focus changes, rotation, resize and hardware keys without duplicate delivery.
Forward document-picker results and new intents into the managed host. Declare
a safe-start launcher shortcut targeting the same Activity; handle it before
profile execution and verify the required resource/manifest emission.

Complete the existing command-payload gate: execute Utility, Management and
Security representatives, including Get-ChildItem, ConvertTo-Json and
ConvertFrom-SecureString, plus ordinary pipelines from the actual console.
Verify crypto initialization and hashing/TLS separately before claiming them.
Do not include credentials, secret values or device identifiers in receipts.

Exit: typed and pasted commands, composition and focus work in the actual
tabbed UI; command families execute on all three backends with post-result
liveness and no process crash. The non-debug manifest has no debuggable flag.

### P6: integrated recovery and profile repair

Before executing the application profile, durably record the startup attempt
using bounded data and a validated write/flush/replace protocol. Clear it only
at a defined host-observed startup success boundary. An incomplete previous
attempt opens recovery and skips the profile. Safe-start shortcut and PC
requests bypass the profile even after an earlier successful startup.

Preserve the main-thread profile contract. A hung profile on that thread can
block the current UI; the guard gives recovery after force-stop/relaunch. It
is not an in-process watchdog or a promise to recover CoreCLR/native crashes.
Android killing a healthy startup may also trigger safe mode; explicit Retry
is the recovery action. Do not add automatic retry loops.

The managed retained UI supplies a recognizable recovery state, profile view,
Copy diagnostic report, Export profile, Replace profile, Restore previous,
Start without profile and Retry. When SMA works, provide a fresh profile-free
repair session. When it does not, the built-in file and diagnostic actions
remain usable. Basic recovery does not depend on command modules, SMA-based
formatting/highlighting, the profile, or cryptography being initialized.

Import/export uses ACTION_OPEN_DOCUMENT/ACTION_CREATE_DOCUMENT and
ContentResolver through the fixed bridge. Export preserves original bytes to
user-selected storage. Replacement is bounded and staged in private storage;
keep a recoverable previous copy, validate the candidate, and explicitly
promote/retry. Retain the failed candidate as needed for repair. Cancellation
or an interrupted copy cannot damage the active or previous profile. No broad
storage permission or hard-coded shared-storage path is required.

Diagnostics identify stage, build, admitted capabilities and error chain;
include PowerShell position and script stack when available. Make them
copyable as a coherent report. Do not automatically export profile contents,
commands, environment dumps or unrelated personal data as diagnostics.

Exit: missing, malformed, throwing and hanging profiles; module/SMA admission
failure; interrupted startup/import; rollback; and picker cancellation each
leave a verified route forward without clearing storage. Repeat on all three
backends, including safe restart from the release configuration.

### P7: installed assets and the Windows-PC run-as workflow

Ship the managed UI/console and a default preview entry independent of a user
profile. Define first-run and missing-profile behavior: the installed console
remains useful; an absent optional application profile does not strand it.
Package pinned fonts, UI data and notices with explicit asset provenance.

Fold the emitters into `setup.ps1`. Integrate deployment as a step-graph node
after signing; proposed options are -RunAs, -Deploy, -Profile and -Device.
-RunAs selects a debuggable development artifact; ordinary release builds stay
non-debuggable. Make option dependencies and device writes part of the
reviewable plan. Use a pinned adb transport tool; it does not produce APK
bytes. Require explicit target selection when multiple devices are present.

Support build/install, profile export, staged replacement, safe start, launch
and diagnostic collection. Preserve the signing identity for upgrades and all
unrelated app files. The existing fixture runner removes private .ps1 files;
do not carry that cleanup behavior into the product repair workflow. Handle
disconnects and refused run-as without reporting success. Verify writes and
launches by readback and device receipts.

A live PC REPL requires a separately admitted session protocol through the
same host/session interface; adb profile deployment is not that protocol.
Direct USB accessory transport remains subsequent work until negotiation,
re-enumeration and bidirectional traffic are proven. Neither transport changes
the application's rendering or console/session contracts.

Exit: fresh install and upgrade are useful on Android without injected probes;
PC-assisted repair works without storage reset; reconnect and rejected access
have correct results; the build is self-contained and reproducible.

### P8: release acceptance and artifact freeze

From an immutable clean source snapshot, build only through `setup.ps1` using
the permanent signing identity and pinned inputs. Run the relevant permanent
build gates; reject unpinned files and unexpected dependency/payload changes.
Update ordered assembly admission and count checks deliberately as generated
assemblies are added; 104 is the current candidate count, not a future limit.

Record the same candidate artifact's cold start, first hardware frame,
input-to-photon latency, draw submission, idle CPU, memory, APK and store size
on every backend claimed. Use controlled scenes and independent pixel checks;
compare with admitted reference data where available. Do not claim old
CellCanvas throughput from an unrelated new workload. Verify that idle UI
produces no recurring frames and that resource use stabilizes after repeated
session creation/close and window recreation.

Complete adaptive icon/font admission, reproducible manifest, SBOM, applicable
notices, APK SHA-256 and per-backend receipts. Verify clean installed startup,
ordinary pipelines, tab switching during commands, IME/rotation, safe startup,
profile export/replacement and upgrade data preservation.

Exit: the signed non-debug preview and its evidence bundle meet all P0-P8
criteria. Update README status to those proven capabilities only.

## Work beyond this preview

The general host and binding contracts preserve room for graphical Activities,
TTS and other services, other renderers, remote surfaces and alternate PC
transports. Their capability claims require separate gates. Frozen CellCanvas
compatibility 2e/2f, Vulkan/direct Skia, a full desktop/window manager, RDP/video,
self-updating IL and native hot-loop competition remain separate roadmap work.

The x86-64 P1 development receipt now passes; an arm32 development APK is built
and awaits a device. Next collect physical P1 receipts and finish the remaining
P0 contracts/conformance-source admission. Complete the three-backend P1 receipt
before building the next runtime layer; current results are not a portability claim.

## ConsoleHost naming and managed contract refinement (2026-10-01)

This section refines P0-P4; it adds no completed gate or device proof. The implementation requires both an operational PowerShell console and a retained graphical surface whose coordinates and content are independent of terminal cells.

### Source and artifact identities

Use `scripts/ConsoleHost.ps1` as the planned development composition/emission entrypoint. It defines and emits the owned host contracts, rather than becoming another run-as screen probe. The existing `modules/Console.psm1` remains the executable reference model while its named algorithms are lowered. `scripts/probes/console-screen/Profile.ps1` remains a diagnostic fixture; renaming it would not make it a production host. No source file has been renamed or new emitter implemented by this refinement.

The ConsoleHost entrypoint can emit more than one IL-only assembly where dependency separation requires it. Basic retained UI and recovery must load without SMA. The PowerShell adapter is separately admitted. An assembly count is not an architecture: use the smallest dependency closure that proves this separation. The process/component host remains usable by graphical applications and services that never instantiate ConsoleHost.

Emission uses the existing `PersistedAssemblyBuilder`, expression kit and `Add-PersistedMethod` machinery in setup.ps1. Define supported typed methods explicitly. Ordinary PowerShell classes or arbitrary scriptblocks do not become persisted assemblies merely by saving a file. Repeated parser, buffer, layout, hit-testing and drawing work must have fixed managed implementations without SMA dynamic dispatch.

### Current implementation inventory

| Source | Established implementation | Required transition |
| --- | --- | --- |
| `modules/Console.psm1:388` | Transcript/progress model, command editor/history, width/reflow, packed frame composition | Lower named methods; preserve the 63-vector reference scope and add terminal behavior separately |
| `modules/Console.psm1:452` | Creates a parser for each Write call; applies CSI only for SGR | Persistent decoder/parser per byte stream; escape sequences may cross write boundaries; implement addressed screen semantics |
| `modules/Console.psm1:766` | Frame-ring reference over unmanaged memory | Define single/multiple producer ownership, slot lifetime and managed release/acquire ordering; reference aligned accesses do not prove cross-thread synchronization |
| `modules/AndroidCanvas.psm1` | JNI/NDK dispatch, window and input callbacks, hardware mode, clip/transform and resource mechanisms | Emit typed bindings and managed callbacks; retain cached resources and bounded JNI references; diagnostic script-block callbacks are not the production path |
| `scripts/probes/console-screen/Profile.ps1:99` | Command submission executes synchronously in the profile's runspace with ad hoc scriptblock construction | Validated pipeline submission, worker runspace ownership, proper formatting/PSHost streams and completion events; no blocking command work on the UI thread |
| `setup.ps1:1971` | Typed expression verification and persisted method emission | Reuse the same producer; reject closure constants, dynamic call sites and unsupported method shapes |
| `setup.ps1:274` | Acquire -> Inspect -> Select -> Store dependency chain | Introduce an explicit UI emission node before Store once the standalone emitter contract is proven |

Existing three-backend console vectors establish the reference model's declared behavior. The x86-64 hardware Canvas receipt establishes the diagnostic hardware path only. Neither is proof of a production managed ConsoleHost, complete TUI compatibility or current dependency-removal candidate startup.

### Shared retained surface

The retained model stores scene nodes between frames. Minimum node state: stable ID and generation, parent/ordered children, logical bounds, visibility, clip, transform, opacity, content/resource references and damage. Controls add measure/arrange, hit testing, focus, pointer capture, keyboard actions and accessibility semantics. Ownership and invalidation are explicit; closing a pane releases resources and rejects stale worker events.

Content includes text, rectangles, paths, images, controls, graphical application panes and terminal frames. A terminal node translates its own cell coordinates into its allocated graphical bounds. Ordinary controls do not allocate cells. Initial layout needs bounded row/column/overlay arrangements and a scroll container, not a CSS engine or a general desktop window manager.

Use one retained root and one platform presentation owner initially. State mutations accumulate damage and request at most one pending frame. Lowered traversal translates retained nodes into drawing operations. The Android presenter obtains a hardware Canvas and renders complete surface coverage when a frame is submitted. Retention means retaining scene state; it does not imply that Android preserves acquired buffer pixels. Independently composited OS surfaces, offscreen textures and native-application drawing callbacks are later capabilities unless a declared workload requires them.

### Console and session contract

Preserve transcript/reflow and command-entry editing. Add a separate addressed terminal screen with primary/alternate buffers, cursor and saved state, wrap and scrolling margins, erase/insert/delete operations and declared VT modes. Parsing must persist across writes, including UTF-8 decoding at byte transports. Replies flow back to the application, not into the displayed transcript. Input encoding respects application modes, keyboard modifiers, mouse reporting and bracketed paste.

PowerShell session integration uses SMA's version-matched PSHost interfaces and pipeline/stream APIs. Command entry, terminal protocol and session execution have separate ownership. A worker emits formatted output, diagnostics, progress and completion events with session generation IDs. Prompt creation occurs after completion; cancellation and interactive reads have explicit protocols. GUI focus may belong to a settings textbox rather than a console. A native application session may own terminal input temporarily without acquiring the PowerShell line editor.

Start with the working PowerShell console gate. Broader full-screen TUI claims require a protocol matrix and application receipts, including Edit's requested modes and queries. The existing parser's recognition of CSI/OSC syntax is not evidence of implementing those commands.

### Microsoft alignment

- [Classic console versus VT](https://learn.microsoft.com/en-us/windows/console/classic-vs-vt): Microsoft recommends VT for portable terminal interaction. Keep platform-specific window/process setup behind adapters rather than duplicating the Windows Console API on Android.
- [VT sequences](https://learn.microsoft.com/en-us/windows/console/console-virtual-terminal-sequences): sequences may span multiple writes; cursor, screen editing, modes and input behavior are explicit contracts. Implement a named supported subset with conformance vectors before making compatibility claims.
- [Retained versus immediate mode](https://learn.microsoft.com/en-us/windows/win32/learnwin32/retained-mode-versus-immediate-mode): retained scene ownership and command generation are distinct from immediate rasterization. A retained managed tree can drive a hardware Canvas backend.
- [DirectComposition concepts](https://learn.microsoft.com/en-us/windows/win32/directcomp/basic-concepts): parent-relative visual ordering and batched changes are useful design references. This does not require importing DirectComposition types into the shared model or implementing its complete API.
- [Terminal appearance](https://learn.microsoft.com/en-us/windows/terminal/customize-settings/appearance) and [NavigationView](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/navigationview): use familiar tabs/profile selection and adaptive settings navigation. Adopt interaction and layout principles without WinUI/XAML dependencies.

### Google alignment at Android boundaries

| Boundary | Official guidance and implementation consequence |
| --- | --- |
| Hardware presentation | [Surface.lockHardwareCanvas](https://developer.android.com/reference/android/view/Surface#lockHardwareCanvas()): acquired buffers are not preserved; partial updates are unsupported. Damage schedules frames, while each submitted frame covers the surface. Check Canvas.isHardwareAccelerated; no silent software fallback in the production renderer. |
| JNI | [JNI tips](https://developer.android.com/ndk/guides/jni-tips): JNIEnv is thread-specific; share JavaVM and attach only threads that need JNI. Cache method IDs, retain objects with owned global references, release local references, check exceptions, and minimize repeated marshalling. Keep drawing submission on the declared presenter thread. |
| NativeActivity lifetime | [ANativeActivityCallbacks](https://developer.android.com/ndk/reference/struct/a-native-activity-callbacks): callbacks occur on the main thread. Stop using a destroyed window before returning from its destruction callback; synchronize any other rendering owner. Generation checks do not replace that lifetime synchronization. |
| Text input | [InputConnection](https://developer.android.com/reference/android/view/inputmethod/InputConnection): support committed text, composing ranges, selection, deletion, nested batch edits and editor-state notifications. Showing the keyboard alone is insufficient. Keep the fixed auxiliary non-drawing input view and NativeContentView architecture required by the repository; managed editor state and Java input offsets need an explicit conversion contract. |
| Layout | [Grids and units](https://developer.android.com/design/ui/mobile/guides/layout-and-content/grids-and-units) and [WindowInsets.Type](https://developer.android.com/reference/android/view/WindowInsets.Type): distinguish logical dimensions, display density, font scale and physical pixels. Handle system bars, cutouts and IME independently; systemBars excludes IME. Recompute pane layout on relevant changes. |
| Resource preparation | [Custom drawing](https://developer.android.com/develop/ui/views/layout/custom-views/custom-drawing): prepare expensive drawing objects ahead of drawing and recompute size-dependent geometry when size changes. Its View.onDraw examples inform caching; they do not require replacing NativeActivity's surface path. |
| Accessibility | [Custom-view accessibility](https://developer.android.com/guide/topics/ui/accessibility/views/custom-views): graphical hit regions need semantic nodes and actions, not pixels alone. An accessibility bridge for the retained tree is an explicit platform contract. The required Java forwarder/provider surface remains unimplemented and must be source-scoped before emission. |

These are official design/specification references consulted on 2026-10-01, not newly pinned build inputs. Exact method implementations used by emitted bindings still require admission against the repository's pinned Android sources and headers. No AndroidX, Compose, browser or third-party managed dependency is implied by following this guidance.

### Future StepGraph integration

Keep the existing numeric public steps stable during development. Once source contracts and emission checks pass, add a dedicated named node such as `ManagedUi` (an unused numeric ID) depending on `Select`/4; make `Store`/5 depend on that node. Selection must stop generating these same images internally: each artifact has one producer. ManagedUi consumes selected pinned metadata and contract sources, emits IL-only images plus identities/hashes, and publishes them to BuildContext for Store. Validate dependency closure and payload order after insertion. Do not package or sign from the standalone emitter.

Declare which inputs are fixed at build time and which metrics remain device-dependent. Preserve the existing host emission path until changing its producer is explicitly part of the gate. Update manifest/count expectations only with the actual emitted identities; do not reserve hypothetical dependencies. Integrate the developed ConsoleHost emitter functions into setup.ps1 for the single-script release build, retaining a separate graph action and ownership boundary.

First visible acceptance target: an installed APK opens the managed shell, shows an operational console plus a graphical pane with proportional text and a control, preserves both panes across switches and resize, accepts IME text, executes commands asynchronously, returns the prompt, and retains repair access after a profile failure. P0-P8 remain the governing gates; no build or test was run for this refinement.

## Implementation tracking and optional application work

`ROADMAP.md` now tracks the ConsoleHost refinements within P0-P8, command dependency repair, and separate full-screen TUI/native-session/Edit demonstration tasks. This work order remains the detailed design and acceptance contract; the roadmap owns checkbox status.

The editor implementation uses SMA language services where available and project-owned document/editing controls. It is not a commitment to reproduce all of Microsoft Edit. The optional native Edit session is a different workload for proving application hosting. Define a versioned session/service ABI and installed-code delivery before the native experiment; adapt Edit's terminal/global assumptions and prove return to the prompt. A PTY is an optional transport choice, not a requirement for callback-based in-process hosting. Native-process fault containment is unavailable inside the shared process. Existing native producer/admission gates continue to govern changes to Pwsh.
## APK preview release boundary

[ROADMAP.md: Release](../ROADMAP.md#release-apk-preview-finish-line) defines the mandatory R1-R9 finish line. P0-P8 remain the engineering gates, scoped to that acceptance workload. Profile repair, essential appearance settings and an independent graphical pane are required; full editor parity, addressed-terminal compatibility and optional native application hosting are follow-on capabilities. No release status is changed by this planning clarification.