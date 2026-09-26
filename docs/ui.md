# Console and UI (design, not proven)

Everything here is planned. Nothing in this document has passed a gate.

## Shape

Pwsh needs both a terminal console and a general UI. Neither replaces the
other.

- The console: a native terminal in the shape of Windows Terminal, with a tab
  strip and one terminal per tab. Its text area is a monospace cell grid that
  is fully VT/ANSI compatible and reflows on resize.
- The UI: a general UI for applications that are not terminals, laid out in
  dp, not constrained to cells. It is drawn and composited by Pwsh on the
  owned surface; `setContentView` over `NativeActivity`'s content view stays
  forbidden.

The device is touch-first.

## Intents

Scripts get the full Android intent system through owned bridges:
constructing any `Intent`, starting activities (including for a result) and
sending broadcasts.

Receiving uses a declared, disabled, frozen manifest:

- The emitted manifest declares, once, nearly every component and
  `<intent-filter>` the product can use. Each declaration ships with
  `android:enabled="false"` and names the script stub that handles it.
- A script enables the components it handles at runtime through
  `PackageManager.setComponentEnabledSetting`, and disables them again when
  it no longer handles them. Nothing is enabled by default.
- The manifest is then frozen and pinned by SHA-256, like CellCanvas. Adding a
  capability means enabling a declared component, not re-emitting the
  manifest or re-signing the APK.
- Activity intents go to `<activity-alias>` entries whose `targetActivity` is
  the `NativeActivity`, so they need no Java class. The host reads the
  launching component and the `Intent`, and dispatches to that alias's stub.
- Receivers and services must name a Java class. Each one points at one
  emitted DEX forwarder per Android base class (roadmap milestone 4), which
  hands the call to the stub named by its component.
- "Nearly every" excludes declarations the platform reserves for privileged
  or signature-level callers. The exact list comes from AOSP's manifest and
  permission definitions at the pinned tag.

Read from AOSP `frameworks/base` at `android-14.0.0_r1` (commit `299fe6f5`):

- An app may change the enabled state of its own components without
  `CHANGE_COMPONENT_ENABLED_STATE`: `PackageManagerService.setEnabledSettings`
  rejects a caller only when it is neither the target package nor holds the
  permission (`PackageManagerService.java:3869-3890`). The one exception is the
  system-generated app-details activity (`:3942-3946`).
- Without `PackageManager.DONT_KILL_APP` the package-changed broadcast is sent
  at once with `dontKillApp=false` (`:4026-4073`). Every call passes
  `DONT_KILL_APP`. Where the unflagged broadcast stops the process is not yet
  traced.
- `NativeActivity` does not override `onNewIntent`, and `Activity.onNewIntent`
  is empty (`Activity.java:2275`); an intent delivered to a running activity
  never reaches native code. Receiving one needs an emitted subclass of
  `NativeActivity` that forwards `onNewIntent`.

## Decision: composite, and use cells only where VT needs them

The UI is not required to be cell-shaped. Only the terminal's text area is a
grid of monospace cells, because VT/ANSI semantics (cursor addressing, erase,
scroll regions) are defined over one. The tab strip, overlays and anything
else are separate layers, sized in dp, and composited over or beside the
grid.

Composition is therefore the first thing to establish. If layers composite
correctly and cheaply, no other part of the UI has to fit the cell grid.

This document does not choose a renderer. The repository already records two:
Android `Canvas` and AGSL reached through JNI, which gate 2e/2f requires for
CellCanvas (`docs/android-facade.md`), and a Vulkan swapchain on the
`NativeActivity` window (`ROADMAP.md`, UI and platform). The terminal is built
on whichever of them the owner confirms, using the bridges gate 2e proves.

## Text input

Read from the same commit: `NativeActivity`'s content view is a bare
`NativeContentView extends View` (`NativeActivity.java:113-123`), and `View`
returns `false` from `onCheckIsTextEditor` and `null` from
`onCreateInputConnection` (`View.java:16460`, `:16483`). The native side has
only `ANativeActivity_showSoftInput` and `hideSoftInput`. Soft-keyboard text
(committed and composing text, deletions) therefore needs a view that returns
an `InputConnection`, which means emitted DEX. The same emitted `NativeActivity`
subclass that forwards `onNewIntent` can host that view. How it attaches
without `setContentView` over the native content view is an owner decision.
`NativeActivity` also sets `SOFT_INPUT_ADJUST_RESIZE` (`:136-138`), so the IME
arrives as a content-rect change, and sets the window format to RGB_565
(`:135`); the host must select a 32-bit buffer format before drawing colour.

## Rules

- Draw on damage only. A frame is requested when state changes (output
  arrived, input, resize, tab switch) and never re-requested unconditionally.
  Command completion arrives as an event; nothing polls for it.
- Touch. Android reserves the left and right edges (back) and the bottom edge
  (home, quick switch; not excludable). No action depends on an edge swipe.
  Tabs are switched by tap. Every action has a single-pointer alternative
  (WCAG 2.2 2.5.1, 2.5.7). Tap targets are at least 24x24 dp (WCAG 2.5.8, AA);
  aim for 44x44 (2.5.5, AAA).
- The tab strip sits at the top, below the status-bar and cutout insets. The
  bottom belongs to the home gesture and the IME.
- Bridges are our own: NDK C APIs first, JNI only where no C API exists, with
  contracts read from AOSP source at a pinned tag. No Mono.Android types, no
  `setContentView` over `NativeActivity`'s content view.
- The VT parser and screen model are built from specifications and
  independent implementations, not from memory: ECMA-48, the DEC VT
  references, xterm's control-sequence documentation, and the Paul Williams
  DEC-compatible parser state machine; Windows Terminal/conhost and other
  mature emulators serve as cross-checks.

## Diagnostics from CellCanvas

CellCanvas's timing line (FPS, cell build, upload, submit, total, dropped
frames) becomes a diagnostic overlay layer that is off by default. Its animated
fill becomes an explicit benchmark mode. Neither is default behaviour.

## Seed script triage

`C:\Scripts\Terminal_20260909-093632_CD2D9A69.ps1` (1,259 lines, not pinned,
not vendored) was reviewed as a possible starting point.

Rejected:

- Every Android binding is a Mono.Android type (`SurfaceView`,
  `IOnTouchListener`, `IOnKeyListener`, `Java.Lang.Runnable`, `RunOnUiThread`)
  or the Xamarin host's `AndroidSMA.RecoveryProgram`, and it calls
  `SetContentView`.
- It redraws every frame: the animation callback re-posts itself and rebuilds
  all cells unconditionally. `$script:Dirty` is assigned in over twenty places
  and never read.
- Command completion is polled: `Complete-TerminalCommand` checks
  `IsCompleted` from inside `Build-Cells` on every frame.
- It has no VT/ANSI parser. Output is converted to strings and drawn as lines.

Ideas worth re-deriving (not copying):

- A tab model with terminal and editor tab types, per-tab input, cursor and
  history.
- Syntax colouring from SMA's own tokenizer (`Parser` tokens, `TokenKind`,
  `TokenFlags`).
- Reflow of logical lines into rows at the current width.
- Commands run with `BeginInvoke` into a `PSDataCollection`; the replacement
  signals completion instead of polling for it.
