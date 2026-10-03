# Views and live tiles

Status: design, 2026-10-02. Gates and receipts are in
[work-managed-ui.md](work-managed-ui.md); the console view is specified in
[console-reference.md](console-reference.md) and
[console-host.md](console-host.md). A Windows-first implementation contract
for the same model is being written in the QuickPS repository.

## The model

The hosted runspace and its scripts are the real thing; every view and every
tile is a projection of them. Views are the console, a Start screen of live
tiles, a settings view, a desktop (windowed, DeX-style), and the editor.

- **A tile is the app.** A tile is one complete `.ps1` that returns its own
  description: title, glyph, accent, size, a face provider, optional controls.
  Opening it shows the same script larger, not a separate application.
- **Knobs are the script's own `param()` block,** read with SMA's parser:
  `[switch]` or `[bool]` is a toggle, `[ValidateSet]` a choice,
  `[ValidateRange]` on a number a slider, other typed parameters a text field,
  help comments the caption. There is no separate settings description.
- **Faces are data,** drawn by one renderer: a value, up to three lines, a
  badge, optionally a back face. Live tiles keep a queue of at most five faces;
  a new face replaces the oldest, a face with the same tag replaces that one
  (the Windows 8.1 rule).
- **Faces change only on events** the script declares (a timer it asked for, a
  job finishing, a file change, a system broadcast). Nothing polls. An update
  that does not change the face changes nothing on screen.
- **Quick actions are tiles.** A control surface (a remote, a toggle such as a
  flashlight, a media widget) is a tile whose buttons, toggles, sliders,
  D-pads and text fields are child nodes. Sizes run from Small (1x1) through
  Medium, Wide and Large (4x4) to an explicit span for extra-large surfaces.
- **Editing is designing.** Every tile and view has its source file. Swiping
  right on a tile opens its source in the editor beside a live preview of the
  tile at each size; every edit that parses re-renders the preview; an edit
  that does not parse shows its errors and changes nothing. Saving applies it.

On a TV the Start view is the natural home screen: large tiles, remote
navigation through the same verbs, scripts as apps. Android lets an app offer
itself as a home screen through the `HOME` intent category; whether Google TV
lets a third-party home screen become the default is not yet checked, so this
is a candidate, not a planned claim.

## Views are peers

A tile that opens the console, a `desktop` command, and a desktop that shows
the same tiles form a cycle, and the cycle is harmless:

- Views are instances owned by one host. Navigation activates an existing
  instance; nothing is constructed inside the current view.
- The back stack holds view references and truncates when navigating to a
  view already in it, so cycling never grows it.
- Start and the desktop are two projections of one tile model.
- Faces are sinks: applying a face never raises an event a face provider can
  subscribe to, so a tile cannot feed back into what it shows.

## Failure stays local

| Failure | Behaviour |
| --- | --- |
| A tile script throws | The tile shows an error face; Edit stays available |
| A tile script hangs | Tile scripts run in their own runspace with a stop deadline; the tile shows Busy |
| A saved source does not parse | The previous version keeps running; the editor shows the errors |
| A view fails to load | Its error page offers Edit and Back; other views are unaffected |
| An event storm | Coalesced per tile; the latest face wins |

## Endpoint tiles and zones

A tile may serve something on a port: a page, speech, a camera stream, a
command pipe. A command endpoint is remote code execution into the runspace,
so two independent gates apply, restated from the author's earlier `subsystem`,
a private repository (`src/runspace/Host/Firewall.cs`, commit `2c8dd804`):

- **Bind:** loopback only, unless the endpoint uses TLS and authenticates every
  client.
- **Connect, by network zone,** default-deny and fail-closed, in trust order
  Mobile < WifiPublic < WifiPrivate < Usb < Loopback. Loopback and USB are
  allowed (adb forwarding arrives as loopback). WifiPrivate needs an opt-in
  rule for a trusted network, WifiPublic an explicit rule, Mobile a separate
  warned acknowledgement. Anything unclassified is denied.
- Clients authenticate with a pairing token shown on the tile; a command
  endpoint exposes declared commands with typed parameters, not raw script
  text. The tile shows its exposure and stops its listener when it stops.

## Navigation is a tree

The scene model is the accessibility tree. Each node has an id, role, name,
value, state, bounds and supported actions; children are in reading order,
which is layout order. Keyboard, screen readers, tests and agents use the same
verbs: `Move(Up|Down|Left|Right)`, `Next`, `Previous`, `Invoke`, `Edit`,
`Open`, `SetValue`, `Swipe`, `Back`. A test or an agent drives the surface by
node, without screenshots or coordinates. Exposing the same tree to
Android's accessibility services needs a view-side bridge, which is part of
the text-input bridge work and not yet designed.

## Motion and type

- Motion is a closed set bounded by the Windows 8.1 animation library's ten
  families (add and delete, content transition, drag, edge UI, fade, page
  transition, pointer click, reposition, pop-up UI, swipe): tilt on press,
  flip and peek for live faces, turnstile between pages, reposition on reflow.
  Each is a finite definition run by the platform's compositor; PowerShell
  never runs per frame.
- A face is rasterized once into its own surface and only again when its data
  changes; flips and moves transform the surface.
- Layout uses a fixed tile unit and derives the column count from the width,
  so tiles keep their size when the device rotates.
- Type follows the Segoe UI ramp of the Windows 8.1 guidelines: 42 pt Light
  for one- or two-word prominent elements, 20 pt Light (or 16 pt Semilight,
  never both on one page) for single attention lines, 11 pt Semilight for most
  text, 9 pt for the smallest captions. The sizes and weights carry over;
  Segoe UI itself is Microsoft's typeface and is not shipped, so the Android
  typeface is chosen separately.

## Behaviour references

The author's conformance scripts (`Start`, `Desktop`, `Rubiks`, `Tetris`,
`CanvasDemo`, each with a TypeScript twin) are the workloads these views must
run; the TypeScript twins are the behaviour reference, not the structure of
their PowerShell ports (the Start port, for one, redraws the whole screen on
every animation frame with no damage tracking). A reference that
is optimized is optimized by measured, one-change-at-a-time steps against a
deterministic metric (canvas operations issued over a fixed scenario suite)
with pixel hashes of every checkpoint as the guard; see
[practices.md](practices.md).

## Lowering boundary

The view host, tile model, layout, queue, semantic tree, navigation and
failure handling are fixed code, written in a typed subset and lowered when
complete and covered by vectors ([lowering.md](lowering.md)). Tile scripts,
knobs, face providers and control actions are user code: they stay editable
source and are never built into the shipped assemblies. Any run-time lowering
of their hot paths is a cache derived from the source and discarded on edit.
