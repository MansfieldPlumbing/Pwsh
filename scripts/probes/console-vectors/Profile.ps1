# Replays the console reference's conformance vectors against
# modules/Console.psm1 in the Pwsh app (docs/work-console-on-device.md,
# task 1). Place with Console.psm1, AndroidCanvas.psm1 and the vector files.
# Language, .NET and SMA only; JSON through Newtonsoft.Json, which ships.
$ErrorActionPreference = 'Stop'
Import-Module ([IO.Path]::Combine($PSScriptRoot, 'AndroidCanvas.psm1'))
Import-Module ([IO.Path]::Combine($PSScriptRoot, 'Console.psm1'))

# A JValue returned from a function is enumerated (to nothing), so return its
# value; containers are returned whole with the unary comma.
function Get-Field($token, [string] $name) {
    $t = $token[$name]
    if ($null -eq $t -or $t.Type -eq [Newtonsoft.Json.Linq.JTokenType]::Null) { return $null }
    if ($t -is [Newtonsoft.Json.Linq.JValue]) { return $t.Value }
    return , $t
}

function Invoke-Step($model, $step, [ref] $snapshot) {
    $op = [string]$step['op']
    switch ($op) {
        'write' {
            $fg = Get-Field $step 'fg'; $bg = Get-Field $step 'bg'
            $model.Write([string]$step['stream'], [string]$step['text'], $(if ($null -ne $fg) { [int]$fg } else { $null }), $(if ($null -ne $bg) { [int]$bg } else { $null }))
        }
        'writeProgress' { $model.WriteProgress([int]$step['activityId'], [string]$step['activity'], [string]$step['status'], [int]$step['percent'], [bool]$step['completed'].Value) }
        'setPrompt' { $model.SetPrompt([string]$step['prompt']) }
        'editorInsert' { $model.EditorInsert([string]$step['text']) }
        'editorBackspace' { $model.EditorBackspace() }
        'editorDelete' { $model.EditorDelete() }
        'editorMove' { $model.EditorMove([int]$step['delta']) }
        'editorHome' { $model.EditorHome() }
        'editorEnd' { $model.EditorEnd() }
        'editorSetComposition' { $model.EditorSetComposition([string]$step['text']) }
        'historyUp' { $model.HistoryUp() }
        'historyDown' { $model.HistoryDown() }
        'submit' { [void]$model.Submit() }
        'scroll' { $model.Scroll([int]$step['deltaRows']) }
        'resize' { $model.Resize([int]$step['cols'], [int]$step['rows']) }
        'snapshot' { $f = New-ConsoleFrame $model; [void]$model.Compose($f); $snapshot.Value = $f }
        default { throw "Unknown op '$op'." }
    }
}

function Format-Op([string] $kind, $row, $col, $count, $bg, $text, $cells, $fg, $attrs) {
    if ($kind -eq 'fill') { "fill r${row}c${col}x$count bg$bg" } else { "text r${row}c${col} '$text' x$cells fg$fg a$attrs" }
}

$pass = 0; $fail = 0
$paths = [IO.Directory]::GetFiles($PSScriptRoot, '*.json'); [Array]::Sort($paths, [StringComparer]::Ordinal)
foreach ($path in $paths) {
    $name = [IO.Path]::GetFileNameWithoutExtension($path)
    $problems = [System.Collections.Generic.List[string]]::new()
    try {
        $v = [Newtonsoft.Json.Linq.JToken]::Parse([IO.File]::ReadAllText($path))
        $model = New-ConsoleModel ([int]$v['cols']) ([int]$v['rows'])
        $snap = $null
        foreach ($s in $v['steps']) { Invoke-Step $model $s ([ref]$snap) }
        $cols = $model.GetCols(); $rows = $model.GetRows()
        $frame = New-ConsoleFrame $model
        $cursor = $model.Compose($frame)
        foreach ($c in $v['expect']['cells']) {
            $e = @(foreach ($x in $c) { [int]$x })
            $i = ($e[0] * $cols + $e[1]) * 3
            $w0 = $frame[$i]; $w1 = $frame[$i + 1]; $w2 = $frame[$i + 2]
            $fm = ($w1 -shr 24) -band 3; $bm = ($w2 -shr 24) -band 3
            $got = @(($w0 -band 0x1fffff), (($w0 -shr 21) -band 3), (($w0 -shr 23) -band 0x3f), $fm,
                $(if ($fm -eq 1) { $w1 -band 0xff } else { $w1 -band 0xffffff }), $bm,
                $(if ($bm -eq 1) { $w2 -band 0xff } else { $w2 -band 0xffffff }))
            if (($got -join ',') -ne ($e[2..8] -join ',')) { $problems.Add("cell r$($e[0])c$($e[1]) got [$($got -join ',')] want [$($e[2..8] -join ',')]") }
        }
        $ec = $v['expect']['cursor']
        $want = "$([int]$ec[0]),$([int]$ec[1]),$([bool]$ec[2].Value)"; $have = "$($cursor.Col),$($cursor.Row),$($cursor.Visible)"
        if ($want -ne $have) { $problems.Add("cursor got $have want $want") }
        $expOps = Get-Field $v['expect'] 'ops'
        if ($null -ne $expOps) {
            $ops = Compare-ConsoleFrame -Previous $snap -Next $frame -Columns $cols -Rows $rows
            $gotOps = @(foreach ($o in $ops) { Format-Op $o.Kind $o.Row $o.Col $o['Count'] $o['Bg'] $o['Text'] $o['Cells'] $o['Fg'] $o['Attrs'] }) -join ' | '
            $wantOps = @(foreach ($o in $expOps) { Format-Op ([string]$o['kind']) ([int]$o['row']) ([int]$o['col']) (Get-Field $o 'count') (Get-Field $o 'bg') (Get-Field $o 'text') (Get-Field $o 'cells') (Get-Field $o 'fg') (Get-Field $o 'attrs') }) -join ' | '
            if ($gotOps -ne $wantOps) { $problems.Add("ops got [$gotOps] want [$wantOps]") }
        }
    }
    catch { $problems.Add("threw $($_.Exception.GetType().Name): $($_.Exception.Message)") }
    if ($problems.Count) { $fail++; Write-AndroidLog ("CONSOLE FAIL ${name}: " + ($problems -join '; ')) 6 } else { $pass++ }
}
Write-AndroidLog "CONSOLE PASS $pass FAIL $fail"
