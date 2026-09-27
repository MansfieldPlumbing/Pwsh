<#
.SYNOPSIS
    Replays the console reference's conformance vectors against
    modules/Console.psm1 and runs the frame-ring tests.

.DESCRIPTION
    Each vector (docs/console-reference.md, "Conformance vectors") names
    ConsoleModel operations, the cells and cursor to expect, and for diff
    vectors the exact draw ops. The vectors live with the reference
    implementation, outside this repository; pass their directory.
#>
param(
    [Parameter(Mandatory)][string] $VectorPath,
    [string] $ModulePath = (Join-Path $PSScriptRoot '..\modules\Console.psm1')
)
$ErrorActionPreference = 'Stop'
Import-Module $ModulePath -Force
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0

function Invoke-Step($model, $step, [ref] $snapshot) {
    switch ($step.op) {
        'write' {
            $fg = if ($step.PSObject.Properties['fg']) { $step.fg } else { $null }
            $bg = if ($step.PSObject.Properties['bg']) { $step.bg } else { $null }
            $model.Write($step.stream, $step.text, $fg, $bg)
        }
        'writeProgress' { $model.WriteProgress($step.activityId, $step.activity, $step.status, $step.percent, $step.completed) }
        'setPrompt' { $model.SetPrompt($step.prompt) }
        'editorInsert' { $model.EditorInsert($step.text) }
        'editorBackspace' { $model.EditorBackspace() }
        'editorDelete' { $model.EditorDelete() }
        'editorMove' { $model.EditorMove($step.delta) }
        'editorHome' { $model.EditorHome() }
        'editorEnd' { $model.EditorEnd() }
        'editorSetComposition' { $model.EditorSetComposition($step.text) }
        'historyUp' { $model.HistoryUp() }
        'historyDown' { $model.HistoryDown() }
        'submit' { [void]$model.Submit() }
        'scroll' { $model.Scroll($step.deltaRows) }
        'resize' { $model.Resize($step.cols, $step.rows) }
        'snapshot' { $f = New-ConsoleFrame $model; [void]$model.Compose($f); $snapshot.Value = $f }
        default { throw "Unknown op '$($step.op)'." }
    }
}

foreach ($file in Get-ChildItem (Join-Path $VectorPath '*.json') | Sort-Object Name) {
    $v = Get-Content $file.FullName -Raw | ConvertFrom-Json
    $problems = [System.Collections.Generic.List[string]]::new()
    try {
        $model = New-ConsoleModel $v.cols $v.rows
        $snap = $null
        foreach ($s in $v.steps) { Invoke-Step $model $s ([ref]$snap) }
        $cols = $model.GetCols(); $rows = $model.GetRows()
        $frame = New-ConsoleFrame $model
        $cursor = $model.Compose($frame)
        foreach ($c in $v.expect.cells) {
            $i = ($c[0] * $cols + $c[1]) * 3
            $w0 = $frame[$i]; $w1 = $frame[$i + 1]; $w2 = $frame[$i + 2]
            $fgMode = ($w1 -shr 24) -band 3; $bgMode = ($w2 -shr 24) -band 3
            $got = @(($w0 -band 0x1fffff), (($w0 -shr 21) -band 3), (($w0 -shr 23) -band 0x3f),
                $fgMode, $(if ($fgMode -eq 1) { $w1 -band 0xff } else { $w1 -band 0xffffff }),
                $bgMode, $(if ($bgMode -eq 1) { $w2 -band 0xff } else { $w2 -band 0xffffff }))
            $want = @($c[2..8])
            if (($got -join ',') -ne ($want -join ',')) { $problems.Add("cell r$($c[0])c$($c[1]) got [$($got -join ',')] want [$($want -join ',')]") }
        }
        $gotCursor = "$($cursor.Col),$($cursor.Row),$($cursor.Visible)"
        $wantCursor = "$($v.expect.cursor[0]),$($v.expect.cursor[1]),$($v.expect.cursor[2])"
        if ($gotCursor -ne $wantCursor) { $problems.Add("cursor got $gotCursor want $wantCursor") }
        if ($v.expect.PSObject.Properties['ops']) {
            $ops = Compare-ConsoleFrame -Previous $snap -Next $frame -Columns $cols -Rows $rows
            $fmt = { param($o) if ($o.Kind -eq 'fill' -or $o.kind -eq 'fill') { "fill r$($o.Row)c$($o.Col)x$($o.Count) bg$($o.Bg)" } else { "text r$($o.Row)c$($o.Col) '$($o.Text)' x$($o.Cells) fg$($o.Fg) a$($o.Attrs)" } }
            $gotOps = @($ops | ForEach-Object { & $fmt $_ }) -join ' | '
            $wantOps = @($v.expect.ops | ForEach-Object { & $fmt ([pscustomobject]@{ Kind = $_.kind; Row = $_.row; Col = $_.col; Count = $_.count; Bg = $_.bg; Text = $_.text; Cells = $_.cells; Fg = $_.fg; Attrs = $_.attrs }) }) -join ' | '
            if ($gotOps -ne $wantOps) { $problems.Add("ops got [$gotOps] want [$wantOps]") }
        }
    }
    catch { $problems.Add("threw $($_.Exception.Message)") }
    if ($problems.Count) { $failures.Add("$($file.BaseName): $($problems -join '; ')") } else { $passed++ }
}

# Frame ring: two instances over one buffer, a held reader slot, and a retry.
$ringChecks = [ordered]@{}
$size = Get-ConsoleFrameRingSize 4 2
$mem = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($size)
try {
    [System.Runtime.InteropServices.Marshal]::Copy([byte[]]::new($size), 0, $mem, $size)
    $writer = New-ConsoleFrameRing $mem 4 2; $reader = New-ConsoleFrameRing $mem 4 2
    $cells = [int[]]::new(24); $cells[0] = 65
    $ringChecks['null before first commit'] = $null -eq $reader.AcquireLatest()
    $slot = $writer.BeginWrite(); $seq = $writer.Commit($slot, $cells, 1, 0, $true)
    $got = $reader.AcquireLatest()
    $ringChecks['reader sees writer frame'] = $got.Sequence -eq $seq -and $got.Cells[0] -eq 65 -and $got.CursorCol -eq 1
    # Hold slot k as the reader slot, then commit twice: neither write may use k.
    $k = [System.Runtime.InteropServices.Marshal]::ReadInt32($mem, 8)
    [System.Runtime.InteropServices.Marshal]::WriteInt32($mem, 12, $k)
    $s1 = $writer.BeginWrite(); [void]$writer.Commit($s1, $cells, 0, 0, $true)
    $s2 = $writer.BeginWrite(); [void]$writer.Commit($s2, $cells, 0, 0, $true)
    $ringChecks['writer never writes the held slot'] = $s1 -ne $k -and $s2 -ne $k
    [System.Runtime.InteropServices.Marshal]::WriteInt32($mem, 12, -1)
    $last = $reader.AcquireLatest()
    $ringChecks['newest sequence wins'] = $last.Sequence -eq ($seq + 2)
}
finally { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($mem) }
foreach ($e in $ringChecks.GetEnumerator()) { if ($e.Value) { $passed++ } else { $failures.Add("ring: $($e.Key)") } }

"passed $passed, failed $($failures.Count)"
$failures
if ($failures.Count) { exit 1 }
