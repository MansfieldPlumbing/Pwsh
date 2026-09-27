# Draws the console core's frame on the app window through AndroidCanvas
# (docs/work-console-on-device.md, task 2). Place with Console.psm1 and
# AndroidCanvas.psm1. The window buffer is not preserved between locks, so
# each draw is a full frame: Compare-ConsoleFrame against $null.
$ErrorActionPreference = 'Stop'
Import-Module ([IO.Path]::Combine($PSScriptRoot, 'AndroidCanvas.psm1'))
Import-Module ([IO.Path]::Combine($PSScriptRoot, 'Console.psm1'))
Initialize-AndroidCanvas -NativeActivity $NativeActivityHandle
# Fluent UI System Icons (MIT, microsoft/fluentui-system-icons a563cf91), placed beside this profile.
$global:IconFont = Get-AndroidTypeface ([IO.Path]::Combine($PSScriptRoot, 'FluentSystemIcons-Regular.ttf'))
$global:IconGear = [char]::ConvertFromUtf32(0xF6AA)   # ic_fluent_settings_24_regular

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
    $m.SetEditorColors((Get-ConsoleHighlight $m.GetEditorText()))   # the prompt line, highlighted by SMA's tokens
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
    # The settings gear, top right of the visible area.
    $gear = [float]([Math]::Max(1.3 * $ch, 48))
    $global:ConsoleGear = @{ Left = $inset.Left + $areaW - 1.4 * $gear; Top = $inset.Top; Size = $gear }
    Add-CanvasText $Canvas $global:IconGear -X ([float]$global:ConsoleGear.Left) -Y ([float]($inset.Top + 1.05 * $gear)) -Size $gear -Color (ConvertTo-CanvasColor 0xcccccc) -Typeface $global:IconFont
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
# The wall: a gesture-threshold haptic (API 34; REJECT before it) and a thud
# pitched for a phone speaker, which reproduces little below about 200 Hz:
# 140 ms, a tone falling 260 Hz to 110 Hz with its second harmonic, soft
# clipped for body, a 2 ms attack and a 45 ms decay. The haptic carries the low end.
# AAUDIO_USAGE_GAME (14): follows media volume, not the often-muted system volume.
$rate = Open-AudioOutput -Usage 14
$n = [int]($rate * 0.14); $global:ConsoleThud = [float[]]::new($n); $phase = 0.0; $peak = 0.0
for ($i = 0; $i -lt $n; $i++) {
    $sec = $i / $rate; $f = 180 + 240 * [Math]::Exp(-$sec / 0.035); $phase += 2 * [Math]::PI * $f / $rate
    $env = [Math]::Min(1.0, $sec / 0.002) * [Math]::Exp(-$sec / 0.05)
    $v = [Math]::Tanh(2.5 * ([Math]::Sin($phase) + 0.5 * [Math]::Sin(2 * $phase))) * $env
    $global:ConsoleThud[$i] = [float]$v; $peak = [Math]::Max($peak, [Math]::Abs($v))
}
for ($i = 0; $i -lt $n; $i++) { $global:ConsoleThud[$i] = [float](0.98 * $global:ConsoleThud[$i] / $peak) }   # peak at -0.2 dBFS
function global:Invoke-ConsoleWall {
    try { Invoke-HapticFeedback -Constant 'GESTURE_THRESHOLD_ACTIVATE' } catch { Invoke-HapticFeedback -Constant 'REJECT' }
    [void](Write-AudioOutput -Samples $global:ConsoleThud)
}
Write-AndroidLog ("CONSOLE audio {0} Hz, thud {1} frames" -f $rate, $n)
$global:ConsoleDirty = $false; $global:ConsoleAtWall = $false
function global:Get-ConsoleCell([float] $X, [float] $Y) {
    $l = $global:ConsoleProbeLayout
    @([int][Math]::Floor(($Y - $l.Top) / $l.CellH), [int][Math]::Floor(($X - $l.Left) / $l.CellW))
}
# Enter runs the typed command in this runspace and writes its output as text
# (no formatting cmdlets ship yet, so objects show their ToString()).
function global:Invoke-ConsoleCommand {
    $m = $global:ConsoleProbeModel
    $cmd = $m.Submit()
    $m.Write('Output', "PS> $(Format-ConsoleHighlight $cmd)`n")
    if ($cmd.Trim().Length -gt 0) {
        try {
            foreach ($o in @(& ([scriptblock]::Create($cmd)) 2>&1)) {
                if ($o -is [System.Management.Automation.ErrorRecord]) { $m.Write('Error', "$o`n") }
                elseif ($null -ne $o) { $m.Write('Output', "$o`n") }
            }
        }
        catch { $m.Write('Error', "$($_.Exception.Message)`n") }
    }
    Write-AndroidLog "CONSOLE RAN $($cmd.Length) chars"
    $global:ConsoleDirty = $true
}
$global:ConsoleKeyboard = $false
function global:Switch-ConsoleKeyboard {
    if ($global:ConsoleKeyboard) { Hide-SoftKeyboard } else { Show-SoftKeyboard }
    $global:ConsoleKeyboard = -not $global:ConsoleKeyboard
    Invoke-HapticFeedback
}

# Holds, timed by the looper timer (no polling):
#   one finger, held still          -> paste
#   tap, then touch again and hold  -> Enter
#   two fingers, held still         -> show or hide the keyboard
Register-LooperTimer -OnElapsed {
    $g = $global:G
    switch ($g.Mode) {
        'pending' {
            $g.Mode = 'done'; Invoke-HapticFeedback
            $text = Get-AndroidClipboard
            if ($text.Length -gt 0) { $global:ConsoleProbeModel.EditorInsert($text) }
            Write-AndroidLog ("CONSOLE PASTED {0} chars" -f $text.Length); Request-WindowDraw
        }
        'pending2' { $g.Mode = 'done'; Invoke-HapticFeedback; Invoke-ConsoleCommand; Request-WindowDraw }
        'two' { $g.Mode = 'twodone'; Switch-ConsoleKeyboard }
    }
}
$global:G.LastTapTicks = 0L; $global:G.LastTapX = 0.0; $global:G.LastTapY = 0.0; $global:G.TpAcc = 0.0
Register-InputHandler -Handle {
    param($Event)
    $g = $global:G; $l = $global:ConsoleProbeLayout; $m = $global:ConsoleProbeModel
    # --- keys (hardware keyboard, or the soft keyboard's key events) ---
    if ($Event.Type -eq 'key') {
        if ($global:ConsoleKeyLog) { Write-AndroidLog ("KEY action {0} code {1} unicode {2} meta {3}" -f $Event.Action, $Event.KeyCode, $Event.Unicode, $Event.MetaState) }
        if ($Event.KeyCode -in 3, 4, 24, 25, 26, 164) { return $false }   # home, back, volume, power, mute stay with Android
        if ($Event.Action -ne 0) { return $true }                          # consume the up of keys we handle
        switch ($Event.KeyCode) {
            { $_ -in 66, 160 } { Invoke-ConsoleCommand }                   # ENTER, NUMPAD_ENTER
            61 { [void](Invoke-ConsoleCompletion $m -Reverse:(($Event.MetaState -band 1) -ne 0)) }   # TAB; META_SHIFT_ON 1 steps back
            67 { $m.EditorBackspace() }                                      # DEL
            112 { $m.EditorDelete() }                                        # FORWARD_DEL
            21 { $m.EditorMove(-1) }                                         # DPAD_LEFT
            22 { $m.EditorMove(1) }                                          # DPAD_RIGHT
            19 { $m.HistoryUp() }                                            # DPAD_UP
            20 { $m.HistoryDown() }                                          # DPAD_DOWN
            122 { $m.EditorHome() }                                          # MOVE_HOME
            123 { $m.EditorEnd() }                                           # MOVE_END
            default { if ($Event.Unicode -gt 0) { $m.EditorInsert([char]::ConvertFromUtf32($Event.Unicode)) } else { return $false } }
        }
        $global:ConsoleDirty = $true
        return $true
    }
    if ($null -eq $l) { return $true }
    # --- mouse (AINPUT_SOURCE_MOUSE 0x2002): drag selects, right click pastes, wheel scrolls ---
    if (($Event.Source -band 0x2002) -eq 0x2002) {
        switch ($Event.Action) {
            8 { $rows = [int][Math]::Round(3 * $Event.VScroll); if ($rows -ne 0) { $m.Scroll($rows); $global:ConsoleDirty = $true } }
            0 {
                if ($Event.Buttons -band 2) {
                    $text = Get-AndroidClipboard; if ($text.Length -gt 0) { $m.EditorInsert($text); $global:ConsoleDirty = $true }
                    $g.Mode = 'done'
                }
                else { $c = Get-ConsoleCell $Event.X $Event.Y; $g.Mode = 'mselect'; $g.MA = $c; $g.MF = $c; $m.ClearSelection(); $global:ConsoleDirty = $true }
            }
            2 {
                if ($g.Mode -eq 'mselect') {
                    $c = Get-ConsoleCell $Event.X $Event.Y
                    if ($null -ne $m.PositionAt($c[0], $c[1])) { $g.MF = $c }
                    $pa = $m.PositionAt($g.MA[0], $g.MA[1]); $pf = $m.PositionAt($g.MF[0], $g.MF[1])
                    if ($null -ne $pa -and $null -ne $pf -and ($g.MA[0] -ne $g.MF[0] -or $g.MA[1] -ne $g.MF[1])) { $m.SetSelection($pa, $pf, $false); $global:ConsoleDirty = $true }
                }
            }
            1 {
                if ($g.Mode -eq 'mselect' -and $m.HasSelection()) { $text = $m.SelectionText(); Set-AndroidClipboard -Text $text; Write-AndroidLog ("CONSOLE COPIED {0} chars, mouse" -f $text.Length) }
                $g.Mode = 'none'
            }
        }
        return $true
    }
    # --- touchpad gestures (classification TWO_FINGER_SWIPE 3, PINCH 5) ---
    if ($Event.Classification -eq 3 -and $Event.Action -eq 2) {
        $g.TpAcc = $g.TpAcc + $Event.GestureScrollY
        $rows = [int][Math]::Truncate($g.TpAcc / $l.CellH)
        if ($rows -ne 0) { $m.Scroll(-$rows); $g.TpAcc = $g.TpAcc - $rows * $l.CellH; $global:ConsoleDirty = $true }
        return $true
    }
    if ($Event.Classification -eq 5 -and $Event.Action -eq 2 -and $Event.PinchScale -gt 0) {
        $z = $global:ConsoleZoom; $max = [Math]::Floor([Math]::Min($z.AreaW / $z.WidthPerPx, $z.AreaH / $z.HeightPerPx))
        $size = [float][Math]::Min($max, [Math]::Max(6, $global:ConsoleTextSize * $Event.PinchScale))
        if ([Math]::Abs($size - $global:ConsoleTextSize) -ge 1) { $global:ConsoleTextSize = $size; $global:ConsoleDirty = $true }
        return $true
    }
    if ($Event.Action -eq 7 -or $Event.Action -eq 8) { return $true }   # hover, scroll from other pointers
    # --- touch: two fingers ---
    if ($Event.Pointers -ge 2) {
        $d = [Math]::Sqrt([Math]::Pow($Event.X2 - $Event.X, 2) + [Math]::Pow($Event.Y2 - $Event.Y, 2))
        if ($g.Mode -notin 'two', 'pinch', 'twodone') {
            Stop-LooperTimer; $g.Mode = 'two'
            $global:ConsolePinch = @{ Distance = [Math]::Max(1.0, $d); Size = [float]$global:ConsoleTextSize }
            Start-LooperTimer -Milliseconds 500
            return $true
        }
        if ($g.Mode -eq 'twodone') { return $true }
        if ($g.Mode -eq 'two') {
            if ([Math]::Abs($d / $global:ConsolePinch.Distance - 1) -lt 0.08) { return $true }   # still a hold
            Stop-LooperTimer; $g.Mode = 'pinch'
        }
        if ($Event.Action -eq 2) {
            # Zoom in until one cell fills the visible area; zoom out to 6 px text.
            $z = $global:ConsoleZoom
            $max = [Math]::Floor([Math]::Min($z.AreaW / $z.WidthPerPx, $z.AreaH / $z.HeightPerPx))
            # Squared ratio: one confident pinch spans normal text to a single cell.
            $want = $global:ConsolePinch.Size * [Math]::Pow($d / $global:ConsolePinch.Distance, 2)
            $size = [float][Math]::Min($max, [Math]::Max(6, $want))
            # One bump per arrival; the wall re-arms only after pulling back 10% from the limit.
            if (-not $global:ConsoleAtWall -and ($want -ge $max -or $want -le 6)) { Invoke-ConsoleWall; $global:ConsoleAtWall = $true }
            elseif ($global:ConsoleAtWall -and $want -lt 0.9 * $max -and $want -gt 6.6) { $global:ConsoleAtWall = $false }
            if ([Math]::Abs($size - $global:ConsoleTextSize) -ge 1) { $global:ConsoleTextSize = $size; $global:ConsoleDirty = $true }
        }
        return $true
    }
    # --- touch: one finger ---
    switch ($Event.Action) {
        0 {   # DOWN
            $edge = $global:ConsoleGestureInsets
            if ($Event.X -lt $edge.Left -or $Event.X -gt ($global:ConsoleSurfaceWidth - $edge.Right)) { $g.Mode = 'ignored'; return $false }
            $near = [Math]::Abs($Event.X - $g.LastTapX) -lt 1.5 * $l.CellW -and [Math]::Abs($Event.Y - $g.LastTapY) -lt 1.5 * $l.CellH
            $recent = ([DateTime]::UtcNow.Ticks - $g.LastTapTicks) -lt 3000000   # 300 ms
            $g.Mode = if ($near -and $recent) { 'pending2' } else { 'pending' }
            $g.X0 = $Event.X; $g.Y0 = $Event.Y; $g.LastY = $Event.Y; $g.ByLine = $false
            Start-LooperTimer -Milliseconds 500
        }
        2 {   # MOVE
            $dx = $Event.X - $g.X0; $dy = $Event.Y - $g.Y0
            if ($g.Mode -in 'pending', 'pending2') {
                if ([Math]::Max([Math]::Abs($dx), [Math]::Abs($dy)) -lt 0.6 * $l.CellW) { return $true }
                Stop-LooperTimer
                if ([Math]::Abs($dx) -ge 1.7 * [Math]::Abs($dy)) {
                    $c = Get-ConsoleCell $g.X0 $g.Y0
                    $g.Mode = if ($null -ne $m.PositionAt($c[0], $c[1])) { 'select' } else { 'none' }
                }
                elseif ([Math]::Abs($dy) -ge 1.7 * [Math]::Abs($dx)) { $g.Mode = 'scroll' }
                else { return $true }
            }
            if ($g.Mode -eq 'select') {
                # The selection follows the rows on screen: by character in reading
                # order, or once the finger has moved a row, whole visible rows.
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
                if ($rows -ne 0) { $m.Scroll(-$rows); $g.LastY = $g.LastY + $rows * $l.CellH; $global:ConsoleDirty = $true }
            }
        }
        { $_ -eq 1 -or $_ -eq 3 } {   # UP, CANCEL
            Stop-LooperTimer
            if ($g.Mode -eq 'select' -and $Event.Action -eq 1) {
                $text = $m.SelectionText(); Set-AndroidClipboard -Text $text; Invoke-HapticFeedback
                Write-AndroidLog ("CONSOLE COPIED {0} chars, {1}" -f $text.Length, $(if ($g.ByLine) { 'lines' } else { 'characters' }))
            }
            elseif ($g.Mode -in 'pending', 'pending2') {   # a tap: clears a selection, and arms tap-then-hold
                if ($m.HasSelection()) { $m.ClearSelection(); $global:ConsoleDirty = $true }
                $g.LastTapTicks = [DateTime]::UtcNow.Ticks; $g.LastTapX = $Event.X; $g.LastTapY = $Event.Y
            }
            $g.Mode = 'none'; $g.FocusCell = $null
        }
    }
    $true
} -AfterInput {
    if ($global:ConsoleDirty) { $global:ConsoleDirty = $false; Request-WindowDraw }
}
Write-AndroidLog 'CONSOLE handler registered'
