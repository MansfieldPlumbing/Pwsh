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
    $global:ConsoleSurfaceWidth = $size.Width
    $global:ConsoleZoom = @{ AreaW = $areaW; AreaH = $areaH; WidthPerPx = $cw / $textSize; HeightPerPx = $ch / $textSize }
    if ($null -eq $global:ConsoleGestureInsets) { $global:ConsoleGestureInsets = Get-SystemBarInsets -Gestures }
    Write-AndroidLog ("CONSOLE DREW {0}x{1} cell {2:N1}x{3:N1} progressRow {4} insets {5},{6},{7},{8}" -f $m.GetCols(), $m.GetRows(), $cw, $ch, $progressRow, $inset.Left, $inset.Top, $inset.Right, $inset.Bottom)
}
# Consume every input event (an unread queue makes Android report the app as
# not responding) and log taps as console cells; hit regions come next.
# Gestures, one mode per touch, decided by the first movement and kept until lift:
#   vertical first  -> scroll by whole rows
#   horizontal first -> select by character from the touch-down cell; once the
#                       finger has moved a row vertically, by whole lines; lift copies
#   still for 500 ms -> long press: haptic and paste the clipboard into the editor
#   two fingers      -> pinch: text size and reflow
# Touches that start inside Android's edge-gesture zones are left to Android.
$global:G = @{ Mode = 'none' }
$global:ConsoleDirty = $false
function global:Get-ConsoleCell([float] $X, [float] $Y) {
    $l = $global:ConsoleProbeLayout
    @([int][Math]::Floor(($Y - $l.Top) / $l.CellH), [int][Math]::Floor(($X - $l.Left) / $l.CellW))
}
Register-LooperTimer -OnElapsed {
    if ($global:G.Mode -ne 'pending') { return }
    $global:G.Mode = 'pasted'
    Invoke-HapticFeedback
    $text = Get-AndroidClipboard
    if ($text.Length -gt 0) { $global:ConsoleProbeModel.EditorInsert($text) }
    Write-AndroidLog ("CONSOLE PASTED {0} chars" -f $text.Length)
    Request-WindowDraw
}
Register-InputHandler -Handle {
    param($Event)
    if ($Event.Type -ne 'motion' -or $null -eq $global:ConsoleProbeLayout) { return $true }
    $g = $global:G; $l = $global:ConsoleProbeLayout; $m = $global:ConsoleProbeModel
    if ($Event.Pointers -ge 2) {
        if ($g.Mode -ne 'pinch') { Stop-LooperTimer; $g.Mode = 'pinch'; $global:ConsolePinch = $null }
        $d = [Math]::Sqrt([Math]::Pow($Event.X2 - $Event.X, 2) + [Math]::Pow($Event.Y2 - $Event.Y, 2))
        if ($null -eq $global:ConsolePinch) { $global:ConsolePinch = @{ Distance = [Math]::Max(1.0, $d); Size = [float]$global:ConsoleTextSize } }
        elseif ($Event.Action -eq 2) {
            # Zoom in until one cell fills the visible area; zoom out to 6 px text.
            $z = $global:ConsoleZoom
            $max = [Math]::Floor([Math]::Min($z.AreaW / $z.WidthPerPx, $z.AreaH / $z.HeightPerPx))
            $size = [float][Math]::Min($max, [Math]::Max(6, $global:ConsolePinch.Size * $d / $global:ConsolePinch.Distance))
            if ([Math]::Abs($size - $global:ConsoleTextSize) -ge 1) { $global:ConsoleTextSize = $size; $global:ConsoleDirty = $true }
        }
        return $true
    }
    switch ($Event.Action) {
        0 {   # DOWN
            $edge = $global:ConsoleGestureInsets
            if ($Event.X -lt $edge.Left -or $Event.X -gt ($global:ConsoleSurfaceWidth - $edge.Right)) { $g.Mode = 'ignored'; return $false }
            $g.Mode = 'pending'; $g.X0 = $Event.X; $g.Y0 = $Event.Y; $g.LastY = $Event.Y; $g.ByLine = $false
            Start-LooperTimer -Milliseconds 500
        }
        2 {   # MOVE
            $dx = $Event.X - $g.X0; $dy = $Event.Y - $g.Y0
            if ($g.Mode -eq 'pending') {
                if ([Math]::Max([Math]::Abs($dx), [Math]::Abs($dy)) -lt 0.6 * $l.CellW) { return $true }
                Stop-LooperTimer
                if ([Math]::Abs($dx) -ge 1.7 * [Math]::Abs($dy)) {
                    $c = Get-ConsoleCell $g.X0 $g.Y0
                    $g.Anchor = $m.PositionAt($c[0], $c[1])
                    $g.Mode = if ($null -ne $g.Anchor) { 'select' } else { 'none' }
                }
                elseif ([Math]::Abs($dy) -ge 1.7 * [Math]::Abs($dx)) { $g.Mode = 'scroll' }
                else { return $true }   # still ambiguous: wait for more movement
            }
            if ($g.Mode -eq 'select') {
                # The selection follows the rows on screen: by character in reading
                # order, or once the finger has moved a row, whole visible rows from
                # the touched row to the row under the finger. Endpoints are stored
                # as text positions, so a later reflow keeps the same text.
                if ([Math]::Abs($dy) -ge $l.CellH) { $g.ByLine = $true }
                $a = Get-ConsoleCell $g.X0 $g.Y0; $c = Get-ConsoleCell $Event.X $Event.Y
                if ($null -ne $m.PositionAt($c[0], $c[1])) { $g.FocusCell = $c }
                $f = if ($null -ne $g.FocusCell) { $g.FocusCell } else { $a }
                if ($g.ByLine) {
                    $last = $m.GetCols() - 1
                    $forward = ($f[0] -gt $a[0]) -or ($f[0] -eq $a[0] -and $f[1] -ge $a[1])
                    if ($forward) { $m.SetSelection($m.PositionAt($a[0], 0), $m.PositionAt($f[0], $last), $false) }
                    else { $m.SetSelection($m.PositionAt($a[0], $last), $m.PositionAt($f[0], 0), $false) }
                }
                else { $m.SetSelection($m.PositionAt($a[0], $a[1]), $m.PositionAt($f[0], $f[1]), $false) }
                $global:ConsoleDirty = $true
            }
            elseif ($g.Mode -eq 'scroll') {
                $rows = [int][Math]::Truncate(($Event.Y - $g.LastY) / $l.CellH)
                if ($rows -ne 0) { $m.Scroll(-$rows); $g.LastY += $rows * $l.CellH; $global:ConsoleDirty = $true }
            }
        }
        { $_ -eq 1 -or $_ -eq 3 } {   # UP, CANCEL
            Stop-LooperTimer
            if ($g.Mode -eq 'select' -and $Event.Action -eq 1) {
                $text = $m.SelectionText()
                Set-AndroidClipboard -Text $text
                Invoke-HapticFeedback
                Write-AndroidLog ("CONSOLE COPIED {0} chars, {1}" -f $text.Length, $(if ($g.ByLine) { 'lines' } else { 'characters' }))
            }
            elseif ($g.Mode -eq 'pending' -and $m.HasSelection()) { $m.ClearSelection(); $global:ConsoleDirty = $true }   # tap clears
            $g.Mode = 'none'; $g.FocusCell = $null
        }
    }
    $true
} -AfterInput {
    if ($global:ConsoleDirty) { $global:ConsoleDirty = $false; Request-WindowDraw }
}
Write-AndroidLog 'CONSOLE handler registered'
