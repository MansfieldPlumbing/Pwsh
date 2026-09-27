# Work order: the console core on Android devices

For an agent working in this repository. Do exactly these two tasks, in
order. Do not change any file outside the paths named here. Where this
document is silent, stop and report instead of guessing.

## What already exists (read these first)

- `modules/Console.psm1`: the console core in PowerShell. Exported functions:
  `New-ConsoleModel`, `New-ConsoleFrame`, `Compare-ConsoleFrame`,
  `New-ConsoleFrameRing`, `Get-ConsoleFrameRingSize`, `Get-ConsoleCellWidth`,
  `Resolve-ConsoleColor`. The model's methods are `Write`, `WriteProgress`,
  `SetPrompt`, `EditorInsert`, `EditorBackspace`, `EditorDelete`, `EditorMove`,
  `EditorHome`, `EditorEnd`, `EditorSetComposition`, `HistoryUp`,
  `HistoryDown`, `Submit`, `Scroll`, `Resize`, `Compose`, `GetCols`, `GetRows`.
- `tools/Test-ConsoleVectors.ps1`: replays the 63 conformance vectors on
  Windows; all pass. Its `Invoke-Step` function is the reference for replaying
  a vector.
- `modules/AndroidCanvas.psm1`: draws on the app window from PowerShell
  (`Initialize-AndroidCanvas`, `Register-WindowDrawHandler`, `Get-CanvasSize`,
  `Get-TextCell`, `Clear-Canvas`, `Add-CanvasRect`, `Add-CanvasText`,
  `ConvertTo-ArgbColor`, `Write-AndroidLog`). `scripts/probes/module/Profile.ps1`
  shows its use.
- `tools/Invoke-DeviceScript.ps1`: places every file of a directory in the
  app's files directory through `run-as` on attached devices, starts the app,
  and reports log lines, liveness and crashes. `-CapturePath` saves a raw
  `screencap` per device. The app must already be installed as a
  `-Debuggable` build.
- The vectors: 63 JSON files, in the directory the owner gives you.

## Rules on the device (each has already cost a failed run)

- The payload has no cmdlet modules. These do not exist on the device:
  `Join-Path`, `Test-Path`, `Add-Member`, `ConvertFrom-Json`, `Write-Host`,
  `Measure-Object`, `Get-Content`, `Get-ChildItem`. Use .NET instead:
  `[IO.Path]::Combine`, `[IO.File]::Exists`, `[IO.File]::ReadAllText`,
  `[IO.Directory]::GetFiles`. `ForEach-Object`, `Where-Object` and
  `Import-Module` are in SMA and work.
- Parse JSON with `[Newtonsoft.Json.Linq.JToken]::Parse($text)`
  (`Newtonsoft.Json.dll` ships in the payload).
- PowerShell variable names are case-insensitive: a local `$m` overwrites a
  script-level `$M`.
- In a class method, a local variable may not share a name with a property.
- An `if` expression that yields a one-element array unrolls it; type the
  variable (`[int[]] $x = if (...) { @(0) } else { $y }`).
- An exception that escapes a window callback aborts the process. Every
  callback catches everything, including failures of its own logging.
- Everything runs on the main thread. No loops that wait, poll or sleep.
- Log with `Write-AndroidLog` (tag `Pwsh`); `tools/Invoke-DeviceScript.ps1`
  collects those lines.

## Task 1: the vectors on the devices

Create `scripts/probes/console-vectors/Profile.ps1`. For each run, place in
one directory: that profile, `modules/Console.psm1`,
`modules/AndroidCanvas.psm1` (for `Write-AndroidLog`) and the 63 vector files.
The profile:

1. imports both modules with `Import-Module ([IO.Path]::Combine($PSScriptRoot, '<file>'))`;
2. replays every `*.json` in `$PSScriptRoot` the way `Invoke-Step` in
   `tools/Test-ConsoleVectors.ps1` does, reading fields from the `JToken`;
3. compares cells, cursor and, when present, `expect.ops` exactly as
   `tools/Test-ConsoleVectors.ps1` does;
4. logs one line per failing vector, then `CONSOLE PASS <n> FAIL <m>`.

Acceptance: `CONSOLE PASS 63 FAIL 0` on the x86_64 emulator, the S23 and the
onn 4K Plus, each process alive afterwards with no crash lines. Record the
three log lines.

## Task 2: the console on the screen

Create `scripts/probes/console-screen/Profile.ps1`. Place it with
`modules/Console.psm1` and `modules/AndroidCanvas.psm1`. The profile:

1. imports both modules and calls `Initialize-AndroidCanvas -NativeActivity $NativeActivityHandle`;
2. registers one window draw handler that:
   - reads `Get-CanvasSize`, sets the text size to `[Math]::Min(width, height) / 30`,
     reads `Get-TextCell` for the cell width and height;
   - creates the model once with `cols = floor(width / cellWidth)` and
     `rows = floor(height / cellHeight)`, then writes one line to each stream
     (`Output`, `Error`, `Warning`, `Verbose`, `Debug`, `Information`), one
     line with SGR 256-color and truecolor text, and one progress record;
   - composes a frame and draws every op from
     `Compare-ConsoleFrame -Previous $null -Next $frame` (a full frame; the
     window's buffer is not preserved between locks): a `fill` op as
     `Add-CanvasRect` over `count` cells, a `text` op as `Add-CanvasText` at
     `x = col * cellWidth`, `y = (row + 0.8) * cellHeight`;
   - logs `CONSOLE DREW <cols>x<rows>`.

Acceptance, with `-CapturePath`: on each device, the pixel 2 px right and
2 px below the top-left corner of the progress row's first cell has the color
`F9F1A5` (Yellow, the progress background; the cell's center can fall on the
black glyph), and the same pixel of the first cell of the empty area below the
editor has `0C0C0C`. Report the cell size, the rows and the two
pixel values per device, and whether each process stayed alive.

## Report

For each task: the files created, the exact commands run, the log lines, and
anything not done. Do not claim a result that is not in a log line or a
capture.
