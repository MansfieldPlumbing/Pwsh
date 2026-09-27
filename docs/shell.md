# The Pwsh shell surface (design, not proven)

How the terminal and, later, the retained desktop reach pixels, local or
remote. `docs/host.md` covers startup, runspaces and isolation; this document
covers the event bus, the frame contract, rendering and apps. Nothing here is
proven until `ROADMAP.md` names a gate and a receipt for it.

## Prior art

- `setup.ps1`'s interactive interface (`Invoke-SetupInterface`,
  `Get-CanvasCells`, `Render-Canvas`) has the event shape: a blocking event
  bus, input produced in its own runspace, every queued event drained before
  one render, a dirty flag, a cell grid, and output emitted only where the
  format changes.
- `System.ConsoleEngine.ts` (an AI Studio terminal prototype) has the console
  model: a transcript of entries tagged by PowerShell stream, a line editor
  with caret, selection and IME composition, reflow by relayout at the current
  width, packed cells, and a renderer that repaints only changed cells.
- `desktop.ps1` has the retained-UI seam: a `DrawingContext` over a canvas
  (rects with radius, lines, text, icons, shadow, clip, transform and opacity
  stacks) and a `HitRegionEngine` that dispatches touches to actions. Its
  frame pump is not carried over.

## Event bus

One queue, drained on the main thread. Producers (local input, shell
runspaces, timers, remote input) add an event and signal an `eventfd` that is
registered with the main looper. The looper callback drains every queued
event, applies each to state, and, if anything is dirty, produces one frame.
Bursts coalesce into one frame. Nothing polls, and nothing waits on a timeout.
This is `setup.ps1`'s `BlockingCollection` shape with the looper, not `Take()`,
as the wait, because blocking the main thread would stall input and lifecycle.

Animation requests one display-refresh callback at a time while something is
moving and stops when it settles.

## Frame contract: a ring of three slots

The engine publishes frames, not pixels. Each display renders its own pixels
at its own size and density.

- Three slots. The engine writes the free slot and commits it by incrementing
  a sequence number; it never waits for a reader. A consumer takes the newest
  committed slot when it wakes, so a slow consumer skips frames without
  stalling the engine or other consumers.
- Each slot starts with a 64-byte header: sequence, columns, rows, cell format
  version, cursor position and flags. The body is the whole frame, not a
  delta: the full cell grid, or later a recorded display-list command buffer.
- Damage is computed per consumer: each diffs the slot against the last frame
  it drew. A consumer that skipped frames still sees every change. A
  changed-rows bitmap in the header is a hint, never required for correctness.
- Commit signals each consumer's wake source: an `eventfd` on its looper, or a
  socket for a remote consumer.
- For another process, the ring lives in shared memory (`memfd`), whose file
  descriptor is passed over a Unix socket and mapped read-only by the reader.
- The cell format is fixed and versioned before any consumer depends on it:
  full Unicode scalar values (not 16-bit units), a width for double-width
  cells, 24-bit foreground and background colors, and attribute bits (bold,
  italic, underline, inverse, strike).

## Consumers

| Consumer | Sends or draws | Rendered | Client needs |
| --- | --- | --- | --- |
| Local display | `Canvas` calls on the window surface | on the device | nothing |
| Contract stream | changed rows of the frame | on the client, at its density | a Pwsh client (PowerShell or the TypeScript reference) |
| RDP | graphics-pipeline region updates ([MS-RDPEGFX]) from frames drawn into an encoder surface | on the device | the stock Windows App client |
| Video | H.264 from the same encoder surface | on the device | any video player |

The engine does not know which consumers are attached. RDP and a foreground
service need manifest declarations fixed at the freeze (`INTERNET`, the
service slot and its types, `POST_NOTIFICATIONS`); TLS needs the crypto
initialization from the emitted `NativeActivity` subclass.

## Rendering: a display list with cells as its first client

The renderer executes a display list against a `Canvas`. Its first
primitives are the two the cell grid needs: a filled rectangle for a
background run and a text run, one `drawText` per span of same-format cells in
a damaged row (the span merge `Render-Canvas` already does). `desktop.ps1`'s
`DrawingContext` operations (rounded rectangles, clip, transform, opacity,
shadow, icons) are added later as further primitives on the same list.
PowerShell records the list; lowered code executes it.

## Apps

The window manager owns displays, windows, z-order, motion, the display list,
damage, hit regions, input dispatch and themes. An app is a small module that
declares, with no host setup and no loop:

- `Get-AppInfo`: title, icon, default size;
- `New-AppState`: its data;
- `Show-App $Context $State $Bounds`: records drawing and hit regions using
  theme tokens;
- `Invoke-AppAction $State $Action $Arguments`: updates state and returns what
  changed.

Themes are `.psd1` data (palette, layout constants, fonts, radii).
`Import-PowerShellDataFile` is in `Microsoft.PowerShell.Commands.Utility`,
which the payload does not ship; reading a `.psd1` through SMA's parser is to
be verified before relying on it. Each app may run in its own runspace behind
the dispatcher, so an app's exception stays in its window. A stable
`Show-App` is a candidate for the device-persisted IL path in `AGENTS.md`.
