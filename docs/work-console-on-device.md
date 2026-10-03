# Console core on Android devices: test protocol

Completed 2026-09-27. The results are recorded in `AGENTS.md` and the checked
console item in `ROADMAP.md`. This file is the reproducible protocol for the
two device tests.

## Components

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
  `screencap` per device. The app must be installed as a `-Debuggable` build.
- The vectors: 63 JSON files from the admitted reference input directory.

## Device constraints

- These receipts used the earlier 91-image payload without cmdlet modules, so
  the probes use .NET instead of commands such as `Join-Path`, `Test-Path`,
  `Add-Member`, `ConvertFrom-Json`, `Write-Host`, `Measure-Object`,
  `Get-Content` or `Get-ChildItem`: `[IO.Path]::Combine`, `[IO.File]::Exists`,
  `[IO.File]::ReadAllText`, `[IO.Directory]::GetFiles`. `ForEach-Object`,
  `Where-Object` and `Import-Module` are in SMA.
- JSON is parsed with `[Newtonsoft.Json.Linq.JToken]::Parse($text)`.
- PowerShell variable names are case-insensitive: a local `$m` overwrites a
  script-level `$M`.
- In a class method, a local variable may not share a name with a property.
- An `if` expression that yields a one-element array unrolls it; type the
  variable (`[int[]] $x = if (...) { @(0) } else { $y }`).
- An exception that escapes a window callback aborts the process. Every
  callback catches everything, including failures of its own logging.
- Everything runs on the main thread. No loops that wait, poll or sleep.
- Logging uses `Write-AndroidLog` (tag `Pwsh`); `tools/Invoke-DeviceScript.ps1`
  collects those lines.

## Test 1: the vectors on the devices

`scripts/probes/console-vectors/Profile.ps1`, placed in one directory with
`modules/Console.psm1`, `modules/AndroidCanvas.psm1` (for `Write-AndroidLog`)
and the 63 vector files:

1. imports both modules with `Import-Module ([IO.Path]::Combine($PSScriptRoot, '<file>'))`;
2. replays every `*.json` in `$PSScriptRoot` the way `Invoke-Step` in
   `tools/Test-ConsoleVectors.ps1` does, reading fields from the `JToken`;
3. compares cells, cursor and, when present, `expect.ops` exactly as
   `tools/Test-ConsoleVectors.ps1` does;
4. logs one line per failing vector, then `CONSOLE PASS <n> FAIL <m>`.

Acceptance: `CONSOLE PASS 63 FAIL 0` on every backend, each process alive
afterwards with no crash lines.

## Test 2: the console on the screen

`scripts/probes/console-screen/Profile.ps1`, placed with `modules/Console.psm1`
and `modules/AndroidCanvas.psm1`:

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

Acceptance, with `-CapturePath`: on each backend, the pixel 2 px right and
2 px below the top-left corner of the progress row's first cell has the color
`F9F1A5` (Yellow, the progress background; the cell's center can fall on the
black glyph), and the same pixel of the first cell of the empty area below the
editor has `0C0C0C`. Each receipt records the cell size, the rows, the two
pixel values and process liveness.
