# Draws the console core's frame on the app window through AndroidCanvas
# (docs/work-console-on-device.md, task 2). Place with Console.psm1 and
# AndroidCanvas.psm1. The window buffer is not preserved between locks, so
# each draw is a full frame: Compare-ConsoleFrame against $null.
$ErrorActionPreference = 'Stop'
Import-Module ([IO.Path]::Combine($PSScriptRoot, 'AndroidCanvas.psm1'))
Import-Module ([IO.Path]::Combine($PSScriptRoot, 'Console.psm1'))
Initialize-AndroidCanvas -NativeActivity $NativeActivityHandle

function global:ConvertTo-CanvasColor([int] $Rgb) {
    ConvertTo-ArgbColor (($Rgb -shr 16) -band 0xff) (($Rgb -shr 8) -band 0xff) ($Rgb -band 0xff)
}

Register-WindowDrawHandler {
    param($Canvas)
    $size = Get-CanvasSize $Canvas
    $inset = Get-SystemBarInsets
    $areaW = $size.Width - $inset.Left - $inset.Right; $areaH = $size.Height - $inset.Top - $inset.Bottom
    if ($null -eq $global:ConsoleTextSize) { $global:ConsoleTextSize = [float]([Math]::Min($size.Width, $size.Height) / 30) }
    $textSize = [float]$global:ConsoleTextSize
    $cell = Get-TextCell $textSize
    # The grid always fits the visible area: whole cells only, nothing off the surface, no scroll bars.
    $cols = [Math]::Max(1, [int][Math]::Floor($areaW / $cell.Width)); $rows = [Math]::Max(1, [int][Math]::Floor($areaH / $cell.Height))
    if ($null -eq $global:ConsoleProbeModel) {
        $m = New-ConsoleModel $cols $rows
        $m.Write('Output', 'Pinch to change the cell size. Every logical line re-wraps at the new width, so this sentence reflows instead of being cut off or scrolled sideways.')
        foreach ($stream in 'Output', 'Error', 'Warning', 'Verbose', 'Debug', 'Information') { $m.Write($stream, "$stream stream") }
        $m.Write('Output', "`e[38;5;208m256-color `e[38;2;58;150;221mtruecolor`e[0m plain")
        $m.WriteProgress(1, 'Probe', 'Drawing', 50, $false)
        $global:ConsoleProbeModel = $m
    }
    $m = $global:ConsoleProbeModel
    if ($m.GetCols() -ne $cols -or $m.GetRows() -ne $rows) { $m.Resize($cols, $rows) }   # reflow
    $frame = New-ConsoleFrame $m
    [void]$m.Compose($frame)
    $cw = [float]$cell.Width; $ch = [float]$cell.Height
    Clear-Canvas $Canvas -Color (ConvertTo-CanvasColor 0x0c0c0c)
    foreach ($op in (Compare-ConsoleFrame -Previous $null -Next $frame -Columns $m.GetCols() -Rows $m.GetRows())) {
        $x = [float]($inset.Left + $op.Col * $cw); $y = [float]($inset.Top + $op.Row * $ch)
        if ($op.Kind -eq 'fill') {
            Add-CanvasRect $Canvas $x $y ([float]($x + $op.Count * $cw)) ([float]($y + $ch)) -Color (ConvertTo-CanvasColor $op.Bg)
        }
        elseif ($op.Text.Trim().Length -gt 0) {
            Add-CanvasText $Canvas $op.Text -X $x -Y ([float]($y + 0.8 * $ch)) -Size $textSize -Color (ConvertTo-CanvasColor $op.Fg)
        }
    }
    # The progress row: the first row whose first cell has palette background 11.
    $progressRow = -1
    for ($r = 0; $r -lt $m.GetRows(); $r++) { $w2 = $frame[($r * $m.GetCols()) * 3 + 2]; if ((($w2 -shr 24) -band 3) -eq 1 -and ($w2 -band 0xff) -eq 11) { $progressRow = $r; break } }
    $global:ConsoleProbeLayout = @{ Left = $inset.Left; Top = $inset.Top; CellW = $cw; CellH = $ch }
    Write-AndroidLog ("CONSOLE DREW {0}x{1} cell {2:N1}x{3:N1} progressRow {4} insets {5},{6},{7},{8}" -f $m.GetCols(), $m.GetRows(), $cw, $ch, $progressRow, $inset.Left, $inset.Top, $inset.Right, $inset.Bottom)
}
# Consume every input event (an unread queue makes Android report the app as
# not responding) and log taps as console cells; hit regions come next.
# Pinch: the text size follows the ratio of the two pointers' distance to the
# distance when the second pointer went down, clamped to 12-160 px.
$global:ConsolePinch = $null; $global:ConsoleResized = $false
Register-InputHandler -Handle {
    param($Event)
    if ($Event.Type -ne 'motion') { return $true }
    if ($Event.Pointers -ge 2) {
        $d = [Math]::Sqrt([Math]::Pow($Event.X2 - $Event.X, 2) + [Math]::Pow($Event.Y2 - $Event.Y, 2))
        if ($Event.Action -eq 5 -or $null -eq $global:ConsolePinch) { $global:ConsolePinch = @{ Distance = [Math]::Max(1.0, $d); Size = [float]$global:ConsoleTextSize } }   # POINTER_DOWN
        elseif ($Event.Action -eq 2) {                                                                                                   # MOVE
            $size = [float][Math]::Min(160, [Math]::Max(12, $global:ConsolePinch.Size * $d / $global:ConsolePinch.Distance))
            if ([Math]::Abs($size - $global:ConsoleTextSize) -ge 1) { $global:ConsoleTextSize = $size; $global:ConsoleResized = $true }
        }
    }
    elseif ($Event.Action -eq 0 -and $null -ne $global:ConsoleProbeLayout) {                                                           # DOWN
        $l = $global:ConsoleProbeLayout
        Write-AndroidLog ('CONSOLE TAP x{0:N0} y{1:N0} cell {2},{3}' -f $Event.X, $Event.Y, [Math]::Floor(($Event.X - $l.Left) / $l.CellW), [Math]::Floor(($Event.Y - $l.Top) / $l.CellH))
    }
    if ($Event.Action -eq 1 -or $Event.Action -eq 3) { $global:ConsolePinch = $null }                                                 # UP, CANCEL
    $true
} -AfterInput {
    if ($global:ConsoleResized) { $global:ConsoleResized = $false; Request-WindowDraw }
}
Write-AndroidLog 'CONSOLE handler registered'
