<#
.SYNOPSIS
    Regenerates the width tables in modules/Console.psm1 from the pinned
    Unicode 16.0.0 files (docs/console-reference.md).

.DESCRIPTION
    Wide: East_Asian_Width W or F, from explicit entries in EastAsianWidth.txt.
    Zero: general categories Mn, Me and Cf in UnicodeData.txt (First/Last
    ranges included), plus U+200B. Both files are verified by SHA-256 before
    use. The tables are written between the generated-region markers.
#>
param([string] $ModulePath = (Join-Path $PSScriptRoot '..\modules\Console.psm1'))
$ErrorActionPreference = 'Stop'
$pins = @(
    @{ Url = 'https://www.unicode.org/Public/16.0.0/ucd/EastAsianWidth.txt'; Sha256 = '43ADC76C0686A42CB370764EB8CFE2B2A45B10B855E5572A2DB4A0EECCE15D5B' },
    @{ Url = 'https://www.unicode.org/Public/16.0.0/ucd/UnicodeData.txt'; Sha256 = 'FF58E5823BD095166564A006E47D111130813DCF8BF234EF79FA51A870EDB48F' })
$text = foreach ($p in $pins) {
    $bytes = (Invoke-WebRequest -Uri $p.Url -UseBasicParsing).RawContentStream.ToArray()
    $digest = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes))
    if ($digest -ne $p.Sha256) { throw "$($p.Url): SHA-256 $digest does not match the pin $($p.Sha256)." }
    [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Merge-Ranges([System.Collections.Generic.List[int[]]] $ranges) {
    $sorted = @($ranges | Sort-Object { $_[0] })
    $out = [System.Collections.Generic.List[int[]]]::new()
    foreach ($r in $sorted) {
        if ($out.Count -gt 0 -and $r[0] -le $out[$out.Count - 1][1] + 1) { $out[$out.Count - 1][1] = [Math]::Max($out[$out.Count - 1][1], $r[1]) }
        else { $out.Add(@($r[0], $r[1])) }
    }
    , $out
}

$wide = [System.Collections.Generic.List[int[]]]::new()
foreach ($line in $text[0] -split "`n") {
    $body = ($line -split '#', 2)[0].Trim()
    if (-not $body) { continue }
    $f = $body -split ';'
    if ($f.Count -lt 2 -or $f[1].Trim() -notin 'W', 'F') { continue }
    $range = $f[0].Trim() -split '\.\.'
    $a = [Convert]::ToInt32($range[0], 16); $b = if ($range.Count -gt 1) { [Convert]::ToInt32($range[1], 16) } else { $a }
    $wide.Add(@($a, $b))
}

$zero = [System.Collections.Generic.List[int[]]]::new()
$first = $null
foreach ($line in $text[1] -split "`n") {
    if (-not $line.Trim()) { continue }
    $f = $line -split ';'
    $cp = [Convert]::ToInt32($f[0], 16); $name = $f[1]; $cat = $f[2]
    if ($name.EndsWith(', First>')) { $first = @($cp, $cat); continue }
    if ($name.EndsWith(', Last>')) { if ($first[1] -in 'Mn', 'Me', 'Cf') { $zero.Add(@($first[0], $cp)) }; $first = $null; continue }
    if ($cat -in 'Mn', 'Me', 'Cf') { $zero.Add(@($cp, $cp)) }
}
$zero.Add(@(0x200B, 0x200B))

$w = Merge-Ranges $wide; $z = Merge-Ranges $zero
function Format-Table([System.Collections.Generic.List[int[]]] $r) {
    $items = foreach ($x in $r) { '0x{0:X},0x{1:X}' -f $x[0], $x[1] }
    $lines = for ($i = 0; $i -lt $items.Count; $i += 8) { '        ' + (($items[$i..([Math]::Min($i + 7, $items.Count - 1))]) -join ', ') }
    "@(`n" + ($lines -join ",`n") + ")"
}
$region = @"
    # region generated width tables (tools/Update-ConsoleWidthTable.ps1; do not edit)
    # EastAsianWidth.txt 16.0.0 SHA-256 $($pins[0].Sha256): $($w.Count) wide ranges.
    # UnicodeData.txt 16.0.0 SHA-256 $($pins[1].Sha256): $($z.Count) zero-width ranges.
    static [int[]] `$Wide = $(Format-Table $w)
    static [int[]] `$Zero = $(Format-Table $z)
    # endregion generated width tables
"@
$path = (Resolve-Path $ModulePath).Path
$src = [System.IO.File]::ReadAllText($path)
$start = $src.IndexOf('    # region generated width tables'); $endMarker = '# endregion generated width tables'
$end = $src.IndexOf($endMarker, $start)
if ($start -lt 0 -or $end -lt 0) { throw 'Generated-region markers not found.' }
$src = $src.Substring(0, $start) + $region + $src.Substring($end + $endMarker.Length)
[System.IO.File]::WriteAllText($path, $src, [System.Text.UTF8Encoding]::new($false))
"wide ranges $($w.Count), zero-width ranges $($z.Count)"
